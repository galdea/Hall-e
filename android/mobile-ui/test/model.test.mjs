import {test} from 'node:test';
import assert from 'node:assert/strict';
import {daysOfMonth,weekDates,duration,dateKey,parseDate,quickRecord,receive,ui,data,nativeResult,deleteMeeting,undo,selectProject,createProject,stop,recordExisting,can,askRemove,removeMeeting,openAccountCalendar,accountCalendarAvailable,pairingAvailable,statusText,saveEventProject} from '../src/model.mjs';
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
test('permanent delete is offered only when native policy lists DELETE and is sent once confirmed',()=>{
  const sent=[];globalThis.HallENative={dispatch:(a,p)=>sent.push([a,JSON.parse(p)])};
  ui.pendingRemove=null;
  askRemove({id:'rec',status:'RECORDING',actions:[]});assert.equal(ui.pendingRemove,null,'never while recording');
  askRemove({id:'legacy',status:'RECORDED'});assert.equal(ui.pendingRemove,null,'no actions list means no delete');
  const draft={id:'draft',status:'DRAFT',actions:['DELETE'],deleteTitle:'¿Eliminar esta reunión?',deleteMessage:'Se eliminará «Plan» de este teléfono. No se puede deshacer.'};
  askRemove(draft);assert.equal(ui.pendingRemove,draft,'a meeting saved without recording can be deleted');
  assert.equal(sent.length,0,'nothing is deleted before confirmation');
  removeMeeting();assert.deepEqual(sent,[['deleteMeeting',{id:'draft'}]]);assert.equal(ui.pendingRemove,null);
  removeMeeting();assert.equal(sent.length,1);
  delete globalThis.HallENative;
});
test('interrupted recordings expose their native actions instead of a dead end',()=>{
  const partial={status:'INTERRUPTED',actions:['SHARE_PARTIAL_FILE','DELETE']};
  assert.equal(can(partial,'SHARE_PARTIAL_FILE'),true);assert.equal(can(partial,'DELETE'),true);assert.equal(can(partial,'PLAY'),false);
  assert.equal(can(null,'DELETE'),false);assert.equal(can({actions:'DELETE'},'DELETE'),false);
  assert.match(statusText(partial),/interrumpida/);
});
test('a confirmed native delete leaves the detail page and clears its undo entry',()=>{
  ui.page='detail';ui.returnPage='calendar';ui.detailId='gone';ui.deleted=[{id:'gone',calendar:false},{id:'kept',calendar:false}];
  nativeResult({deleted:{id:'gone'}});
  assert.equal(ui.page,'calendar');assert.equal(ui.detailId,null);assert.deepEqual(ui.deleted,[{id:'kept',calendar:false}]);
  ui.page='detail';ui.detailId='other';nativeResult({deleted:{id:'unrelated'}});assert.equal(ui.page,'detail');assert.equal(ui.detailId,'other');
  ui.deleted=[];
});
test('Agenda privada opens the native account calendar on the selected day, never in preview',()=>{
  const sent=[];globalThis.HallENative={dispatch:(a,p)=>sent.push([a,JSON.parse(p)])};
  data.preview=false;ui.date='2026-12-03';assert.equal(accountCalendarAvailable(),true);
  openAccountCalendar();assert.deepEqual(sent,[['accountCalendar',{date:'2026-12-03'}]]);
  data.preview=true;assert.equal(accountCalendarAvailable(),false);openAccountCalendar();assert.equal(sent.length,1);
  data.preview=false;delete globalThis.HallENative;
});
test('staging snapshots hide pairing',()=>{
  receive({staging:true});assert.equal(pairingAvailable(),false);
  receive({staging:false});assert.equal(pairingAvailable(),true);
});
test('preview recordings are kept, never auto-deleted, and carry no transfer state',()=>{
  data.active=null;ui.starting=false;data.meetings=[];quickRecord();const id=data.active.id;stop();
  const saved=data.meetings.find(m=>m.id===id);
  assert.ok(saved,'a short preview recording stays in the list');assert.equal(saved.status,'RECORDED');
  assert.equal('transferState' in saved,false);assert.deepEqual(saved.actions,['PLAY','SHARE_AUDIO','DELETE']);
});
test('a calendar event keeps its project through assignProject, local meetings through updateMeeting',()=>{
  const sent=[];globalThis.HallENative={dispatch:(a,p)=>sent.push([a,JSON.parse(p)])};
  data.active=null;data.meetings=[{id:'calendar:1:9:0',calendar:true,title:'Board'},{id:'local',title:'Local'}];
  ui.detailId='calendar:1:9:0';ui.project='Hall-e';saveEventProject();
  ui.detailId='local';saveEventProject();
  assert.deepEqual(sent,[['assignProject',{id:'calendar:1:9:0',project:'Hall-e'}]]);
  delete globalThis.HallENative;
});
