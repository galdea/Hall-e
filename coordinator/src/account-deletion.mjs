import { accountJSON } from "./account-meetings.mjs";

const fail = (error, status) => accountJSON({error}, status);
// Tables keyed by user_id, children before parents. account_calendar_versions follows the
// recording delete, whose trigger writes a new version for the same user.
const meetingTables = ["account_transcript_imports", "account_meeting_projects", "account_projects",
  "account_meeting_mutations", "account_meetings"];
const identityTables = ["account_sessions", "account_identities", "account_emails", "account_calendar_versions", "account_users"];
const blobs = "SELECT blob_id FROM account_recordings WHERE user_id=?";
const pending = `SELECT challenge_id FROM account_auth_challenges
  WHERE link_session IN (SELECT session_id FROM account_sessions WHERE user_id=?)
  OR email IN (SELECT email FROM account_emails WHERE user_id=?)`;

// `request` is already bounded by the router; null means the body was too large.
async function confirmed(request) {
  try { return (await request?.json())?.confirmation === "DELETE"; } catch { return false; }
}

// A short, one-way reference for the audit log. It never carries an email or the account ID itself.
async function auditReference(userId) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(userId)));
  return Array.from(digest.subarray(0, 6), byte => byte.toString(16).padStart(2, "0")).join("");
}

// One D1 batch is one transaction: a failure before commit leaves everything, so the same session can retry.
export async function deleteAccount(request, env, userId) {
  if (env.ACCOUNT_DELETION_ENABLED !== "yes") return fail("deletion_disabled", 403);
  if (!await confirmed(request)) return fail("confirmation_required", 400);
  const db = env.ACCOUNT_DB;
  const sql = (text, ...values) => db.prepare(text).bind(...values);
  await db.batch([
    // The disposal queue keeps only opaque blob IDs, so R2 cleanup outlives the rows removed below.
    sql(`INSERT INTO account_disposals(blob_id,size,queued_at) SELECT blob_id,size,? FROM account_recordings
      WHERE user_id=? ON CONFLICT(blob_id) DO NOTHING`, Date.now(), userId),
    sql(`DELETE FROM account_recording_transcripts WHERE blob_id IN (${blobs})`, userId),
    sql(`DELETE FROM account_recording_parts WHERE blob_id IN (${blobs})`, userId),
    sql("DELETE FROM account_recordings WHERE user_id=?", userId),
    ...meetingTables.map(table => sql(`DELETE FROM ${table} WHERE user_id=?`, userId)),
    // Unfinished sign-ins or links of this account, including the address they were sent to.
    sql(`DELETE FROM account_browser_attempts WHERE challenge_id IN (${pending})`, userId, userId),
    sql(`DELETE FROM account_auth_challenges WHERE challenge_id IN (${pending})`, userId, userId),
    ...identityTables.map(table => sql(`DELETE FROM ${table} WHERE user_id=?`, userId)),
  ]);
  console.log("account_deleted", await auditReference(userId));
  return accountJSON({status: "deleting"}, 202);
}
