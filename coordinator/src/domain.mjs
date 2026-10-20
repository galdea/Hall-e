export const LIMITS = Object.freeze({
  devices: 4,
  sessions: 100,
  segments: 500,
  inviteMs: 10 * 60_000,
  tokenMs: 90 * 24 * 60 * 60_000,
  leaseMs: 20_000,
  idleMs: 7 * 24 * 60 * 60_000,
});

export const emptyState = (workspaceId, now) => ({
  workspaceId,
  createdAtMs: now,
  lastActivityAtMs: now,
  ownerDeviceId: null,
  devices: {},
  invites: {},
  sessions: {},
  segments: {},
  activeLease: null,
  generation: 0,
});

export function claimLease(state, { sessionId, deviceId, now, leaseId, generationToken }) {
  const session = state.sessions[sessionId];
  const device = state.devices[deviceId];
  if (!session || !device || device.revokedAtMs !== null) return { error: "not_found" };
  const current = state.activeLease;
  if (current && current.expiresAtMs > now) return { error: "lease_held" };
  const generation = state.generation + 1;
  const lease = { sessionId, deviceId, leaseId, generation, generationToken, expiresAtMs: now + LIMITS.leaseMs, handoffRequestedDeviceId: null };
  state.generation = generation;
  state.activeLease = lease;
  state.lastActivityAtMs = now;
  return { lease };
}

export function requestHandoff(state, { requestedDeviceId, callerDeviceId, now }) {
  const target = state.devices[requestedDeviceId];
  const lease = state.activeLease;
  if (!target || target.revokedAtMs !== null) return { error: "not_found" };
  if (!lease || lease.expiresAtMs <= now) return { error: "lease_stale" };
  if (requestedDeviceId !== callerDeviceId) return { error: "target_must_be_caller" };
  if (lease.deviceId === callerDeviceId) return { error: "cannot_handoff_to_self" };
  lease.handoffRequestedDeviceId = requestedDeviceId;
  state.lastActivityAtMs = now;
  return { handoffRequested: true, holderDeviceId: lease.deviceId };
}

export function renewLease(state, { deviceId, leaseId, generation, generationToken, now }) {
  const lease = state.activeLease;
  if (!lease || lease.expiresAtMs <= now || lease.deviceId !== deviceId || lease.leaseId !== leaseId ||
      lease.generation !== generation || lease.generationToken !== generationToken) return { error: "lease_stale" };
  if (lease.handoffRequestedDeviceId) return { expiresAtMs: lease.expiresAtMs, handoffRequested: true };
  lease.expiresAtMs = now + LIMITS.leaseMs;
  state.lastActivityAtMs = now;
  return { expiresAtMs: lease.expiresAtMs, handoffRequested: false };
}

export function releaseLease(state, { deviceId, leaseId, generation, generationToken, now }) {
  const lease = state.activeLease;
  if (!lease || lease.expiresAtMs <= now || lease.deviceId !== deviceId || lease.leaseId !== leaseId ||
      lease.generation !== generation || lease.generationToken !== generationToken) return { error: "lease_stale" };
  state.activeLease = null;
  state.lastActivityAtMs = now;
  return { released: true };
}
