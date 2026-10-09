import { test, expect } from 'bun:test';
import { buildPrompt } from './prompt';
import { resolve, type RulesFile } from './rules';
const rules: RulesFile = {defaults:{max_lines:6,read_instructions:'Summarise the message.',draft_instructions:'Edit my selected draft.'},profiles:{},rules:[]};
test('incoming correction preserves content with legacy personal rule files',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'correct' as const,text:'plese check this'};
 const result=resolve(rules,cap);
 expect(result.instructions.join(' ')).toContain('Do not summarise');
 expect(result.instructions.join(' ')).not.toContain('Edit my selected draft');
 expect(buildPrompt('id',cap,result)).toContain('instead of silently truncating');
});
test('context explicitly searches both notes and Drive and requires citations',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'read' as const,text:'release date?',context:true};
 const prompt=buildPrompt('id',cap,resolve(rules,cap));
 expect(prompt).toContain('Obsidian vault AND connected Google Drive');
 expect(prompt).toContain('Cite document titles and source links');
 expect(prompt).toContain('which source could not be checked');
});
