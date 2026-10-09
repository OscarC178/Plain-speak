import { test, expect } from 'bun:test';
import { mkdtemp, mkdir, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { searchVault, vaultNote } from './vault';
test('vault search returns cited excerpts; note reads reject traversal and escaping symlinks',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'plainspeak-vault-'));
 try {
  const root=join(dir,'vault'); await mkdir(root); await Bun.write(join(root,'Schedule.md'),'# Schedule\nReview deadline Friday 3pm.');
  await Bun.write(join(dir,'outside.md'),'private outside'); await symlink(join(dir,'outside.md'),join(root,'escape.md'));
  const result=await searchVault(root,'deadline'); expect(result.results[0].title).toBe('Schedule'); expect(result.results[0].link).toContain('obsidian://');
  expect((await vaultNote(root,'Schedule.md')).text).toContain('Friday');
  await expect(vaultNote(root,'../outside.md')).rejects.toThrow();
  await expect(vaultNote(root,'escape.md')).rejects.toThrow('outside');
  expect(result.results.some(r=>r.path==='escape.md')).toBe(false);
 }finally{await rm(dir,{recursive:true,force:true});}
});
