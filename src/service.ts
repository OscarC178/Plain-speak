import { mkdir, chmod, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { z } from 'zod';
import { loadRules, resolve, type Capture } from './rules';
import { buildPrompt } from './prompt';
import { rulesFile } from './paths';

const input = z.object({
  app: z.string().max(200), title: z.string().max(2000), mode: z.enum(['read', 'correct', 'draft']),
  text: z.string().max(40000).optional(), image_base64: z.string().max(8_000_000).optional(),
  context: z.boolean().optional(),
}).strict().refine(v => v.text?.trim() || v.image_base64, 'Capture needs text or a PNG');
export type Result = { request_id: string; state: 'pending' | 'done' | 'error'; mode: string; text?: string; created: number };

/** Loopback service: an owner-only token also blocks requests from arbitrary web pages. */
export async function createService(root: string, notify: (id: string, prompt: string) => Promise<void>, port = 8790, local = join(root, '.local')) {
  await mkdir(local, { recursive: true, mode: 0o700 });
  await chmod(local, 0o700);
  const tokenPath = join(local, 'token');
  let token: string;
  if (await Bun.file(tokenPath).exists()) token = (await Bun.file(tokenPath).text()).trim();
  else { token = randomBytes(32).toString('hex'); await Bun.write(tokenPath, token); }
  await chmod(tokenPath, 0o600);
  const pending = new Map<string, Result & { image?: string }>();
  const rulesPath = await rulesFile(root, local);
  // Reload each request: a malformed edit rejects the request instead of silently using stale rules.
  await loadRules(rulesPath);
  const removeImage = async (item: { image?: string }) => { if (item.image) { await unlink(item.image).catch(() => {}); item.image = undefined; } };
  const clean = setInterval(() => {
    for (const [id, item] of pending) {
      if (Date.now() - item.created > 120000 && item.state === 'pending') {
        item.state = 'error'; item.text = 'Claude did not respond within two minutes. Attach to the session to check permissions or usage.'; void removeImage(item);
      }
      if (Date.now() - item.created > 600000) { void removeImage(item); pending.delete(id); }
    }
  }, 5000);
  const server = Bun.serve({
    hostname: '127.0.0.1', port,
    async fetch(req) {
      const url = new URL(req.url);
      const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
      const json = (v: unknown, status = 200) => Response.json(v, { status, headers });
      if (req.headers.get('host') !== `127.0.0.1:${server.port}`) return json({ error: 'Invalid host' }, 403);
      const origin = req.headers.get('origin');
      if (origin && origin !== `http://127.0.0.1:${server.port}`) return json({ error: 'Invalid origin' }, 403);
      if (req.method === 'GET' && url.pathname === '/health') return json({ service: 'plainspeak', transport: 'connected', pending: [...pending.values()].filter(v => v.state === 'pending').length });
      if (req.method === 'GET' && url.pathname === '/overlay') {
        return new Response(await Bun.file(join(root, 'src/overlay.html')).text(), { headers: { ...headers, 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" } });
      }
      if (req.headers.get('authorization') !== `Bearer ${token}`) return json({ error: 'Unauthorised' }, 401);
      try {
        if (req.method === 'GET' && url.pathname.startsWith('/result/')) {
          const item = pending.get(url.pathname.slice(8));
          if (!item) return json({ error: 'Unknown or expired request' }, 404);
          const { image, ...publicItem } = item; return json(publicItem);
        }
        if (req.method === 'GET' && url.pathname === '/rules') return json(resolve(await loadRules(rulesPath), { app: url.searchParams.get('app') ?? '', title: url.searchParams.get('title') ?? '', mode: 'read' }));
        if (req.method !== 'POST' || url.pathname !== '/capture') return json({ error: 'Not found' }, 404);
        if (Number(req.headers.get('content-length')) > 8_100_000) return json({ error: 'Capture too large' }, 413);
        if (!(req.headers.get('content-type') ?? '').startsWith('application/json')) return json({ error: 'Expected JSON' }, 415);
        // Bound streaming bodies too; Content-Length alone is not sufficient.
        const reader = req.body?.getReader(); if (!reader) return json({ error: 'Missing body' }, 400);
        const chunks: Uint8Array[] = []; let size = 0;
        while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; if (size > 8_100_000) { await reader.cancel(); return json({ error: 'Capture too large' }, 413); } chunks.push(value); }
        const cap = input.parse(JSON.parse(Buffer.concat(chunks).toString()));
        if ([...pending.values()].some(v => v.state === 'pending')) return json({ error: 'A capture is already processing. Wait for its result.' }, 429);
        if (cap.mode === 'draft' && !cap.text?.trim()) return json({ error: 'Select your own draft text before using the draft hotkey.' }, 400);
        const rules = resolve(await loadRules(rulesPath), cap);
        const id = crypto.randomUUID();
        const item: Result & { image?: string } = { request_id: id, state: 'pending', mode: cap.mode, created: Date.now() };
        if (cap.image_base64) {
          if (!/^[A-Za-z0-9+/]+={0,2}$/.test(cap.image_base64)) return json({ error: 'Invalid base64 PNG' }, 400);
          const bytes = Buffer.from(cap.image_base64, 'base64');
          if (!bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) return json({ error: 'Expected PNG screenshot' }, 400);
          item.image = join(local, `${id}.png`); await Bun.write(item.image, bytes); await chmod(item.image, 0o600);
        }
        pending.set(id, item);
        try { await notify(id, buildPrompt(id, { ...cap, image: item.image } as Capture, rules)); }
        catch { pending.delete(id); await removeImage(item); return json({ error: 'Claude transport unavailable' }, 503); }
        return json({ request_id: id }, 202);
      } catch (e) { return json({ error: e instanceof Error ? e.message : 'Invalid request' }, 400); }
    },
  });
  return {
    server, token,
    async image(id: string) { const item = pending.get(id); if (!item?.image || item.state !== 'pending') throw new Error('No active screenshot'); return (await Bun.file(item.image).arrayBuffer()); },
    async show(id: string, text: string) {
      const item = pending.get(id); if (!item || item.state !== 'pending') throw new Error('Request is unknown, expired or already complete');
      item.text = text; item.state = 'done'; await removeImage(item);
    },
    async close() { clearInterval(clean); server.stop(true); await Promise.all([...pending.values()].map(removeImage)); },
  };
}
