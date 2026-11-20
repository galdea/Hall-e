import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openAccountDatabase } from '../test-support/account.mjs';
import { authenticate, createAccountAuth } from '../src/account-auth.mjs';

const enc = new TextEncoder();
const audience = 'synthetic-client.apps.googleusercontent.com';
const algorithm = { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' };
const keys = await crypto.subtle.generateKey(algorithm, false, ['sign', 'verify']);
const jwk = { ...await crypto.subtle.exportKey('jwk', keys.publicKey), kid: 'fixture-key', alg: 'RS256', use: 'sig' };

function setup(t) {
  const db = openAccountDatabase();
  t.after(() => db.close());
  const mail = [];
  let now = Date.now();
  const env = { ACCOUNT_DB: db, ACCOUNT_GOOGLE_CLIENT_ID: audience, ACCOUNT_AUTH_SECRET: 'generated virtual fixture key of sufficient length',
    ACCOUNT_MAILER: { async fetch(url, init) {
      assert.equal(url, 'https://mail.internal/email-code');
      mail.push(JSON.parse(init.body));
      return new Response(null, { status: 204 });
    } } };
  const handle = createAccountAuth({ clock: () => now, fetchImpl: async url => {
    assert.equal(url, 'https://www.googleapis.com/oauth2/v3/certs');
    return Response.json({ keys: [jwk] }, { headers: { 'cache-control': 'max-age=300' } });
  } });
  async function call(route, body, token) {
    const request = new Request(`https://synthetic.invalid/account/v1/auth/${route}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: token ? { Authorization: `Bearer ${token}` } : {}, body: body === undefined ? undefined : JSON.stringify(body),
    });
    const response = await handle(request, env);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return { status: response.status, result: response.status === 204 ? null : await response.json() };
  }
  async function emailStart(email, token) {
    const start = await call('email/start', { email, ...(token ? { link: true } : {}) }, token);
    assert.equal(start.status, 200);
    assert.deepEqual(Object.keys(start.result), ['challengeId']);
    return { ...start.result, code: mail.at(-1).code };
  }
  async function emailLogin(email, token) {
    return call('email/verify', await emailStart(email, token), token);
  }
  async function signedGoogle(nonce, overrides = {}) {
    const header = Buffer.from(JSON.stringify({ alg: 'RS256', kid: jwk.kid })).toString('base64url');
    const payload = { iss: 'https://accounts.google.com', aud: audience, exp: Math.floor(now / 1000) + 300,
      iat: Math.floor(now / 1000), nonce, sub: 'fixture-google-account', email: 'ana@example.test', email_verified: true, ...overrides };
    const claims = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const signature = await crypto.subtle.sign(algorithm, keys.privateKey, enc.encode(`${header}.${claims}`));
    return `${header}.${claims}.${Buffer.from(signature).toString('base64url')}`;
  }
  async function googleStart(token) {
    const response = await call('google/start', token ? { link: true } : {}, token);
    assert.equal(response.status, 200);
    assert.equal(response.result.clientId, audience);
    return response.result;
  }
  async function googleLogin(overrides, token) {
    const { challengeId, nonce } = await googleStart(token);
    return call('google/verify', { challengeId, idToken: await signedGoogle(nonce, overrides) }, token);
  }
  return { call, emailStart, emailLogin, googleStart, signedGoogle, googleLogin, db, mail, env,
    advance: ms => { now += ms; } };
}

test('synthetic desktop and phone logins give one durable identity, separately revocable sessions', async t => {
  const f = setup(t);
  const a = await f.emailLogin(' Ana@Example.Test ');
  const b = await f.emailLogin('ana@example.test');
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.equal(a.result.userId, b.result.userId);
  assert.notEqual(a.result.token, b.result.token);
  const auth = () => authenticate(new Request('https://synthetic.invalid', { headers: { authorization: `Bearer ${a.result.token}` } }), f.env);
  assert.equal((await auth()).userId, a.result.userId);
  const row = await f.db.prepare('SELECT token_digest FROM account_sessions LIMIT 1').first();
  assert.notEqual(row.token_digest, a.result.token);
  assert.equal((await f.call('logout', {}, a.result.token)).status, 204);
  assert.equal(await auth(), null);
  assert.equal((await f.call('session', undefined, a.result.token)).status, 401);
  assert.equal((await f.call('session', undefined, b.result.token)).result.userId, a.result.userId);
  f.advance(31 * 86_400_000);
  assert.equal((await f.call('session', undefined, b.result.token)).status, 401);
});

test('email code is single use under parallel confirmation; attempts, expiry and start throttling persist', async t => {
  const f = setup(t);
  const email = 'retry@example.test';
  const proof = await f.emailStart(email);
  const row = await f.db.prepare('SELECT proof FROM account_auth_challenges').first();
  assert.notEqual(row.proof, proof.code);
  const parallel = await Promise.all([f.call('email/verify', proof), f.call('email/verify', proof)]);
  assert.deepEqual(parallel.map(r => r.status).sort(), [200, 401]);
  const limited = await f.emailStart(email);
  for (let n = 0; n < 5; n++) assert.equal((await f.call('email/verify', { ...limited, code: 'invalid' })).status, 401);
  assert.equal((await f.call('email/verify', limited)).status, 401);
  const expired = await f.emailStart(email);
  f.advance(600_001);
  assert.equal((await f.call('email/verify', expired)).status, 401);
  for (let n = 0; n < 5; n++) await f.emailStart(email);
  assert.equal((await f.call('email/start', { email })).status, 429);
});

test('competing first logins settle on one account without leftover users', async t => {
  const f = setup(t);
  const first = await f.emailStart('race@example.test');
  const second = await f.emailStart('race@example.test');
  const [a, b] = await Promise.all([f.call('email/verify', first), f.call('email/verify', second)]);
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.equal(a.result.userId, b.result.userId);
  assert.equal(await f.db.prepare('SELECT count(*) AS n FROM account_users').first('n'), 1);
});

test('simultaneous first email and OIDC logins reserve the same verified address once', async t => {
  const f = setup(t);
  const email = await f.emailStart('ana@example.test');
  const { challengeId, nonce } = await f.googleStart();
  const idToken = await f.signedGoogle(nonce);
  const outcomes = await Promise.all([f.call('email/verify', email), f.call('google/verify', { challengeId, idToken })]);
  assert.deepEqual(outcomes.map(x => x.status).sort(), [200, 409]);
  assert.equal(outcomes.find(x => x.status === 409).result.error, 'link_required');
  assert.equal(await f.db.prepare('SELECT count(*) AS n FROM account_users').first('n'), 1);
  assert.equal(await f.db.prepare('SELECT count(*) AS n FROM account_identities').first('n'), 1);
});

test('Google and email require explicit linking with the initiating live session; sub is stable across email changes', async t => {
  const f = setup(t);
  const a = (await f.emailLogin('ana@example.test')).result;
  const b = (await f.emailLogin('bet@example.test')).result;
  assert.notEqual(a.userId, b.userId);
  assert.deepEqual(await f.googleLogin(), { status: 409, result: { error: 'link_required' } });
  assert.equal((await f.call('google/start', { link: true })).status, 401);
  assert.equal((await f.call('google/start', {}, a.token)).status, 400);
  const start = await f.googleStart(a.token);
  const proof = { challengeId: start.challengeId, idToken: await f.signedGoogle(start.nonce) };
  assert.equal((await f.call('google/verify', proof)).status, 401);
  assert.equal((await f.call('google/verify', proof, b.token)).status, 401);
  const linked = await f.call('google/verify', proof, a.token);
  assert.equal(linked.status, 200);
  assert.equal(linked.result.userId, a.userId);
  assert.equal((await f.call('session', undefined, a.token)).status, 401);
  assert.equal((await f.call('session', undefined, linked.result.token)).status, 200);
  assert.equal((await f.call('google/verify', proof, a.token)).status, 401);
  assert.equal((await f.googleLogin({ email: 'new-address@example.test' })).result.userId, a.userId);
  assert.equal((await f.emailLogin('new-address@example.test')).status, 409);
  assert.equal((await f.googleLogin({}, b.token)).status, 409);
  const old = await f.googleStart(linked.result.token);
  await f.call('logout', {}, linked.result.token);
  assert.equal((await f.call('google/verify', { challengeId: old.challengeId, idToken: await f.signedGoogle(old.nonce) }, linked.result.token)).status, 401);
  assert.equal(await f.db.prepare('SELECT count(*) AS n FROM account_users').first('n'), 2);
});

test('Google-first identity reserves the address; email code only signs in after explicit link', async t => {
  const f = setup(t);
  const first = await f.googleLogin();
  assert.equal(first.status, 200);
  assert.deepEqual(await f.emailLogin('ana@example.test'), { status: 409, result: { error: 'link_required' } });
  assert.equal((await f.emailLogin('ana@example.test', first.result.token)).result.userId, first.result.userId);
  assert.equal((await f.emailLogin('ana@example.test')).result.userId, first.result.userId);
});

test('Google requires signed and current identity, exact issuer/audience, checked email and matching nonce', async t => {
  const f = setup(t);
  for (const overrides of [{ aud: 'other-client' }, { azp: 'other-presenter' }, { iss: 'https://synthetic.invalid' }, { email_verified: false },
    { exp: 1 }, { nonce: 'other-nonce' }, { iat: 9999999999 }]) {
    assert.equal((await f.googleLogin(overrides)).status, 401);
  }
  const start = await f.googleStart();
  const signed = await f.signedGoogle(start.nonce);
  const pieces = signed.split('.');
  pieces[2] = (pieces[2][0] === 'a' ? 'b' : 'a') + pieces[2].slice(1);
  assert.equal((await f.call('google/verify', { challengeId: start.challengeId, idToken: pieces.join('.') })).status, 401);
  assert.equal(await f.db.prepare('SELECT count(*) AS n FROM account_users').first('n'), 0);
});

test('missing email delivery or HMAC configuration fails closed', async t => {
  const f = setup(t);
  delete f.env.ACCOUNT_MAILER;
  assert.equal((await f.call('email/start', { email: 'never@example.test' })).status, 503);
  assert.equal(await f.db.prepare('SELECT count(*) AS n FROM account_auth_challenges').first('n'), 0);
  delete f.env.ACCOUNT_AUTH_SECRET;
  assert.equal((await f.call('google/start', {})).status, 503);
});

test('staging admits exact tester addresses and rechecks challenges and existing account sessions', async t => {
  const f = setup(t);
  f.env.ACCOUNT_STAGING_TESTER_EMAILS = ' Ana@Example.TEST, bet@example.test ';
  const outside = await f.call('email/start', { email: 'ana+other@example.test' });
  assert.equal(outside.status, 200);
  assert.deepEqual(Object.keys(outside.result), ['challengeId']);
  assert.equal(f.mail.length, 0);
  assert.equal(await f.db.prepare('SELECT COUNT(*) AS n FROM account_auth_challenges').first('n'), 0);
  assert.equal((await f.call('email/verify', { ...outside.result, code: '12345678' })).status, 401);

  const ana = (await f.emailLogin(' ana@example.test ')).result;
  const bet = (await f.emailLogin('BET@example.test')).result;
  assert.notEqual(ana.userId, bet.userId);
  const pending = await f.emailStart('ana@example.test');
  f.env.ACCOUNT_STAGING_TESTER_EMAILS = 'bet@example.test';
  assert.equal((await f.call('email/verify', pending)).status, 403);
  assert.equal((await f.call('session', undefined, ana.token)).status, 401);
  assert.equal((await f.call('session', undefined, bet.token)).result.userId, bet.userId);
  const request = new Request('https://synthetic.invalid/account/v1/meetings', { headers: { authorization: 'Bearer ' + ana.token } });
  assert.equal(await authenticate(request, f.env), null);
  assert.equal((await f.call('logout', {}, ana.token)).status, 204);
  f.env.ACCOUNT_STAGING_TESTER_EMAILS = '';
  const mailCount = f.mail.length;
  assert.equal((await f.call('email/start', { email: 'bet@example.test' })).status, 200);
  assert.equal(f.mail.length, mailCount);
  assert.equal((await f.call('session', undefined, bet.token)).status, 401);
});

test('staging Google proof and explicit linking require the signed, verified tester email', async t => {
  const f = setup(t);
  f.env.ACCOUNT_STAGING_TESTER_EMAILS = 'ana@example.test';
  const a = (await f.emailLogin('ana@example.test')).result;
  const { challengeId, nonce } = await f.googleStart(a.token);
  const unlisted = await f.signedGoogle(nonce, { email: 'other@example.test' });
  const denied = await f.call('google/verify', { challengeId, idToken: unlisted, email: 'ana@example.test' }, a.token);
  assert.deepEqual(denied, { status: 403, result: { error: 'tester_required' } });
  assert.equal((await f.googleLogin({ email_verified: false }, a.token)).status, 401);
  assert.equal((await f.googleLogin({ email: 'another@example.test' })).status, 403);
  assert.equal(await f.db.prepare('SELECT count(*) AS n FROM account_identities').first('n'), 1);
  assert.equal((await f.googleLogin({ email: 'ANA@example.test' }, a.token)).result.userId, a.userId);
  assert.equal((await f.googleLogin({ email: 'new-address@example.test' })).status, 403);
  assert.equal((await f.googleLogin()).result.userId, a.userId);
});
