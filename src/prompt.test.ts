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
test('pointer position steers which visible message is explained, only for screenshots',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'read' as const,image:'/tmp/x.png',pointer:{x:0.425,y:0.7}};
 expect(buildPrompt('id',cap,resolve(rules,cap))).toContain('about 43% across and 70% down the screenshot');
 const noImage={...cap,image:undefined};
 expect(buildPrompt('id',noImage,resolve(rules,noImage))).not.toContain('pointed at');
});
