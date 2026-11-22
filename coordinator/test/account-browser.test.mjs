import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {createAccountAuth} from "../src/account-auth.mjs";
import {createBrowserAuth} from "../src/account-browser.mjs";
import {openAccountDatabase} from "../test-support/account.mjs";

const origin = "https://account.example.test";
const path = origin + "/account/v1/auth/browser/";
const hash = (value) => createHash("sha256").update(value).digest("base64url");

function fixture(t) {
  const db = openAccountDatabase();
  t.after(() => db.close());
  const env = {ACCOUNT_DB:db, ACCOUNT_AUTH_SECRET:"synthetic-proof-key-generated-for-this-fixture", ACCOUNT_GOOGLE_CLIENT_ID:"synthetic-client", ACCOUNT_GOOGLE_CLIENT_SECRET:"synthetic-secret", ACCOUNT_PUBLIC_ORIGIN:origin};
  let now = 1000;
  const calls = [];
  const exchanges = [];
  const handle = createBrowserAuth({
    clock:() => now,
    async identity(request) {
      calls.push({path:new URL(request.url).pathname, bearer:request.headers.get("Authorization"), body:await request.json()});
      return Response.json(request.url.endsWith("/start")
        ? {challengeId:"synthetic-challenge", nonce:"test-nonce", clientId:env.ACCOUNT_GOOGLE_CLIENT_ID}
        : {userId:"synthetic-user", token:"synthetic-session", expiresAt:789});
    },
    async fetchImpl(url, options) {
      assert.equal(url, "https://oauth2.googleapis.com/token");
      exchanges.push(Object.fromEntries(options.body));
      return Response.json({id_token:"synthetic-id", access_token:"unused"});
    },
  });
  const post = (action, body, bearer) => handle(new Request(path + action, {
    method:"POST", headers:{"Content-Type":"application/json", ...(bearer ? {Authorization:bearer} : {})}, body:JSON.stringify(body),
  }), env);
  const callback = (state, result) => handle(new Request(path + "callback?" + new URLSearchParams({state,...result})), env);
  return {db, env, calls, exchanges, post, callback, advance:ms => now += ms};
}

test("browser login uses nonce, PKCE, fixed callback, single-use exchange and native link session", async t => {
  const f = fixture(t);
  const bearer = "Bearer synthetic-link";
  const response = await f.post("start", {link:true}, bearer);
  assert.equal(response.status, 200);
  const {url, pollToken} = await response.json();
  const auth = new URL(url);
  const state = auth.searchParams.get("state");
  assert.equal(auth.origin, "https://accounts.google.com");
  assert.equal(auth.searchParams.get("scope"), "openid email");
  assert.equal(auth.searchParams.get("response_type"), "code");
  assert.equal(auth.searchParams.get("code_challenge_method"), "S256");
  assert.equal(auth.searchParams.get("nonce"), "test-nonce");
  assert.equal(auth.searchParams.get("redirect_uri"), path + "callback");
  assert.equal(url.includes(pollToken), false);
  assert.equal(f.calls[0].bearer, bearer);
  const stored = await f.db.prepare("SELECT * FROM account_browser_attempts").first();
  for (const raw of [pollToken,state,bearer]) assert.equal(JSON.stringify(stored).includes(raw),false);
  assert.equal((await f.post("finish",{pollToken},bearer)).status,202);
  assert.equal((await f.callback("x".repeat(43),{code:"bad"})).status,410);
  const returned = await f.callback(state,{code:"synthetic-code"});
  assert.equal(returned.status,200);
  assert.equal(returned.headers.get("cache-control"), "no-store");
  assert.equal(returned.headers.get("referrer-policy"), "no-referrer");
  const confirmationCode = (await returned.text()).match(/\b\d{8}\b/)[0];
  const pending = await f.post("finish", {pollToken}, bearer);
  assert.equal(pending.status,202);
  assert.deepEqual(await pending.json(), {status:"confirmation_required"});
  assert.equal(f.exchanges.length,0);
  const proof = await f.db.prepare("SELECT confirmation_tag FROM account_browser_attempts").first();
  assert.notEqual(proof.confirmation_tag, confirmationCode);
  assert.equal((await f.callback(state,{code:"replacement"})).status,410);
  assert.equal((await f.post("finish",{pollToken},"Bearer another")).status,410);
  const results = await Promise.all([f.post("finish",{pollToken,confirmationCode},bearer), f.post("finish",{pollToken,confirmationCode},bearer)]);
  assert.deepEqual(results.map(r => r.status).sort(),[200,410]);
  assert.equal((await results.find(r => r.ok).json()).token,"synthetic-session");
  assert.equal(f.exchanges.length,1);
  assert.equal(f.exchanges[0].code,"synthetic-code");
  assert.equal(hash(f.exchanges[0].code_verifier),auth.searchParams.get("code_challenge"));
  assert.equal(f.calls[1].bearer,bearer);
  assert.deepEqual(f.calls[1].body,{challengeId:"synthetic-challenge",idToken:"synthetic-id"});
  assert.equal(await f.db.prepare("SELECT * FROM account_browser_attempts").first(),null);
});

test("cancelled and expired grants cannot yield a session", async t => {
  const f = fixture(t);
  const first = await (await f.post("start",{})).json();
  assert.equal((await f.callback(new URL(first.url).searchParams.get("state"),{error:"access_denied"})).status,200);
  assert.equal((await f.post("finish",{pollToken:first.pollToken})).status,403);
  const second = await (await f.post("start",{})).json();
  f.advance(300001);
  assert.equal((await f.callback(new URL(second.url).searchParams.get("state"),{code:"expired"})).status,410);
  assert.equal((await f.post("finish",{pollToken:second.pollToken})).status,410);
  assert.equal(f.exchanges.length,0);
  assert.equal((await f.post("start",{},"Bearer old")).status,400);
});


test("both the browser code and original native grant are required; five wrong codes lock the grant", async t => {
  const f = fixture(t);
  const begin = async () => {
    const {url, pollToken} = await (await f.post("start", {})).json();
    const state = new URL(url).searchParams.get("state");
    const content = await (await f.callback(state, {code:"synthetic-authorization"})).text();
    return {pollToken, confirmationCode:content.match(/\b\d{8}\b/)[0]};
  };
  const original = await begin();
  const unknown = await f.post("finish", {pollToken:"z".repeat(43), confirmationCode:original.confirmationCode});
  assert.equal(unknown.status,410);
  const incorrect = original.confirmationCode.replace(/^./, digit => String((Number(digit) + 1) % 10));
  const tries = await Promise.all(Array.from({length:5}, () => f.post("finish", {pollToken:original.pollToken, confirmationCode:incorrect})));
  assert.deepEqual(tries.map(r => r.status).sort(), [401,401,401,401,410]);
  assert.equal((await f.post("finish", original)).status,410);
  const expired = await begin();
  f.advance(300001);
  assert.equal((await f.post("finish", expired)).status,410);
  assert.equal(f.exchanges.length,0);
});

test("staging browser Google sign-in refuses a verified non-tester without creating a user, identity or session", async t => {
  const db = openAccountDatabase();
  t.after(() => db.close());
  const clientId = "synthetic-client";
  const env = {ACCOUNT_DB:db, ACCOUNT_AUTH_SECRET:"synthetic-proof-key-generated-for-this-fixture", ACCOUNT_GOOGLE_CLIENT_ID:clientId,
    ACCOUNT_GOOGLE_CLIENT_SECRET:"synthetic-secret", ACCOUNT_PUBLIC_ORIGIN:origin, ACCOUNT_STAGING_TESTER_EMAILS:"halle-owner@example.test"};
  const algorithm = {name:"RSASSA-PKCS1-v1_5", modulusLength:2048, publicExponent:new Uint8Array([1,0,1]), hash:"SHA-256"};
  const keys = await crypto.subtle.generateKey(algorithm, false, ["sign","verify"]);
  const jwk = {...await crypto.subtle.exportKey("jwk", keys.publicKey), kid:"fixture-key", alg:"RS256", use:"sig"};
  const identity = createAccountAuth({fetchImpl: async url => {
    assert.equal(url, "https://www.googleapis.com/oauth2/v3/certs");
    return Response.json({keys:[jwk]});
  }});
  let signIn;
  const exchanges = [];
  async function idToken(nonce, email) {
    const now = Math.floor(Date.now() / 1000);
    const part = value => Buffer.from(JSON.stringify(value)).toString("base64url");
    const signed = part({alg:"RS256", kid:jwk.kid}) + "." + part({iss:"https://accounts.google.com", aud:clientId, exp:now + 300, iat:now,
      nonce, sub:"synthetic-google-" + email, email, email_verified:true});
    const signature = await crypto.subtle.sign(algorithm, keys.privateKey, new TextEncoder().encode(signed));
    return signed + "." + Buffer.from(signature).toString("base64url");
  }
  const handle = createBrowserAuth({identity, async fetchImpl(url) {
    assert.equal(url, "https://oauth2.googleapis.com/token");
    exchanges.push(signIn.email);
    return Response.json({id_token:await idToken(signIn.nonce, signIn.email)});
  }});
  const post = (action, body) => handle(new Request(path + action, {
    method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(body),
  }), env);
  const count = async table => (await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first()).n;
  async function login(email) {
    const {url, pollToken} = await (await post("start", {})).json();
    const auth = new URL(url);
    signIn = {email, nonce:auth.searchParams.get("nonce")};
    const returned = await handle(new Request(path + "callback?" + new URLSearchParams({state:auth.searchParams.get("state"), code:"synthetic-code"})), env);
    const confirmationCode = (await returned.text()).match(/\b\d{8}\b/)[0];
    const response = await post("finish", {pollToken, confirmationCode});
    return {status:response.status, body:await response.json()};
  }

  // Only Google's verified id_token names the account, so the code exchange precedes the roster check.
  assert.deepEqual(await login("someone@example.test"), {status:403, body:{error:"tester_required"}});
  assert.deepEqual(exchanges, ["someone@example.test"]);
  for (const table of ["account_users","account_emails","account_identities","account_sessions","account_auth_challenges","account_browser_attempts"]) {
    assert.equal(await count(table), 0, table);
  }
  const admitted = await login("halle-owner@example.test");
  assert.equal(admitted.status, 200);
  assert.ok(admitted.body.token);
  assert.equal(await count("account_users"), 1);
  assert.equal((await db.prepare("SELECT email FROM account_emails").first()).email, "halle-owner@example.test");
  env.ACCOUNT_STAGING_TESTER_EMAILS = "";
  const closed = await post("start", {});
  assert.deepEqual([closed.status, await closed.json()], [403, {error:"tester_required"}]);
  assert.equal(await count("account_browser_attempts"), 0);
  assert.equal(exchanges.length, 2);
});
