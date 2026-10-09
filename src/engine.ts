import { query as sdkQuery, type HookCallback, type McpServerConfig, type Options, type SDKMessage, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';

/**
 * Agent SDK engine: one warm Claude session, one capture per turn, answers streamed back.
 *
 * Each new session first answers a short warm-up turn, so the first real capture does
 * not wait for start-up. After `recycleAfter` captures the session is replaced, which
 * keeps its context, and so each capture's time and usage, small. The next session
 * warms up straight away in the background.
 */
export type Sink = {
  progress(id: string, text: string): void;
  done(id: string, text: string): Promise<void>;
  fail(id: string, message: string): Promise<void>;
};
export type EngineOptions = {
  model: string; effort: Options['effort']; system: string; cwd: string;
  recycleAfter?: number; log?: (line: string) => void;
  /** The Claude binary shipped inside Plainspeak.app; the SDK finds its own copy otherwise. */
  claudePath?: string;
  /** In-process tools for context lookups, such as the Obsidian vault search. */
  contextServers?: Record<string, McpServerConfig>;
};

/** The only tools a context lookup may run: Obsidian reads and Google Drive's read-only tools. */
export const CONTEXT_TOOLS = [
  'mcp__plainspeak__vault_search', 'mcp__plainspeak__vault_note',
  'mcp__claude_ai_Google_Drive__search_files', 'mcp__claude_ai_Google_Drive__read_file_content',
  'mcp__claude_ai_Google_Drive__get_file_metadata', 'mcp__claude_ai_Google_Drive__list_recent_files',
  'mcp__claude_ai_Google_Drive__download_file_content',
];
/** Hooks run before allow rules, so no rule in the user's own settings can let a send, write or share through. */
export const onlyContextTools: HookCallback = async input => input.hook_event_name !== 'PreToolUse' || CONTEXT_TOOLS.includes(input.tool_name) ? {}
  : { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: 'Plainspeak context lookups may only read Obsidian notes and Google Drive.' } };

const WARM_UP = 'Session start check: reply with the single word Ready.';
// Run on the signed-in Claude subscription, never on inherited API or cloud credentials.
const CREDENTIALS = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'];

function userTurn(text: string, image?: Buffer): SDKUserMessage {
  return { type: 'user', parent_tool_use_id: null, message: { role: 'user', content: image
    ? [{ type: 'text', text }, { type: 'image', source: { type: 'base64', media_type: 'image/png', data: image.toString('base64') } }]
    : text } };
}

type Session = {
  push(m?: SDKUserMessage): void; end(): void;
  /** Requests in the order their results will arrive; null is the warm-up turn. */
  turns: Array<{ id: string; sent: number } | null>;
  uses: number; dead: boolean; text: string;
};

export function createEngine(o: EngineOptions, sink: Sink, query = sdkQuery) {
  const env: Record<string, string | undefined> = { ...process.env };
  for (const key of CREDENTIALS) delete env[key];
  const quiet = (p: Promise<void>) => { p.catch(() => {}); }; // the request may already have expired
  let session: Session | undefined;

  function open(): Session {
    const queue: SDKUserMessage[] = [];
    let wake: (() => void) | undefined, ending = false;
    async function* input() {
      while (true) {
        while (queue.length) yield queue.shift()!;
        if (ending) return;
        await new Promise<void>(r => { wake = r; });
      }
    }
    const s: Session = {
      push(m) { if (m) queue.push(m); const w = wake; wake = undefined; w?.(); },
      end() { ending = true; s.push(); },
      turns: [null], uses: 0, dead: false, text: '',
    };
    const q = query({ prompt: input(), options: {
      model: o.model, effort: o.effort, systemPrompt: o.system,
      // No built-in tools, and nothing from disk (settings, CLAUDE.md, MCP servers): only what Plainspeak passes.
      tools: [], settingSources: [], mcpServers: {}, strictMcpConfig: true,
      includePartialMessages: true, persistSession: false, cwd: o.cwd, env, pathToClaudeCodeExecutable: o.claudePath,
    } });
    s.push(userTurn(WARM_UP));
    void (async () => {
      try { for await (const m of q) handle(s, m); }
      catch (e) { o.log?.(`Claude session failed: ${e instanceof Error ? e.message : String(e)}`); }
      s.dead = true;
      // Anything still queued on this session will never be answered.
      for (const turn of s.turns.splice(0)) if (turn) quiet(sink.fail(turn.id, 'The Claude session stopped before answering. Try again.'));
      if (session === s) session = undefined;
    })();
    return s;
  }

  function handle(s: Session, m: SDKMessage) {
    const turn = s.turns[0];
    if (m.type === 'stream_event') {
      if (m.event.type === 'message_start') s.text = ''; // show only the reply being written, not earlier steps
      if (turn && m.event.type === 'content_block_delta' && m.event.delta.type === 'text_delta') {
        s.text += m.event.delta.text;
        sink.progress(turn.id, s.text);
      }
      return;
    }
    if (m.type !== 'result') return;
    s.turns.shift(); s.text = '';
    const failed = m.subtype !== 'success' || m.is_error;
    const detail = m.subtype === 'success' ? m.result : m.subtype;
    if (!turn) { o.log?.(failed ? `Claude session could not start: ${detail}` : 'Claude session ready.'); return; }
    o.log?.(`Answered in ${((performance.now() - turn.sent) / 1000).toFixed(1)}s`);
    if (failed) quiet(sink.fail(turn.id, `Claude could not finish this capture: ${detail}`));
    else quiet(sink.done(turn.id, detail.trim() || 'Claude returned no text.'));
    if (++s.uses >= (o.recycleAfter ?? 15)) { s.end(); if (session === s) session = open(); }
  }

  /**
   * Context lookups are rare and slow anyway, so each gets its own short session. It loads the
   * user's settings, which is what brings in the claude.ai Google Drive connector, and can only
   * run CONTEXT_TOOLS.
   */
  async function lookup(id: string, text: string, image?: Buffer) {
    const sent = performance.now(), used: string[] = []; let partial = '';
    async function* input() { yield userTurn(text, image); }
    try {
      for await (const m of query({ prompt: input(), options: {
        model: o.model, effort: o.effort, systemPrompt: o.system, tools: [],
        settingSources: ['user'], mcpServers: o.contextServers ?? {},
        permissionMode: 'dontAsk', allowedTools: CONTEXT_TOOLS, hooks: { PreToolUse: [{ hooks: [onlyContextTools] }] },
        maxTurns: 12, includePartialMessages: true, persistSession: false, cwd: o.cwd, env, pathToClaudeCodeExecutable: o.claudePath,
      } })) {
        if (m.type === 'assistant') for (const b of m.message.content) { if (b.type === 'tool_use') used.push(b.name.replace(/^mcp__/, '')); }
        if (m.type === 'stream_event' && m.event.type === 'message_start') partial = '';
        else if (m.type === 'stream_event' && m.event.type === 'content_block_delta' && m.event.delta.type === 'text_delta') { partial += m.event.delta.text; sink.progress(id, partial); }
        else if (m.type === 'result') {
          o.log?.(`Context answer in ${((performance.now() - sent) / 1000).toFixed(1)}s (tools: ${used.join(', ') || 'none'})`);
          if (m.subtype === 'success' && !m.is_error) quiet(sink.done(id, m.result.trim() || 'Claude returned no text.'));
          else quiet(sink.fail(id, `Claude could not finish this lookup: ${m.subtype === 'success' ? m.result : m.subtype}`));
          return;
        }
      }
      quiet(sink.fail(id, 'The Claude session stopped before answering. Try again.'));
    } catch (e) { quiet(sink.fail(id, `Claude could not finish this lookup: ${e instanceof Error ? e.message : String(e)}`)); }
  }

  return {
    /** Open and warm a session now, so the first capture does not wait for it. */
    start() { if (!session || session.dead) session = open(); },
    async submit(id: string, text: string, image?: Buffer, context = false) {
      if (context) { void lookup(id, text, image); return; }
      if (!session || session.dead) session = open();
      session.turns.push({ id, sent: performance.now() });
      session.push(userTurn(text, image));
    },
    close() { session?.end(); session = undefined; },
  };
}
