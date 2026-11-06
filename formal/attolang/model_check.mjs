// Abstract flag-visibility model, not the production native/C parser.
import assert from 'node:assert/strict';
const flagScopes=['global','run','run/add','publish'];
const commands=['root','run','run/add','publish'];
const visible=(command,flag)=>{
 if(flag==='global')return true;
 if(command===flag)return true;
 return command.startsWith(flag+'/');
};
const resolve=(command,flag)=>visible(command,flag);
const seen=new Set(),witnesses=[];
for(const c of commands)for(const flag of flagScopes){
 const ok=resolve(c,flag), record=JSON.stringify({c,flag,ok});
 seen.add(record);witnesses.push({c,flag,ok});
 assert.equal(ok,flag==='global'||c===flag||c.startsWith(flag+'/'));
 // A command-scoped flag cannot be resolved from a sibling or root command.
 if(flag!=='global'&&!c.startsWith(flag+'/')&&c!==flag)assert.equal(ok,false);
}
assert.equal(seen.size,commands.length*flagScopes.length);
assert.ok(witnesses.some(w=>w.c==='run/add'&&w.flag==='run'&&w.ok));
assert.ok(witnesses.some(w=>w.c==='publish'&&w.flag==='run'&&!w.ok));
assert.throws(()=>{
 const bad=(c,f)=>f==='run'||visible(c,f); // illegally leaks run flags into publish/root
 for(const c of commands)for(const f of flagScopes)
   assert.equal(bad(c,f),visible(c,f),`scope leak ${c}/${f}`);
},/scope leak/);
console.log(`model=flag_scope_visibility states=${seen.size} negative_controls=1 status=PASS scope=abstract`);
