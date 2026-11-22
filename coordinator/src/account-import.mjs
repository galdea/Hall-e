import { accountJSON, isAccountId } from "./account-meetings.mjs";

const maxTranscriptBytes = 512 * 1024;
const fail = (error, status) => accountJSON({error}, status);

function view(row) {
  return {
    id: row.id, meetingId: row.meeting_id, status: "completed",
    transcript: row.transcript, source: "local-import",
  };
}

function lazyView(row) {
  return {...view({...row, transcript: null}), transcriptAvailable: true, transcriptBytes: row.transcript_bytes};
}

const liveImports = `FROM account_transcript_imports imported JOIN account_meetings meeting
      ON meeting.user_id=imported.user_id AND meeting.id=imported.meeting_id
    WHERE imported.user_id=? AND imported.transcript IS NOT NULL AND meeting.deleted=0`;

export async function importedRecordingsFor(env, userId, {lazy = false} = {}) {
  const text = lazy ? "length(CAST(imported.transcript AS BLOB)) AS transcript_bytes" : "imported.transcript";
  const {results} = await env.ACCOUNT_DB.prepare(`
    SELECT imported.id, imported.meeting_id, ${text}
    ${liveImports}
    ORDER BY imported.id`).bind(userId).all();
  return results.map(lazy ? lazyView : view);
}

export async function importedTranscript(env, [userId, meetingId, importId]) {
  return await env.ACCOUNT_DB.prepare(`SELECT imported.transcript ${liveImports} AND imported.meeting_id=? AND imported.id=?`)
    .bind(userId, meetingId, importId).first("transcript") ?? null;
}

export async function handleTranscriptImport(request, env, userId, meetingId, importId) {
  if (!isAccountId(meetingId) || !isAccountId(importId)) return fail("not_found", 404);
  meetingId = meetingId.toLowerCase();
  importId = importId.toLowerCase();
  const db = env.ACCOUNT_DB;
  if (request.method === "DELETE") {
    const existing = await db.prepare(`
      UPDATE account_transcript_imports SET transcript=NULL
      WHERE user_id=? AND id=? AND meeting_id=? RETURNING id`).bind(userId, importId, meetingId).first();
    if (!existing) return fail("not_found", 404);
    return new Response(null, { status: 204, headers: {"Cache-Control":"no-store"} });
  }
  if (request.method !== "PUT") return fail("method_not_allowed", 405);
  let body;
  try { body = await request.json(); } catch { return fail("invalid_json", 400); }
  if (body?.consent !== true || typeof body.transcript !== "string" || !body.transcript.trim()) {
    return fail("invalid_transcript_import", 400);
  }
  if (new TextEncoder().encode(body.transcript).byteLength > maxTranscriptBytes) {
    return fail("transcript_too_large", 413);
  }
  const select = db.prepare(`SELECT imported.* FROM account_transcript_imports imported
    JOIN account_meetings meeting ON meeting.user_id=imported.user_id AND meeting.id=?
    WHERE imported.user_id=? AND imported.id=? AND meeting.deleted=0`).bind(meetingId, userId, importId);
  const [, result] = await db.batch([
    db.prepare(`INSERT INTO account_transcript_imports (user_id,id,meeting_id,transcript)
      SELECT ?,?,?,? WHERE EXISTS (SELECT 1 FROM account_meetings WHERE user_id=? AND id=? AND deleted=0)
      ON CONFLICT (user_id,id) DO NOTHING`).bind(userId, importId, meetingId, body.transcript, userId, meetingId),
    select,
  ]);
  const row = result.results[0];
  if (!row) return fail("not_found", 404);
  if (row.meeting_id !== meetingId) return fail("import_conflict", 409);
  if (row.transcript === null) return fail("import_removed", 410);
  if (row.transcript !== body.transcript) return fail("import_conflict", 409);
  return accountJSON({recording:view(row)});
}
