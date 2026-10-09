import { realpath } from 'node:fs/promises';
import { resolve, relative, basename, sep, isAbsolute } from 'node:path';

/** Constrain reads to markdown inside the configured vault, including symlink targets. */
export async function vaultNote(root: string, path: string) {
  if (isAbsolute(path) || path.split(/[\\/]/).includes('..') || !path.endsWith('.md')) throw new Error('Use a relative markdown note path');
  const base = await realpath(root), target = await realpath(resolve(base, path));
  const rel = relative(base, target);
  if (rel.startsWith('..' + sep) || rel === '..' || isAbsolute(rel)) throw new Error('Note is outside the vault');
  const file = Bun.file(target);
  if (file.size > 1_000_000) throw new Error('Note is too large');
  const text = await file.text();
  return { path: rel, title: basename(rel, '.md'), link: `obsidian://open?vault=${encodeURIComponent(basename(base))}&file=${encodeURIComponent(rel)}`, text: text.slice(0, 16000), truncated: text.length > 16000 };
}

/** Local search is read-only; return small excerpts before fetching whole notes. */
export async function searchVault(root: string, query: string) {
  const words = query.toLowerCase().split(/\s+/).filter(w => w.length > 1);
  if (!words.length) throw new Error('Search needs a word of at least two characters');
  const base = await realpath(root);
  const results: Array<{ path: string; title: string; link: string; excerpt: string; score: number }> = [];
  let scanned = 0, capped = false;
  for await (const path of new Bun.Glob('**/*.md').scan({ cwd: base, onlyFiles: true, followSymlinks: false })) {
    if (path.split(/[\\/]/).some(p => p.startsWith('.'))) continue;
    if (++scanned > 4000) { capped = true; break; }
    try {
      const note = await vaultNote(base, path);
      const lower = note.text.toLowerCase(), title = note.title.toLowerCase();
      const hits = words.filter(w => lower.includes(w) || title.includes(w));
      if (!hits.length) continue;
      const offset = Math.max(0, lower.indexOf(hits[0]) - 150);
      results.push({ path, title: note.title, link: note.link, excerpt: note.text.slice(offset, offset + 900), score: hits.length + words.filter(w=>title.includes(w)).length * 3 });
    } catch { /* Skip unreadable notes and links outside the vault; no source is modified. */ }
  }
  results.sort((a,b)=>b.score-a.score || a.path.localeCompare(b.path));
  return { results: results.slice(0,8), scanned, capped, note: 'Search examines the first 16,000 characters per note; results are excerpts, not a complete vault audit.' };
}
