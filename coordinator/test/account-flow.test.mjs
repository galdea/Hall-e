import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import accountWorker from "../src/account-worker.mjs";
import { processPending } from "../src/account-recording.mjs";
import { memoryRecordingBucket, openAccountDatabase } from "../test-support/account.mjs";

const prefix = "https://halle.test/account/v1";
const verifiedEmail = "alex@example.test";
const transcriptText = "This is a synthetic account flow transcript.";
const startAt = "2026-11-20T14:00:00.000Z";
const endAt = "2026-11-20T14:30:00.000Z";

function accountFlow(t) {
  const directory = mkdtempSync(join(tmpdir(), "halle-account-flow-"));
  const path = join(directory, "accounts.sqlite");
  const codes = new Map();
  const env = {
    ACCOUNT_DB: openAccountDatabase(path),
    ACCOUNT_AUDIO: memoryRecordingBucket(),
    ACCOUNT_ENABLE_TRANSCRIPTION: "yes",
    ACCOUNT_DEEPGRAM_KEY: "fixture-provider-key",
    ACCOUNT_AUTH_SECRET: "synthetic-fixture-secret-never-used-externally",
    ACCOUNT_MAILER: {
      async fetch(url, options) {
        assert.equal(url, "https://mail.internal/email-code");
        const { email, code } = JSON.parse(options.body);
        codes.set(email, code);
        return new Response(null, { status: 204 });
      },
    },
  };
  t.after(() => {
    env.ACCOUNT_DB.close();
    rmSync(directory, { recursive: true, force: true });
  });
  function restart() {
    env.ACCOUNT_DB.close();
    env.ACCOUNT_DB = openAccountDatabase(path, { migrate: false });
  }

  async function request(method, route, { token, body } = {}) {
    const headers = new Headers();
    if (token) headers.set("authorization", `Bearer ${token}`);
    if (body !== undefined) {
      const binary = body instanceof Uint8Array;
      headers.set("content-type", binary ? "application/octet-stream" : "application/json");
      if (!binary) body = JSON.stringify(body);
    }
    const response = await accountWorker.fetch(new Request(prefix + route, { method, headers, body }), env);
    assert.match(response.headers.get("cache-control") ?? "", /\bno-store\b/);
    const content = await response.text();
    return { status: response.status, body: content ? JSON.parse(content) : null };
  }

  async function login(email, checkReplay = false) {
    const started = await request("POST", "/auth/email/start", { body: { email } });
    expectSuccess(started);
    assert.ok(started.body.challengeId);
    assert.equal(started.body.code, undefined);
    const code = codes.get(email);
    assert.ok(code);
    const verify = { challengeId: started.body.challengeId, code };
    const verified = await request("POST", "/auth/email/verify", { body: verify });
    expectSuccess(verified);
    assert.ok(verified.body.token);
    assert.ok(verified.body.userId);
    if (checkReplay) {
      const replay = await request("POST", "/auth/email/verify", { body: verify });
      assert.ok([400, 401, 409, 410].includes(replay.status));
      assert.equal(replay.body?.token, undefined);
    }
    return verified.body;
  }

  return { env, request, login, restart };
}

function expectSuccess(response) {
  assert.ok(response.status >= 200 && response.status < 300, JSON.stringify(response));
  return response.body;
}

function expectInaccessible(response) {
  assert.ok([403, 404].includes(response.status), JSON.stringify(response));
}

const meetingChange = (title, baseRevision = 0, extras = {}) => ({
  title, startAt, endAt, baseRevision, mutationId: randomUUID(), ...extras,
});

test("two devices sync a private meeting and recover one transcription after an interrupted upload", async (t) => {
  const { env, request, login, restart } = accountFlow(t);
  const mac = await login(verifiedEmail, true);
  const phone = await login(verifiedEmail);
  const other = await login("jamie@example.test");
  assert.equal(mac.userId, phone.userId);
  assert.notEqual(mac.token, phone.token);
  assert.notEqual(other.userId, mac.userId);

  const meetingId = randomUUID();
  const recordingId = randomUUID();
  const meeting = `/meetings/${meetingId}`;
  const recording = `${meeting}/recordings/${recordingId}`;
  const created = expectSuccess(await request("PUT", meeting, {
    token: mac.token, body: meetingChange("Synthetic desktop meeting"),
  })).meeting;
  const phoneCalendar = expectSuccess(await request("GET", "/meetings", { token: phone.token }));
  assert.deepEqual(phoneCalendar.meetings.map(({ id, title }) => ({ id, title })), [
    { id: meetingId, title: "Synthetic desktop meeting" },
  ]);
  const phoneUpdate = meetingChange("Synthetic phone update", created.revision);
  const updated = expectSuccess(await request("PUT", meeting, {
    token: phone.token, body: phoneUpdate,
  })).meeting;
  assert.equal(updated.title, "Synthetic phone update");
  assert.deepEqual(expectSuccess(await request("GET", "/meetings", { token: other.token })).meetings, []);

  // The provider never sees actual media. The API stores only these deterministic fixture bytes.
  const fixture = new TextEncoder().encode("synthetic fixture bytes");
  const audio = new Uint8Array(8 * 1024 * 1024 + fixture.length);
  audio.set(fixture);
  audio.set(fixture, audio.length - fixture.length);
  const proposal = {
    size: audio.length,
    sha256: createHash("sha256").update(audio).digest("hex"),
    mimeType: "audio/mp4",
    consent: true,
    provider: "deepgram",
  };
  expectInaccessible(await request("PUT", recording, { token: other.token, body: proposal }));
  const noConsent = await request("PUT", recording, {
    token: phone.token, body: { ...proposal, consent: false },
  });
  assert.ok([400, 403, 422].includes(noConsent.status), JSON.stringify(noConsent));
  const upload = expectSuccess(await request("PUT", recording, { token: phone.token, body: proposal }));
  assert.ok(upload.partSize > 0 && upload.partSize < audio.length);
  const firstPart = audio.subarray(0, upload.partSize);
  const remaining = audio.subarray(upload.partSize);
  assert.ok(remaining.length <= upload.partSize);
  expectSuccess(await request("PUT", `${recording}/parts/0`, { token: phone.token, body: firstPart }));
  const incomplete = await request("POST", `${recording}/complete`, { token: phone.token, body: {} });
  assert.ok([400, 409, 422].includes(incomplete.status), JSON.stringify(incomplete));

  restart();
  let prematureCalls = 0;
  await processPending(env, { fetch: async () => { prematureCalls++; return Response.json({}); } });
  assert.equal(prematureCalls, 0);
  expectInaccessible(await request("PUT", `${recording}/parts/0`, { token: other.token, body: firstPart }));
  // A client that lost the acknowledgement must safely repeat a saved part and completion.
  expectSuccess(await request("PUT", `${recording}/parts/0`, { token: phone.token, body: firstPart }));
  const altered = firstPart.slice();
  altered[0] ^= 1;
  assert.equal((await request("PUT", `${recording}/parts/0`, { token: phone.token, body: altered })).status, 409);
  expectSuccess(await request("PUT", `${recording}/parts/1`, { token: phone.token, body: remaining }));
  expectInaccessible(await request("POST", `${recording}/complete`, { token: other.token, body: {} }));
  expectSuccess(await request("POST", `${recording}/complete`, { token: phone.token, body: {} }));
  expectSuccess(await request("POST", `${recording}/complete`, { token: phone.token, body: {} }));

  restart();
  let processorCalls = 0;
  const processor = async (url, options) => {
    processorCalls++;
    assert.equal(new URL(url).hostname, "api.deepgram.com");
    assert.deepEqual(new Uint8Array(await new Response(options.body).arrayBuffer()), audio);
    return Response.json({
      metadata: { request_id: "synthetic-request" },
      results: {
        channels: [{ alternatives: [{ transcript: transcriptText, words: [] }] }],
      },
    });
  };
  await processPending(env, { fetch: processor });
  await processPending(env, { fetch: processor });
  assert.equal(processorCalls, 1);
  for (const { token } of [mac, phone]) {
    const { meetings } = expectSuccess(await request("GET", "/meetings", { token }));
    assert.equal(meetings.length, 1);
    assert.equal(meetings[0].title, updated.title);
    assert.equal(meetings[0].recordings.length, 1);
    const [saved] = meetings[0].recordings;
    assert.equal(saved.id, recordingId);
    assert.equal(saved.status, "completed");
    assert.match(JSON.stringify(saved.transcript), /This is a synthetic account flow transcript/);
  }
  assert.deepEqual(expectSuccess(await request("GET", "/meetings", { token: other.token })).meetings, []);
  expectInaccessible(await request("GET", recording, { token: other.token }));
  assert.equal((await request("GET", recording)).status, 401);
  expectSuccess(await request("POST", "/auth/logout", { token: phone.token, body: {} }));
  assert.equal((await request("GET", recording, { token: phone.token })).status, 401);
  assert.equal(expectSuccess(await request("GET", recording, { token: mac.token })).id, recordingId);
});

test("meeting replay, concurrent revisions, deletion and session revocation survive reopening storage", async (t) => {
  const { request, login, restart } = accountFlow(t);
  const first = await login(verifiedEmail);
  const second = await login(verifiedEmail);
  const other = await login("jamie@example.test");
  const id = randomUUID();
  const route = `/meetings/${id}`;
  const create = meetingChange("Synthetic mobile meeting");
  assert.equal((await request("GET", "/meetings")).status, 401);
  const initial = expectSuccess(await request("PUT", route, { token: first.token, body: create })).meeting;

  restart();
  const replay = expectSuccess(await request("PUT", route, { token: first.token, body: create })).meeting;
  assert.equal(replay.revision, initial.revision);
  assert.equal((await request("PUT", route, {
    token: first.token, body: { ...create, title: "Different payload with same mutation ID" },
  })).status, 409);
  const update = meetingChange("Desktop moved the meeting", initial.revision, {
    startAt: "2026-11-20T15:00:00.000Z", endAt: "2026-11-20T15:30:00.000Z",
  });
  const latest = expectSuccess(await request("PUT", route, { token: second.token, body: update })).meeting;
  assert.equal(latest.startAt, update.startAt);
  assert.equal(latest.endAt, update.endAt);
  assert.equal((await request("PUT", route, {
    token: first.token, body: meetingChange("Stale update", initial.revision),
  })).status, 409);
  expectInaccessible(await request("PUT", route, {
    token: other.token, body: meetingChange("Different account update", latest.revision),
  }));

  expectSuccess(await request("PUT", route, {
    token: first.token, body: meetingChange(latest.title, latest.revision, { deleted: true }),
  }));
  assert.equal((await request("PUT", route, {
    token: second.token, body: meetingChange("Stale resurrection", latest.revision),
  })).status, 409);
  const { meetings } = expectSuccess(await request("GET", "/meetings", { token: second.token }));
  assert.equal(meetings.find(({ id: meetingId }) => meetingId === id)?.deleted, true);
  expectSuccess(await request("POST", "/auth/logout", { token: first.token, body: {} }));

  restart();
  assert.equal((await request("GET", "/auth/session", { token: first.token })).status, 401);
  assert.equal((await request("GET", "/meetings", { token: first.token })).status, 401);
  assert.equal((await request("PUT", route, { token: first.token, body: create })).status, 401);
  assert.equal(expectSuccess(await request("GET", "/auth/session", { token: second.token })).userId, second.userId);
});

test("an unconfirmed provider submission is held for review after restart", async (t) => {
  const { env, request, login, restart } = accountFlow(t);
  const { token } = await login(verifiedEmail);
  const route = `/meetings/${randomUUID()}`;
  const recording = `${route}/recordings/${randomUUID()}`;
  const audio = new TextEncoder().encode("synthetic uncertain submission");
  expectSuccess(await request("PUT", route, { token, body: meetingChange("Synthetic uncertain meeting") }));
  expectSuccess(await request("PUT", recording, {
    token,
    body: {
      size: audio.length,
      sha256: createHash("sha256").update(audio).digest("hex"),
      mimeType: "audio/mp4",
      consent: true,
      provider: "deepgram",
    },
  }));
  expectSuccess(await request("PUT", `${recording}/parts/0`, { token, body: audio }));
  expectSuccess(await request("POST", `${recording}/complete`, { token, body: {} }));
  let submissions = 0;
  const processor = async (_url, options) => {
    submissions++;
    assert.deepEqual(new Uint8Array(await new Response(options.body).arrayBuffer()), audio);
    throw new Error("synthetic loss of response after provider had the payload");
  };
  await processPending(env, { fetch: processor });
  restart();
  expectSuccess(await request("POST", `${recording}/complete`, { token, body: {} }));
  await processPending(env, { fetch: processor, now: () => Date.now() + 30 * 60 * 1000 });
  assert.equal(submissions, 1);
  const result = expectSuccess(await request("GET", recording, { token }));
  assert.equal(result.status, "review");
  assert.equal(result.detail, "submission_uncertain");
  assert.equal(result.transcript, null);
});

test("an explicitly copied local transcript is private, immutable, and removable", async (t) => {
  const { env, request, login, restart } = accountFlow(t);
  const mac = await login(verifiedEmail);
  const phone = await login(verifiedEmail);
  const other = await login("jamie@example.test");
  const first = `/meetings/${randomUUID()}`;
  const second = `/meetings/${randomUUID()}`;
  const importId = randomUUID();
  const route = `${first}/imports/${importId}`;
  const otherMeeting = `${second}/imports/${importId}`;
  const fixture = { transcript: "Una transcripción sintética del Mac.", consent: true };
  const sourceMeeting = expectSuccess(await request("PUT", first, {
    token: mac.token, body: meetingChange("Synthetic import destination"),
  })).meeting;
  expectSuccess(await request("PUT", second, {
    token: mac.token, body: meetingChange("Synthetic second destination"),
  }));
  assert.equal((await request("PUT", route, { body: fixture })).status, 401);
  assert.equal((await request("PUT", route, { token: other.token, body: fixture })).status, 404);
  assert.equal((await request("PUT", route, {
    token: mac.token, body: { ...fixture, consent: false },
  })).status, 400);
  assert.equal((await request("PUT", route, {
    token: mac.token, body: { ...fixture, transcript: "é".repeat(256 * 1024 + 1) },
  })).status, 413);
  const uppercaseIds = `/meetings/${sourceMeeting.id.toUpperCase()}/imports/${importId.toUpperCase()}`;
  assert.equal(expectSuccess(await request("PUT", uppercaseIds, {
    token: mac.token, body: fixture,
  })).recording.id, importId);

  restart();
  expectSuccess(await request("PUT", route, { token: mac.token, body: fixture }));
  assert.equal((await request("PUT", route, {
    token: mac.token, body: { ...fixture, transcript: "Changed synthetic text" },
  })).status, 409);
  assert.equal((await request("PUT", otherMeeting, { token: mac.token, body: fixture })).status, 409);
  const copied = expectSuccess(await request("GET", "/meetings", { token: phone.token }))
    .meetings.find(({id}) => id === sourceMeeting.id).recordings;
  assert.deepEqual(copied, [{ id: importId, status: "completed", transcript: fixture.transcript, source: "local-import" }]);
  assert.deepEqual(expectSuccess(await request("GET", "/meetings", { token: other.token })).meetings, []);
  assert.equal((await request("DELETE", route, { token: other.token })).status, 404);
  assert.equal((await request("DELETE", route, { token: phone.token })).status, 204);
  assert.equal((await request("DELETE", route, { token: phone.token })).status, 204);
  assert.equal((await request("PUT", route, { token: mac.token, body: fixture })).status, 410);
  assert.equal((await request("PUT", otherMeeting, { token: mac.token, body: fixture })).status, 409);
  const movedImport = `${second}/imports/${randomUUID()}`;
  expectSuccess(await request("PUT", movedImport, { token: mac.token, body: fixture }));
  assert.deepEqual(expectSuccess(await request("GET", "/meetings", { token: mac.token }))
    .meetings.find(({id}) => id === sourceMeeting.id).recordings, []);

  const attachedToDeletedMeeting = `${first}/imports/${randomUUID()}`;
  expectSuccess(await request("PUT", attachedToDeletedMeeting, { token: mac.token, body: fixture }));
  expectSuccess(await request("PUT", first, {
    token: mac.token, body: meetingChange(sourceMeeting.title, sourceMeeting.revision, { deleted: true }),
  }));
  assert.equal(await env.ACCOUNT_DB.prepare("SELECT COUNT(*) FROM account_transcript_imports WHERE meeting_id=?")
    .bind(sourceMeeting.id).first("COUNT(*)"), 0);
  assert.equal((await request("PUT", attachedToDeletedMeeting, { token: mac.token, body: fixture })).status, 404);
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 0);
});
