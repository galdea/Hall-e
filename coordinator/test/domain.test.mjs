import test from "node:test";
import assert from "node:assert/strict";
import { emptyState, claimLease, requestHandoff, renewLease, releaseLease, LIMITS } from "../src/domain.mjs";

const setup = () => {
  const state = emptyState("workspace", 0);
  state.devices.a = { id: "a", name: "Mac", revokedAtMs: null };
  state.devices.b = { id: "b", name: "Phone", revokedAtMs: null };
  state.sessions.s = { id: "s" };
  return state;
};
const claim = (state, deviceId, now) => claimLease(state, { sessionId: "s", deviceId, now, leaseId: `lease-${deviceId}`, generationToken: `secret-${deviceId}` });
const creds = { deviceId: "a", leaseId: "lease-a", generation: 1, generationToken: "secret-a" };

test("one workspace lease excludes a concurrent second device", () => {
  const state = setup();
  assert.equal(claim(state, "a", 100).lease.expiresAtMs, 100 + LIMITS.leaseMs);
  assert.equal(claim(state, "b", 101).error, "lease_held");
  assert.equal(state.activeLease.deviceId, "a");
});

test("handoff can only be requested by its target and prevents lease extension", () => {
  const state = setup(); claim(state, "a", 100);
  assert.equal(requestHandoff(state, { requestedDeviceId: "a", callerDeviceId: "b", now: 200 }).error, "target_must_be_caller");
  assert.equal(requestHandoff(state, { requestedDeviceId: "b", callerDeviceId: "b", now: 200 }).handoffRequested, true);
  const before = state.activeLease.expiresAtMs;
  const renewed = renewLease(state, { ...creds, now: 300 });
  assert.equal(renewed.handoffRequested, true);
  assert.equal(renewed.expiresAtMs, before);
});

test("expired lease cannot renew or release; next claim advances generation", () => {
  const state = setup(); claim(state, "a", 100);
  assert.equal(renewLease(state, { ...creds, now: 100 + LIMITS.leaseMs }).error, "lease_stale");
  assert.equal(releaseLease(state, { ...creds, now: 100 + LIMITS.leaseMs }).error, "lease_stale");
  const next = claim(state, "b", 100 + LIMITS.leaseMs);
  assert.equal(next.lease.generation, 2);
  assert.equal(releaseLease(state, { ...creds, now: 100 + LIMITS.leaseMs + 1 }).error, "lease_stale");
  assert.equal(state.activeLease.deviceId, "b");
});

test("release allows a target claim with the next generation", () => {
  const state = setup(); claim(state, "a", 100);
  assert.deepEqual(releaseLease(state, { ...creds, now: 101 }), { released: true });
  assert.equal(claim(state, "b", 102).lease.generation, 2);
});
