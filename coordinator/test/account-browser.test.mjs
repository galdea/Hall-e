import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
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
