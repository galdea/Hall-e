import {test} from 'node:test';
import assert from 'node:assert/strict';
import {daysOfMonth,weekDates,duration,dateKey,parseDate,quickRecord,receive,ui,data,nativeResult,deleteMeeting,undo} from '../src/model.mjs';
test('February leap year and Sunday-first month keep Monday calendar alignment',()=>{
  assert.equal(daysOfMonth('2028-02-15').filter(Boolean).length,29);
  assert.equal(daysOfMonth('2026-11-01').slice(0,6).every(d=>d===null),true);
  assert.deepEqual(weekDates('2026-11-01'),['2026-10-26','2026-10-27','2026-10-28','2026-10-29','2026-10-30','2026-10-31','2026-11-01']);
  assert.equal(dateKey(parseDate('2026-10-20')),'2026-10-20');
});
test('one Record tap dispatches capture before any project/title selection',()=>{
  const sent=[];globalThis.HallENative={dispatch:(action,p)=>sent.push([action,JSON.parse(p)])};
  data.active=null;ui.starting=false;ui.project='Existing project';ui.title='Old meeting';
  quickRecord();assert.deepEqual(sent,[['quickRecord',{}]]);assert.equal(ui.page,'record');assert.equal(ui.project,'');assert.equal(ui.title,'');
  quickRecord();assert.equal(sent.length,1,'double tap must not create another recording');
  receive({preparing:false,active:{id:'active',status:'RECORDING',elapsedMs:2500}});assert.equal(ui.detailId,'active');
  delete globalThis.HallENative;
});
test('trash is acknowledged before Undo becomes available and maintains a stack',()=>{
  const sent=[];globalThis.HallENative={dispatch:(a,p)=>sent.push([a,JSON.parse(p)])};ui.deleted=[];ui.pendingDelete={id:'a'};deleteMeeting();assert.equal(ui.deleted.length,0);
  nativeResult({trash:{id:'a',calendar:false}});nativeResult({trash:{id:'b',calendar:true}});undo();undo();assert.deepEqual(sent.slice(-2),[['restore',{id:'b',calendar:true}],['restore',{id:'a',calendar:false}]]);delete globalThis.HallENative;
});
test('recording duration remains correct past an hour and clamps negative values',()=>{assert.equal(duration(3_661_000),'61:01');assert.equal(duration(-5),'00:00');});
