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

  async function request(method, route, { token, body, ctx } = {}) {
    const headers = new Headers();
    if (token) headers.set("authorization", `Bearer ${token}`);
    if (body !== undefined) {
      const binary = body instanceof Uint8Array;
      headers.set("content-type", binary ? "application/octet-stream" : "application/json");
      if (!binary) body = JSON.stringify(body);
    }
    const response = await accountWorker.fetch(new Request(prefix + route, { method, headers, body }), env, ctx);
    assert.match(response.headers.get("cache-control") ?? "", /\bno-store\b/);
    const content = await response.text();
    const type = response.headers.get("content-type") ?? "";
    const parsed = content && type.startsWith("application/json") ? JSON.parse(content) : content || null;
    return { status: response.status, body: parsed, type };
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

test("a meeting delete starts R2 disposal at once, logs only the error class and leaves the cron as fallback", async (t) => {
  const { env, request, login } = accountFlow(t);
  const owner = await login(verifiedEmail);
  const bytes = new TextEncoder().encode("synthetic disposal fixture");
  const proposal = {
    size: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
    consent: true, mimeType: "audio/mp4", provider: "deepgram",
  };
  const logged = t.mock.method(console, "error", () => {});
  async function removeWithAudio(failStorage) {
    const meeting = `/meetings/${randomUUID()}`;
    const recording = `${meeting}/recordings/${randomUUID()}`;
    const created = expectSuccess(await request("PUT", meeting, { token: owner.token, body: meetingChange("Synthetic disposal") })).meeting;
    expectSuccess(await request("PUT", recording, { token: owner.token, body: proposal }));
    expectSuccess(await request("PUT", `${recording}/parts/0`, { token: owner.token, body: bytes }));
    assert.equal(env.ACCOUNT_AUDIO.objects.size, 1);
    const tasks = [];
    const ctx = { waitUntil: (task) => tasks.push(task) };
    const remove = env.ACCOUNT_AUDIO.delete;
    if (failStorage) env.ACCOUNT_AUDIO.delete = async () => { throw new TypeError("synthetic storage failure for alex@example.test"); };
    expectSuccess(await request("PUT", meeting, {
      token: owner.token, ctx, body: meetingChange("Synthetic disposal", created.revision, { deleted: true }),
    }));
    assert.equal(tasks.length, 1);
    await Promise.all(tasks);
    env.ACCOUNT_AUDIO.delete = remove;
  }
  await removeWithAudio(false);
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 0);
  assert.equal(await env.ACCOUNT_DB.prepare("SELECT COUNT(*) AS n FROM account_recordings").first("n"), 0);
  assert.equal(logged.mock.callCount(), 0);

  await removeWithAudio(true);
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 1);
  assert.deepEqual(logged.mock.calls.map((call) => call.arguments), [["account_disposal_failed", "TypeError"]]);
  await processPending(env, { fetch: () => assert.fail("unexpected provider request") });
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 0);

  const ctx = { waitUntil: () => assert.fail("an edit must not start disposal") };
  const kept = `/meetings/${randomUUID()}`;
  const draft = expectSuccess(await request("PUT", kept, { token: owner.token, body: meetingChange("Synthetic kept") })).meeting;
  expectSuccess(await request("PUT", kept, { token: owner.token, ctx, body: meetingChange("Synthetic edit", draft.revision) }));
});

// Synthetic Deepgram result without turns: the published transcript is exactly `words`.
const deepgramWords = (words) => async (_url, options) => {
  await new Response(options.body).arrayBuffer();
  return Response.json({ results: { channels: [{ alternatives: [{ transcript: words, words: [] }] }] } });
};
// About 760 KiB of UTF-8: above the 512 KiB row limit, below the 8 MiB stored limit.
const largeWords = "Línea sintética de prueba. ".repeat(28 * 1024);

async function uploadRecording(env, request, token, meeting, words) {
  const recordingId = randomUUID();
  const recording = `${meeting}/recordings/${recordingId}`;
  const bytes = new TextEncoder().encode(`synthetic audio ${recordingId}`);
  expectSuccess(await request("PUT", recording, { token, body: {
    size: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
    consent: true, mimeType: "audio/mp4", provider: "deepgram",
  } }));
  expectSuccess(await request("PUT", `${recording}/parts/0`, { token, body: bytes }));
  expectSuccess(await request("POST", `${recording}/complete`, { token, body: {} }));
  if (words !== undefined) await processPending(env, { fetch: deepgramWords(words) });
  return recordingId;
}

test("the session advertises account deletion only when the operator enables it, and lazy transcripts always", async (t) => {
  const { env, request, login } = accountFlow(t);
  const { token } = await login(verifiedEmail);
  const features = async () => expectSuccess(await request("GET", "/auth/session", { token })).features;
  assert.deepEqual(await features(), { accountDeletion: false, lazyTranscripts: true });
  for (const value of ["true", "YES", "1", " yes"]) {
    env.ACCOUNT_DELETION_ENABLED = value;
    assert.deepEqual(await features(), { accountDeletion: false, lazyTranscripts: true });
  }
  env.ACCOUNT_DELETION_ENABLED = "yes";
  assert.deepEqual(await features(), { accountDeletion: true, lazyTranscripts: true });
});

test("a lazy agenda carries transcript sizes only and each owner fetches the text per recording", async (t) => {
  const { env, request, login } = accountFlow(t);
  const mac = await login(verifiedEmail);
  const other = await login("jamie@example.test");
  const meetingId = randomUUID();
  const meeting = `/meetings/${meetingId}`;
  const created = expectSuccess(await request("PUT", meeting, { token: mac.token, body: meetingChange("Synthetic lazy agenda") })).meeting;
  const short = "Texto breve sintético.";
  const small = await uploadRecording(env, request, mac.token, meeting, short);
  const large = await uploadRecording(env, request, mac.token, meeting, largeWords);
  const queued = await uploadRecording(env, request, mac.token, meeting);
  const importId = randomUUID();
  const copied = "Copia local sintética del Mac.";
  expectSuccess(await request("PUT", `${meeting}/imports/${importId}`, { token: mac.token, body: { transcript: copied, consent: true } }));
  const size = (text) => new TextEncoder().encode(text).length;

  const full = expectSuccess(await request("GET", "/meetings", { token: mac.token }));
  const byId = (list) => Object.fromEntries(list.meetings[0].recordings.map((recording) => [recording.id, recording]));
  const inline = byId(full);
  assert.equal(inline[small].transcript, short);
  assert.equal("transcriptStoredSeparately" in inline[small], false);
  assert.equal(inline[large].status, "completed");
  assert.equal(inline[large].transcript, null);
  assert.equal(inline[large].transcriptStoredSeparately, true);
  assert.deepEqual(inline[importId], { id: importId, status: "completed", transcript: copied, source: "local-import" });

  const lazy = expectSuccess(await request("GET", "/meetings?transcripts=lazy", { token: mac.token }));
  assert.equal(lazy.version, full.version);
  const sized = byId(lazy);
  assert.deepEqual(Object.values(sized).map(({ transcript }) => transcript), [null, null, null, null]);
  assert.deepEqual(
    [small, large, queued, importId].map((id) => [sized[id].transcriptAvailable, sized[id].transcriptBytes]),
    [[true, size(short)], [true, size(largeWords)], [false, null], [true, size(copied)]],
  );
  assert.equal(sized[importId].source, "local-import");
  assert.ok(Object.values(sized).every((recording) => !("transcriptStoredSeparately" in recording)));
  assert.deepEqual(expectSuccess(await request("GET", `/meetings?transcripts=lazy&since=${lazy.version}`, { token: mac.token })),
    { unchanged: true, version: lazy.version });
  const stale = expectSuccess(await request("GET", "/meetings?since=00000000000000000000000000000000&transcripts=lazy", { token: mac.token }));
  assert.deepEqual(stale, lazy);

  const transcriptOf = (id, token = mac.token) => request("GET", `${meeting}/recordings/${id}/transcript`, { token });
  for (const [id, text] of [[small, short], [large, largeWords], [importId, copied]]) {
    const response = await transcriptOf(id);
    assert.equal(response.status, 200);
    assert.equal(response.type, "text/plain; charset=utf-8");
    assert.equal(response.body, text);
    assert.deepEqual(await transcriptOf(id, other.token), { status: 404, body: { error: "not_found" }, type: "application/json" });
    assert.equal((await transcriptOf(id, null)).status, 401);
  }
  assert.deepEqual((await transcriptOf(queued)).body, { error: "not_found" });
  assert.deepEqual((await transcriptOf(randomUUID())).body, { error: "not_found" });
  assert.equal((await request("GET", `/meetings/${randomUUID()}/recordings/${small}/transcript`, { token: mac.token })).status, 404);

  expectSuccess(await request("PUT", meeting, {
    token: mac.token, body: meetingChange(created.title, created.revision, { deleted: true }),
  }));
  for (const id of [small, large, importId]) assert.equal((await transcriptOf(id)).status, 404);
  await processPending(env, { fetch: () => assert.fail("unexpected provider request") });
  await processPending(env, { fetch: () => assert.fail("unexpected provider request") });
  await processPending(env, { fetch: () => assert.fail("unexpected provider request") });
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 0);
});

test("account deletion needs the operator flag, a session and the typed confirmation, then revokes every session", async (t) => {
  const { env, request, login } = accountFlow(t);
  const mac = await login(verifiedEmail);
  const phone = await login(verifiedEmail);
  const other = await login("jamie@example.test");
  const confirmation = { confirmation: "DELETE" };
  const logs = t.mock.method(console, "log", () => {});
  const errors = t.mock.method(console, "error", () => {});
  for (const token of [mac.token, other.token]) {
    const meeting = `/meetings/${randomUUID()}`;
    expectSuccess(await request("PUT", meeting, { token, body: meetingChange("Synthetic deletion fixture") }));
    await uploadRecording(env, request, token, meeting, largeWords);
  }
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 4);

  assert.deepEqual(await request("POST", "/account/delete", { token: mac.token, body: confirmation }),
    { status: 403, body: { error: "deletion_disabled" }, type: "application/json" });
  env.ACCOUNT_DELETION_ENABLED = "yes";
  assert.equal((await request("POST", "/account/delete", { body: confirmation })).status, 401);
  assert.equal((await request("POST", "/account/delete", { token: "x".repeat(43), body: confirmation })).status, 401);
  assert.equal((await request("GET", "/account/delete", { token: mac.token })).status, 405);
  assert.equal((await request("POST", "/account/remove", { token: mac.token, body: confirmation })).status, 404);
  for (const body of [undefined, {}, { confirmation: "delete" }, { confirmation: "DELETE ".repeat(200) }, ["DELETE"]]) {
    assert.deepEqual((await request("POST", "/account/delete", { token: mac.token, body })).body, { error: "confirmation_required" });
  }
  const malformed = await accountWorker.fetch(new Request(`${prefix}/account/delete`, {
    method: "POST", headers: { authorization: `Bearer ${mac.token}` }, body: "{confirmation: DELETE}",
  }), env);
  assert.equal(malformed.status, 400);
  assert.equal(expectSuccess(await request("GET", "/auth/session", { token: phone.token })).userId, mac.userId);
  assert.equal(logs.mock.callCount(), 0);

  // R2 fails during the immediate disposal; the queue keeps the objects for the cron.
  const tasks = [];
  const remove = env.ACCOUNT_AUDIO.delete;
  env.ACCOUNT_AUDIO.delete = async () => { throw new TypeError(`synthetic storage failure for ${verifiedEmail}`); };
  const deleted = await request("POST", "/account/delete", { token: mac.token, body: confirmation, ctx: { waitUntil: (task) => tasks.push(task) } });
  assert.deepEqual(deleted, { status: 202, body: { status: "deleting" }, type: "application/json" });
  assert.equal(tasks.length, 1);
  await Promise.all(tasks);
  env.ACCOUNT_AUDIO.delete = remove;
  assert.deepEqual(errors.mock.calls.map((call) => call.arguments), [["account_disposal_failed", "TypeError"]]);
  const [audit] = logs.mock.calls.map((call) => call.arguments);
  assert.equal(logs.mock.callCount(), 1);
  assert.equal(audit[0], "account_deleted");
  assert.match(audit[1], /^[0-9a-f]{12}$/);
  assert.ok(!JSON.stringify(audit).includes(mac.userId) && !JSON.stringify(audit).includes(verifiedEmail));

  for (const token of [mac.token, phone.token]) {
    assert.equal((await request("GET", "/auth/session", { token })).status, 401);
    assert.equal((await request("GET", "/meetings", { token })).status, 401);
    assert.equal((await request("POST", "/account/delete", { token, body: confirmation })).status, 401);
  }
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 4);
  assert.equal(await env.ACCOUNT_DB.prepare("SELECT COUNT(*) AS n FROM account_disposals").first("n"), 1);
  await processPending(env, { fetch: () => assert.fail("unexpected provider request") });
  assert.equal(await env.ACCOUNT_DB.prepare("SELECT COUNT(*) AS n FROM account_disposals").first("n"), 0);
  const [otherBlob] = (await env.ACCOUNT_DB.prepare("SELECT blob_id FROM account_recordings").all()).results.map((row) => row.blob_id);
  assert.deepEqual([...env.ACCOUNT_AUDIO.objects.keys()].sort(), [`recordings/${otherBlob}/0`, `recordings/${otherBlob}/transcript`]);
  assert.equal(expectSuccess(await request("GET", "/meetings", { token: other.token })).meetings.length, 1);

  // The address can start again as a new, empty account.
  const again = await login(verifiedEmail);
  assert.notEqual(again.userId, mac.userId);
  assert.deepEqual(expectSuccess(await request("GET", "/meetings", { token: again.token })).meetings, []);
});

test("account deletion removes every row that refers to the user in every table, and keeps another user's", async (t) => {
  const { env, request, login } = accountFlow(t);
  const db = env.ACCOUNT_DB;
  env.ACCOUNT_DELETION_ENABLED = "yes";
  t.mock.method(console, "log", () => {});
  async function populate(email) {
    const device = await login(email);
    await login(email);
    const meetingId = randomUUID();
    const meeting = `/meetings/${meetingId}`;
    const project = { id: randomUUID(), name: `Synthetic project ${email}` };
    const created = expectSuccess(await request("PUT", meeting, { token: device.token, body: meetingChange("Synthetic full account", 0, { project }) })).meeting;
    expectSuccess(await request("PUT", meeting, { token: device.token, body: meetingChange("Synthetic edited", created.revision, { project }) }));
    const recordingIds = [await uploadRecording(env, request, device.token, meeting, largeWords), await uploadRecording(env, request, device.token, meeting, "Texto sintético breve.")];
    const importId = randomUUID();
    expectSuccess(await request("PUT", `${meeting}/imports/${importId}`, { token: device.token, body: { transcript: "Copia sintética.", consent: true } }));
    // Unfinished sign-in elsewhere and an unfinished link from this session, including a browser attempt.
    const linkEmail = `link-${email}`;
    expectSuccess(await request("POST", "/auth/email/start", { body: { email } }));
    const { challengeId } = expectSuccess(await request("POST", "/auth/email/start", { token: device.token, body: { email: linkEmail, link: true } }));
    await db.prepare(`INSERT INTO account_browser_attempts (poll_hash,state_hash,link_bearer_hash,challenge_id,expires_at,phase)
      VALUES (?,?,?,?,?,'waiting')`).bind(randomUUID(), randomUUID(), randomUUID(), challengeId, Date.now() + 60_000).run();
    const sessions = (await db.prepare("SELECT session_id FROM account_sessions WHERE user_id=?").bind(device.userId).all()).results;
    const blobs = (await db.prepare("SELECT blob_id FROM account_recordings WHERE user_id=?").bind(device.userId).all()).results;
    const markers = [device.userId, email, linkEmail, challengeId, meetingId, project.id, importId, ...recordingIds,
      ...sessions.map((row) => row.session_id), ...blobs.map((row) => row.blob_id)];
    return { ...device, markers, blobs: blobs.map((row) => row.blob_id) };
  }
  const target = await populate(verifiedEmail);
  const other = await populate("jamie@example.test");
  const tables = (await db.prepare("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all())
    .results.map((row) => row.name);
  const userTables = [];
  for (const table of tables) {
    const columns = (await db.prepare("SELECT name FROM pragma_table_info(?)").bind(table).all()).results.map((row) => row.name);
    if (columns.includes("user_id")) userTables.push(table);
  }
  const owned = async (table, userId) => db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id=?`).bind(userId).first("n");
  // A new user-keyed table fails here until this fixture fills it, and then the scan below requires its deletion.
  for (const table of userTables) assert.ok(await owned(table, target.userId) > 0, `fixture does not populate ${table}`);
  const mentions = async (markers) => {
    const found = [];
    for (const table of tables) {
      for (const row of (await db.prepare(`SELECT * FROM ${table}`).all()).results) {
        const text = JSON.stringify(row);
        if (markers.some((marker) => text.includes(marker))) found.push(table);
      }
    }
    return [...new Set(found)];
  };
  for (const table of ["account_recording_parts", "account_recording_transcripts", "account_auth_challenges", "account_browser_attempts"]) {
    assert.ok((await mentions(target.markers)).includes(table), table);
  }

  const tasks = [];
  expectSuccess(await request("POST", "/account/delete", { token: target.token, body: { confirmation: "DELETE" }, ctx: { waitUntil: (task) => tasks.push(task) } }));
  await Promise.all(tasks);
  assert.deepEqual(await mentions(target.markers), []);
  for (const table of userTables) assert.ok(await owned(table, other.userId) > 0, `${table} lost another user's rows`);
  assert.deepEqual((await mentions(other.markers)).sort(), [
    "account_auth_challenges", "account_browser_attempts", "account_calendar_versions", "account_emails", "account_identities",
    "account_meeting_mutations", "account_meeting_projects", "account_meetings", "account_projects", "account_recording_parts",
    "account_recording_transcripts", "account_recordings", "account_sessions", "account_transcript_imports", "account_users",
  ]);
  const keys = [...env.ACCOUNT_AUDIO.objects.keys()];
  assert.ok(target.blobs.every((blob) => !keys.some((key) => key.includes(blob))));
  assert.ok(other.blobs.every((blob) => keys.includes(`recordings/${blob}/0`)));
});
