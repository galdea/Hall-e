// A private service binding used only by the synthetic Hall-e staging accounts.
const testers = new Set(["halle-owner@example.test", "halle-other@example.test"]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.href !== "https://mail.internal/email-code") {
      return new Response(null, { status: 404 });
    }
    const mail = await request.json().catch(() => null);
    if (!testers.has(mail?.email) || typeof mail?.code !== "string" || !/^\d{8}$/.test(mail.code)) {
      return new Response(null, { status: 400 });
    }
    const now = Date.now();
    await env.ACCOUNT_DB.batch([
      env.ACCOUNT_DB.prepare("DELETE FROM staging_qa_mailbox WHERE expires_at <= ?").bind(now),
      env.ACCOUNT_DB.prepare("INSERT INTO staging_qa_mailbox(email,code,expires_at) VALUES (?,?,?) ON CONFLICT(email) DO UPDATE SET code=excluded.code, expires_at=excluded.expires_at")
        .bind(mail.email, mail.code, now + 10 * 60_000),
    ]);
    return new Response(null, { status: 204 });
  },

  async scheduled(_event, env) {
    await env.ACCOUNT_DB.prepare("DELETE FROM staging_qa_mailbox WHERE expires_at <= ?").bind(Date.now()).run();
  },
};
