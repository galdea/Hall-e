import {authenticate, handleAuth} from "./account-auth.mjs";
import {handleBrowserAuth} from "./account-browser.mjs";
import {deleteAccount} from "./account-deletion.mjs";
import {handleTranscriptImport, importedRecordingsFor, importedTranscript} from "./account-import.mjs";
import {disposeRemoved, handleRecording, processPending, recordingTranscript, recordingsFor} from "./account-recording.mjs";
import {accountJSON, isAccountId, listMeetings, putMeeting} from "./account-meetings.mjs";

const fail = (error, status) => accountJSON({error}, status);

async function boundedRequest(request, limit) {
  if (Number(request.headers.get("content-length")) > limit) return null;
  const reader = request.body?.getReader();
  if (!reader) return request;
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new Request(request, {body: bytes});
}

// Start R2 cleanup once a removal is acknowledged; the cron retries. Logs carry only the error class.
function disposeSoon(env, ctx) {
  ctx?.waitUntil?.(disposeRemoved(env).catch(error => console.error("account_disposal_failed", error?.name ?? "Error")));
}

// One path serves provider recordings and local-import copies; both queries are scoped to the owner.
async function transcriptOf(env, ids) {
  const text = (await recordingTranscript(env, ids)) ?? (await importedTranscript(env, ids));
  if (text === null) return fail("not_found", 404);
  return new Response(text, {headers: {"Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store"}});
}

async function route(request, env, ctx) {
  const url = new URL(request.url);
  if (url.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) {
    return fail("https_required", 400);
  }
  const prefix = "/account/v1/";
  if (!url.pathname.startsWith(prefix)) return fail("not_found", 404);
  const [area, meeting, resource, recording, ...tail] = url.pathname.slice(prefix.length).split("/");
  if (area === "auth") {
    return meeting === "browser" ? handleBrowserAuth(request, env) : handleAuth(request, env);
  }
  if (area === "account") {
    if (meeting !== "delete" || resource !== undefined) return fail("not_found", 404);
    if (request.method !== "POST") return fail("method_not_allowed", 405);
    const session = await authenticate(request, env);
    if (!session) return fail("unauthorized", 401);
    const response = await deleteAccount(await boundedRequest(request, 1024), env, session.userId);
    if (response.status === 202) disposeSoon(env, ctx);
    return response;
  }
  if (area !== "meetings") return fail("not_found", 404);
  const session = await authenticate(request, env);
  if (!session) return fail("unauthorized", 401);
  if (meeting === undefined && request.method === "GET") {
    // Opt-in only: without it the agenda keeps sending inline transcripts to older clients.
    const lazy = url.searchParams.get("transcripts") === "lazy";
    return listMeetings(env, session.userId, async (env, userId) =>
      [...await recordingsFor(env, userId, {lazy}), ...await importedRecordingsFor(env, userId, {lazy})],
      url.searchParams.get("since"));
  }
  if (!isAccountId(meeting)) return fail("not_found", 404);
  const meetingId = meeting.toLowerCase();
  if (resource === undefined && request.method === "PUT") {
    const bounded = await boundedRequest(request, 8192);
    if (!bounded) return fail("body_too_large", 413);
    let body;
    try { body = await bounded.json(); } catch { return fail("invalid_json", 400); }
    const response = await putMeeting(body, env, session.userId, meetingId);
    if (response.ok && body?.deleted === true) disposeSoon(env, ctx);
    return response;
  }
  if (resource === "recordings" && isAccountId(recording)) {
    if (tail.join("/") === "transcript" && request.method === "GET") {
      return transcriptOf(env, [session.userId, meetingId, recording.toLowerCase()]);
    }
    const response = await handleRecording(request, env, session.userId, meetingId, recording.toLowerCase(), tail.join("/"));
    if (response.status === 204 && request.method === "DELETE") disposeSoon(env, ctx);
    return response;
  }
  if (resource === "imports" && isAccountId(recording) && tail.length === 0) {
    if (request.method === "PUT") {
      request = await boundedRequest(request, 6 * 512 * 1024 + 1024);
      if (!request) return fail("body_too_large", 413);
    }
    return handleTranscriptImport(request, env, session.userId, meetingId, recording.toLowerCase());
  }
  return fail("not_found", 404);
}

export default {
  async fetch(request, env, ctx) {
    try {
      const response = await route(request, env, ctx);
      const headers = new Headers(response.headers);
      headers.set("Cache-Control", "no-store");
      headers.set("Referrer-Policy", "no-referrer");
      headers.set("X-Content-Type-Options", "nosniff");
      return new Response(response.body, {status: response.status, headers});
    } catch {
      // Provider errors, object keys and user content must never reach a client or a log.
      return fail("service_unavailable", 503);
    }
  },
  async scheduled(_event, env) {
    await processPending(env);
  },
};
