// Runs the actual Swift and Kotlin account clients against one disposable local Worker.
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { coordinatorRoot, startAccountRuntime } from "../test-support/local-runtime.mjs";

const repo = resolve(coordinatorRoot, "..");
const temp = await mkdtemp(join(tmpdir(), "halle-native-"));
const fixturePath = join(temp, "fixture.json");
const transcript = "Synthetic native transcript.";
const audio = resolve(coordinatorRoot, "test-support/phone-tone.mp4");
const audioBytes = await readFile(audio);
const codes = new Map();
let submissions = 0;
let runtime;

function run(command, args, extraEnv = {}) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, {
      cwd: repo, stdio: "inherit", env: {
        ...process.env, HALL_E_NATIVE_QA: fixturePath, HALLE_DEBUG_FIXTURES: "1",
        HALLE_DEBUG_DATA_DIR: join(temp, "data"), ...extraEnv,
      },
    });
    child.once("error", reject);
    child.once("exit", (status, signal) => {
      if (status === 0) resolveRun();
      else reject(new Error(`${command} failed (${signal || status})`));
    });
  });
}

async function syntheticProvider(request) {
  const url = new URL(request.url);
  if (request.method === "POST" && url.href === "https://api.resend.com/emails") {
    const { to, text } = await request.json();
    assert.ok(["owner@example.test", "other@example.test"].includes(to[0]));
    codes.set(to[0], text.match(/\b\d{8}\b/)[0]);
    return Response.json({ id: randomUUID() });
  }
  assert.equal(request.method, "POST");
  assert.equal(url.origin, "https://api.deepgram.com");
  assert.deepEqual(Buffer.from(await request.arrayBuffer()), audioBytes);
  submissions++;
  return Response.json({
    metadata: { request_id: "synthetic-native" },
    results: { channels: [{ alternatives: [{ transcript, words: [] }] }] },
  });
}

try {
  // Trust is scoped to each test process. The temporary key is never installed on the host.
  const key = join(temp, "key.pem");
  const certificate = join(temp, "certificate.pem");
  await promisify(execFile)("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
    "-addext", "subjectAltName=IP:127.0.0.1", "-addext", "extendedKeyUsage=serverAuth",
    "-keyout", key, "-out", certificate,
  ]);
  const started = await startAccountRuntime({
    https: true, httpsCert: await readFile(certificate, "utf8"), httpsKey: await readFile(key, "utf8"),
    bindings: {
      ACCOUNT_AUTH_SECRET: randomUUID() + randomUUID(),
      ACCOUNT_MAIL_FROM: "Hall-e QA <qa@example.test>", ACCOUNT_RESEND_KEY: "synthetic-mail",
      ACCOUNT_ENABLE_TRANSCRIPTION: "yes", ACCOUNT_DEEPGRAM_KEY: "synthetic-transcription",
    },
    outboundService: syntheticProvider,
  });
  runtime = started.runtime;
  const address = await runtime.ready;
  assert.equal(address.protocol, "https:");
  assert.equal(address.hostname, "127.0.0.1");
  const origin = address.origin;
  async function post(route, payload) {
    const result = await runtime.dispatchFetch(origin + "/account/v1/auth/email/" + route, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload),
    });
    assert.equal(result.status, 200, "email " + route);
    return result.json();
  }
  async function login(email) {
    const { challengeId } = await post("start", { email });
    return post("verify", { challengeId, code: codes.get(email) });
  }
  const desktop = await login("owner@example.test");
  const mobile = await login("owner@example.test");
  const stranger = await login("other@example.test");
  assert.equal(desktop.userId, mobile.userId);
  assert.notEqual(desktop.token, mobile.token);
  assert.notEqual(desktop.userId, stranger.userId);

  const meetingId = randomUUID();
  const recordingId = randomUUID();
  const project = { id: randomUUID(), name: "Synthetic native project" };
  await writeFile(fixturePath, JSON.stringify({
    origin, certificate, desktop, mobile, stranger, meetingId, recordingId, project, audio,
  }), { mode: 0o600 });

  const swiftArgs = ["test", "--jobs", "2", "--disable-automatic-resolution", "--filter", "NativeAccountInteropTests"];
  await run("swift", swiftArgs, { HALL_E_NATIVE_PHASE: "create" });
  await run(resolve(repo, "android/gradlew"), [
    "--offline", "--no-daemon", "--max-workers=1", "-Dorg.gradle.jvmargs=-Xmx768m",
    "-Pkotlin.compiler.execution.strategy=in-process", ":app:testDebugUnitTest", "--tests", "app.halle.companion.NativeAccountInteropTest", "--rerun",
  ]);
  const item = () => started.db.prepare("SELECT status FROM account_recordings WHERE user_id=? AND meeting_id=? AND id=?")
    .bind(desktop.userId, meetingId, recordingId).first();
  assert.equal((await item())?.status, "queued", "Android must submit this fixture's recording");
  const worker = await runtime.getWorker();
  await worker.scheduled({ cron: "* * * * *" });
  await worker.scheduled({ cron: "* * * * *" });
  assert.equal(submissions, 1);
  assert.equal((await item())?.status, "completed");
  await run("swift", [...swiftArgs, "--skip-build"], { HALL_E_NATIVE_PHASE: "verify" });
  assert.equal(await readFile(join(temp, "swift-verified"), "utf8"), meetingId);
  console.log("PASS Swift → Android JVM → workerd/D1/R2 → Swift: shared meeting and project, resumed AAC upload, one transcription, separate account.");
} finally {
  try { await runtime?.dispose(); }
  finally { await rm(temp, { recursive: true, force: true }); }
}
