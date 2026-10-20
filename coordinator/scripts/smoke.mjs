import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const base = process.env.HALLE_COORDINATOR_SMOKE_URL || 'http://127.0.0.1:8789';
async function call(path, method = 'GET', token, body) {
  const response = await fetch(base + path, {
    method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(10000),
  });
  return { status: response.status, body: await response.json() };
}
const created = await call('/v1/workspaces', 'POST', null, { deviceName: 'Hall-e synthetic Mac' });
assert.equal(created.status, 201);
const owner = created.body;
const path = `/v1/workspaces/${owner.workspaceId}`;
const joined = await call(path + '/join', 'POST', null, { deviceName: 'Hall-e synthetic Phone', inviteToken: owner.inviteToken });
assert.equal(joined.status, 201);
const phone = joined.body;
assert.equal((await call(path + '/join', 'POST', null, { deviceName: 'Replay', inviteToken: owner.inviteToken })).status, 401);
const sessionId = randomUUID();
const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
const iv = crypto.getRandomValues(new Uint8Array(12));
const plaintext = new TextEncoder().encode(JSON.stringify({ v: 1, title: 'Synthetic meeting', projectName: 'QA', startAtMs: Date.now() }));
const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
  additionalData: new TextEncoder().encode(`session:${sessionId}`) }, key, plaintext));
assert.equal((await call(path + '/sessions', 'POST', owner.deviceToken,
  { id: sessionId, encryptedPayload: Buffer.concat([iv, ciphertext]).toString('base64') })).status, 201);
const results = await Promise.all([owner, phone].map(device =>
  call(path + '/lease/claim', 'POST', device.deviceToken, { sessionId })));
assert.deepEqual(results.map(result => result.status).sort(), [201, 409]);
const winner = results[0].status === 201 ? owner : phone;
const next = winner === owner ? phone : owner;
const lease = results.find(result => result.status === 201).body;
const proof = { leaseId: lease.leaseId, generation: lease.generation, generationToken: lease.generationToken };
const segmentId = randomUUID();
const startedAtMs = Date.now();
assert.equal((await call(path + `/sessions/${sessionId}/segments`, 'POST', winner.deviceToken,
  { ...proof, id: segmentId, startedAtMs, endedAtMs: null, status: 'recording' })).status, 201);
assert.equal((await call(path + '/lease/handoff', 'POST', next.deviceToken, { requestedDeviceId: next.deviceId })).status, 200);
assert.equal((await call(path + '/lease/renew', 'POST', winner.deviceToken, proof)).body.handoffRequested, true);
assert.equal((await call(path + '/lease/claim', 'POST', next.deviceToken, { sessionId })).status, 409);
assert.equal((await call(path + `/sessions/${sessionId}/segments/${segmentId}`, 'PATCH', winner.deviceToken,
  { ...proof, endedAtMs: Date.now(), status: 'complete' })).status, 200);
assert.equal((await call(path + '/lease/release', 'POST', winner.deviceToken, proof)).status, 200);
const transferred = await call(path + '/lease/claim', 'POST', next.deviceToken, { sessionId });
assert.equal(transferred.status, 201);
assert.equal((await call(path + '/lease/renew', 'POST', winner.deviceToken, proof)).status, 409);
const state = (await call(path + '/state', 'GET', owner.deviceToken)).body;
assert.equal(state.segments[0].status, 'complete');
assert.equal(state.activeLease.deviceId, next.deviceId);
// Revoke synthetic credentials after the check. Idle metadata expires automatically.
assert.equal((await call(path + '/lease/release', 'POST', next.deviceToken, transferred.body)).status, 200);
assert.equal((await call(path + '/devices/' + phone.deviceId, 'DELETE', owner.deviceToken)).status, 200);
assert.equal((await call(path + '/leave', 'POST', owner.deviceToken, {})).status, 200);
console.log('PASS real Cloudflare Worker + SQLite Durable Object: pairing, encrypted metadata, concurrent claim, handoff, finalization, fencing. Synthetic credentials revoked.');
