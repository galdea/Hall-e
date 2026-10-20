import {test} from 'node:test';
import assert from 'node:assert/strict';
import {daysOfMonth,weekDates,duration,dateKey,parseDate,quickRecord,receive,ui,data,nativeResult,deleteMeeting,undo,selectProject,createProject,stop,recordExisting} from '../src/model.mjs';
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
test('capture project changes save immediately without sending a stale or empty meeting name',()=>{
  const sent=[];globalThis.HallENative={dispatch:(a,p)=>sent.push([a,JSON.parse(p)])};
  data.active=null;data.meetings=[{id:'capture-project',title:'Original title'}];ui.page='record';ui.detailId='capture-project';ui.title='Stale editor value';
  selectProject({target:{value:'Marketing'}});
  assert.deepEqual(sent,[['updateMeeting',{id:'capture-project',project:'Marketing'}]]);
  ui.projectName='New project';createProject();
  assert.deepEqual(sent.slice(-2),[['createProject',{name:'New project'}],['updateMeeting',{id:'capture-project',project:'New project'}]]);
  ui.page='schedule';selectProject({target:{value:'Operations'}});assert.equal(sent.length,3,'scheduled meeting selection remains a draft until Create');
  delete globalThis.HallENative;
});
test('returning to Home with native capture binds the picker to that recording, not an old detail',()=>{
  const sent=[];globalThis.HallENative={dispatch:(a,p)=>sent.push([a,JSON.parse(p)])};
  ui.page='home';ui.detailId='old-detail';ui.project='Old project';
  receive({preparing:false,active:{id:'native-capture',status:'RECORDING',project:'Hall-e'}});
  assert.equal(ui.detailId,'native-capture');assert.equal(ui.project,'Hall-e');
  selectProject({target:{value:'Marketing'}});
  assert.deepEqual(sent,[['updateMeeting',{id:'native-capture',project:'Marketing'}]]);
  data.active=null;delete globalThis.HallENative;
});
test('discard feedback tracks pending cleanup only for the viewed capture',()=>{
  ui.detailId='discarded-capture';ui.captureOutcome=null;
  nativeResult({captureOutcome:'discarded_short',meetingId:'discarded-capture',reason:'Pending cleanup',discardCleanupPending:true});
  assert.equal(ui.captureOutcome,'discarded_short');assert.equal(ui.discardCleanupPending,true);
  nativeResult({captureOutcome:'discarded_short',meetingId:'discarded-capture',reason:'Removed',discardCleanupPending:false});
  assert.equal(ui.discardCleanupPending,false);
  ui.detailId='new-capture';ui.captureOutcome=null;
  nativeResult({captureOutcome:'discarded_short',meetingId:'old-capture',reason:'Old capture removed'});
  assert.equal(ui.captureOutcome,null,'late cleanup must not mark a different capture discarded');
});
test('preview short clips disappear but their scheduled meeting remains available',()=>{
  data.active=null;ui.starting=false;data.meetings=[];quickRecord();const instantId=data.active.id;stop();
  assert.equal(data.active,null);assert.equal(data.meetings.some(m=>m.id===instantId),false);assert.equal(ui.captureOutcome,'discarded_short');
  data.meetings=[{id:'scheduled-preview',title:'Scheduled meeting',status:'DRAFT'}];ui.detailId='scheduled-preview';recordExisting();stop();
  assert.equal(data.meetings[0].status,'DRAFT');assert.ok(data.meetings[0].discardedRecordingAtMs);assert.equal(data.meetings[0].transferState,undefined);
});
