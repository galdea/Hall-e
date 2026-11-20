import { execFile } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

const runFile = promisify(execFile);
export const ownerEmail = "halle-owner@example.test";
export const otherEmail = "halle-other@example.test";

export async function consumeStagingCode(email) {
  if (email !== ownerEmail && email !== otherEmail) throw new Error("Unknown staging mailbox");
  const command = `DELETE FROM staging_qa_mailbox WHERE email='${email}' AND expires_at>unixepoch()*1000 RETURNING code`;
  // Do not replay stdout/stderr on error. A returned row contains a short-lived login code.
  let rows;
  try {
    const env = { ...process.env, WRANGLER_SEND_METRICS: "false", WRANGLER_WRITE_LOGS: "false", WRANGLER_LOG_SANITIZE: "true" };
    delete env.WRANGLER_OUTPUT_FILE_DIRECTORY;
    delete env.WRANGLER_OUTPUT_FILE_PATH;
    const result = await runFile(process.env.WRANGLER_BIN, [
      "d1", "execute", "ACCOUNT_DB", "--remote", "--config", resolve(process.env.HALLE_STAGE_CONFIG),
      "--command", command, "--json",
    ], { timeout: 60_000, env });
    rows = JSON.parse(result.stdout);
  } catch { throw new Error("Could not consume private staging mail via D1"); }
  const code = rows[0]?.results?.[0]?.code;
  if (!/^\d{8}$/.test(code ?? "")) throw new Error("No fresh code in the private staging mailbox");
  return code;
}

// Operator invocation. Only print a code to an interactive terminal on the authenticated Mac.
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (!process.stdout.isTTY) throw new Error("Open an interactive terminal to view the staging code.");
  const email = process.argv[2] || ownerEmail;
  process.env.HALLE_STAGE_CONFIG ||= fileURLToPath(new URL("../wrangler.account.staging.jsonc", import.meta.url));
  process.env.WRANGLER_BIN ||= "wrangler";
  try {
    const code = await consumeStagingCode(email);
    console.log(`Hall-e Staging — ${email}: ${code}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
