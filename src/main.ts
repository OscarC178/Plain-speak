// Plainspeak on the Agent SDK: the local service plus one warm Claude session.
// Start with `bun run start`. No tmux, no channels and no first-run prompts.
import { resolve } from 'node:path';
import { createSdkMcpServer, tool, type McpServerConfig, type Options } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod/v4'; // the SDK's tool() takes zod 4 schemas
import { createService } from './service';
import { createEngine } from './engine';
import { buildTurn, SDK_SYSTEM } from './prompt';
import { stateHome } from './paths';
import { searchVault, vaultNote } from './vault';

const root = resolve(import.meta.dir, '..');
const state = stateHome();
const port = Number(process.env.PLAINSPEAK_PORT ?? 8790);
// Haiku 5.5 at high effort by default: the warm session leaves time to spare. Override per run.
const model = process.env.PLAINSPEAK_MODEL ?? 'claude-haiku-5-5';
const effort = (process.env.PLAINSPEAK_EFFORT ?? 'high') as Options['effort'];
const log = (line: string) => console.log(`${new Date().toLocaleTimeString('en-GB')} ${line}`);

// Read-only Obsidian tools for context lookups, when ~/.plainspeak/config.json names a vault.
const configFile = Bun.file(resolve(state, 'config.json'));
const vault = await configFile.exists() ? (await configFile.json()).vault : undefined;
const json = (value: unknown) => ({ content: [{ type: 'text' as const, text: JSON.stringify(value) }] });
const contextServers: Record<string, McpServerConfig> = typeof vault === 'string' ? { plainspeak: createSdkMcpServer({ name: 'plainspeak', tools: [
  tool('vault_search', 'Read-only search of the owner configured Obsidian vault. Returns note paths, links and excerpts.', { query: z.string().min(2).max(200) }, async ({ query }) => json(await searchVault(vault, query)), { annotations: { readOnlyHint: true } }),
  tool('vault_note', 'Read a markdown note inside the owner configured vault. Cannot write or read outside it.', { path: z.string().min(1).max(1000) }, async ({ path }) => json(await vaultNote(vault, path)), { annotations: { readOnlyHint: true } }),
] }) } : {};

let service: Awaited<ReturnType<typeof createService>>;
const engine = createEngine({ model, effort, system: SDK_SYSTEM, cwd: state, log, contextServers }, {
  progress: (id, text) => service.progress(id, text),
  done: (id, text) => service.show(id, text),
  fail: (id, message) => service.fail(id, message),
});
try {
  service = await createService(root, async (id, job) => engine.submit(id, buildTurn(job.cap, job.rules), job.image, job.cap.context), port, state);
} catch (e) {
  if ((e as { code?: string }).code !== 'EADDRINUSE') throw e;
  console.error(`Port ${port} is already in use. If the old tmux daemon is running, stop it with: bun run daemon:stop`);
  process.exit(1);
}
engine.start();
log(`Plainspeak listening on http://127.0.0.1:${service.server.port} (${model}, ${effort} effort${vault ? ', Obsidian vault connected' : ''}). Control+C stops it.`);

for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { engine.close(); void service.close().then(() => process.exit(0)); });
