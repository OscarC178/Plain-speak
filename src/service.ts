import { mkdir, chmod } from 'node:fs/promises';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { z } from 'zod';
import { resolve, type Capture, type Resolved } from './rules';
import { catalogue, loadSettings, saveSettings, SettingsError, toRulesFile } from './settings';

const input = z.object({
  app: z.string().max(200), title: z.string().max(2000), mode: z.enum(['read', 'correct', 'draft']),
  text: z.string().max(40000).optional(), image_base64: z.string().max(8_000_000).optional(),
  context: z.boolean().optional(),
  pointer: z.object({ x: z.number().min(0).max(1), y: z.number().min(0).max(1), marked: z.boolean().optional() }).strict().optional(),
}).strict().refine(v => v.text?.trim() || v.image_base64, 'Capture needs text or a PNG');
/** One capture handed to an engine. Each engine builds its own prompt from it. */
export type Job = { cap: Capture & { context?: boolean }; rules: Resolved; image?: Buffer };
export type Result = { request_id: string; state: 'pending' | 'done' | 'error'; mode: string; text?: string; created: number };

/** Loopback service: an owner-only token also blocks requests from arbitrary web pages. */
export async function createService(root: string, notify: (id: string, job: Job) => Promise<void>, port = 8790, local = join(root, '.local')) {
  await mkdir(local, { recursive: true, mode: 0o700 });
  await chmod(local, 0o700);
  const tokenPath = join(local, 'token');
  let token: string;
  if (await Bun.file(tokenPath).exists()) token = (await Bun.file(tokenPath).text()).trim();
  else { token = randomBytes(32).toString('hex'); await Bun.write(tokenPath, token); }
  await chmod(tokenPath, 0o600);
  // Results stay in memory for ten minutes. Screenshots are never written to disk.
  const pending = new Map<string, Result>();
  const clean = setInterval(() => {
    for (const [id, item] of pending) {
      if (Date.now() - item.created > 120000 && item.state === 'pending') {
        item.state = 'error'; item.text = 'Claude did not respond within two minutes. Open the log from the Plainspeak menu, or check your usage limit.';
      }
      if (Date.now() - item.created > 600000) pending.delete(id);
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
      // The panel and the settings window are pages; their credentials arrive in the URL fragment.
      const page = { '/overlay': 'src/overlay.html', '/settings-page': 'src/settings.html' }[url.pathname];
      if (req.method === 'GET' && page) {
        return new Response(await Bun.file(join(root, page)).text(), { headers: { ...headers, 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" } });
      }
      if (req.headers.get('authorization') !== `Bearer ${token}`) return json({ error: 'Unauthorised' }, 401);
      try {
        if (req.method === 'GET' && url.pathname.startsWith('/result/')) {
          const item = pending.get(url.pathname.slice(8));
          if (!item) return json({ error: 'Unknown or expired request' }, 404);
          return json(item);
        }
        if (url.pathname === '/settings') {
          if (req.method === 'GET') { const settings = await loadSettings(local); return json({ settings, styles: catalogue(settings) }); }
          if (req.method !== 'PUT') return json({ error: 'Not found' }, 404);
          if (!(req.headers.get('content-type') ?? '').startsWith('application/json')) return json({ error: 'Expected JSON' }, 415);
          const body = await req.text();
          if (body.length > 200_000) return json({ error: 'Settings too large' }, 413);
          try { const settings = await saveSettings(local, JSON.parse(body)); return json({ settings, styles: catalogue(settings) }); }
          catch (e) { return json({ error: e instanceof SettingsError ? e.message : 'Settings were not valid JSON' }, 400); }
        }
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
        const rules = resolve(toRulesFile(await loadSettings(local)), cap);
        const id = crypto.randomUUID();
        const item: Result = { request_id: id, state: 'pending', mode: cap.mode, created: Date.now() };
        let bytes: Buffer | undefined;
        if (cap.image_base64) {
          if (!/^[A-Za-z0-9+/]+={0,2}$/.test(cap.image_base64)) return json({ error: 'Invalid base64 PNG' }, 400);
          bytes = Buffer.from(cap.image_base64, 'base64');
          if (!bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) return json({ error: 'Expected PNG screenshot' }, 400);
        }
        pending.set(id, item);
        const { image_base64, ...fields } = cap;
        try { await notify(id, { cap: { ...fields, image: Boolean(bytes) }, rules, image: bytes }); }
        catch { pending.delete(id); return json({ error: 'Claude is not available' }, 503); }
        return json({ request_id: id }, 202);
      } catch (e) { return json({ error: e instanceof Error ? e.message : 'Invalid request' }, 400); }
    },
  });
  return {
    server, token,
    async show(id: string, text: string) {
      const item = pending.get(id); if (!item || item.state !== 'pending') throw new Error('Request is unknown, expired or already complete');
      item.text = text; item.state = 'done';
    },
    /** Partial text while Claude is still writing; the overlay shows it as it grows. */
    progress(id: string, text: string) { const item = pending.get(id); if (item?.state === 'pending') item.text = text; },
    async fail(id: string, message: string) {
      const item = pending.get(id); if (!item || item.state !== 'pending') return;
      item.text = message; item.state = 'error';
    },
    async close() { clearInterval(clean); server.stop(true); },
  };
}
