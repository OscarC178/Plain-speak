import { test, expect } from 'bun:test';
import { buildTurn } from './prompt';
import { resolve, type RulesFile } from './rules';
const rules: RulesFile = {defaults:{max_lines:6,read_instructions:'Summarise the message.',draft_instructions:'Edit my selected draft.'},profiles:{},rules:[]};
test('correcting a message preserves its content and never uses the draft style',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'correct' as const,text:'plese check this'};
 const result=resolve(rules,cap);
 expect(result.instructions.join(' ')).toContain('Do not summarise');
 expect(result.instructions.join(' ')).not.toContain('Edit my selected draft');
 expect(buildTurn(cap,result)).toContain('instead of silently truncating');
});
test('context explicitly searches both notes and Drive and requires citations',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'read' as const,text:'release date?',context:true};
 const prompt=buildTurn(cap,resolve(rules,cap));
 expect(prompt).toContain('Obsidian vault AND connected Google Drive');
 expect(prompt).toContain('Cite document titles and source links');
 expect(prompt).toContain('which source could not be checked');
});
test('a turn starts with the mode and carries the resolved style',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'read' as const,text:'hello'};
 const turn=buildTurn(cap,resolve(rules,cap));
 expect(turn).toStartWith('New capture. Mode: read.');
 expect(turn).toContain('Summarise the message.');
});
test('the pointer steers which visible message is explained, only when there is a screenshot',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'read' as const,image:true,pointer:{x:0.425,y:0.7}};
 expect(buildTurn(cap,resolve(rules,cap))).toContain('about 43% across and 70% down the screenshot');
 const noImage={...cap,image:false};
 expect(buildTurn(noImage,resolve(rules,noImage))).not.toContain('pointed at');
});
test('a marked pointer sends Claude to the ring drawn on the screenshot',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'read' as const,image:true,pointer:{x:0.43,y:0.3,marked:true}};
 const prompt=buildTurn(cap,resolve(rules,cap));
 expect(prompt).toContain('marked with a pink ring');
 expect(prompt).toContain('The ring is not part of the message');
 expect(prompt).toContain('Never mention the ring, the pointer or how you chose the message');
});
test('highlighted text is the focus and the outlined screenshot is context only',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'read' as const,text:'can u lock the edit by the 18th',image:true,outlined:true};
 const prompt=buildTurn(cap,resolve(rules,cap));
 expect(prompt).toContain('Work on exactly that text, not the rest of the screen');
 expect(prompt).toContain('which is outlined in pink');
 expect(prompt).toContain('Use it only as context');
 expect(prompt).toContain('Never mention them, the screenshot, or how you found the text');
 expect(prompt).not.toContain('Work on the message under or nearest the ring');
});
test('when only the pointer shows where the selection is, the ring marks it but the text stays the focus',()=>{
 const cap={app:'Slack',title:'general - Slack',mode:'correct' as const,text:'plese chek',image:true,pointer:{x:0.4,y:0.5,marked:true}};
 const prompt=buildTurn(cap,resolve(rules,cap));
 expect(prompt).toContain('marked with a pink ring');
 expect(prompt).toContain('Work on exactly that text');
 expect(prompt).not.toContain('The reader pointed at');
});
test('a draft may use the screenshot for tone but never for content',()=>{
 const cap={app:'Mail',title:'Re: budget',mode:'draft' as const,text:'sure, will send it tmrw',image:true,outlined:true};
 const prompt=buildTurn(cap,resolve(rules,cap));
 expect(prompt).toContain('Never add content from it');
 expect(prompt).not.toContain('Work on exactly that text, not the rest of the screen');
 expect(prompt).toContain('For draft mode: edit selected text only');
});
