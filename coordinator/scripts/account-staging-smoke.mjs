// Run with HALLE_STAGE_ORIGIN, HALLE_STAGE_CONFIG and WRANGLER_BIN set to the dedicated staging resources.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { consumeStagingCode, ownerEmail, otherEmail } from "./staging-code.mjs";


export async function runStagingSmoke({ origin, send, readCode, tone, waitForCron }) {
  const sessions = [];
  let mac, revision;
  const meetingId = randomUUID(), recordingId = randomUUID();
  const meeting = "/meetings/" + meetingId;
  const recording = meeting + "/recordings/" + recordingId;

  async function call(method, path, token, data, expected = 200) {
    const binary = data instanceof Uint8Array;
    const headers = {};
    if (token) headers.authorization = "Bearer " + token;
    if (data !== undefined) headers["content-type"] = binary ? "application/octet-stream" : "application/json";
    const response = await send(new Request(origin + "/account/v1" + path, {
      method, headers, redirect: "error", signal: AbortSignal.timeout(30_000),
      body: binary ? data : JSON.stringify(data),
    }));
    assert.equal(response.status, expected, method + " " + path + " returned HTTP " + response.status);
    return response.status === 204 ? null : response.json();
  }

  async function login(email) {
    const { challengeId } = await call("POST", "/auth/email/start", null, { email });
    const account = await call("POST", "/auth/email/verify", null, { challengeId, code: await readCode(email) });
    assert.ok(typeof account.token === "string" && account.token.length === 43, "Expected a new session");
    sessions.push(account.token);
    return account;
  }

  const change = {
    title: "Synthetic staging meeting", startAt: "2026-11-20T12:00:00Z", endAt: "2026-11-20T12:15:00Z",
    baseRevision: 0, mutationId: randomUUID(),
  };
  try {
    await call("GET", "/meetings", null, undefined, 401);
    mac = await login(ownerEmail);
    const phone = await login(ownerEmail), other = await login(otherEmail);
    assert.equal(mac.userId, phone.userId);
    assert.ok(mac.token !== phone.token, "Devices need separate sessions");
    assert.notEqual(other.userId, mac.userId);
    const created = (await call("PUT", meeting, mac.token, change)).meeting;
    revision = created.revision;
    const onPhone = (await call("GET", "/meetings", phone.token)).meetings;
    assert.ok(onPhone.some(item => item.id === meetingId && item.title === change.title));
    const project = { id: randomUUID(), name: "Synthetic staging project" };
    const update = { ...change, baseRevision: revision, mutationId: randomUUID(), project };
    revision = (await call("PUT", meeting, phone.token, update)).meeting.revision;
    assert.equal((await call("PUT", meeting, phone.token, update)).meeting.revision, revision);

    const manifest = {
      size: tone.length, sha256: createHash("sha256").update(tone).digest("hex"),
      consent: true, mimeType: "audio/mp4", provider: "deepgram",
    };
    await call("PUT", recording, other.token, manifest, 404);
    await call("PUT", recording, phone.token, manifest);
    await call("POST", recording + "/complete", phone.token, {}, 409);
    await call("PUT", recording + "/parts/0", phone.token, tone);
    await call("PUT", recording + "/parts/0", phone.token, tone);
    await call("POST", recording + "/complete", phone.token, {});
    await call("POST", recording + "/complete", phone.token, {});
    const deadline = Date.now() + 16 * 60_000;
    for (;;) {
      const result = await call("GET", recording, mac.token);
      if (result.status === "completed") {
        assert.equal(result.detail, "staging_synthetic_fixture");
        break;
      }
      assert.ok(["queued", "submitting"].includes(result.status), "Unexpected recording status: " + result.status);
      if (result.detail === "provider_unconfigured") throw new Error("Staging fixture processing is disabled");
      if (Date.now() >= deadline) throw new Error("Staging cron did not finish the fixture before timeout");
      await waitForCron();
    }
    for (const device of [mac, phone]) {
      const matches = (await call("GET", "/meetings", device.token)).meetings.filter(item => item.id === meetingId);
      assert.equal(matches.length, 1);
      assert.deepEqual(matches[0].project, project);
      assert.equal(matches[0].recordings.length, 1);
      assert.equal(matches[0].recordings[0].id, recordingId);
      assert.match(matches[0].recordings[0].transcript, /^\[STAGING SYNTHETIC\]/);
    }
    const outsiders = (await call("GET", "/meetings", other.token)).meetings;
    assert.ok(!outsiders.some(item => item.id === meetingId));
    await call("GET", recording, other.token, undefined, 404);
  } finally {
    try {
      if (revision) await call("PUT", meeting, mac.token, {
        deleted: true, baseRevision: revision, mutationId: randomUUID(),
      });
    } finally {
      const revoked = await Promise.allSettled(sessions.map(async token => {
        await call("POST", "/auth/logout", token, {}, 204);
        await call("GET", "/auth/session", token, undefined, 401);
      }));
      if (revoked.some(outcome => outcome.status === "rejected")) throw new Error("Could not confirm revocation of every staging session");
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  for (const key of ["HALLE_STAGE_ORIGIN", "HALLE_STAGE_CONFIG", "WRANGLER_BIN"]) {
    if (!process.env[key]) throw new Error("Missing " + key);
  }
  const url = new URL(process.env.HALLE_STAGE_ORIGIN);
  if (url.protocol !== "https:" || url.href !== url.origin + "/") throw new Error("Expected a staging HTTPS origin");
  const tone = await readFile(new URL("../test-support/phone-tone.mp4", import.meta.url));
  await runStagingSmoke({
    origin: url.origin, send: request => fetch(request), readCode: consumeStagingCode,
    tone, waitForCron: () => delay(10_000),
  });
  console.log("PASS hosted staging: passwordless private test inbox, two-device projects, isolated accounts, R2 replay, marked synthetic transcript, session revocation.");
}
