import { accountProofTag, handleAuth, newNumericCode } from "./account-auth.mjs";
// Native clients open the authorization URL in their system browser and retain the
// independent poll secret. Returning from that browser also requires its one-time code.
const route = "/account/v1/auth/browser/";
const lifetime = 5 * 60 * 1000;
const encode = (bytes) => btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
const secret = () => encode(crypto.getRandomValues(new Uint8Array(32)));
async function hash(value) {
  return encode(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

const headers = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
};
function failure(status, error) {
  return Response.json({error}, {status, headers});
}
function googleCallback(env) {
  const origin = new URL(env.ACCOUNT_PUBLIC_ORIGIN);
  if (origin.protocol !== "https:" || origin.origin !== env.ACCOUNT_PUBLIC_ORIGIN) {
    throw new Error("Invalid account origin");
  }
  return origin.origin + route + "callback";
}
function identityRequest(request, path, data, useBearer) {
  const h = new Headers({"Content-Type":"application/json"});
  if (useBearer && request.headers.has("Authorization")) h.set("Authorization", request.headers.get("Authorization"));
  // Preserve caller address for identity rate limiting.
  if (request.headers.has("CF-Connecting-IP")) h.set("CF-Connecting-IP", request.headers.get("CF-Connecting-IP"));
  return new Request(new URL("/account/v1/auth/google/" + path, request.url), {
    method:"POST", headers:h, body:JSON.stringify(data),
  });
}
async function readBody(request) {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return null;
  const reader = request.body?.getReader();
  if (!reader) return null;
  const parts = [];
  let size = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > 2048) { await reader.cancel(); return null; }
    parts.push(value);
  }
  try {
    const data = JSON.parse(await new Blob(parts).text());
    return data && typeof data === "object" && !Array.isArray(data) ? data : null;
  } catch { return null; }
}

export function createBrowserAuth({identity = handleAuth, fetchImpl = (...args) => globalThis.fetch(...args), clock = Date.now} = {}) {
  async function handle(request, env) {
    const address = new URL(request.url);
    const action = address.pathname.slice(route.length);
    if (!address.pathname.startsWith(route) || !["start","finish","callback"].includes(action)) return failure(404, "not_found");
    if (request.method !== (action === "callback" ? "GET" : "POST")) return failure(405, "method_not_allowed");
    const db = env.ACCOUNT_DB;
    if (!db || typeof env.ACCOUNT_AUTH_SECRET !== "string" || env.ACCOUNT_AUTH_SECRET.length < 32 || !env.ACCOUNT_GOOGLE_CLIENT_SECRET || !env.ACCOUNT_GOOGLE_CLIENT_ID) return failure(503, "google_unavailable");
    const callback = googleCallback(env);
    const now = clock();
    if (action === "callback") {
      if (address.origin !== new URL(callback).origin) return failure(400, "invalid_callback");
      const query = address.searchParams;
      const state = query.get("state");
      if (!/^[\w-]{43}$/.test(state ?? "") || query.getAll("state").length !== 1) return failure(400, "invalid_callback");
      const denied = query.has("error");
      const code = query.get("code");
      if (!denied && (!code || code.length > 2048 || query.getAll("code").length !== 1)) return failure(400, "invalid_callback");
      const stateHash = await hash(state);
      const confirmationCode = denied ? null : newNumericCode();
      const proof = denied ? null : await accountProofTag(env, `browser-return:${stateHash}:${confirmationCode}`);
      const row = await db.prepare("UPDATE account_browser_attempts SET phase=?, authorization_code=?, confirmation_tag=? WHERE state_hash=? AND phase='waiting' AND expires_at>? RETURNING phase")
        .bind(denied ? "denied" : "ready", denied ? null : code, proof, stateHash, now).first();
      if (!row) return failure(410, "attempt_expired");
      const message = denied ? "Acceso cancelado. Puedes volver a Hall-e." :
        `Tu código de confirmación de Hall-e es ${confirmationCode}.\n\nIntrodúcelo en la app Hall-e del dispositivo donde iniciaste el acceso. No compartas este código con otra persona.`;
      return new Response(message, {
        headers:{...headers, "Content-Type":"text/plain; charset=utf-8"},
      });
    }
    const body = await readBody(request);
    if (!body) return failure(400, "invalid_request");
    const bearer = request.headers.get("Authorization") ?? "";
    const binding = await hash(bearer);
    if (action === "start") {
      if (body.link !== undefined && typeof body.link !== "boolean") return failure(400, "invalid_request");
      if (bearer && !body.link) return failure(400, "explicit_link_required");
      const initiated = await identity(identityRequest(request, "start", {link:body.link === true}, true), env);
      if (!initiated.ok) return initiated;
      const {challengeId, nonce, clientId} = await initiated.json();
      const pollToken = secret();
      const state = secret();
      const verifier = await hash("pkce:" + pollToken);
      const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
      url.search = new URLSearchParams({
        client_id:clientId, nonce, state, scope:"openid email", response_type:"code",
        redirect_uri:callback, code_challenge_method:"S256", code_challenge:await hash(verifier), prompt:"select_account",
      });
      await db.batch([
        db.prepare("DELETE FROM account_browser_attempts WHERE expires_at<=?").bind(now),
        db.prepare("INSERT INTO account_browser_attempts (poll_hash,state_hash,link_bearer_hash,challenge_id,expires_at,phase) VALUES (?,?,?,?,?,'waiting')")
          .bind(await hash(pollToken), await hash(state), binding, challengeId, now + lifetime),
      ]);
      return Response.json({url:url.href, pollToken}, {headers});
    }
    if (typeof body.pollToken !== "string" || !/^[\w-]{43}$/.test(body.pollToken)) return failure(400, "invalid_request");
    const key = await hash(body.pollToken);
    const grant = await db.prepare(`SELECT phase, state_hash FROM account_browser_attempts
      WHERE poll_hash=? AND link_bearer_hash=? AND expires_at>? AND failed_confirmations<5`).bind(key, binding, now).first();
    if (!grant) return failure(410, "attempt_expired");
    if (grant.phase === "denied") {
      await db.prepare("DELETE FROM account_browser_attempts WHERE poll_hash=? AND phase='denied'").bind(key).run();
      return failure(403, "google_denied");
    }
    if (grant.phase === "waiting" || body.confirmationCode === undefined) {
      const status = grant.phase === "ready" ? "confirmation_required" : "pending";
      return Response.json({status}, {status:202, headers:{...headers,"Retry-After":"3"}});
    }
    const validFormat = typeof body.confirmationCode === "string" && /^\d{8}$/.test(body.confirmationCode);
    const tag = validFormat ? await accountProofTag(env, `browser-return:${grant.state_hash}:${body.confirmationCode}`) : "invalid";
    const attempt = await db.prepare(`DELETE FROM account_browser_attempts
      WHERE poll_hash=? AND link_bearer_hash=? AND expires_at>? AND phase='ready' AND failed_confirmations<5 AND confirmation_tag=?
      RETURNING challenge_id,authorization_code`).bind(key, binding, clock(), tag).first();
    if (!attempt) {
      const failed = await db.prepare(`UPDATE account_browser_attempts SET failed_confirmations=failed_confirmations+1
        WHERE poll_hash=? AND link_bearer_hash=? AND expires_at>? AND phase='ready' AND failed_confirmations<5 AND confirmation_tag<>?
        RETURNING failed_confirmations`).bind(key, binding, clock(), tag).first();
      if (!failed || failed.failed_confirmations >= 5) return failure(410, "attempt_expired");
      return failure(401, "invalid_confirmation");
    }
    const exchanged = await fetchImpl("https://oauth2.googleapis.com/token", {
      method:"POST", redirect:"manual", body:new URLSearchParams({
        grant_type:"authorization_code", code:attempt.authorization_code, client_id:env.ACCOUNT_GOOGLE_CLIENT_ID,
        client_secret:env.ACCOUNT_GOOGLE_CLIENT_SECRET, redirect_uri:callback, code_verifier:await hash("pkce:" + body.pollToken),
      }),
    });
    if (!exchanged.ok) return failure(401, "google_exchange_failed");
    const {id_token:idToken} = await exchanged.json();
    if (typeof idToken !== "string" || !idToken) return failure(401, "google_exchange_failed");
    return identity(identityRequest(request, "verify", {challengeId:attempt.challenge_id, idToken}, Boolean(bearer)), env);
  }
  return async (request, env) => {
    try { return await handle(request, env); }
    catch { return failure(503, "browser_auth_unavailable"); }
  };
}
export const handleBrowserAuth = createBrowserAuth();
