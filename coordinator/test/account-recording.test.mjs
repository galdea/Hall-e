import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { openAccountDatabase, memoryRecordingBucket } from "../test-support/account.mjs";
import { handleRecording, processPending, recordingsFor } from "../src/account-recording.mjs";

const body = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0, 1, 2, 3]);
const manifest = {
  size: body.length,
  sha256: createHash("sha256").update(body).digest("hex"),
  consent: true,
  mimeType: "audio/wav",
  provider: "deepgram",
};

async function setup(t) {
  const db = openAccountDatabase();
  const bucket = memoryRecordingBucket();
  const env = {
    ACCOUNT_DB: db,
    ACCOUNT_AUDIO: bucket,
    ACCOUNT_ENABLE_TRANSCRIPTION: "yes",
    ACCOUNT_DEEPGRAM_KEY: "fixture",
    ACCOUNT_SPEECHMATICS_KEY: "fixture",
    ACCOUNT_SPEECHMATICS_REGION: "eu1",
    ACCOUNT_SPEECHMATICS_TRAINING_OPT_OUT: "confirmed",
  };
  t.after(() => db.close());
  for (const user of ["one", "two"]) {
    await db
      .prepare(
        "INSERT INTO account_meetings VALUES (?, 'meeting', 'Fixture', '2026-11-20T00:00:00Z', '2026-11-20T00:30:00Z', 1, 0, 'fixture')",
      )
      .bind(user)
      .run();
  }
  const call = async (method, tail, data, user = "one") => {
    const request = new Request("https://fixture.invalid/", {
      method,
      body: data instanceof Uint8Array ? data : data === undefined ? undefined : JSON.stringify(data),
    });
    return handleRecording(request, env, user, "meeting", "recording", tail);
  };
  const queue = async (spec = manifest) => {
    assert.equal((await call("PUT", "", spec)).status, 200);
    assert.equal((await call("PUT", "parts/0", body)).status, 200);
    assert.equal((await (await call("POST", "complete")).json()).status, "queued");
  };
  const read = async (user = "one") => (await call("GET", "", undefined, user)).json();
  return { env, db, bucket, call, queue, read };
}

test("replay repairs R2 IO interrupted after the write, without accepting a different part or manifest", async (t) => {
  const { env, bucket, call, read } = await setup(t);
  await call("PUT", "", manifest);
  const original = bucket.put.bind(bucket);
  bucket.put = async (...args) => {
    await original(...args);
    throw new Error("lost acknowledgement");
  };
  await assert.rejects(call("PUT", "parts/0", body), /acknowledgement/);
  bucket.put = original;
  assert.equal((await call("POST", "complete")).status, 409);
  assert.equal((await call("PUT", "parts/0", body.subarray(0, 4))).status, 400);
  assert.equal(
    (
      await call(
        "PUT",
        "parts/0",
        body.map((b) => b + 1),
      )
    ).status,
    409,
  );
  assert.equal((await call("PUT", "", { ...manifest, mimeType: "audio/mp4" })).status, 409);
  await call("PUT", "parts/0", body);
  assert.equal((await call("POST", "complete")).status, 200);
  assert.equal((await read()).status, "queued");
  assert.equal(bucket.objects.size, 1);
  assert.deepEqual(await recordingsFor(env, "two"), []);
});

test("a verified size without the declared full file digest never reaches the processor", async (t) => {
  const { env, call, read } = await setup(t);
  await call("PUT", "", { ...manifest, sha256: "a".repeat(64) });
  await call("PUT", "parts/0", body);
  assert.equal((await call("POST", "complete")).status, 409);
  await processPending(env, { fetch: () => assert.fail("unexpected processor") });
  assert.equal((await read()).status, "uploading");
});

test("a dropped provider acknowledgement or expired submission claim requires review and never resubmits", async (t) => {
  const { env, db, queue, call, read } = await setup(t);
  await queue();
  let calls = 0;
  async function lostAck(_, { body: sent }) {
    calls++;
    assert.deepEqual(new Uint8Array(await new Response(sent).arrayBuffer()), body);
    throw new Error("provider accepted, connection dropped");
  }
  await Promise.all([processPending(env, { fetch: lostAck }), processPending(env, { fetch: lostAck })]);
  assert.equal((await read()).status, "review");
  await call("POST", "complete");
  await processPending(env, { fetch: lostAck });
  assert.equal(calls, 1);
  await db.prepare("UPDATE account_recordings SET status='submitting',next_at=1,detail=NULL").run();
  await processPending(env, { fetch: lostAck });
  assert.equal((await read()).detail, "submission_uncertain");
  assert.equal(calls, 1);
});

test("Speechmatics uses the consented region and persists the remote job before retry-safe polling", async (t) => {
  const { env, queue, read } = await setup(t);
  const spec = { ...manifest, provider: "speechmatics", region: "eu1" };
  await queue(spec);
  let at = Date.now(),
    submitted = 0,
    polls = 0,
    reference;
  const options = {
    now: () => at,
    fetch: async (url, init) => {
      const address = new URL(url);
      assert.equal(address.hostname, "eu1.asr.api.speechmatics.com");
      if (init.method === "POST") {
        submitted++;
        const payload = await new Response(init.body).text();
        assert.match(payload, /"model":"melia-1"/);
        reference = /"reference":"([^"]+)"/.exec(payload)[1];
        return Response.json({ id: "remote_fixture" }, { status: 201 });
      }
      if (address.pathname.endsWith("/transcript"))
        return Response.json({
          results: [
            { type: "word", start_time: 1.25, end_time: 1.5, alternatives: [{ content: "Hola", speaker: "S1" }] },
            { type: "punctuation", attaches_to: "previous", is_eos: true, alternatives: [{ content: "." }] },
          ],
        });
      polls++;
      return polls === 1
        ? new Response(null, { status: 503 })
        : Response.json({ job: { id: "remote_fixture", status: "done", tracking: { reference } } });
    },
  };
  env.ACCOUNT_SPEECHMATICS_REGION = "us1";
  await processPending(env, options);
  assert.equal(submitted, 0);
  assert.equal((await read()).detail, "provider_unconfigured");
  env.ACCOUNT_SPEECHMATICS_REGION = "eu1";
  at += 61_000;
  await processPending(env, options);
  assert.equal((await read()).status, "processing");
  at += 61_000;
  await processPending(env, options);
  assert.equal((await read()).status, "processing");
  at += 61_000;
  await processPending(env, options);
  assert.equal((await read()).transcript, "[0:00:01.250–0:00:01.500 · S1] Hola.");
  assert.equal(submitted, 1);
  assert.equal(polls, 2);
});

test("delete hides account artifacts immediately and resumes interrupted garbage collection", async (t) => {
  const { env, db, bucket, queue, call } = await setup(t);
  await queue();
  // A different user's recording with the same client identifiers has independent private storage.
  await call("PUT", "", manifest, "two");
  await call("PUT", "parts/0", body, "two");
  assert.equal(bucket.objects.size, 2);
  await db.prepare("UPDATE account_meetings SET deleted=1 WHERE user_id='one'").run();
  assert.equal((await call("GET", "")).status, 404);
  const del = bucket.delete.bind(bucket);
  bucket.delete = async () => {
    throw new Error("temporary storage failure");
  };
  const noSend = { fetch: () => assert.fail("unexpected provider request") };
  await assert.rejects(processPending(env, noSend), /storage failure/);
  bucket.delete = del;
  await processPending(env, noSend);
  assert.equal(bucket.objects.size, 1);
  assert.equal((await db.prepare("SELECT COUNT(*) n FROM account_recording_parts").first()).n, 1);
  assert.equal((await call("GET", "", undefined, "two")).status, 200);
  const week = 7 * 24 * 60 * 60 * 1000;
  await processPending(env, { ...noSend, now: () => Date.now() + week + 10_000 });
  assert.equal(bucket.objects.size, 0);
});

test("Deepgram publishes the returned turn boundaries and speaker IDs using desktop model options", async (t) => {
  const { env, queue, read } = await setup(t);
  await queue();
  await processPending(env, {
    fetch: async (url, options) => {
      assert.equal(url.searchParams.get("mip_opt_out"), "true");
      assert.equal(url.searchParams.get("model"), "nova-3");
      assert.equal(url.searchParams.get("diarize_model"), "v2");
      assert.deepEqual(new Uint8Array(await new Response(options.body).arrayBuffer()), body);
      return Response.json({
        results: {
          channels: [{ alternatives: [{ transcript: "Hola. Sí." }] }],
          utterances: [
            { speaker: 0, start: 1, end: 2.1, transcript: "Hola." },
            { speaker: 1, start: 5, end: 6.22, transcript: "Sí." },
          ],
        },
      });
    },
  });
  assert.equal(
    (await read()).transcript,
    "[0:00:01.000–0:00:02.100 · S0] Hola.\n[0:00:05.000–0:00:06.220 · S1] Sí.",
  );
});

test("a provider redirect stops locally and cannot forward audio or the authorization header", async (t) => {
  const { env, queue, read } = await setup(t);
  await queue();
  let calls = 0;
  const send = async (url, options) => {
    calls++;
    assert.equal(new URL(url).hostname, "api.deepgram.com");
    assert.equal(options.redirect, "manual");
    await new Response(options.body).arrayBuffer();
    return Response.redirect("https://fixture.invalid/no-follow", 307);
  };
  await processPending(env, { fetch: send });
  await processPending(env, { fetch: send });
  assert.equal((await read()).status, "failed");
  assert.equal(calls, 1);
});

test("Speechmatics accepts UU or missing speaker tokens without discarding the transcript", async (t) => {
  const { env, queue, read } = await setup(t);
  await queue({ ...manifest, provider: "speechmatics", region: "eu1" });
  let at = Date.now(),
    reference;
  const options = {
    now: () => at,
    fetch: async (url, init) => {
      const address = new URL(url);
      if (init.method === "POST") {
        const payload = await new Response(init.body).text();
        reference = /"reference":"([^"]+)"/.exec(payload)[1];
        return Response.json({ id: "remote_uu" }, { status: 201 });
      }
      if (address.pathname.endsWith("/transcript")) {
        return Response.json({
          results: [
            { type: "word", start_time: 1.0, end_time: 1.4, alternatives: [{ content: "Hola", speaker: "UU" }] },
            { type: "punctuation", attaches_to: "previous", is_eos: true, alternatives: [{ content: "." }] },
            { type: "word", start_time: 1.6, end_time: 2.0, alternatives: [{ content: "Mundo", speaker: "S1" }] },
            { type: "punctuation", attaches_to: "previous", is_eos: true, alternatives: [{ content: "." }] },
          ],
        });
      }
      return Response.json({ job: { id: "remote_uu", status: "done", tracking: { reference } } });
    },
  };
  await processPending(env, options);
  at += 61_000;
  await processPending(env, options);
  const done = await read();
  assert.equal(done.status, "completed");
  assert.equal(done.transcript, "[0:00:01.000–0:00:01.400] Hola.\n[0:00:01.600–0:00:02.000 · S1] Mundo.");
});

test("uploading while a stale recording is disposing on a live meeting returns retryable 503", async (t) => {
  const { env, db, call } = await setup(t);
  assert.equal((await call("PUT", "", manifest)).status, 200);
  await db.prepare("UPDATE account_recordings SET status='disposing' WHERE user_id='one'").run();
  const initRes = await call("PUT", "", manifest);
  assert.equal(initRes.status, 503);
  assert.equal((await initRes.json()).error, "upload_disposing");
  assert.equal((await call("PUT", "parts/0", body)).status, 503);
  assert.equal((await call("POST", "complete", {})).status, 503);
  assert.equal((await call("GET", "")).status, 404);
  await db.prepare("UPDATE account_meetings SET deleted=1 WHERE user_id='one'").run();
  assert.equal((await call("PUT", "", manifest)).status, 404);
});

test("a stored part missing from R2 or of the wrong size is requested again, keeping the parts that are present", async (t) => {
  const { db, bucket, call, read } = await setup(t);
  const MiB = 1024 * 1024;
  const large = new Uint8Array(8 * MiB + 8).map((_, i) => i % 251);
  const spec = { ...manifest, size: large.length, sha256: createHash("sha256").update(large).digest("hex") };
  const first = large.subarray(0, 8 * MiB),
    second = large.subarray(8 * MiB);
  await call("PUT", "", spec);
  assert.equal((await call("PUT", "parts/0", first)).status, 200);
  assert.equal((await call("PUT", "parts/1", second)).status, 200);
  const [kept, lost] = [...bucket.objects.keys()].sort();
  bucket.objects.delete(lost);
  const stored = () => db.prepare("SELECT part_index, stored FROM account_recording_parts ORDER BY part_index").all();
  const missing = await call("POST", "complete");
  assert.equal(missing.status, 409);
  assert.equal((await missing.json()).error, "missing_parts");
  assert.deepEqual((await stored()).results.map((p) => p.stored), [1, 0]);
  assert.equal(bucket.objects.get(kept).size, 8 * MiB);
  assert.equal((await call("PUT", "parts/1", second.map((b) => b + 1))).status, 409);
  assert.equal((await call("PUT", "parts/1", second)).status, 200);
  assert.equal((await (await call("POST", "complete")).json()).status, "queued");

  // A truncated object is replaced only by the bytes matching the part's reserved digest.
  const { call: other, bucket: otherBucket, read: otherRead } = await setup(t);
  await other("PUT", "", manifest);
  await other("PUT", "parts/0", body);
  const [only] = otherBucket.objects.keys();
  await otherBucket.put(only, body.subarray(0, 3));
  assert.equal((await (await other("POST", "complete")).json()).error, "missing_parts");
  assert.equal((await otherRead()).status, "uploading");
  await other("PUT", "parts/0", body);
  assert.deepEqual(otherBucket.objects.get(only).bytes, body);
  assert.equal((await (await other("POST", "complete")).json()).status, "queued");
  assert.equal((await read()).status, "queued");
});

test("an oversize transcript keeps its audio and provider reference until the owner discards the recording", async (t) => {
  const { env, db, bucket, queue, call, read } = await setup(t);
  await queue();
  const turn = { speaker: 0, start: 0, end: 1, transcript: "x".repeat(600 * 1024) };
  await processPending(env, {
    fetch: async () =>
      Response.json({
        metadata: { request_id: "dg-fixture-request" },
        results: { channels: [{ alternatives: [{ transcript: "x" }] }], utterances: [turn] },
      }),
  });
  const held = await read();
  assert.equal(held.status, "review");
  assert.equal(held.detail, "transcript_unreadable_or_oversize");
  assert.equal(held.transcript, null);
  const row = () => db.prepare("SELECT status, provider_job FROM account_recordings WHERE user_id='one'").first();
  assert.equal((await row()).provider_job, "dg-fixture-request");
  const week = 7 * 24 * 60 * 60 * 1000;
  const noSend = { fetch: () => assert.fail("unexpected provider request"), now: () => Date.now() + 2 * week };
  await processPending(env, noSend);
  assert.equal(bucket.objects.size, 1);
  assert.equal((await read()).status, "review");
  assert.equal((await call("DELETE", "", undefined, "two")).status, 404);

  const discard = await call("DELETE", "");
  assert.equal(discard.status, 204);
  assert.equal((await call("DELETE", "")).status, 204);
  assert.equal((await call("GET", "")).status, 404);
  assert.deepEqual(await recordingsFor(env, "one"), []);
  assert.equal((await row()).status, "disposing");
  await processPending(env, noSend);
  assert.equal(bucket.objects.size, 0);
  assert.equal(await row(), null);
  assert.equal((await call("DELETE", "")).status, 404);
});

test("a provider response over 12 MiB keeps Deepgram's request header, and active recordings cannot be discarded", async (t) => {
  const { env, db, queue, call, read } = await setup(t);
  await queue();
  assert.equal((await (await call("DELETE", "")).json()).error, "recording_active");
  await processPending(env, {
    fetch: async () =>
      new Response(new Uint8Array(12 * 1024 * 1024 + 1), { headers: { "dg-request-id": "dg-header-request" } }),
  });
  assert.equal((await read()).detail, "transcript_unreadable_or_oversize");
  const job = await db.prepare("SELECT provider_job FROM account_recordings WHERE user_id='one'").first("provider_job");
  assert.equal(job, "dg-header-request");
  assert.equal((await call("DELETE", "")).status, 204);
});
