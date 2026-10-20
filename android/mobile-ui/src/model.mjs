export const dateKey = d => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
export const parseDate = key => new Date(`${key}T12:00:00`);
export const daysOfMonth = key => {
  const d=parseDate(key),first=new Date(d.getFullYear(),d.getMonth(),1),count=new Date(d.getFullYear(),d.getMonth()+1,0).getDate();
  return [...Array((first.getDay()+6)%7).fill(null),...Array.from({length:count},(_,i)=>dateKey(new Date(d.getFullYear(),d.getMonth(),i+1)))];
};
export const weekDates = key => {const d=parseDate(key);d.setDate(d.getDate()-(d.getDay()+6)%7);return Array.from({length:7},(_,i)=>{const day=new Date(d);day.setDate(d.getDate()+i);return dateKey(day);});};
export const duration = ms => {const s=Math.floor(Math.max(0,ms||0)/1000);return `${String(Math.floor(s/60)).padStart(2,'0')}:${String(s%60).padStart(2,'0')}`;};
export const nice = key => parseDate(key).toLocaleDateString('es-CL',{day:'numeric',month:'long'});
export const statusText = m => ({DRAFT:'Por comenzar',STARTING:'Preparando micrófono',RECORDING:'Grabando en este teléfono',RECORDED:'Audio guardado en el teléfono',INTERRUPTED:'Grabación interrumpida · audio conservado',FAILED:'No se pudo grabar'}[m.status]||m.status||'Por comenzar');
export const transferText = state => ({queued:'Esperando conexión con tu Mac',uploading:'Enviando audio cifrado al Mac',uploaded:'Esperando transcripción en tu Mac',receipt_received:'Texto verificado · eliminando audio',audio_deleted:'Texto en tu Mac · audio eliminado',purged:'Texto en tu Mac · audio eliminado',failed:'Envío pendiente · audio conservado'}[state]||state);
const now=new Date();
export const ui = {page:'home',date:dateKey(now),calendarView:'month',detailId:null,returnPage:'home',title:'',project:'',scheduledDate:dateKey(now),scheduledTime:'14:00',starting:false,pendingDelete:null,deleted:[],message:'',newProject:false,projectName:'',captureOutcome:null,discardCleanupPending:false};
export const data = {meetings:[],projects:[],active:null,paired:false,calendarPermission:false,notificationsAllowed:true,preview:false,error:null,today:dateKey(now),reminderMinutes:10};
let repaint=()=>{};
const pageTop=()=>globalThis.scrollTo?.(0,0);
export const connect = fn => {repaint=fn;};
export function send(action,payload={}) {
  if(globalThis.HallENative){globalThis.HallENative.dispatch(action,JSON.stringify(payload));return;}
  demoAction(action,payload);
}
export function receive(snapshot) {
  const previousActiveId=data.active?.id;
  Object.assign(data,snapshot);
  if (!recording() && typeof document !== 'undefined') document.documentElement.classList.remove('recording-reminder');
  ui.starting=Boolean(snapshot.preparing);
  if(snapshot.active && ['STARTING','RECORDING'].includes(snapshot.active.status)){
    if(previousActiveId!==snapshot.active.id){ui.captureOutcome=null;ui.discardCleanupPending=false;}
    if(ui.detailId!==snapshot.active.id && ui.starting)ui.page='record';
    if(ui.page==='record'||ui.page==='home'){
      if(ui.detailId!==snapshot.active.id||previousActiveId!==snapshot.active.id)ui.project=snapshot.active.project||'';
      ui.detailId=snapshot.active.id;
    }
  }
  if(snapshot.message)ui.message=snapshot.message;
  repaint();
  if(previousActiveId&&snapshot.active===null&&ui.page==='record')pageTop();
}
export const meetingsFor = key => data.meetings.filter(m=>m.date===key).sort((a,b)=>(a.startAtMs||0)-(b.startAtMs||0));
export const chosen = () => data.meetings.find(m=>m.id===ui.detailId)||data.active;
export const recording = () => data.active?.status==='RECORDING';
export function navigate(page){if(page==='home'&&data.active){openRecord();return;}ui.page=page;if(page==='home')ui.date=data.today;repaint();pageTop();}
export function quickRecord(){if(data.active||ui.starting){openRecord();return;}ui.starting=true;ui.detailId=null;ui.page='record';ui.project='';ui.title='';ui.captureOutcome=null;ui.discardCleanupPending=false;ui.message='';send('quickRecord');repaint();pageTop();}
export function stop(){send('stop');pageTop();}
export function openMeeting(m){ui.returnPage=ui.page;ui.detailId=m.id;ui.title=m.title;ui.project=m.project||'';ui.page=m.status==='RECORDING'||m.status==='STARTING'?'record':'detail';repaint();pageTop();}
export function openRecord(){if(data.active){ui.detailId=data.active.id;ui.title=data.active.title;ui.project=data.active.project||'';}ui.page='record';repaint();pageTop();}
export function saveDetails(){const m=chosen();if(m)send('updateMeeting',{id:m.id,title:ui.title,project:ui.project});}
export function saveProject(){const m=data.active||chosen();if(m)send('updateMeeting',{id:m.id,project:ui.project});}
const capturePage=()=>ui.page==='record'||(ui.page==='home'&&data.active);
export function selectProject(event){ui.project=event.target.value;if(capturePage())saveProject();}
export function recordExisting(){const m=chosen();if(!m)return;ui.starting=true;ui.page='record';ui.captureOutcome=null;ui.discardCleanupPending=false;ui.message='';send('recordMeeting',{id:m.id});repaint();pageTop();}
export function askDelete(m){if(m.status==='RECORDING'||m.status==='STARTING')return;ui.pendingDelete=m;repaint();}
export function deleteMeeting(){if(!ui.pendingDelete)return;send('trash',{id:ui.pendingDelete.id,calendar:!!ui.pendingDelete.calendar});ui.pendingDelete=null;}
export function undo(){const entry=ui.deleted.pop();if(entry)send('restore',entry);repaint();}
export function createProject(){const name=ui.projectName.trim();if(!name){ui.message='Escribe un nombre para el proyecto.';repaint();return;}ui.project=name;send('createProject',{name});if(capturePage())saveProject();ui.projectName='';ui.newProject=false;repaint();}
export function schedule(){if(!ui.scheduledDate||!ui.scheduledTime){ui.message='Elige fecha y hora.';repaint();return;}send('schedule',{title:ui.title.trim()||'Nueva reunión',project:ui.project,date:ui.scheduledDate,time:ui.scheduledTime});ui.page='calendar';ui.date=ui.scheduledDate;requestRange();}
export function movePeriod(sign){const d=parseDate(ui.date);if(ui.calendarView==='month'){d.setDate(1);d.setMonth(d.getMonth()+sign);}else d.setDate(d.getDate()+7*sign);ui.date=dateKey(d);requestRange();repaint();}
export function requestRange(){send('range',{date:ui.date});}
export function selectDate(key){ui.date=key;repaint();}
export function toast(message){ui.message=message;repaint();}
export function setView(view){ui.calendarView=view;repaint();}
export function beginSchedule(){ui.title='';ui.project='';ui.scheduledDate=ui.date;ui.page='schedule';repaint();pageTop();}
export function nativeResult(result){if(result.trash){ui.deleted.push(result.trash);if(ui.page==='detail')ui.page=ui.returnPage;}if(result.error){ui.starting=false;ui.message=result.error;}if(result.message)ui.message=result.message;if(result.captureOutcome==='discarded_short'){if(result.meetingId===ui.detailId){ui.captureOutcome='discarded_short';ui.discardCleanupPending=Boolean(result.discardCleanupPending);}if(result.reason)ui.message=result.reason;}repaint();}
globalThis.hallEReceive=receive;globalThis.hallEResult=nativeResult;
// Browser-only review fixture. Native builds always replace this via their trusted bridge.
let demoStarted=0,demoExisting=false;
function demoAction(action,p){
  if(action==='quickRecord'||action==='recordMeeting'){
    const m=action==='recordMeeting'?data.meetings.find(m=>m.id===p.id):{id:String(Date.now()),title:'Reunión instantánea',date:data.today,time:new Date().toLocaleTimeString('es-CL',{hour:'2-digit',minute:'2-digit'}),project:'',status:'DRAFT'};
    if(!data.meetings.includes(m))data.meetings.push(m);demoExisting=action==='recordMeeting';demoStarted=Date.now();m.status='RECORDING';m.elapsedMs=0;m.discardedRecordingAtMs=null;m.error=null;data.active=m;ui.starting=false;ui.detailId=m.id;
  }else if(action==='stop'){if(data.active){const m=data.active;data.active=null;if(Date.now()-demoStarted<10_000){const reason='Grabación de menos de 10 segundos descartada. No se envió al Mac.';m.discardedRecordingAtMs=Date.now();m.error=reason;if(demoExisting)m.status='DRAFT';else data.meetings=data.meetings.filter(item=>item.id!==m.id);nativeResult({captureOutcome:'discarded_short',meetingId:m.id,reason});}else{m.status='RECORDED';m.transferState='queued';}}}
  else if(action==='updateMeeting'){const m=data.meetings.find(m=>m.id===p.id);if(m){m.title=p.title||m.title;m.project=p.project;}}
  else if(action==='createProject'){if(!data.projects.includes(p.name))data.projects.push(p.name);}
  else if(action==='trash'){const m=data.meetings.find(m=>m.id===p.id);if(m){data.meetings=data.meetings.filter(m=>m.id!==p.id);ui.deleted.push({id:p.id,calendar:p.calendar,meeting:m});}}
  else if(action==='restore'&&p.meeting)data.meetings.push(p.meeting);
  else if(action==='schedule')data.meetings.push({id:String(Date.now()),title:p.title,date:p.date,time:p.time,project:p.project,status:'DRAFT'});
  else if(!['refresh','range'].includes(action))ui.message='Disponible en la app Android.';
  repaint();
}
export function start(){
  if(globalThis.HallENative){send('refresh');return;}
  data.preview=true;data.paired=false;data.projects=['Hall-e','Marketing','Operaciones'];data.meetings=[{id:'demo-done',title:'Revisión de producto',project:'Hall-e',date:data.today,time:'09:00',status:'RECORDED',transferState:'audio_deleted'},{id:'demo-later',title:'Ideas para el lanzamiento',project:'Marketing',date:data.today,time:'12:30',status:'DRAFT'}];
  repaint();
  setInterval(()=>{if(data.active){data.active.elapsedMs=Date.now()-demoStarted;repaint();}},1000);
}

// Only a native service-owned reminder invokes this; it never starts capture.
let reminderTimer = 0;
globalThis.hallEReminder = () => {
  if (!recording()) return;
  clearTimeout(reminderTimer);
  document.documentElement.classList.add('recording-reminder');
  reminderTimer = setTimeout(() => document.documentElement.classList.remove('recording-reminder'), 1000);
};
