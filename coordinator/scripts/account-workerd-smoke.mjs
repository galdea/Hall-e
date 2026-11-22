// Usage: ACCOUNT_WORKER_TOOLS=/absolute/path/to/node_modules node scripts/account-workerd-smoke.mjs
// Miniflare creates only disposable local D1/R2 instances. All Worker egress is intercepted.
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { coordinatorRoot as root, startAccountRuntime } from "../test-support/local-runtime.mjs";
const codes = new Map();
const oauthCodes = new Map();
const runtimeOrigin = "https://fixture.test";
const audience = "fixture-app.apps.googleusercontent.com";
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const kid = randomUUID();
const publicJwk = { ...publicKey.export({ format: "jwk" }), kid, alg: "RS256", use: "sig" };
const redirect = () => new Response(null, {status: 307, headers:{location:"https://unexpected.invalid/blocked"}});
let redirectJwks = false;
function idToken(nonce) {
  const encode = data => Buffer.from(JSON.stringify(data)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss:"https://accounts.google.com", aud:audience, azp:audience, iat:now, exp:now+300, nonce,
    sub:"fixture-google-subject", email:"fixture@example.test", email_verified:true };
  const signed = `${encode({alg:"RS256", kid})}.${encode(payload)}`;
  return `${signed}.${sign("sha256", Buffer.from(signed), privateKey).toString("base64url")}`;
}
const networkAttempts = [];
const transcript = "Synthetic local runtime transcript.";
// Above the 512 KiB row limit: published from R2 through the transcript endpoint.
const largeTranscript = "Transcripción sintética extensa. ".repeat(20 * 1024);
let deepgramTranscript = transcript;
// This mono AAC fixture is a 0.20-second synthesized 440 Hz tone. An MP4
// 'free' box preserves the playable recording while exercising a second part.
const tone = await readFile(resolve(root, "test-support/phone-tone.mp4"));
const audio = Buffer.alloc(8 * 1024 * 1024 + 64);
tone.copy(audio);
audio.writeUInt32BE(audio.length - tone.length, tone.length);
audio.write("free", tone.length + 4, "ascii");
let regionalReference;
let regionalSubmissions = 0;
const options = {
  bindings: {
    ACCOUNT_AUTH_SECRET: "synthetic-local-runtime-secret-never-for-deployment",
    ACCOUNT_RESEND_KEY: "synthetic-resend-key", ACCOUNT_MAIL_FROM: "Hall-e QA <qa@example.test>",
    ACCOUNT_GOOGLE_CLIENT_ID: audience, ACCOUNT_GOOGLE_CLIENT_SECRET: "synthetic-google-secret", ACCOUNT_PUBLIC_ORIGIN: runtimeOrigin,
    ACCOUNT_ENABLE_TRANSCRIPTION: "yes", ACCOUNT_DEEPGRAM_KEY: "synthetic-local-runtime-key",
    ACCOUNT_SPEECHMATICS_REGION: "eu1", ACCOUNT_SPEECHMATICS_KEY: "synthetic-region-key",
    ACCOUNT_SPEECHMATICS_TRAINING_OPT_OUT: "confirmed", ACCOUNT_DELETION_ENABLED: "yes",
  },
  async outboundService(request) {
    const url = new URL(request.url);
    networkAttempts.push(url.hostname);
    if (url.href === "https://api.resend.com/emails") {
      assert.equal(request.method, "POST");
      assert.equal(request.headers.get("authorization"), "Bearer synthetic-resend-key");
      const message = await request.json();
      assert.equal(message.from, "Hall-e QA <qa@example.test>");
      assert.equal(message.to.length, 1);
      const [email] = message.to;
      assert.ok(email.endsWith("@example.test"));
      if (email === "redirect@example.test") return redirect();
      const code = message.text.match(/\b\d{8}\b/)[0];
      codes.set(email, code);
      return Response.json({id:randomUUID()});
    }
    if (url.href === "https://oauth2.googleapis.com/token") {
      assert.equal(request.method, "POST");
      const form = new URLSearchParams(await request.text());
      const grant = oauthCodes.get(form.get("code"));
      assert.ok(grant);
      oauthCodes.delete(form.get("code"));
      assert.equal(form.get("grant_type"), "authorization_code");
      assert.equal(form.get("client_id"), audience);
      assert.equal(form.get("client_secret"), "synthetic-google-secret");
      assert.equal(form.get("redirect_uri"), runtimeOrigin + "/account/v1/auth/browser/callback");
      assert.equal(createHash("sha256").update(form.get("code_verifier")).digest("base64url"), grant.challenge);
      if (grant.redirectToken) return redirect();
      return Response.json({id_token:idToken(grant.nonce)});
    }
    if (url.href === "https://www.googleapis.com/oauth2/v3/certs") {
      assert.equal(request.method, "GET");
      if (redirectJwks) return redirect();
      return Response.json({keys:[publicJwk]}, {headers:{"cache-control":"max-age=600"}});
    }
    if (url.origin === "https://eu1.asr.api.speechmatics.com") {
      assert.equal(request.headers.get("authorization"), "Bearer synthetic-region-key");
      if (request.method === "POST") {
        regionalSubmissions++;
        const form = await request.formData();
        assert.deepEqual(Buffer.from(await form.get("data_file").arrayBuffer()), tone);
        const config = JSON.parse(form.get("config"));
        assert.equal(config.transcription_config.language, "multi");
        regionalReference = config.tracking.reference;
        return Response.json({id:"runtime_eu"}, {status:201});
      }
      if (url.pathname.endsWith("/transcript")) return Response.json({results:[
        {type:"word",start_time:0,end_time:0.2,alternatives:[{content:"Sintético",speaker:"S1"}]},
      ]});
      return Response.json({job:{id:"runtime_eu",status:"done",tracking:{reference:regionalReference}}});
    }
    assert.equal(url.origin, "https://api.deepgram.com");
    assert.equal(request.method, "POST");
    assert.deepEqual(Buffer.from(await request.arrayBuffer()), audio);
    return Response.json({
      metadata: { request_id: "synthetic-local-id" },
      results: { channels: [{ alternatives: [{ transcript: deepgramTranscript, words: [] }] }] },
    });
  },
};
const { runtime, db } = await startAccountRuntime(options);

try {
  const worker = await runtime.getWorker();
  async function call(method, route, token, payload, expected) {
    const bytes = payload instanceof Uint8Array;
    const headers = {};
    if (token) headers.authorization = "Bearer " + token;
    if (payload !== undefined) headers["content-type"] = bytes ? "application/octet-stream" : "application/json";
    const result = await runtime.dispatchFetch(runtimeOrigin + "/account/v1" + route, {
      method, headers, body: bytes ? payload : JSON.stringify(payload),
    });
    const body = await result.text();
    if (expected) assert.ok(expected.includes(result.status), method + " " + route + " " + result.status + " " + body);
    else assert.ok(result.ok, method + " " + route + " " + result.status + " " + body);
    return body && JSON.parse(body);
  }
  async function login(email) {
    const {challengeId} = await call("POST", "/auth/email/start", null, {email});
    return call("POST", "/auth/email/verify", null, {challengeId, code:codes.get(email)});
  }
  async function finishGoogle(bearer, expected, {redirectToken = false} = {}) {
    const {url, pollToken} = await call("POST", "/auth/browser/start", bearer, {link:Boolean(bearer)});
    const authorize = new URL(url);
    assert.equal(authorize.origin, "https://accounts.google.com");
    assert.equal(authorize.searchParams.get("scope"), "openid email");
    const callback = new URL(authorize.searchParams.get("redirect_uri"));
    assert.equal(callback.origin, runtimeOrigin);
    const code = randomUUID();
    oauthCodes.set(code,{nonce:authorize.searchParams.get("nonce"), challenge:authorize.searchParams.get("code_challenge"), redirectToken});
    callback.search = new URLSearchParams({code,state:authorize.searchParams.get("state")});
    const returned = await runtime.dispatchFetch(callback.href);
    assert.equal(returned.status,200);
    assert.equal(returned.headers.get("cache-control"),"no-store");
    const confirmationCode = (await returned.text()).match(/\b\d{8}\b/)[0];
    const pending = await call("POST", "/auth/browser/finish", bearer, {pollToken}, [202]);
    assert.deepEqual(pending,{status:"confirmation_required"});
    const payload = {pollToken,confirmationCode};
    const result = await call("POST", "/auth/browser/finish", bearer, payload, [expected]);
    await call("POST", "/auth/browser/finish", bearer, payload, [410]);
    return result;
  }
  let desktop = await login("fixture@example.test");
  const mobile = await login("fixture@example.test");
  const stranger = await login("other@example.test");
  assert.equal(desktop.userId, mobile.userId);
  assert.notEqual(desktop.token, mobile.token);
  assert.equal((await call("POST", "/auth/email/start", null, {email:"redirect@example.test"}, [503])).error, "mail_unavailable");
  assert.equal((await finishGoogle(null,401,{redirectToken:true})).error,"google_exchange_failed");
  redirectJwks = true;
  assert.equal((await finishGoogle(null,503)).error,"google_unavailable");
  redirectJwks = false;
  assert.equal((await finishGoogle(null,409)).error,"link_required");
  const previous = desktop;
  desktop = await finishGoogle(previous.token,200);
  assert.equal(desktop.userId,previous.userId);
  await call("GET", "/auth/session", previous.token, undefined, [401]);
  assert.equal((await finishGoogle(null,200)).userId, desktop.userId);
  const meeting = "/meetings/" + randomUUID();
  const recording = meeting + "/recordings/" + randomUUID();
  const project = {id: randomUUID(), name: "Synthetic field survey"};
  const proposalFromDesktop = {
    title:"Synthetic runtime meeting", startAt:"2026-11-20T15:00:00Z", endAt:"2026-11-20T16:00:00Z",
    baseRevision:0, mutationId:randomUUID(),
  };
  await call("PUT", meeting, desktop.token, proposalFromDesktop);
  await call("PUT", meeting, mobile.token, {...proposalFromDesktop,baseRevision:1,mutationId:randomUUID(),project});
  const desktopSnapshot = await call("GET","/meetings",desktop.token);
  assert.deepEqual(desktopSnapshot.meetings[0].project,project);
  assert.deepEqual(desktopSnapshot.meetings[0].recordings,[]);
  const editedOnLegacyClient = await call("PUT", meeting, desktop.token, {
    ...proposalFromDesktop,baseRevision:2,mutationId:randomUUID(),title:"Synthetic updated title",
  });
  assert.deepEqual(editedOnLegacyClient.meeting.project,project);
  assert.deepEqual((await call("GET","/meetings",stranger.token)).meetings,[]);
  const proposal = {size:audio.length, sha256:createHash("sha256").update(audio).digest("hex"), mimeType:"audio/mp4", consent:true, provider:"deepgram"};
  const {partSize} = await call("PUT", recording, mobile.token, proposal);
  assert.ok(partSize < audio.length && audio.length <= 2 * partSize);
  const first = audio.subarray(0, partSize);
  await call("PUT", recording + "/parts/0", mobile.token, first);
  await call("POST", recording + "/complete", mobile.token, {}, [409]);
  await call("PUT", recording + "/parts/0", mobile.token, first);
  await call("PUT", recording + "/parts/1", mobile.token, audio.subarray(partSize));
  await call("POST", recording + "/complete", mobile.token, {});
  await call("POST", recording + "/complete", mobile.token, {});
  await worker.scheduled({cron:"* * * * *"});
  await worker.scheduled({cron:"* * * * *"});
  const state = await db.prepare("SELECT status, detail FROM account_recordings").first();
  const outboundCount = host => networkAttempts.filter(name => name === host).length;
  assert.equal(outboundCount("api.deepgram.com"),1, JSON.stringify(state));
  assert.equal(outboundCount("api.resend.com"),4);
  assert.equal(outboundCount("oauth2.googleapis.com"),5);
  assert.equal(outboundCount("www.googleapis.com"),2);
  assert.equal(outboundCount("unexpected.invalid"),0);
  assert.equal(networkAttempts.length,12);
  for (const {token} of [desktop,mobile]) {
    const {meetings} = await call("GET", "/meetings", token);
    const [result] = meetings[0].recordings;
    assert.equal(result.status, "completed");
    assert.ok(JSON.stringify(result.transcript).includes(transcript));
  }
  assert.deepEqual((await call("GET", "/meetings", stranger.token)).meetings, []);
  await call("GET", recording, stranger.token, undefined, [403,404]);
  const regional = meeting + "/recordings/" + randomUUID();
  await call("PUT", regional, mobile.token, {...proposal, provider:"speechmatics", region:"eu1",
    size:tone.length, sha256:createHash("sha256").update(tone).digest("hex")});
  await call("PUT", regional + "/parts/0", mobile.token, tone);
  await call("POST", regional + "/complete", mobile.token, {});
  await worker.scheduled({cron:"* * * * *"});
  const pending = await call("GET", regional, desktop.token);
  assert.equal(pending.status,"processing");
  // Advance this synthetic job's eligibility without waiting for a real minute.
  await db.prepare("UPDATE account_recordings SET next_at=0 WHERE id=?").bind(pending.id).run();
  await worker.scheduled({cron:"* * * * *"});
  assert.equal(regionalSubmissions,1);
  assert.match((await call("GET", regional, desktop.token)).transcript,/S1.*Sintético/);
  assert.deepEqual((await call("GET", "/auth/session", desktop.token)).features, {accountDeletion:true, lazyTranscripts:true});
  const recordingId = recording.split("/").at(-1);
  const lazy = await call("GET", "/meetings?transcripts=lazy", mobile.token);
  const listed = lazy.meetings[0].recordings.find(item => item.id === recordingId);
  assert.deepEqual([listed.transcript, listed.transcriptAvailable, listed.transcriptBytes], [null, true, Buffer.byteLength(transcript)]);
  const text = await runtime.dispatchFetch(runtimeOrigin + "/account/v1" + recording + "/transcript", {
    headers: {authorization: "Bearer " + desktop.token},
  });
  assert.equal(text.status, 200);
  assert.equal(text.headers.get("content-type"), "text/plain; charset=utf-8");
  assert.equal(await text.text(), transcript);
  await call("GET", recording + "/transcript", stranger.token, undefined, [404]);
  deepgramTranscript = largeTranscript;
  const large = meeting + "/recordings/" + randomUUID();
  await call("PUT", large, mobile.token, proposal);
  await call("PUT", large + "/parts/0", mobile.token, audio.subarray(0, partSize));
  await call("PUT", large + "/parts/1", mobile.token, audio.subarray(partSize));
  await call("POST", large + "/complete", mobile.token, {});
  await worker.scheduled({cron:"* * * * *"});
  const stored = await call("GET", large, desktop.token);
  assert.deepEqual([stored.status, stored.transcript, stored.transcriptStoredSeparately], ["completed", null, true]);
  const largeText = await runtime.dispatchFetch(runtimeOrigin + "/account/v1" + large + "/transcript", {
    headers: {authorization: "Bearer " + desktop.token},
  });
  assert.equal(await largeText.text(), largeTranscript);
  assert.equal((await (await runtime.getR2Bucket("ACCOUNT_AUDIO")).list()).objects.length, 6);
  await call("POST", "/account/delete", mobile.token, {confirmation:"delete"}, [400]);
  assert.deepEqual(await call("POST", "/account/delete", mobile.token, {confirmation:"DELETE"}, [202]), {status:"deleting"});
  for (const {token} of [desktop, mobile]) await call("GET", "/auth/session", token, undefined, [401]);
  assert.equal((await call("GET", "/auth/session", stranger.token)).userId, stranger.userId);
  // The cron drains whatever the immediate disposal has not finished.
  await worker.scheduled({cron:"* * * * *"});
  for (const table of ["account_users", "account_emails", "account_identities", "account_sessions", "account_meetings",
    "account_meeting_mutations", "account_projects", "account_meeting_projects", "account_recordings",
    "account_transcript_imports", "account_calendar_versions"]) {
    assert.equal(await db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id=?`).bind(desktop.userId).first("n"), 0, table);
  }
  assert.equal(await db.prepare("SELECT COUNT(*) AS n FROM account_recording_parts").first("n"), 0);
  assert.equal(await db.prepare("SELECT COUNT(*) AS n FROM account_disposals").first("n"), 0);
  assert.equal((await (await runtime.getR2Bucket("ACCOUNT_AUDIO")).list()).objects.length, 0);
  console.log("PASS local workerd + D1 + R2: email, Google PKCE/JWKS/browser proof, linking, revoked session, tenant isolation, AAC upload replay, Deepgram and regional Speechmatics doubles, lazy transcripts and account deletion.");
} finally {
  await runtime.dispose();
}
