// The account API is independent from calendar OAuth and the pairing coordinator.
const PREFIX = '/account/v1/auth/';
const TEN_MINUTES = 10 * 60 * 1000;
const SESSION_LIFETIME = 30 * 24 * 60 * 60 * 1000;
const GOOGLE_JWKS = 'https://www.googleapis.com/oauth2/v3/certs';
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const json = (value, status = 200) => Response.json(value, { status, headers: { 'Cache-Control': 'no-store' } });
const base64url = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
const randomToken = () => base64url(crypto.getRandomValues(new Uint8Array(32)));
const digest = async value => base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value))));
const statement = (db, sql, ...values) => db.prepare(sql).bind(...values);

class AuthError extends Error {
  constructor(status, code) { super(code); this.status = status; }
}
function reject(status, code) { throw new AuthError(status, code); }
function normalizedEmail(value) {
  if (typeof value !== 'string') reject(400, 'invalid_email');
  const email = value.trim().toLowerCase();
  const parts = email.split('@');
  if (email.length > 254 || parts.length !== 2 || parts[0].length > 64 ||
      !/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(parts[0]) || /(^\.|\.$|\.\.)/.test(parts[0]) ||
      !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/.test(parts[1])) reject(400, 'invalid_email');
  return email;
}
// Omission keeps the ordinary account service open. A configured, empty roster admits nobody.
function stagingTesters(env) {
  if (env.ACCOUNT_STAGING_TESTER_EMAILS === undefined) return null;
  const value = env.ACCOUNT_STAGING_TESTER_EMAILS;
  return typeof value === 'string' ? value.split(',').map(email => email.trim().toLowerCase()).filter(Boolean) : [];
}
function fromBase64url(value) {
  if (!/^[\w-]+$/.test(value)) throw new Error('invalid encoding');
  return Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
}
async function bodyOf(request) {
  if (!request.body) return {};
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > 16_384) { await reader.cancel(); reject(413, 'body_too_large'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  try {
    const bytes = new Uint8Array(total);
    let at = 0;
    for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length; }
    const result = JSON.parse(decoder.decode(bytes));
    if (result && typeof result === 'object' && !Array.isArray(result)) return result;
  } catch { /* Return a stable client error. */ }
  reject(400, 'invalid_json');
}
export function newNumericCode() {
  // Rejection sampling keeps the eight decimal digits uniformly distributed.
  const n = new Uint32Array(1);
  do { crypto.getRandomValues(n); } while (n[0] >= 4_200_000_000);
  return String(n[0] % 100_000_000).padStart(8, '0');
}
async function hmacKey(env) {
  if (typeof env.ACCOUNT_AUTH_SECRET !== 'string' || env.ACCOUNT_AUTH_SECRET.length < 32) reject(503, 'auth_unavailable');
  return crypto.subtle.importKey('raw', encoder.encode(env.ACCOUNT_AUTH_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
export async function accountProofTag(env, value) {
  const signature = await crypto.subtle.sign('HMAC', await hmacKey(env), encoder.encode(value));
  return base64url(new Uint8Array(signature));
}
async function limit(db, bucket, max, now) {
  const row = await statement(db, `INSERT INTO account_auth_limits (bucket, used, expires_at) VALUES (?, 1, ?)
    ON CONFLICT(bucket) DO UPDATE SET
      used = CASE WHEN expires_at <= ? THEN 1 ELSE used + 1 END,
      expires_at = CASE WHEN expires_at <= ? THEN excluded.expires_at ELSE expires_at END
    WHERE expires_at <= ? OR used < ? RETURNING used`, bucket, now + TEN_MINUTES, now, now, now, max).first();
  if (!row) reject(429, 'rate_limited');
}

async function sessionFor(request, env, now, testers = stagingTesters(env)) {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/i.exec(request.headers.get('Authorization') || '');
  if (!match || !env.ACCOUNT_DB) return null;
  const eligibility = testers === null ? '' : ` AND EXISTS (
    SELECT 1 FROM json_each(?) AS tester JOIN account_emails AS e ON e.email = tester.value
    WHERE e.user_id = account_sessions.user_id)`;
  return statement(env.ACCOUNT_DB, `SELECT user_id AS userId, session_id AS sessionId, expires_at AS expiresAt
    FROM account_sessions WHERE token_digest = ? AND expires_at > ?${eligibility}`, await digest(match[1]), now,
    ...(testers === null ? [] : [JSON.stringify(testers)])).first();
}

export function authenticate(request, env) { return sessionFor(request, env, Date.now()); }

async function establishSession(db, provider, subject, email, linkSession, now) {
  // UNIQUE constraints arbitrate concurrent account creation and linking. The
  // losing transaction rolls back in full, then re-reads the canonical owner.
  for (let attempt = 0; attempt < 3; attempt++) {
    const identity = await statement(db, 'SELECT user_id FROM account_identities WHERE provider = ? AND subject = ?', provider, subject).first();
    if (identity && linkSession && identity.user_id !== linkSession.userId) reject(409, 'identity_in_use');
    const userId = identity?.user_id ?? linkSession?.userId ?? crypto.randomUUID();
    const writes = [];
    if (!identity) {
      const owner = await statement(db, 'SELECT user_id FROM account_emails WHERE email = ?', email).first();
      if (owner && owner.user_id !== linkSession?.userId) reject(409, 'link_required');
      if (linkSession) {
        const current = await statement(db, 'SELECT subject FROM account_identities WHERE user_id = ? AND provider = ?', userId, provider).first();
        if (current && current.subject !== subject) reject(409, 'provider_already_linked');
      } else {
        writes.push(statement(db, 'INSERT INTO account_users (user_id) VALUES (?)', userId));
      }
      if (!owner) writes.push(statement(db, 'INSERT INTO account_emails (email, user_id) VALUES (?, ?)', email, userId));
      writes.push(statement(db, 'INSERT INTO account_identities (provider, subject, user_id) VALUES (?, ?, ?)', provider, subject, userId));
    }
    if (identity && provider === 'google') {
      // An updated verified address can block an accidental second sign-up,
      // but can never silently transfer an email identity between accounts.
      writes.push(statement(db, 'INSERT INTO account_emails (email, user_id) VALUES (?, ?) ON CONFLICT(email) DO NOTHING', email, userId));
    }
    const token = randomToken();
    const sessionId = crypto.randomUUID();
    const expiresAt = now + SESSION_LIFETIME;
    const hash = await digest(token);
    if (linkSession) {
      // NOT NULL guard rolls back all writes if logout won this race.
      writes.push(statement(db, `INSERT INTO account_sessions (session_id, token_digest, user_id, expires_at)
        VALUES (?, ?, (SELECT user_id FROM account_sessions WHERE session_id = ? AND user_id = ? AND expires_at > ?), ?)`,
        sessionId, hash, linkSession.sessionId, userId, now, expiresAt));
      writes.push(statement(db, 'DELETE FROM account_sessions WHERE session_id = ?', linkSession.sessionId));
    } else {
      writes.push(statement(db, 'INSERT INTO account_sessions VALUES (?, ?, ?, ?)', sessionId, hash, userId, expiresAt));
    }
    try { await db.batch(writes); return { userId, token, expiresAt }; }
    catch (error) {
      const detail = `${error?.message} ${error?.cause?.message}`;
      if (linkSession && /NOT NULL constraint failed: account_sessions.user_id/i.test(detail)) reject(401, 'unauthorized');
      if (!/UNIQUE constraint failed/i.test(detail) || attempt === 2) throw error;
    }
  }
}

// Network injection is local to the constructor. HTTP callers cannot select a
// key source, a token verifier, a clock, a mail transport or an account id.
export function createAccountAuth({ fetchImpl = (...args) => globalThis.fetch(...args), clock = Date.now } = {}) {
  let keys = [];
  let keysUntil = 0;
  async function googleIdentity(token, challenge, clientId, now) {
    let header, payload, signature, signed;
    try {
      const parts = typeof token === 'string' ? token.split('.') : [];
      if (parts.length !== 3) throw new Error();
      header = JSON.parse(decoder.decode(fromBase64url(parts[0])));
      payload = JSON.parse(decoder.decode(fromBase64url(parts[1])));
      signature = fromBase64url(parts[2]);
      signed = encoder.encode(`${parts[0]}.${parts[1]}`);
    } catch { reject(401, 'invalid_proof'); }
    if (header?.alg !== 'RS256' || typeof header?.kid !== 'string' || !payload || typeof payload !== 'object') reject(401, 'invalid_proof');
    if (now >= keysUntil) {
      const response = await fetchImpl(GOOGLE_JWKS, { redirect: 'manual' });
      if (!response.ok) reject(503, 'google_unavailable');
      const data = await response.json();
      if (!Array.isArray(data.keys)) reject(503, 'google_unavailable');
      keys = data.keys.filter(key => key?.kty === 'RSA' && (!key.use || key.use === 'sig') && (!key.alg || key.alg === 'RS256'));
      const ttl = Number(/\bmax-age=(\d+)/i.exec(response.headers.get('cache-control') || '')?.[1] ?? 60);
      keysUntil = now + Math.min(ttl, 3600) * 1000;
    }
    const jwk = keys.find(key => key.kid === header.kid);
    if (!jwk) reject(401, 'invalid_proof');
    const algorithm = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' };
    const key = await crypto.subtle.importKey('jwk', jwk, algorithm, false, ['verify']);
    if (!await crypto.subtle.verify(algorithm, key, signature, signed)) reject(401, 'invalid_proof');
    const seconds = Math.floor(now / 1000);
    if (!['accounts.google.com', 'https://accounts.google.com'].includes(payload.iss) || payload.aud !== clientId ||
        (payload.azp !== undefined && payload.azp !== clientId) ||
        !Number.isSafeInteger(payload.exp) || payload.exp <= seconds || !Number.isSafeInteger(payload.iat) || payload.iat > seconds + 60 ||
        (payload.nbf !== undefined && (!Number.isSafeInteger(payload.nbf) || payload.nbf > seconds + 60)) ||
        payload.nonce !== challenge.proof || typeof payload.sub !== 'string' || !payload.sub.length || payload.sub.length > 255 ||
        payload.email_verified !== true) reject(401, 'invalid_proof');
    return { subject: payload.sub, email: normalizedEmail(payload.email) };
  }
  async function sendCode(env, email, code) {
    const message = { from: env.ACCOUNT_MAIL_FROM, to: [email], subject: 'Tu código para Hall-e',
      text: `Tu código de acceso a Hall-e es ${code}. Caduca en diez minutos. Si no lo solicitaste, puedes ignorar este mensaje.` };
    let response;
    if (env.ACCOUNT_MAILER) {
      // Private Worker service binding; suitable for the owner's chosen mail provider.
      response = await env.ACCOUNT_MAILER.fetch('https://mail.internal/email-code', { method: 'POST',
        headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, code }) });
    } else if (env.ACCOUNT_RESEND_KEY && env.ACCOUNT_MAIL_FROM) {
      response = await fetchImpl('https://api.resend.com/emails', { method: 'POST', redirect: 'manual',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${env.ACCOUNT_RESEND_KEY}` }, body: JSON.stringify(message) });
    } else reject(503, 'mail_unavailable');
    if (!response.ok) reject(503, 'mail_unavailable');
  }
  async function handle(request, env) {
    const route = new URL(request.url).pathname;
    if (!route.startsWith(PREFIX)) return json({ error: 'not_found' }, 404);
    const action = route.slice(PREFIX.length);
    const db = env.ACCOUNT_DB;
    if (!db) reject(503, 'auth_unavailable');
    const now = clock();
    const testers = stagingTesters(env);
    if (action === 'session' || action === 'logout') {
      if (request.method !== (action === 'session' ? 'GET' : 'POST')) reject(405, 'method_not_allowed');
      // A removed tester can still revoke their own bearer.
      const session = await sessionFor(request, env, now, action === 'logout' ? null : testers);
      if (!session) reject(401, 'unauthorized');
      // Clients offer account deletion only when the operator enabled it on this service.
      if (action === 'session') return json({ userId: session.userId, expiresAt: session.expiresAt,
        features: { accountDeletion: env.ACCOUNT_DELETION_ENABLED === 'yes', lazyTranscripts: true } });
      await statement(db, 'DELETE FROM account_sessions WHERE session_id = ?', session.sessionId).run();
      return new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });
    }
    const match = /^(email|google)\/(start|verify)$/.exec(action);
    if (!match) reject(404, 'not_found');
    if (request.method !== 'POST') reject(405, 'method_not_allowed');
    const [, provider, phase] = match;
    const body = await bodyOf(request);
    if (provider === 'google' && !env.ACCOUNT_GOOGLE_CLIENT_ID) reject(503, 'google_unavailable');
    const session = request.headers.has('Authorization') ? await sessionFor(request, env, now, testers) : null;
    if (request.headers.has('Authorization') && !session) reject(401, 'unauthorized');
    if (phase === 'start') {
      if (body.link === true && !session) reject(401, 'unauthorized');
      if (session && body.link !== true) reject(400, 'explicit_link_required');
      // Google reveals the address only after the code exchange; a closed roster stops before Google is involved.
      if (provider === 'google' && testers?.length === 0) reject(403, 'tester_required');
      const email = provider === 'email' ? normalizedEmail(body.email) : null;
      const key = await hmacKey(env);
      const fingerprint = async value => base64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(value))));
      await limit(db, await fingerprint('ip:' + (request.headers.get('CF-Connecting-IP') || 'local')), 30, now);
      await db.batch(['account_auth_challenges', 'account_auth_limits', 'account_sessions'].map(table =>
        statement(db, `DELETE FROM ${table} WHERE expires_at <= ?`, now)));
      if (email) await limit(db, await fingerprint(`email:${email}`), 5, now);
      // Match the normal challenge response without sending mail or persisting an outsider's address.
      if (provider === 'email' && testers !== null && !testers.includes(email)) {
        return json({ challengeId: crypto.randomUUID() });
      }
      const challengeId = crypto.randomUUID();
      const code = email ? newNumericCode() : null;
      const proof = email ? await fingerprint(`otp:${challengeId}:${code}`) : randomToken();
      await statement(db, `INSERT INTO account_auth_challenges (challenge_id, provider, link_session, email, proof, expires_at)
        VALUES (?, ?, ?, ?, ?, ?)`, challengeId, provider, session?.sessionId ?? null, email, proof, now + TEN_MINUTES).run();
      if (email) {
        try { await sendCode(env, email, code); }
        catch (error) { await statement(db, 'DELETE FROM account_auth_challenges WHERE challenge_id = ?', challengeId).run(); throw error; }
        return json({ challengeId });
      }
      return json({ challengeId, nonce: proof, clientId: env.ACCOUNT_GOOGLE_CLIENT_ID });
    }
    if (typeof body.challengeId !== 'string' || body.challengeId.length !== 36) reject(401, 'invalid_proof');
    const challenge = await statement(db, `UPDATE account_auth_challenges SET attempts = attempts + 1
      WHERE challenge_id = ? AND provider = ? AND expires_at > ? AND attempts < 5 AND link_session IS ?
      RETURNING email, proof`, body.challengeId, provider, now, session?.sessionId ?? null).first();
    if (!challenge) reject(401, 'invalid_proof');
    let subject, email;
    if (provider === 'email') {
      if (typeof body.code !== 'string' || !/^\d{8}$/.test(body.code) ||
          !await crypto.subtle.verify('HMAC', await hmacKey(env), fromBase64url(challenge.proof), encoder.encode(`otp:${body.challengeId}:${body.code}`))) reject(401, 'invalid_proof');
      subject = email = challenge.email;
    } else ({ subject, email } = await googleIdentity(body.idToken, challenge, env.ACCOUNT_GOOGLE_CLIENT_ID, now));
    // Single-use for concurrent requests, independent of the client's retry timing.
    const consumed = await statement(db, 'DELETE FROM account_auth_challenges WHERE challenge_id = ? AND expires_at > ? RETURNING challenge_id', body.challengeId, clock()).first();
    if (!consumed) reject(401, 'invalid_proof');
    // Both native and browser Google sign-in reach this point after verifying the signed email claim.
    if (testers !== null && !testers.includes(email)) reject(403, 'tester_required');
    return json(await establishSession(db, provider, subject, email, session, clock()));
  }
  return async function handleAuth(request, env) {
    try { return await handle(request, env); }
    catch (error) { return error instanceof AuthError ? json({ error: error.message }, error.status) : json({ error: 'auth_unavailable' }, 503); }
  };
}

export const handleAuth = createAccountAuth();
