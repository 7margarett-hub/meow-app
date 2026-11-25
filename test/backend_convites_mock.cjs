const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),ts=require('typescript');
const source=fs.readFileSync(require('path').join(__dirname,'../supabase/functions/meow-convites/index.ts'),'utf8');
const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
const root='projects/meow-app-8ac5e/databases/(default)/documents/';const docs=new Map();const str=s=>({stringValue:s}),num=n=>({integerValue:String(n)}),bool=b=>({booleanValue:b});
const put=(p,f)=>docs.set(p,{name:root+p,fields:f});put('servers/server1',{name:str('Teste'),ownerId:str('owner'),members:{arrayValue:{values:[str('owner')]}}});put('servers/server1/channels/general',{name:str('geral'),order:num(0)});put('users/member',{displayName:str('Visitante')});put('users/member2',{displayName:str('Outra pessoa')});
let handler, commits=0;const ok=v=>new Response(JSON.stringify(v),{status:200});
const fetch=async(url,opts={})=>{if(url==='https://oauth2.googleapis.com/token')return ok({access_token:'mock',expires_in:3600});let p=url.split('/documents')[1];const b=opts.body?JSON.parse(opts.body):{};
 if(p===':beginTransaction')return ok({transaction:'mock-transaction'});if(p===':rollback')return ok({});if(p===':commit'){for(const w of b.writes){const k=w.update.name.slice(root.length);if(w.currentDocument.exists===false)assert(!docs.has(k));if(w.currentDocument.exists===true)assert(docs.has(k));}for(const w of b.writes){let k=w.update.name.slice(root.length);put(k,w.updateMask?{...docs.get(k).fields,...w.update.fields}:w.update.fields);}commits++;return ok({});}
 if(p.endsWith(':runQuery')){let parent=p.slice(0,-9).replace(/^\//,'');let col=b.structuredQuery.from[0].collectionId;let prefix=(parent?parent+'/':'')+col+'/';let result=[...docs.entries()].filter(([k,d])=>k.startsWith(prefix)&&!k.slice(prefix.length).includes('/'));if(b.structuredQuery.where){const f=b.structuredQuery.where.fieldFilter;result=result.filter(([k,d])=>d.fields[f.field.fieldPath]?.stringValue===f.value.stringValue);}return ok(result.map(([k,d])=>({document:d})));}
 p=p.replace(/^\//,'').split('?')[0];return docs.has(p)?ok(docs.get(p)):new Response('{}',{status:404});};
class SignJWT {setProtectedHeader(){return this;}setIssuer(){return this;}setAudience(){return this;}setIssuedAt(){return this;}setExpirationTime(){return this;}async sign(){return 'mock';}}
vm.runInNewContext(code,{exports:{},require:()=>({createRemoteJWKSet:()=>null,jwtVerify:async(token)=>({payload:{sub:token}}),importPKCS8:async()=>null,SignJWT}),Deno:{env:{get:()=>JSON.stringify({project_id:'meow-app-8ac5e',private_key:'fake',client_email:'fake'})},serve:f=>handler=f},URL,URLSearchParams,Response,Request,fetch,AbortSignal,crypto:require('node:crypto').webcrypto,console,Date,setTimeout});
async function call(uid,action,rest={}){const response=await handler(new Request('https://mock',{method:'POST',headers:{Authorization:'Bearer '+uid},body:JSON.stringify({action,...rest})}));return {status:response.status,body:await response.json()};}
(async()=>{
 let r=await call('member','create',{serverId:'server1',days:7,maxUses:1});assert.equal(r.status,403);
 r=await call('owner','create',{serverId:'server1',days:7,maxUses:1});assert.equal(r.status,200);const c=r.body.code;assert.match(c,/^[0-9a-f]{32}$/);
 r=await call('member','inspect',{code:c});assert.equal(r.status,200);assert.equal(r.body.joined,false);
 r=await call('member','join',{code:c});assert.equal(r.status,200);assert.equal(r.body.alreadyMember,false);assert.equal(docs.get('invites/'+c).fields.uses.integerValue,'1');assert.equal(docs.get('servers/server1').fields.members.arrayValue.values.length,2);assert.equal([...docs.keys()].filter(k=>k.includes('/messages/join_')).length,1);
 const before=commits;r=await call('member','join',{code:c});assert.equal(r.body.alreadyMember,true);assert.equal(commits,before);assert.equal([...docs.keys()].filter(k=>k.includes('/messages/join_')).length,1);
 r=await call('member2','join',{code:c});assert.equal(r.status,404);
 r=await call('member','welcome',{serverId:'server1',enabled:false,channel:''});assert.equal(r.status,403);
 r=await call('owner','welcome',{serverId:'server1',enabled:false,channel:''});assert.equal(r.status,200);
 r=await call('owner','create',{serverId:'server1',days:0,maxUses:0});assert.equal(r.status,200);const c2=r.body.code;
 r=await call('member2','join',{code:c2});assert.equal(r.status,200);assert.equal([...docs.keys()].filter(k=>k.includes('/messages/join_')).length,1);
 r=await call('owner','revoke',{serverId:'server1',code:c2});assert.equal(r.status,200);r=await call('member','inspect',{code:c2});assert.equal(r.status,404);
 console.log('PASS: mock local do backend: proprietário, criação, inspeção, entrada, limite, repetição idempotente, boas-vindas, toggle, revogação.');
})().catch(e=>{console.error(e);process.exit(1)});
