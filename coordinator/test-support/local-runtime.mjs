import { readFile, readdir } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const coordinatorRoot = fileURLToPath(new URL("../", import.meta.url));

export async function startAccountRuntime(options) {
  const requireTools = createRequire(resolve(process.env.ACCOUNT_WORKER_TOOLS || resolve(coordinatorRoot, "node_modules"), ".local-smoke.cjs"));
  const { Miniflare, convertV4MiniflareOptions } = requireTools("miniflare");
  const { build } = requireTools("esbuild");
  const { outputFiles } = await build({
    entryPoints: [resolve(coordinatorRoot, "src/account-worker.mjs")], bundle: true, write: false,
    platform: "neutral", format: "esm", external: ["node:crypto"],
  });
  const config = {
    host: "127.0.0.1", port: 0, modules: true, script: outputFiles[0].text, cf: {},
    compatibilityDate: "2026-09-15", compatibilityFlags: ["nodejs_compat"],
    d1Databases: ["ACCOUNT_DB"], r2Buckets: ["ACCOUNT_AUDIO"], ...options,
  };
  const runtime = new Miniflare(convertV4MiniflareOptions ? convertV4MiniflareOptions(config) : config);
  try {
    const db = await runtime.getD1Database("ACCOUNT_DB");
    await installSchema(db);
    return { runtime, db };
  } catch (error) {
    await runtime.dispose();
    throw error;
  }
}

async function installSchema(db) {
  // Parse complete SQL, including trigger bodies, before applying it to the actual D1 instance.
  const schema = new DatabaseSync(":memory:");
  try {
    for (const name of (await readdir(coordinatorRoot)).filter(n => /^account.*\.sql$/.test(n)).sort()) {
      schema.exec(await readFile(resolve(coordinatorRoot, name), "utf8"));
    }
    const statements = schema.prepare("SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid").all();
    await db.batch(statements.map(row => db.prepare(row.sql)));
  } finally {
    schema.close();
  }
}
