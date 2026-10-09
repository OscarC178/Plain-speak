import { test, expect } from 'bun:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

/** Exercise the real stdio entrypoint without spending any model usage. */
test('stdio MCP advertises channel and tools, validates unknown requests', async () => {
  const transport = new StdioClientTransport({ command: 'bun', args: ['src/server.ts'], env: { ...process.env, PLAINSPEAK_PORT: '18790', PLAINSPEAK_HOME: mkdtempSync(join(tmpdir(), 'plainspeak-mcp-')) } as Record<string,string>, stderr: 'pipe' });
  const client = new Client({ name: 'plainspeak-smoke', version: '1.0' });
  try {
    await client.connect(transport);
    expect(client.getServerCapabilities()?.experimental?.['claude/channel']).toEqual({});
    const { tools } = await client.listTools();
    expect(tools.map(t=>t.name)).toContain('capture_image');
    expect(tools.map(t=>t.name)).toContain('show');
    const result = await client.callTool({name:'show',arguments:{request_id:crypto.randomUUID(),text:'No pending capture'}});
    expect(result.isError).toBe(true);
  } finally { await client.close(); }
});
