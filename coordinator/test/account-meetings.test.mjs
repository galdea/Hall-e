import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {openAccountDatabase} from "../test-support/account.mjs";
import {putMeeting, listMeetings} from "../src/account-meetings.mjs";

function fixture(t) {
  const env = {ACCOUNT_DB: openAccountDatabase()};
  t.after(() => env.ACCOUNT_DB.close());
  const owner = crypto.randomUUID(), id = crypto.randomUUID();
  const change = {mutationId:crypto.randomUUID(), baseRevision:0, title:"Taller sintético",
    startAt:"2026-11-20T09:30:00-03:00", endAt:"2026-11-20T13:30:00Z"};
  return {env, owner, id, change};
}

test("calendar uses explicit instants and rejects impossible or reversed dates", async t => {
  const {env, owner, id, change} = fixture(t);
  for (const startAt of ["2026-11-20", "2026-11-20T09:30:00", "2026-02-30T12:30:00Z", "2026-11-21T09:30:00Z", change.endAt]) {
    assert.equal((await putMeeting({...change,startAt},env,owner,id)).status, 400);
  }
  const {meeting} = await (await putMeeting(change,env,owner,id)).json();
  assert.equal(meeting.startAt, "2026-11-20T12:30:00.000Z");
  assert.equal(meeting.endAt, "2026-11-20T13:30:00.000Z");
  assert.equal(meeting.revision, 1);
});

test("only one concurrent revision wins and replay returns current state without resurrecting a deleted event", async t => {
  const {env, owner, id, change} = fixture(t);
  await putMeeting(change,env,owner,id);
  const responses = await Promise.all(["Uno","Dos"].map(title =>
    putMeeting({...change,title,mutationId:crypto.randomUUID(),baseRevision:1},env,owner,id)));
  assert.deepEqual(responses.map(x => x.status).sort(),[200,409]);
  const remove = {mutationId:crypto.randomUUID(),baseRevision:2,deleted:true};
  assert.equal((await putMeeting(remove,env,owner,id)).status,200);
  const replay = await (await putMeeting(change,env,owner,id)).json();
  assert.equal(replay.meeting.revision,3);
  assert.equal(replay.meeting.deleted,true);
  assert.equal(replay.meeting.title,"");
  assert.equal((await putMeeting(change,env,owner,crypto.randomUUID())).status,409);
  const list = await (await listMeetings(env,owner,async () => [{meetingId:id,transcript:"synthetic text"}])).json();
  assert.deepEqual(list.meetings[0].recordings,[]);
});

test("unchanged account polls skip transcript reads and only that account's data invalidates its version", async t => {
  const {env, owner, id, change} = fixture(t);
  const get = async (user, since, read = async () => []) => (await listMeetings(env,user,read,since)).json();
  const {version: empty} = await get(owner);
  await putMeeting(change,env,owner,id);
  const {version} = await get(owner,empty);
  assert.notEqual(version,empty);
  assert.match(version,/^[a-f0-9]{32}$/);
  await putMeeting(change,env,crypto.randomUUID(),id);
  assert.deepEqual(await get(owner,version,() => assert.fail("idle poll read transcripts")), {unchanged:true,version});
  await putMeeting(change,env,owner,id);
  assert.equal((await get(owner,version)).unchanged,true);
  await env.ACCOUNT_DB.prepare("INSERT INTO account_transcript_imports (user_id,id,meeting_id,transcript) VALUES (?,?,?,?)")
    .bind(owner,crypto.randomUUID(),id,"synthetic").run();
  const imported = await get(owner,version);
  assert.notEqual(imported.version,version);
  await env.ACCOUNT_DB.prepare("UPDATE account_transcript_imports SET transcript=NULL WHERE user_id=?").bind(owner).run();
  assert.notEqual((await get(owner,imported.version)).version,imported.version);
});

test("phone and desktop share private project labels, preserve older-client edits and respect a concurrent unlink", async t => {
  const {env, owner, id, change} = fixture(t);
  const project = {id: crypto.randomUUID(), name: "Synthetic coastal survey"};
  const put = (user, mid, body) => putMeeting(body, env, user, mid);
  const snapshot = async user => (await listMeetings(env,user,async () => [])).json();
  const tagged = {...change,project};
  assert.deepEqual((await (await put(owner,id,tagged)).json()).meeting.project,project);
  assert.deepEqual((await snapshot(owner)).meetings[0].project, project);

  const next = (base, patch) => ({...change,baseRevision:base,mutationId:crypto.randomUUID(),...patch});
  const legacyEdit = next(1, {title:"Moved from an earlier client"});
  assert.deepEqual((await (await put(owner,id,legacyEdit)).json()).meeting.project,project);
  const other = crypto.randomUUID();
  assert.deepEqual((await snapshot(other)).meetings, []);
  const privateProject = {...project,name:"Different account, same identifier"};
  assert.deepEqual((await (await put(other,id,{...change,project:privateProject})).json()).meeting.project,privateProject);
  const secondId = crypto.randomUUID();
  await put(owner,secondId,next(0,{project:{...project,name:"Stale spelling"}}));
  assert.deepEqual((await snapshot(owner)).meetings.map(m => m.project), [project,project]);
  assert.equal((await put(owner,id,next(1,{project:null}))).status,409);
  assert.equal((await (await put(owner,id,next(2,{project:null}))).json()).meeting.project,null);
  assert.equal((await (await put(owner,id,tagged)).json()).meeting.project,null);
  assert.equal((await put(owner,id,{...tagged,project:null})).status,409);
  assert.equal((await put(owner,id,next(3,{project:{id:"local-client-name",name:"private"}}))).status,400);
  assert.deepEqual((await snapshot(other)).meetings[0].project,privateProject);
});

test("a tombstone keeps no schedule and deleting the last linked meeting removes that account's project label", async t => {
  const {env, owner, id, change} = fixture(t);
  const put = (user, mid, body) => putMeeting(body, env, user, mid);
  const next = (base, patch) => ({...change,baseRevision:base,mutationId:crypto.randomUUID(),...patch});
  const shared = {id: crypto.randomUUID(), name: "Synthetic shared label"};
  const solo = {id: crypto.randomUUID(), name: "Synthetic single label"};
  const secondId = crypto.randomUUID(), other = crypto.randomUUID();
  await put(owner,id,{...change,project:shared});
  await put(owner,secondId,next(0,{project:shared}));
  const thirdId = crypto.randomUUID();
  await put(owner,thirdId,next(0,{project:solo}));
  await put(other,id,{...change,project:solo});
  const labels = async user => (await env.ACCOUNT_DB.prepare("SELECT id FROM account_projects WHERE user_id=? ORDER BY name")
    .bind(user).all()).results.map(row => row.id);

  const remove = {mutationId:crypto.randomUUID(),baseRevision:1,deleted:true};
  const removed = (await (await put(owner,thirdId,remove)).json()).meeting;
  assert.equal(removed.startAt, "1970-01-01T00:00:00.000Z");
  assert.equal(removed.endAt, "1970-01-01T00:00:00.000Z");
  assert.ok(Date.parse(removed.startAt) === 0 && Date.parse(removed.endAt) === 0);
  assert.deepEqual(await labels(owner), [shared.id]);
  assert.deepEqual(await labels(other), [solo.id]);
  assert.deepEqual((await (await put(owner,thirdId,remove)).json()).meeting, removed);

  await put(owner,id,next(1,{project:null}));
  assert.deepEqual(await labels(owner), [shared.id]);
  await put(owner,secondId,next(1,{deleted:true,title:undefined,startAt:undefined,endAt:undefined}));
  assert.deepEqual(await labels(owner), []);
  const list = await (await listMeetings(env,owner,async () => [])).json();
  for (const meeting of list.meetings.filter(m => m.deleted)) {
    assert.deepEqual([meeting.title, meeting.startAt, meeting.endAt, meeting.project],
      ["", "1970-01-01T00:00:00.000Z", "1970-01-01T00:00:00.000Z", null]);
  }
  assert.deepEqual(list.meetings.filter(m => !m.deleted).map(m => [m.id, m.startAt]), [[id, "2026-11-20T12:30:00.000Z"]]);
});

test("the retention backfill scrubs earlier tombstones and unused labels and is safe to re-run", async t => {
  const {env, owner, id, change} = fixture(t);
  const db = env.ACCOUNT_DB;
  const label = {id: crypto.randomUUID(), name: "Synthetic kept label"};
  await putMeeting({...change,project:label}, env, owner, id);
  await db.prepare("INSERT INTO account_meetings VALUES (?,?,'',?,?,2,1,'legacy')")
    .bind(owner, "legacy-tombstone", "2026-01-02T03:04:05.000Z", "2026-01-02T04:04:05.000Z").run();
  await db.prepare("INSERT INTO account_projects VALUES (?,?,?)").bind(owner, "legacy-label", "Synthetic orphan").run();
  const sql = readFileSync(new URL("../account-retention.sql", import.meta.url), "utf8");
  for (let run = 0; run < 2; run++) await db.exec(sql);
  const rows = (await db.prepare("SELECT id, start_at, end_at FROM account_meetings WHERE user_id=? ORDER BY deleted").bind(owner).all()).results;
  assert.deepEqual(rows.map(row => [row.id, row.start_at, row.end_at]), [
    [id, "2026-11-20T12:30:00.000Z", "2026-11-20T13:30:00.000Z"],
    ["legacy-tombstone", "1970-01-01T00:00:00.000Z", "1970-01-01T00:00:00.000Z"],
  ]);
  assert.deepEqual((await db.prepare("SELECT id FROM account_projects").all()).results.map(row => row.id), [label.id]);
});
