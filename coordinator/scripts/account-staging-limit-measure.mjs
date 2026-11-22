// Measures a maximum-size (256 MiB) upload against the dedicated staging account service.
// Synthetic random bytes only: staging processes nothing but its test tone, so no provider is called.
// Run with HALLE_STAGE_ORIGIN, HALLE_STAGE_CONFIG and WRANGLER_BIN set, like account-staging-smoke.mjs.
// Optional: HALLE_MEASURE_MIB (default 256, the service maximum).
import assert from "node:assert/strict";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { consumeStagingCode, ownerEmail } from "./staging-code.mjs";

const origin = "https://halle-account-staging.gabriel-aldea.workers.dev";
assert.equal(process.env.HALLE_STAGE_ORIGIN, origin, "Explicit staging origin required");
assert.ok(process.env.WRANGLER_BIN && process.env.HALLE_STAGE_CONFIG, "Set WRANGLER_BIN and HALLE_STAGE_CONFIG");
const MiB = 1024 * 1024;
const PART = 8 * MiB;
const size = Number(process.env.HALLE_MEASURE_MIB || 256) * MiB;
assert.ok(Number.isSafeInteger(size) && size > 0 && size <= 256 * MiB, "HALLE_MEASURE_MIB must be 1..256");

async function call(method, path, token, body, expected = [200]) {
  const binary = body instanceof Uint8Array;
  const headers = {};
  if (token) headers.authorization = "Bearer " + token;
  if (body !== undefined) headers["content-type"] = binary ? "application/octet-stream" : "application/json";
  const started = performance.now();
  const response = await fetch(origin + "/account/v1" + path, {
    method, headers, redirect: "error", signal: AbortSignal.timeout(180_000),
    body: binary ? body : body === undefined ? undefined : JSON.stringify(body),
  });
  const ms = Math.round(performance.now() - started);
  const text = await response.text();
  if (!expected.includes(response.status)) {
    throw new Error(`${method} ${path.replace(/[0-9a-f-]{36}/g, "<id>")} -> ${response.status} ${text.slice(0, 120)} (${ms} ms)`);
  }
  return { status: response.status, ms, json: text ? JSON.parse(text) : null };
}

const meetingId = randomUUID(), recordingId = randomUUID();
const meeting = "/meetings/" + meetingId, recording = meeting + "/recordings/" + recordingId;
let token, revision;
const report = { sizeMiB: size / MiB, parts: Math.ceil(size / PART) };
try {
  const { json: { challengeId } } = await call("POST", "/auth/email/start", null, { email: ownerEmail });
  token = (await call("POST", "/auth/email/verify", null, { challengeId, code: await consumeStagingCode(ownerEmail) })).json.token;
  revision = (await call("PUT", meeting, token, {
    title: "Synthetic limit measurement", startAt: "2026-11-22T12:00:00Z", endAt: "2026-11-22T13:00:00Z",
    baseRevision: 0, mutationId: randomUUID(),
  })).json.meeting.revision;

  const data = randomBytes(size);
  const sha256 = createHash("sha256").update(data).digest("hex");
  await call("PUT", recording, token, { size, sha256, consent: true, mimeType: "audio/mp4", provider: "deepgram" });
  const partMs = [];
  const uploadStarted = performance.now();
  for (let i = 0; i * PART < size; i++) {
    partMs.push((await call("PUT", `${recording}/parts/${i}`, token, data.subarray(i * PART, Math.min(size, (i + 1) * PART)))).ms);
  }
  report.uploadSeconds = Math.round((performance.now() - uploadStarted) / 100) / 10;
  report.partMs = { min: Math.min(...partMs), median: partMs.sort((a, b) => a - b)[partMs.length >> 1], max: Math.max(...partMs) };
  const complete = await call("POST", `${recording}/complete`, token, {}, [200, 202, 409, 500, 503]);
  report.complete = { status: complete.status, ms: complete.ms, body: complete.status >= 400 ? complete.json : undefined };
  const replay = await call("POST", `${recording}/complete`, token, {}, [200, 202, 409, 500, 503]);
  report.completeReplay = { status: replay.status, ms: replay.ms };
  report.state = (await call("GET", recording, token, undefined, [200, 404])).json?.status;
} finally {
  try {
    if (revision) {
      await call("PUT", meeting, token, { deleted: true, baseRevision: revision, mutationId: randomUUID() });
      // Disposal starts at once on delete; give it a moment, then confirm the recording is gone.
      for (let i = 0; i < 12; i++) {
        await delay(5_000);
        if ((await call("GET", recording, token, undefined, [200, 404])).status === 404) { report.disposedAfterSeconds = (i + 1) * 5; break; }
      }
    }
  } finally {
    if (token) await call("POST", "/auth/logout", token, {}, [204]);
  }
}
console.log(JSON.stringify(report, null, 2));
