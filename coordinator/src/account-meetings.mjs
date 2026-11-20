const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isAccountId = value => typeof value === "string" && uuid.test(value);

export function accountJSON(body, status = 200) {
  return Response.json(body, {status, headers: {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"}});
}
const fail = (error, status) => accountJSON({error}, status);

// Require an explicit offset. Device time zones and local DST settings must not change an instant.
function instant(value) {
  if (typeof value !== "string") return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.exec(value);
  if (!match) return null;
  const date = new Date(match[0].slice(0, 10) + "T00:00:00Z");
  if (!Number.isFinite(date.valueOf()) || date.toISOString().slice(0,10) !== value.slice(0,10)) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? new Date(time).toISOString() : null;
}

function serialize(row, recordings = []) {
  return {id: row.id, title: row.title, startAt: row.start_at, endAt: row.end_at,
    revision: row.revision, deleted: Boolean(row.deleted), recordings: row.deleted ? [] : recordings};
}

export async function listMeetings(env, userId, recordingsFor, since = null) {
  // Read the version first. A concurrent commit remains visible on the next poll.
  const version = await env.ACCOUNT_DB.prepare("SELECT version FROM account_calendar_versions WHERE user_id=?")
    .bind(userId).first("version") ?? "00000000000000000000000000000000";
  if (since === version) return accountJSON({unchanged: true, version});
  const {results} = await env.ACCOUNT_DB.prepare(
    "SELECT * FROM account_meetings WHERE user_id = ? ORDER BY start_at, id"
  ).bind(userId).all();
  const byMeeting = new Map();
  for (const {meetingId, ...recording} of await recordingsFor(env, userId)) {
    if (!byMeeting.has(meetingId)) byMeeting.set(meetingId, []);
    byMeeting.get(meetingId).push(recording);
  }
  return accountJSON({version, meetings: results.map(row => serialize(row, byMeeting.get(row.id)))});
}

function mutation(body) {
  if (!body || !isAccountId(body.mutationId) ||
      !Number.isSafeInteger(body.baseRevision) || body.baseRevision < 0 ||
      (body.deleted !== undefined && typeof body.deleted !== "boolean")) return null;
  const deleted = body.deleted === true;
  if (deleted && body.baseRevision === 0) return null;
  const title = typeof body.title === "string" ? body.title.trim() : "";
  const start = instant(body.startAt), end = instant(body.endAt);
  if (!deleted && (!title || title.length > 512 || !start || !end || Date.parse(end) <= Date.parse(start))) return null;
  return {id: body.mutationId.toLowerCase(), base: body.baseRevision, deleted, title: deleted ? "" : title,
    start: deleted ? null : start, end: deleted ? null : end};
}

export async function putMeeting(body, env, userId, meetingId) {
  const change = mutation(body);
  if (!change) return fail("invalid_meeting", 400);
  const bytes = new TextEncoder().encode(JSON.stringify([meetingId, change.base, change.deleted, change.title, change.start, change.end]));
  const fingerprint = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    byte => byte.toString(16).padStart(2, "0")).join("");
  const db = env.ACCOUNT_DB;
  const previous = db.prepare("SELECT fingerprint FROM account_meeting_mutations WHERE user_id=? AND mutation_id=?")
    .bind(userId, change.id);
  const read = db.prepare("SELECT * FROM account_meetings WHERE user_id=? AND id=?").bind(userId, meetingId);
  // D1 executes a batch as a single transaction. A reused key cannot race a second write.
  const unused = "NOT EXISTS (SELECT 1 FROM account_meeting_mutations WHERE user_id=? AND mutation_id=?)";
  let write;
  if (change.base === 0) {
    write = db.prepare(`INSERT INTO account_meetings (user_id,id,title,start_at,end_at,revision,deleted,last_mutation)
      SELECT ?,?,?,?,?,1,0,? WHERE ${unused} ON CONFLICT(user_id,id) DO NOTHING`)
      .bind(userId, meetingId, change.title, change.start, change.end, change.id, userId, change.id);
  } else {
    write = db.prepare(`UPDATE account_meetings SET title=?,start_at=COALESCE(?,start_at),end_at=COALESCE(?,end_at),
      revision=revision+1,deleted=?,last_mutation=?
      WHERE user_id=? AND id=? AND revision=? AND deleted=0 AND ${unused}`)
      .bind(change.title, change.start, change.end, Number(change.deleted), change.id, userId, meetingId, change.base, userId, change.id);
  }
  const receipt = db.prepare(`INSERT INTO account_meeting_mutations (user_id,mutation_id,meeting_id,fingerprint)
    SELECT user_id,last_mutation,id,? FROM account_meetings WHERE user_id=? AND id=? AND last_mutation=?
    ON CONFLICT(user_id,mutation_id) DO NOTHING`).bind(fingerprint, userId, meetingId, change.id);
  const [, , key, result] = await db.batch([write, receipt, previous, read]);
  const row = result.results[0];
  if (key.results.length && key.results[0].fingerprint !== fingerprint) return fail("mutation_key_reused", 409);
  if (!row) return fail("not_found", 404);
  if (!key.results.length) return accountJSON({error:"revision_conflict", meeting:serialize(row)}, 409);
  return accountJSON({meeting: serialize(row)});
}
