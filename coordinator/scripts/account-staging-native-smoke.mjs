// Runs synthetic native-client interoperability against the dedicated staging account service.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { createNativeMeeting, editFromAndroid, verifyFromMac } from "../test-support/native-clients.mjs";
import { consumeStagingCode, ownerEmail, otherEmail } from "./staging-code.mjs";

const origin = "https://halle-account-staging.gabriel-aldea.workers.dev";
assert.equal(process.env.HALLE_STAGE_ORIGIN, origin, "Explicit staging origin required");
assert.ok(process.env.WRANGLER_BIN, "Set WRANGLER_BIN to the authorized CLI");
assert.notEqual(process.env.NODE_TLS_REJECT_UNAUTHORIZED, "0", "System TLS verification must be enabled");
const config = JSON.parse(await readFile(process.env.HALLE_STAGE_CONFIG, "utf8"));
assert.equal(config.name, "halle-account-staging");
assert.equal(config.vars.ACCOUNT_PUBLIC_ORIGIN, origin);
assert.equal(config.d1_databases.find(d => d.binding === "ACCOUNT_DB")?.database_name, "halle-account-staging");

const temp = await mkdtemp(join(tmpdir(), "halle-native-staging-"));
const meetingId = randomUUID();
const recordingId = randomUUID();
const sessions = [];

async function call(method, path, token, body, expected = 200) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body) headers["content-type"] = "application/json";
  const result = await fetch(origin + "/account/v1" + path, {
    method, headers, body: JSON.stringify(body), redirect: "error", signal: AbortSignal.timeout(25_000),
  });
  assert.equal(result.status, expected, method + " " + path + " returned HTTP " + result.status);
  if (result.status !== 204) return result.json();
}

async function login(email) {
  const { challengeId } = await call("POST", "/auth/email/start", null, { email });
  const account = await call("POST", "/auth/email/verify", null, { challengeId, code: await consumeStagingCode(email) });
  assert.ok(typeof account.token === "string" && account.token.length === 43, "A new session is required");
  sessions.push(account);
  return account;
}

async function cleanupMeetings() {
  if (!sessions.length) return;
  // The Mac records only this run's private IDs before any network writes.
  let ids;
  try { ids = JSON.parse(await readFile(join(temp, "swift-cleanup.json"), "utf8")); }
  catch (error) { if (error.code === "ENOENT") return; throw error; }
  assert.ok(ids.length === 2 && ids[0] === meetingId && /^[a-f0-9-]{36}$/i.test(ids[1]));
  const { token } = sessions[0];
  const { meetings } = await call("GET", "/meetings", token);
  for (const item of meetings.filter(m => ids.includes(m.id) && !m.deleted)) {
    await call("PUT", "/meetings/" + item.id, token, {
      baseRevision: item.revision, deleted: true, mutationId: randomUUID(),
    });
  }
  const refreshed = await call("GET", "/meetings", token);
  assert.ok(!refreshed.meetings.some(m => ids.includes(m.id) && !m.deleted), "Fixture meetings still visible");
}

try {
  const desktop = await login(ownerEmail);
  const mobile = await login(ownerEmail);
  const stranger = await login(otherEmail);
  assert.ok(desktop.token !== mobile.token);
  assert.equal(desktop.userId, mobile.userId);
  assert.notEqual(desktop.userId, stranger.userId);
  const audio = fileURLToPath(new URL("../test-support/phone-tone.mp4", import.meta.url));
  const project = { id: "923594ec-6f02-4b82-9b78-9f22d20a5ceb", name: "Native staging QA project" };
  await writeFile(join(temp, "fixture.json"), JSON.stringify({
    origin, desktop, mobile, stranger, meetingId, recordingId, project, audio,
  }), { mode: 0o600, flag: "wx" });
  await createNativeMeeting(temp);
  await editFromAndroid(temp);
  const deadline = Date.now() + 2 * 60_000;
  for (;;) {
    const result = await call("GET", `/meetings/${meetingId}/recordings/${recordingId}`, desktop.token);
    if (result.status === "completed") {
      assert.equal(result.detail, "staging_synthetic_fixture");
      break;
    }
    assert.ok(["queued", "submitting"].includes(result.status), "Unexpected fixture job state");
    assert.notEqual(result.detail, "provider_unconfigured");
    if (Date.now() >= deadline) throw new Error("Staging fixture did not complete within two minutes");
    await delay(2_000);
  }
  await verifyFromMac(temp);
  assert.equal(await readFile(join(temp, "swift-verified"), "utf8"), meetingId);
} finally {
  try { await cleanupMeetings(); }
  finally {
    try {
      const revoked = await Promise.allSettled(sessions.map(async ({ token }) => {
        await call("POST", "/auth/logout", token, {}, 204);
        await call("GET", "/auth/session", token, undefined, 401);
      }));
      assert.ok(revoked.every(item => item.status === "fulfilled"), "Staging session revocation incomplete");
    } finally { await rm(temp, { recursive: true, force: true }); }
  }
}
console.log("PASS hosted Swift → Android JVM → staging Worker/D1/R2 → Swift, authorized test email, system TLS, project sync, resumed upload, marked synthetic transcript, private accounts, cleanup and logout.");
