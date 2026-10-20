import test from "node:test";
import assert from "node:assert/strict";
import worker, { WorkspaceCoordinator } from "../src/worker.mjs";

function fakeCloudflare() {
  const objects = new Map();
  const WORKSPACES = {
    idFromName(name) { return name; },
    get(id) {
      if (!objects.has(id)) {
        const values = new Map();
        const state = { storage: {
          async get(key) { const value = values.get(key); return value === undefined ? undefined : structuredClone(value); },
          async put(key, value) { values.set(key, structuredClone(value)); },
          async setAlarm() {}, async deleteAlarm() {}, async deleteAll() { values.clear(); },
        } };
        const object = new WorkspaceCoordinator(state);
        objects.set(id, { fetch(input, init) {
          const request = input instanceof Request ? input : new Request(input, init);
          return object.fetch(request);
        } });
      }
      return objects.get(id);
    },
  };
  return { env: { WORKSPACES }, objects };
}

async function request(env, path, { method = "GET", body, token } = {}) {
  return worker.fetch(new Request(`https://coordinator.test${path}`, {
    method,
    headers: {
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
}

async function createWorkspace(env, deviceName = "Mac") {
  const response = await request(env, "/v1/workspaces", { method: "POST", body: { deviceName } });
  assert.equal(response.status, 201);
  return response.json();
}

async function joinWorkspace(env, workspaceId, inviteToken, deviceName = "Phone") {
  const response = await request(env, `/v1/workspaces/${workspaceId}/join`, {
    method: "POST", body: { inviteToken, deviceName },
  });
  return { response, value: await response.json() };
}

async function reissueInvite(env, workspace) {
  const response = await request(env, `/v1/workspaces/${workspace.workspaceId}/invites`, {
    method: "POST", body: {}, token: workspace.deviceToken,
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function createSession(env, workspace, token, id) {
  const response = await request(env, `/v1/workspaces/${workspace.workspaceId}/sessions`, {
    method: "POST", token, body: { id, encryptedPayload: btoa("0123456789012345678901234567") },
  });
  assert.equal(response.status, 201);
  return response.json();
}

const workspacePath = (workspace, suffix) => `/v1/workspaces/${workspace.workspaceId}${suffix}`;

test("HTTP routes consume invites once and isolate workspace credentials and state", async () => {
  const { env } = fakeCloudflare();
  const first = await createWorkspace(env);
  const firstJoin = await joinWorkspace(env, first.workspaceId, first.inviteToken);
  assert.equal(firstJoin.response.status, 201);
  assert.equal(firstJoin.value.workspaceId, first.workspaceId);

  const replay = await joinWorkspace(env, first.workspaceId, first.inviteToken, "Replay");
  assert.equal(replay.response.status, 401);
  assert.equal((await request(env, workspacePath(first, "/state"), { token: firstJoin.value.deviceToken })).status, 200);

  const second = await createWorkspace(env, "Other Mac");
  assert.notEqual(first.workspaceId, second.workspaceId);
  assert.equal((await request(env, workspacePath(second, "/state"), { token: first.deviceToken })).status, 401);
  const crossJoin = await joinWorkspace(env, second.workspaceId, first.inviteToken, "Wrong Workspace");
  assert.equal(crossJoin.response.status, 401);

  const sessionId = "47f13ed1-11e1-4fb7-9c88-158084e94a4a";
  await createSession(env, first, first.deviceToken, sessionId);
  const state = await (await request(env, workspacePath(first, "/state"), { token: firstJoin.value.deviceToken })).json();
  assert.equal(state.sessions.length, 1);
  assert.equal(state.sessions[0].id, sessionId);
  assert.equal(state.ownerDeviceId, first.deviceId);
});

test("HTTP lease claim conflicts, handoff waits for release, and stale proofs cannot release a newer lease", async () => {
  const { env } = fakeCloudflare();
  const owner = await createWorkspace(env);
  const joined = await joinWorkspace(env, owner.workspaceId, owner.inviteToken);
  const phone = joined.value;
  assert.equal(joined.response.status, 201);
  const firstSession = "47f13ed1-11e1-4fb7-9c88-158084e94a4a";
  const nextSession = "670c74f6-9a38-4bc9-9fdc-e2d090d725f3";
  await createSession(env, owner, owner.deviceToken, firstSession);
  await createSession(env, owner, owner.deviceToken, nextSession);

  const claimResponse = await request(env, workspacePath(owner, "/lease/claim"), {
    method: "POST", token: owner.deviceToken, body: { sessionId: firstSession },
  });
  assert.equal(claimResponse.status, 201);
  const lease = await claimResponse.json();
  const proof = { leaseId: lease.leaseId, generation: lease.generation, generationToken: lease.generationToken };

  const conflict = await request(env, workspacePath(owner, "/lease/claim"), {
    method: "POST", token: phone.deviceToken, body: { sessionId: nextSession },
  });
  assert.equal(conflict.status, 409);
  assert.deepEqual(await conflict.json(), { error: "lease_held" });

  const badHandoff = await request(env, workspacePath(owner, "/lease/handoff"), {
    method: "POST", token: phone.deviceToken, body: { requestedDeviceId: owner.deviceId },
  });
  assert.equal(badHandoff.status, 404);
  const handoff = await request(env, workspacePath(owner, "/lease/handoff"), {
    method: "POST", token: phone.deviceToken, body: { requestedDeviceId: phone.deviceId },
  });
  assert.equal(handoff.status, 200);
  assert.equal((await handoff.json()).handoffRequested, true);

  const renew = await request(env, workspacePath(owner, "/lease/renew"), {
    method: "POST", token: owner.deviceToken, body: proof,
  });
  assert.equal(renew.status, 200);
  const handoffRenewal = await renew.json();
  assert.equal(handoffRenewal.handoffRequested, true);
  assert.equal(handoffRenewal.expiresAtMs, lease.expiresAtMs);
  const waitingClaim = await request(env, workspacePath(owner, "/lease/claim"), {
    method: "POST", token: phone.deviceToken, body: { sessionId: nextSession },
  });
  assert.equal(waitingClaim.status, 409);
  const release = await request(env, workspacePath(owner, "/lease/release"), {
    method: "POST", token: owner.deviceToken, body: proof,
  });
  assert.equal(release.status, 200);
  assert.deepEqual(await release.json(), { released: true });

  const nextClaim = await request(env, workspacePath(owner, "/lease/claim"), {
    method: "POST", token: phone.deviceToken, body: { sessionId: nextSession },
  });
  assert.equal(nextClaim.status, 201);
  const newer = await nextClaim.json();
  assert.equal(newer.generation, lease.generation + 1);
  const staleRelease = await request(env, workspacePath(owner, "/lease/release"), {
    method: "POST", token: owner.deviceToken, body: proof,
  });
  assert.equal(staleRelease.status, 409);
  const state = await (await request(env, workspacePath(owner, "/state"), { token: owner.deviceToken })).json();
  assert.equal(state.activeLease.leaseId, newer.leaseId);
  assert.equal("generationToken" in state.activeLease, false);
});

test("HTTP segment route binds metadata to the claimed session and makes finalization immutable", async () => {
  const { env } = fakeCloudflare();
  const owner = await createWorkspace(env);
  const phone = (await joinWorkspace(env, owner.workspaceId, owner.inviteToken)).value;
  const sessionId = "47f13ed1-11e1-4fb7-9c88-158084e94a4a";
  const otherSessionId = "670c74f6-9a38-4bc9-9fdc-e2d090d725f3";
  await createSession(env, owner, owner.deviceToken, sessionId);
  await createSession(env, owner, owner.deviceToken, otherSessionId);
  const lease = await (await request(env, workspacePath(owner, "/lease/claim"), {
    method: "POST", token: owner.deviceToken, body: { sessionId },
  })).json();
  const proof = { leaseId: lease.leaseId, generation: lease.generation, generationToken: lease.generationToken };
  const segmentId = "343fca52-edbd-4225-aed7-fbd3e51ff12f";
  const metadata = { ...proof, id: segmentId, startedAtMs: 1000, endedAtMs: null, status: "recording" };

  const otherSession = await request(env, workspacePath(owner, `/sessions/${otherSessionId}/segments`), {
    method: "POST", token: owner.deviceToken, body: metadata,
  });
  assert.equal(otherSession.status, 409);
  const wrongProof = await request(env, workspacePath(owner, `/sessions/${sessionId}/segments`), {
    method: "POST", token: owner.deviceToken, body: { ...metadata, generationToken: "wrong-proof" },
  });
  assert.equal(wrongProof.status, 409);

  const created = await request(env, workspacePath(owner, `/sessions/${sessionId}/segments`), {
    method: "POST", token: owner.deviceToken, body: metadata,
  });
  assert.equal(created.status, 201);
  const finalized = await request(env, workspacePath(owner, `/sessions/${sessionId}/segments/${segmentId}`), {
    method: "PATCH", token: owner.deviceToken,
    body: { ...proof, id: segmentId, sessionId, deviceId: owner.deviceId, startedAtMs: 1000, endedAtMs: 2000, status: "complete" },
  });
  assert.equal(finalized.status, 200);
  assert.equal((await finalized.json()).status, "complete");

  const changedStart = await request(env, workspacePath(owner, `/sessions/${sessionId}/segments/${segmentId}`), {
    method: "PATCH", token: owner.deviceToken,
    body: { ...proof, startedAtMs: 1001, endedAtMs: 2000, status: "complete" },
  });
  assert.equal(changedStart.status, 409);
  const changedEnd = await request(env, workspacePath(owner, `/sessions/${sessionId}/segments/${segmentId}`), {
    method: "PATCH", token: owner.deviceToken,
    body: { ...proof, endedAtMs: 2001, status: "complete" },
  });
  assert.equal(changedEnd.status, 409);
  const regressed = await request(env, workspacePath(owner, `/sessions/${sessionId}/segments/${segmentId}`), {
    method: "PATCH", token: owner.deviceToken,
    body: { ...proof, endedAtMs: 2000, status: "interrupted" },
  });
  assert.equal(regressed.status, 409);
  const replay = await request(env, workspacePath(owner, `/sessions/${sessionId}/segments`), {
    method: "POST", token: owner.deviceToken, body: metadata,
  });
  assert.equal(replay.status, 200);
  assert.equal((await replay.json()).status, "complete");
  assert.equal((await request(env, workspacePath(owner, "/lease/release"), { method: "POST", token: phone.deviceToken, body: proof })).status, 409);
});

test("HTTP device revocation rejects future auth and request-size bounds return 413", async () => {
  const { env } = fakeCloudflare();
  const owner = await createWorkspace(env);
  const phone = (await joinWorkspace(env, owner.workspaceId, owner.inviteToken)).value;
  const revoke = await request(env, workspacePath(owner, `/devices/${phone.deviceId}`), {
    method: "DELETE", token: owner.deviceToken,
  });
  assert.equal(revoke.status, 200);
  assert.equal((await request(env, workspacePath(owner, "/state"), { token: phone.deviceToken })).status, 401);

  const oversized = await request(env, workspacePath(owner, "/sessions"), {
    method: "POST", token: owner.deviceToken,
    body: { id: "47f13ed1-11e1-4fb7-9c88-158084e94a4a", encryptedPayload: "x".repeat(17_000) },
  });
  assert.equal(oversized.status, 413);
});
