import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import mailbox from "../src/staging-mailbox.mjs";
import { openAccountDatabase } from "../test-support/account.mjs";

const schema = await readFile(new URL("../staging/mailbox.sql", import.meta.url), "utf8");

async function setup(t) {
  const db = openAccountDatabase(":memory:", { migrate: false });
  t.after(() => db.close());
  await db.exec(schema);
  const env = { ACCOUNT_DB: db };
  const send = (body, { url = "https://mail.internal/email-code", method = "POST" } = {}) =>
    mailbox.fetch(new Request(url, { method, body: method === "GET" ? undefined : JSON.stringify(body) }), env);
  const rows = async () => (await db.prepare("SELECT email, code, expires_at FROM staging_qa_mailbox ORDER BY email").all()).results;
  return { db, env, send, rows };
}

test("the staging mailbox accepts eight-digit codes only for the two synthetic testers", async (t) => {
  const { send, rows } = await setup(t);
  for (const body of [
    { email: "someone@example.test", code: "12345678" },
    { email: "HALLE-OWNER@example.test", code: "12345678" },
    { email: "halle-owner@example.test", code: "1234567" },
    { email: "halle-owner@example.test", code: 12345678 },
    null,
  ]) {
    assert.equal((await send(body)).status, 400);
  }
  assert.deepEqual(await rows(), []);
  const before = Date.now();
  assert.equal((await send({ email: "halle-owner@example.test", code: "12345678" })).status, 204);
  const [row] = await rows();
  assert.equal(row.code, "12345678");
  assert.ok(row.expires_at >= before + 10 * 60_000 && row.expires_at <= Date.now() + 10 * 60_000);
});

test("the staging mailbox answers 404 outside its private service URL and method", async (t) => {
  const { send, rows } = await setup(t);
  const mail = { email: "halle-owner@example.test", code: "12345678" };
  for (const options of [
    { url: "https://mail.internal/email-code", method: "GET" },
    { url: "https://mail.internal/email-code", method: "PUT" },
    { url: "https://mail.internal/email-code?read=1" },
    { url: "https://mail.internal/other" },
    { url: "http://mail.internal/email-code" },
    { url: "https://halle-account-staging.example.test/email-code" },
  ]) {
    assert.equal((await send(mail, options)).status, 404, options.url);
  }
  assert.deepEqual(await rows(), []);
});

test("expired codes are removed by the scheduled cleanup and by the next delivery", async (t) => {
  const { db, env, send, rows } = await setup(t);
  const insert = db.prepare("INSERT INTO staging_qa_mailbox(email,code,expires_at) VALUES (?,?,?)");
  await insert.bind("halle-owner@example.test", "11111111", Date.now() - 1).run();
  await insert.bind("halle-other@example.test", "22222222", Date.now() + 60_000).run();
  await mailbox.scheduled({}, env);
  assert.deepEqual((await rows()).map((row) => row.email), ["halle-other@example.test"]);

  await db.prepare("UPDATE staging_qa_mailbox SET expires_at=?").bind(Date.now() - 1).run();
  assert.equal((await send({ email: "halle-owner@example.test", code: "33333333" })).status, 204);
  assert.deepEqual((await rows()).map((row) => [row.email, row.code]), [["halle-owner@example.test", "33333333"]]);
});
