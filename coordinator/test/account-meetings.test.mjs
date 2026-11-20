import test from "node:test";
import assert from "node:assert/strict";
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
