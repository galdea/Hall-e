import test from "node:test";
import assert from "node:assert/strict";
import worker, { WorkspaceCoordinator } from "../src/worker.mjs";

function coordinator() {
  const records = new Map();
  const state = {
    storage: {
      async get(key) { return records.get(key) ?? null; },
      async put(key, value) { records.set(key, structuredClone(value)); },
      async setAlarm() {},
      async deleteAlarm() {},
      async deleteAll() { records.clear(); },
    },
    blockConcurrencyWhile(fn) { return fn(); },
  };
  return { app: new WorkspaceCoordinator(state), records };
}
const call = (app, path, { method = "GET", body, token } = {}) => app.fetch(new Request(`https://coordinator.test${path}`, {
  method,
  headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...(token ? { authorization: `Bearer ${token}` } : {}) },
  body: body === undefined ? undefined : JSON.stringify(body),
}));

test("invite is single-use and can be reissued by the owner", async () => {
  const { app } = coordinator();
  const workspaceId = "e67d3c2f-947f-4aae-b0c6-b0a02f81e02c";
  const created = await (await call(app, "/v1/internal/create", { method: "POST", body: { workspaceId, deviceName: "Mac" } })).json();
  const firstJoin = await call(app, `/v1/workspaces/${workspaceId}/join`, { method: "POST", body: { inviteToken: created.inviteToken, deviceName: "Phone" } });
  assert.equal(firstJoin.status, 201);
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/join`, { method: "POST", body: { inviteToken: created.inviteToken, deviceName: "Tablet" } })).status, 401);
  const renewed = await (await call(app, `/v1/workspaces/${workspaceId}/invites`, { method: "POST", body: {}, token: created.deviceToken })).json();
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/join`, { method: "POST", body: { inviteToken: renewed.inviteToken, deviceName: "Tablet" } })).status, 201);
});

test("lease secrets are hidden from other paired devices and segment finalization is allowed", async () => {
  const { app } = coordinator();
  const workspaceId = "e67d3c2f-947f-4aae-b0c6-b0a02f81e02c";
  const created = await (await call(app, "/v1/internal/create", { method: "POST", body: { workspaceId, deviceName: "Mac" } })).json();
  const joined = await (await call(app, `/v1/workspaces/${workspaceId}/join`, { method: "POST", body: { inviteToken: created.inviteToken, deviceName: "Phone" } })).json();
  const sessionId = "47f13ed1-11e1-4fb7-9c88-158084e94a4a";
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/sessions`, { method: "POST", token: created.deviceToken, body: { id: sessionId, encryptedPayload: btoa("1234567890123456789012345678") } })).status, 201);
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/sessions/${sessionId}`, { method: "PATCH", token: created.deviceToken, body: { encryptedPayload: btoa("1234567890123456789012345678"), expectedRevision: 0 } })).status, 409);
  const lease = await (await call(app, `/v1/workspaces/${workspaceId}/lease/claim`, { method: "POST", token: created.deviceToken, body: { sessionId } })).json();
  const state = await (await call(app, `/v1/workspaces/${workspaceId}/state`, { token: joined.deviceToken })).json();
  assert.equal(state.ownerDeviceId, created.deviceId);
  assert.equal("generationToken" in state.activeLease, false);
  const otherSessionId = "670c74f6-9a38-4bc9-9fdc-e2d090d725f3";
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/sessions`, { method: "POST", token: created.deviceToken, body: { id: otherSessionId, encryptedPayload: btoa("1234567890123456789012345678") } })).status, 201);
  const segmentId = "343fca52-edbd-4225-aed7-fbd3e51ff12f";
  const credentials = { leaseId: lease.leaseId, generation: lease.generation, generationToken: lease.generationToken };
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/sessions/${otherSessionId}/segments`, { method: "POST", token: created.deviceToken, body: { ...credentials, id: segmentId, startedAtMs: 1, endedAtMs: null, status: "recording" } })).status, 409);
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/sessions/${sessionId}/segments`, { method: "POST", token: created.deviceToken, body: { ...credentials, id: segmentId, startedAtMs: 1, endedAtMs: null, status: "recording" } })).status, 201);
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/sessions/${sessionId}/segments/${segmentId}`, { method: "PATCH", token: created.deviceToken, body: { ...credentials, id: segmentId, startedAtMs: 7, endedAtMs: 2, status: "complete" } })).status, 409);
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/sessions/${sessionId}/segments/${segmentId}`, { method: "PATCH", token: created.deviceToken, body: { ...credentials, id: otherSessionId, endedAtMs: 2, status: "complete" } })).status, 409);
  const finished = await call(app, `/v1/workspaces/${workspaceId}/sessions/${sessionId}/segments/${segmentId}`, { method: "PATCH", token: created.deviceToken, body: { ...credentials, endedAtMs: 2, status: "complete" } });
  assert.equal(finished.status, 200);
  assert.equal((await finished.json()).status, "complete");
});

test("stale workspaces expire synchronously before invite consumption or auth", async () => {
  const { app, records } = coordinator();
  const workspaceId = "e67d3c2f-947f-4aae-b0c6-b0a02f81e02c";
  const created = await (await call(app, "/v1/internal/create", { method: "POST", body: { workspaceId, deviceName: "Mac" } })).json();
  const workspace = records.get("workspace");
  workspace.lastActivityAtMs = Date.now() - 7 * 24 * 60 * 60_000;
  records.set("workspace", workspace);
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/join`, { method: "POST", body: { inviteToken: created.inviteToken, deviceName: "Phone" } })).status, 404);
  assert.equal(records.has("workspace"), false);
});

test("revoked device is unauthorized and input parser rejects non-object and oversized bodies", async () => {
  const { app } = coordinator();
  const workspaceId = "e67d3c2f-947f-4aae-b0c6-b0a02f81e02c";
  const created = await (await call(app, "/v1/internal/create", { method: "POST", body: { workspaceId, deviceName: "Mac" } })).json();
  const joined = await (await call(app, `/v1/workspaces/${workspaceId}/join`, { method: "POST", body: { inviteToken: created.inviteToken, deviceName: "Phone" } })).json();
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/devices/${joined.deviceId}`, { method: "DELETE", token: created.deviceToken })).status, 200);
  assert.equal((await call(app, `/v1/workspaces/${workspaceId}/state`, { token: joined.deviceToken })).status, 401);
  const nullBody = await call(app, `/v1/workspaces/${workspaceId}/sessions`, { method: "POST", token: created.deviceToken, body: null });
  assert.equal(nullBody.status, 400);
  const large = await app.fetch(new Request(`https://coordinator.test/v1/workspaces/${workspaceId}/sessions`, {
    method: "POST", headers: { authorization: `Bearer ${created.deviceToken}`, "content-type": "application/json" },
    body: `{"padding":"${"x".repeat(17_000)}"}`,
  }));
  assert.equal(large.status, 413);
});

test("public create and join rate-limit binding can reject before Durable Object access", async () => {
  let calls = 0;
  const env = {
    PUBLIC_RATE_LIMITER: { async limit({ key }) { calls += 1; return { success: key !== "workspace-create" }; } },
    WORKSPACES: { get() { throw new Error("must not reach object when limited"); }, idFromName() { return "unused"; } },
  };
  const limited = await worker.fetch(new Request("https://coordinator.test/v1/workspaces", { method: "POST", body: "{}" }), env);
  assert.equal(limited.status, 429);
  assert.equal(calls, 1);
});
