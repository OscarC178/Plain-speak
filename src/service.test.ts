import { test, expect, afterEach } from 'bun:test';
import { mkdtemp, mkdir, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createService } from './service';
import { loadRules } from './rules';
let services: Awaited<ReturnType<typeof createService>>[] = [];
let dirs: string[] = [];
afterEach(async () => { for (const s of services) await s.close(); services = []; for (const d of dirs) await rm(d, { recursive: true, force: true }); dirs = []; });
async function fixture(notify: (id: string, prompt: string) => Promise<void> = async () => {}) {
  const root = await mkdtemp(join(tmpdir(), 'plainspeak-test-')); dirs.push(root);
  await mkdir(join(root, 'rules')); await cp('rules/rules.example.yaml',join(root,'rules/rules.example.yaml'));
  const service = await createService(root,notify,0); services.push(service);
  const url = `http://127.0.0.1:${service.server.port}`;
  const post = (body: unknown, secret = service.token, origin?: string) => fetch(url+'/capture',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${secret}`,...(origin?{Origin:origin}:{})},body:JSON.stringify(body)});
  return {root,service,url,post};
}
const capture = {app:'Slack',title:'general - Slack',mode:'read',text:'plz send friday'};
test('unauthenticated and foreign-origin requests never reach Claude', async () => {
  let calls=0; const f=await fixture(async()=>{calls++});
  expect((await f.post(capture,'wrong')).status).toBe(401);
  expect((await f.post(capture,f.service.token,'https://evil.example')).status).toBe(403);
  expect(calls).toBe(0);
});
test('capture reaches notification and correlated results survive late overlay connection',async()=>{
  let prompt=''; const f=await fixture(async(_,p)=>{prompt=p});
  const response=await f.post(capture); expect(response.status).toBe(202); const {request_id}=await response.json();
  expect(prompt).toContain('untrusted'); expect(prompt).toContain('Use only this capture');
  expect((await f.post(capture)).status).toBe(429);
  await f.service.show(request_id,'Send it by Friday.');
  const result=await fetch(f.url+'/result/'+request_id,{headers:{Authorization:'Bearer '+f.service.token}});
  expect((await result.json()).text).toBe('Send it by Friday.');
  await expect(f.service.show(request_id,'duplicate')).rejects.toThrow();
});
test('transport failure is reported and clears the busy request',async()=>{
  const f=await fixture(async()=>{throw Error('closed')});
  expect((await f.post(capture)).status).toBe(503); expect((await f.post(capture)).status).toBe(503);
});
test('draft requires selection and HTTP cannot supply arbitrary filesystem paths',async()=>{
  const f=await fixture();
  expect((await f.post({...capture,mode:'draft',text:''})).status).toBe(400);
  expect((await f.post({...capture,image:'/etc/passwd'})).status).toBe(400);
  expect((await f.post({...capture,image_base64:'c2VjcmV0'})).status).toBe(400);
});
test('PNG tool returns image only for the active request and deletes it after showing',async()=>{
  const f=await fixture();
  const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGZkAAAAASUVORK5CYII=';
  const r=await f.post({...capture,image_base64:png}); const {request_id}=await r.json();
  expect(Buffer.from(await f.service.image(request_id)).toString('base64')).toBe(png);
  const path=join(f.root,'.local',request_id+'.png'); expect(await Bun.file(path).exists()).toBe(true);
  await f.service.show(request_id,'Done'); expect(await Bun.file(path).exists()).toBe(false);
  await expect(f.service.image(request_id)).rejects.toThrow();
});
test('invalid rule line limits and profiles fail before processing',async()=>{
  const f=await fixture(); const path=join(f.root,'rules/rules.example.yaml');
  await Bun.write(path,'defaults: {max_lines: -1, read_instructions: read, draft_instructions: draft}');
  await expect(loadRules(path)).rejects.toThrow('max_lines');
});

test('correction reads incoming text without draft selection requirements',async()=>{
 const f=await fixture();
 const response=await f.post({...capture,mode:'correct',text:'plese check the reveiw'});
 expect(response.status).toBe(202); const {request_id}=await response.json();
 await f.service.show(request_id,'Please check the review.');
 const result=await fetch(f.url+'/result/'+request_id,{headers:{Authorization:'Bearer '+f.service.token}});
 expect((await result.json()).mode).toBe('correct');
});

test('pointer is accepted inside the window and rejected outside 0 to 1',async()=>{
 const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGZkAAAAASUVORK5CYII=';
 let prompt=''; const f=await fixture(async(_,p)=>{prompt=p});
 expect((await f.post({...capture,image_base64:png,pointer:{x:1.5,y:0.2}})).status).toBe(400);
 expect((await f.post({...capture,image_base64:png,pointer:{x:0.2,y:0.8}})).status).toBe(202);
 expect(prompt).toContain('about 20% across and 80% down');
});
