import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

import staging from "../src/account-staging-worker.mjs";
import stagingMail from "../src/staging-mailbox.mjs";
import { handleRecording } from "../src/account-recording.mjs";
import { runStagingSmoke } from "../scripts/account-staging-smoke.mjs";
import { memoryRecordingBucket, openAccountDatabase } from "../test-support/account.mjs";

const tone = await readFile(new URL("../test-support/phone-tone.mp4", import.meta.url));

function setup(t) {
  const db = openAccountDatabase();
  t.after(() => db.close());
  return { ACCOUNT_DB: db, ACCOUNT_AUDIO: memoryRecordingBucket(), ACCOUNT_STAGING_FIXTURE: "yes" };
}

test("hosted QA story exercises the actual staging entrypoint, shared fixture result and revocation", async t => {
  const env = setup(t);
  await env.ACCOUNT_DB.exec(await readFile(new URL("../staging/mailbox.sql", import.meta.url), "utf8"));
  env.ACCOUNT_AUTH_SECRET = randomUUID() + randomUUID();
  env.ACCOUNT_STAGING_TESTER_EMAILS = "halle-owner@example.test,halle-other@example.test";
  env.ACCOUNT_MAILER = { fetch: (url, init) => stagingMail.fetch(new Request(url, init), env) };
  const background = [];
  const ctx = { waitUntil: task => background.push(task) };
  await runStagingSmoke({
    origin: "https://fixture.test", send: request => staging.fetch(request, env, ctx), tone,
    readCode: email => env.ACCOUNT_DB.prepare("DELETE FROM staging_qa_mailbox WHERE email=? AND expires_at>unixepoch()*1000 RETURNING code").bind(email).first("code"),
    waitForCron: () => Promise.all(background),
  });
  assert.equal(background.length, 2);
  await Promise.all(background);
  assert.equal(await env.ACCOUNT_DB.prepare("SELECT count(*) AS n FROM staging_qa_mailbox").first("n"), 0);
  assert.equal(await env.ACCOUNT_DB.prepare("SELECT count(*) AS n FROM account_sessions").first("n"), 0);
  await staging.scheduled({}, env);
  assert.equal(env.ACCOUNT_AUDIO.objects.size, 0);
});

test("staging never mocks unrecognized audio and rehashes the stored tone before producing a fixture result", async t => {
  const env = setup(t);
  // Even accidentally configured production provider settings cannot enable external sends in this entrypoint.
  env.ACCOUNT_ENABLE_TRANSCRIPTION = "yes";
  env.ACCOUNT_DEEPGRAM_KEY = "unit-test-double";
  const user = randomUUID(), meeting = randomUUID();
  await env.ACCOUNT_DB.prepare("INSERT INTO account_meetings VALUES (?,?,'Fixture','a','b',1,0,'initial')").bind(user, meeting).run();
  async function queue(bytes) {
    const recording = randomUUID();
    const call = (method, tail, data) => handleRecording(new Request("https://fixture.test", {
      method, body: data instanceof Uint8Array ? data : JSON.stringify(data),
    }), env, user, meeting, recording, tail);
    const spec = {
      consent: true, mimeType: "audio/mp4", provider: "deepgram",
      size: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
    };
    assert.equal((await call("PUT", "", spec)).status, 200);
    assert.equal((await call("PUT", "parts/0", bytes)).status, 200);
    assert.equal((await (await call("POST", "complete", {})).json()).status, "queued");
    return () => call("GET", "").then(result => result.json());
  }
  const changed = Buffer.from(tone);
  changed[0] ^= 1;
  const other = await queue(changed);
  await staging.scheduled({}, env);
  assert.equal((await other()).detail, "provider_unconfigured");
  assert.equal((await other()).transcript, null);

  const known = await queue(tone);
  const object = [...env.ACCOUNT_AUDIO.objects.values()].find(obj => Buffer.from(obj.bytes).equals(tone));
  assert.ok(object);
  object.bytes[0] ^= 1;
  await staging.scheduled({}, env);
  assert.equal((await known()).detail, "staging_fixture_mismatch");
  assert.equal((await known()).transcript, null);
});
