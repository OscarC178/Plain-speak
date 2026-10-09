import { test, expect } from 'bun:test';
import type { SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { createEngine, onlyContextTools, CONTEXT_TOOLS, type Sink } from './engine';

/** Stand-in for the SDK's query(): answers each user turn with scripted events. No model usage. */
function fakeQuery(answer: (turn: string, hasImage: boolean) => unknown[]) {
  const sessions: string[][] = [], options: Record<string, unknown>[] = [];
  const query = ({ prompt, options: o }: { prompt: AsyncIterable<SDKUserMessage>; options: Record<string, unknown> }) => (async function* () {
    const seen: string[] = []; sessions.push(seen); options.push(o);
    for await (const m of prompt) {
      const c = m.message.content;
      const text = typeof c === 'string' ? c : (c[0] as { text: string }).text;
      seen.push(text);
      yield* answer(text, typeof c !== 'string' && c.some(b => b.type === 'image'));
    }
  })();
  return { query: query as never, sessions, options };
}
const delta = (text: string) => ({ type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } } });
const result = (text: string, is_error = false) => ({ type: 'result', subtype: 'success', result: text, is_error });

function recorder() {
  const log: string[] = [];
  let settle = () => {};
  const sink: Sink = {
    progress: (id, text) => { log.push(`progress ${id} ${text}`); },
    done: async (id, text) => { log.push(`done ${id} ${text}`); settle(); },
    fail: async (id, message) => { log.push(`fail ${id} ${message}`); settle(); },
  };
  const next = () => new Promise<void>(r => { settle = r; });
  return { log, sink, next };
}
const options = { model: 'claude-haiku-5-5', effort: 'medium' as const, system: 'test', cwd: '/tmp' };

test('warm-up is hidden, answers stream as progress, and the screenshot travels with the turn', async () => {
  const fake = fakeQuery((turn, hasImage) => turn.startsWith('Session start') ? [delta('Ready'), result('Ready')] : [delta('The point: '), delta(hasImage ? 'pictured' : 'text'), result('The point: final')]);
  const r = recorder();
  const engine = createEngine(options, r.sink, fake.query);
  engine.start();
  let next = r.next(); await engine.submit('a', 'capture one', Buffer.from('png')); await next;
  next = r.next(); await engine.submit('b', 'capture two'); await next;
  expect(r.log).toEqual(['progress a The point: ', 'progress a The point: pictured', 'done a The point: final', 'progress b The point: ', 'progress b The point: text', 'done b The point: final']);
  expect(fake.sessions).toHaveLength(1);
  engine.close();
});

test('a session is replaced after recycleAfter captures', async () => {
  const fake = fakeQuery(() => [result('ok')]);
  const r = recorder();
  const engine = createEngine({ ...options, recycleAfter: 2 }, r.sink, fake.query);
  for (const id of ['a', 'b', 'c']) { const next = r.next(); await engine.submit(id, `capture ${id}`); await next; }
  expect(fake.sessions.map(s => s.length)).toEqual([3, 2]); // warm-up + 2 captures, then warm-up + 1
  expect(fake.sessions[1][0]).toStartWith('Session start');
  engine.close();
});

test('errors and a crashed session reach the panel, and the next capture gets a fresh session', async () => {
  const fake = fakeQuery(turn => {
    if (turn === 'bad') return [result('Not logged in · Please run /login', true)];
    if (turn === 'crash') throw new Error('process exited');
    return [result('ok')];
  });
  const r = recorder();
  const engine = createEngine(options, r.sink, fake.query);
  let next = r.next(); await engine.submit('a', 'bad'); await next;
  next = r.next(); await engine.submit('b', 'crash'); await next;
  next = r.next(); await engine.submit('c', 'fine'); await next;
  expect(r.log).toEqual([
    'fail a Claude could not finish this capture: Not logged in · Please run /login',
    'fail b The Claude session stopped before answering. Try again.',
    'done c ok',
  ]);
  expect(fake.sessions).toHaveLength(2);
  engine.close();
});

test('context lookups run in their own read-only session and never touch the warm one', async () => {
  const fake = fakeQuery(turn => turn.startsWith('Session start') ? [result('Ready')] : [delta('Searching'), { type: 'stream_event', event: { type: 'message_start' } }, delta('Found: note'), result('Found: note')]);
  const r = recorder();
  const engine = createEngine(options, r.sink, fake.query);
  engine.start();
  const next = r.next(); await engine.submit('a', 'context capture', undefined, true); await next;
  expect(r.log).toEqual(['progress a Searching', 'progress a Found: note', 'done a Found: note']); // earlier step text is replaced
  expect(fake.sessions).toEqual([['Session start check: reply with the single word Ready.'], ['context capture']]);
  expect(fake.options[1]).toMatchObject({ settingSources: ['user'], permissionMode: 'dontAsk', allowedTools: CONTEXT_TOOLS, tools: [] });
  expect(fake.options[0]).toMatchObject({ settingSources: [], strictMcpConfig: true, tools: [] });
  engine.close();
});

test('the context hook denies every tool outside the read-only list, whatever the user settings allow', async () => {
  const ask = (tool_name: string) => onlyContextTools({ hook_event_name: 'PreToolUse', tool_name, tool_input: {}, tool_use_id: 't', session_id: 's', transcript_path: '', cwd: '' } as never, 't', { signal: new AbortController().signal });
  for (const blocked of ['mcp__claude_ai_Gmail__send_message', 'mcp__plugin_slack_slack__slack_send_message', 'mcp__claude_ai_Google_Drive__share_file', 'mcp__claude_ai_Google_Drive__trash_file', 'Bash', 'Write'])
    expect(await ask(blocked)).toMatchObject({ hookSpecificOutput: { permissionDecision: 'deny' } });
  for (const allowed of ['mcp__plainspeak__vault_search', 'mcp__claude_ai_Google_Drive__search_files', 'mcp__claude_ai_Google_Drive__read_file_content'])
    expect(await ask(allowed)).toEqual({});
});
