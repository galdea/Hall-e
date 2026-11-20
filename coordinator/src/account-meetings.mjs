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
  const project = row.project_id && !row.deleted ? {id: row.project_id, name: row.project_name} : null;
  return {id: row.id, title: row.title, startAt: row.start_at, endAt: row.end_at,
    revision: row.revision, deleted: Boolean(row.deleted), project, recordings: row.deleted ? [] : recordings};
}

const meetingWithProject = `SELECT m.*, p.id AS project_id, p.name AS project_name FROM account_meetings m
  LEFT JOIN account_meeting_projects link ON link.user_id=m.user_id AND link.meeting_id=m.id
  LEFT JOIN account_projects p ON p.user_id=link.user_id AND p.id=link.project_id`;

export async function listMeetings(env, userId, recordingsFor, since = null) {
  // Read the version first. A concurrent commit remains visible on the next poll.
  const version = await env.ACCOUNT_DB.prepare("SELECT version FROM account_calendar_versions WHERE user_id=?")
    .bind(userId).first("version") ?? "00000000000000000000000000000000";
  if (since === version) return accountJSON({unchanged: true, version});
  const {results} = await env.ACCOUNT_DB.prepare(
    meetingWithProject + " WHERE m.user_id = ? ORDER BY m.start_at, m.id"
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
  let project = body.project;
  if (project !== undefined && project !== null) {
    const name = typeof project?.name === "string" ? project.name.trim() : "";
    if (!isAccountId(project?.id) || !name || name.length > 120 || /[\u0000-\u001f\u007f]/u.test(name)) return null;
    project = {id: project.id.toLowerCase(), name};
  }
  return {id: body.mutationId.toLowerCase(), base: body.baseRevision, deleted, title: deleted ? "" : title,
    start: deleted ? null : start, end: deleted ? null : end, project};
}

function projectWrites(db, change, owner, meetingId) {
  if (!change.deleted && change.project === undefined) return [];
  // Only a successful new meeting mutation may alter its project. Replays, competing
  // writes and pre-project clients keep the last explicitly saved association.
  const accepted = `EXISTS (SELECT 1 FROM account_meetings WHERE user_id=? AND id=? AND last_mutation=?)
    AND NOT EXISTS (SELECT 1 FROM account_meeting_mutations WHERE user_id=? AND mutation_id=?)`;
  const guard = [owner, meetingId, change.id, owner, change.id];
  if (change.deleted || !change.project) {
    return [db.prepare(`DELETE FROM account_meeting_projects WHERE user_id=? AND meeting_id=? AND ${accepted}`)
      .bind(owner, meetingId, ...guard)];
  }
  const {id, name} = change.project;
  return [
    db.prepare(`INSERT INTO account_projects(user_id,id,name) SELECT ?,?,? WHERE ${accepted}
      ON CONFLICT(user_id,id) DO NOTHING`).bind(owner, id, name, ...guard),
    db.prepare(`INSERT INTO account_meeting_projects(user_id,meeting_id,project_id) SELECT ?,?,? WHERE ${accepted}
      ON CONFLICT(user_id,meeting_id) DO UPDATE SET project_id=excluded.project_id`).bind(owner, meetingId, id, ...guard),
  ];
}

export async function putMeeting(body, env, userId, meetingId) {
  const change = mutation(body);
  if (!change) return fail("invalid_meeting", 400);
  const fields = [meetingId, change.base, change.deleted, change.title, change.start, change.end];
  if (change.project !== undefined) fields.push(change.project);
  const bytes = new TextEncoder().encode(JSON.stringify(fields));
  const fingerprint = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    byte => byte.toString(16).padStart(2, "0")).join("");
  const db = env.ACCOUNT_DB;
  const previous = db.prepare("SELECT fingerprint FROM account_meeting_mutations WHERE user_id=? AND mutation_id=?")
    .bind(userId, change.id);
  const read = db.prepare(meetingWithProject + " WHERE m.user_id=? AND m.id=?").bind(userId, meetingId);
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
  const batch = await db.batch([write, ...projectWrites(db, change, userId, meetingId), receipt, previous, read]);
  const [key, result] = batch.slice(-2);
  const row = result.results[0];
  if (key.results.length && key.results[0].fingerprint !== fingerprint) return fail("mutation_key_reused", 409);
  if (!row) return fail("not_found", 404);
  if (!key.results.length) return accountJSON({error:"revision_conflict", meeting:serialize(row)}, 409);
  return accountJSON({meeting: serialize(row)});
}
