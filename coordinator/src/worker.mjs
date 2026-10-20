import { LIMITS, emptyState, claimLease, requestHandoff, renewLease, releaseLease } from "./domain.mjs";

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
});
const fail = (code, status = 400) => json({ error: code }, status);
const parseFailure = (error) => fail(error.message, error.message === "body_too_large" ? 413 : 400);
const bytesToBase64Url = (bytes) => btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
const newSecret = () => bytesToBase64Url(crypto.getRandomValues(new Uint8Array(32)));
const digest = async (value) => bytesToBase64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
const opaqueId = () => crypto.randomUUID();
const asString = (value, max = 256) => typeof value === "string" && value.trim().length > 0 && value.length <= max;
const cleanName = (value) => typeof value === "string" ? value.trim().slice(0, 80) : "";

async function readJson(request) {
  const length = Number(request.headers.get("content-length") || 0);
  if (length > 16 * 1024) throw new Error("body_too_large");
  const reader = request.body?.getReader();
  if (!reader) return {};
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 16 * 1024) {
        await reader.cancel();
        throw new Error("body_too_large");
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  let parsed;
  try { parsed = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Error("invalid_json"); }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid_body");
  return parsed;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: { "allow": "GET, POST, DELETE, OPTIONS" } });
    const path = url.pathname.replace(/\/$/, "");
    if (path === "/v1/workspaces" && request.method === "POST") {
      if (env.PUBLIC_RATE_LIMITER) {
        const { success } = await env.PUBLIC_RATE_LIMITER.limit({ key: "workspace-create" });
        if (!success) return fail("rate_limited", 429);
      }
      let body; try { body = await readJson(request); } catch (e) { return parseFailure(e); }
      const deviceName = cleanName(body.deviceName);
      if (!deviceName) return fail("invalid_device_name");
      const workspaceId = opaqueId();
      const stub = env.WORKSPACES.get(env.WORKSPACES.idFromName(workspaceId));
      return stub.fetch("https://workspace.internal/v1/internal/create", { method: "POST", body: JSON.stringify({ workspaceId, deviceName }) });
    }
    const match = path.match(/^\/v1\/workspaces\/([0-9a-f-]+)(\/.*)?$/i);
    if (!match) return fail("not_found", 404);
    const workspaceId = match[1];
    if (match[2] === "/join" && request.method === "POST" && env.PUBLIC_RATE_LIMITER) {
      const { success } = await env.PUBLIC_RATE_LIMITER.limit({ key: "workspace-join" });
      if (!success) return fail("rate_limited", 429);
    }
    const stub = env.WORKSPACES.get(env.WORKSPACES.idFromName(workspaceId));
    return stub.fetch(new Request(`https://workspace.internal/v1/workspaces/${workspaceId}${match[2] || ""}`, request));
  },
};

export class WorkspaceCoordinator {
  constructor(state) {
    this.state = state;
    this.queue = Promise.resolve();
  }

  async serialized(operation) {
    const run = this.queue.then(operation, operation);
    this.queue = run.catch(() => {});
    return run;
  }

  async load() { return await this.state.storage.get("workspace"); }
  async save(data) {
    if (data && new TextEncoder().encode(JSON.stringify(data)).byteLength + "workspace".length > 1_900_000) throw new Error("workspace_state_limit");
    await this.state.storage.put("workspace", data);
    if (data) await this.state.storage.setAlarm(data.lastActivityAtMs + LIMITS.idleMs);
    else await this.state.storage.deleteAlarm();
  }

  async fetch(request) {
    return this.serialized(async () => {
      try { return await this.handle(request); }
      catch (error) {
        if (error?.message === "workspace_state_limit") return fail("workspace_storage_limit", 507);
        throw error;
      }
    });
  }

  async handle(request) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/$/, "");
    const now = Date.now();
    const internalCreate = path === "/v1/internal/create" && request.method === "POST";
    if (internalCreate) {
      let body; try { body = await readJson(request); } catch (e) { return parseFailure(e); }
      if (await this.load()) return fail("already_exists", 409);
      const workspace = emptyState(body.workspaceId, now);
      const deviceId = opaqueId(), deviceToken = newSecret(), inviteToken = newSecret();
      workspace.ownerDeviceId = deviceId;
      workspace.devices[deviceId] = { id: deviceId, name: cleanName(body.deviceName), createdAtMs: now,
        lastSeenAtMs: now, revokedAtMs: null, tokenHash: await digest(deviceToken), tokenExpiresAtMs: now + LIMITS.tokenMs };
      workspace.invites[await digest(inviteToken)] = { expiresAtMs: now + LIMITS.inviteMs };
      await this.save(workspace);
      return json({ workspaceId: workspace.workspaceId, deviceId, deviceToken, inviteToken,
        inviteExpiresAtMs: now + LIMITS.inviteMs }, 201);
    }

    const wsMatch = path.match(/^\/v1\/workspaces\/([0-9a-f-]+)(\/.*)?$/i);
    if (!wsMatch) return fail("not_found", 404);
    const [, workspaceId, suffix = ""] = wsMatch;
    let workspace = await this.load();
    if (!workspace || workspace.workspaceId !== workspaceId) return fail("not_found", 404);
    if (now - workspace.lastActivityAtMs >= LIMITS.idleMs) {
      await this.state.storage.deleteAll();
      await this.state.storage.deleteAlarm();
      return fail("not_found", 404);
    }

    if (suffix === "/join" && request.method === "POST") {
      let body; try { body = await readJson(request); } catch (e) { return parseFailure(e); }
      const inviteToken = body.inviteToken, deviceName = cleanName(body.deviceName);
      if (!asString(inviteToken, 128) || !deviceName) return fail("invalid_request");
      const inviteHash = await digest(inviteToken), invite = workspace.invites[inviteHash];
      if (!invite || invite.expiresAtMs <= now) return fail("invite_invalid", 401);
      if (Object.keys(workspace.devices).length >= LIMITS.devices) return fail("device_limit", 409);
      delete workspace.invites[inviteHash];
      const deviceId = opaqueId(), deviceToken = newSecret();
      workspace.devices[deviceId] = { id: deviceId, name: deviceName, createdAtMs: now, lastSeenAtMs: now,
        revokedAtMs: null, tokenHash: await digest(deviceToken), tokenExpiresAtMs: now + LIMITS.tokenMs };
      workspace.lastActivityAtMs = now;
      await this.save(workspace);
      return json({ workspaceId, deviceId, deviceToken }, 201);
    }

    const auth = request.headers.get("authorization") || "";
    const tokenMatch = auth.match(/^Bearer ([A-Za-z0-9_-]{40,60})$/);
    if (!tokenMatch) return fail("unauthorized", 401);
    const tokenHash = await digest(tokenMatch[1]);
    const caller = Object.values(workspace.devices).find((d) => d.tokenHash === tokenHash && !d.revokedAtMs && d.tokenExpiresAtMs > now);
    if (!caller) return fail("unauthorized", 401);
    caller.lastSeenAtMs = now;
    workspace.lastActivityAtMs = now;

    if (suffix === "/state" && request.method === "GET") {
      const activeLease = workspace.activeLease ? { ...workspace.activeLease } : null;
      if (activeLease && activeLease.expiresAtMs <= now) { workspace.activeLease = null; }
      if (activeLease && activeLease.deviceId !== caller.id) delete activeLease.generationToken;
      await this.save(workspace);
      return json({ ownerDeviceId: workspace.ownerDeviceId, devices: Object.values(workspace.devices).map(({ id, name, createdAtMs, lastSeenAtMs, revokedAtMs }) => ({ id, name, createdAtMs, lastSeenAtMs, revokedAtMs })),
        sessions: Object.values(workspace.sessions), activeLease: workspace.activeLease && workspace.activeLease.expiresAtMs > now ? activeLease : null,
        segments: Object.values(workspace.segments) });
    }

    if (suffix === "/leave" && request.method === "POST") {
      if (caller.id === workspace.ownerDeviceId && Object.values(workspace.devices).some((d) => d.id !== caller.id && !d.revokedAtMs)) return fail("revoke_devices_first", 409);
      caller.revokedAtMs = now; if (workspace.activeLease?.deviceId === caller.id) { /* expires naturally; do not transfer a running capture */ }
      await this.save(workspace); return json({ revoked: true });
    }
    if (suffix === "/invites" && request.method === "POST") {
      if (caller.id !== workspace.ownerDeviceId) return fail("forbidden", 403);
      for (const hash of Object.keys(workspace.invites)) delete workspace.invites[hash];
      const inviteToken = newSecret(), inviteExpiresAtMs = now + LIMITS.inviteMs;
      workspace.invites[await digest(inviteToken)] = { expiresAtMs: inviteExpiresAtMs };
      await this.save(workspace); return json({ inviteToken, inviteExpiresAtMs });
    }
    const revoke = suffix.match(/^\/devices\/([0-9a-f-]+)$/i);
    if (revoke && request.method === "DELETE") {
      if (caller.id !== workspace.ownerDeviceId) return fail("forbidden", 403);
      const target = workspace.devices[revoke[1]];
      if (!target || target.id === caller.id) return fail("not_found", 404);
      target.revokedAtMs = now; await this.save(workspace); return json({ revoked: true });
    }

    if (suffix === "/sessions" && request.method === "POST") {
      let body; try { body = await readJson(request); } catch (e) { return parseFailure(e); }
      if (!isUuid(body.id) || !isCiphertext(body.encryptedPayload)) return fail("invalid_session");
      const prior = workspace.sessions[body.id];
      if (prior) return prior.encryptedPayload === body.encryptedPayload ? json(prior, 200) : fail("session_conflict", 409);
      if (Object.keys(workspace.sessions).length >= LIMITS.sessions) return fail("session_limit", 409);
      const session = { id: body.id, encryptedPayload: body.encryptedPayload, revision: 1, createdAtMs: now, updatedAtMs: now };
      workspace.sessions[body.id] = session; await this.save(workspace); return json(session, 201);
    }

    const sessionPatch = suffix.match(/^\/sessions\/([0-9a-f-]+)$/i);
    if (sessionPatch && request.method === "PATCH") {
      let body; try { body = await readJson(request); } catch (e) { return parseFailure(e); }
      const session = workspace.sessions[sessionPatch[1]];
      if (!session) return fail("not_found", 404);
      if (!isCiphertext(body.encryptedPayload) || !Number.isSafeInteger(body.expectedRevision)) return fail("invalid_session");
      if (session.revision !== body.expectedRevision) return fail("revision_conflict", 409);
      session.encryptedPayload = body.encryptedPayload;
      session.revision += 1; session.updatedAtMs = now;
      await this.save(workspace); return json(session);
    }

    const claim = suffix === "/lease/claim" && request.method === "POST";
    const renew = suffix === "/lease/renew" && request.method === "POST";
    const release = suffix === "/lease/release" && request.method === "POST";
    const handoff = suffix === "/lease/handoff" && request.method === "POST";
    if (claim || renew || release || handoff) {
      let body; try { body = await readJson(request); } catch (e) { return parseFailure(e); }
      let result;
      if (claim) result = claimLease(workspace, { sessionId: body.sessionId, deviceId: caller.id, now, leaseId: opaqueId(), generationToken: newSecret() });
      else if (handoff) result = requestHandoff(workspace, { requestedDeviceId: body.requestedDeviceId, callerDeviceId: caller.id, now });
      else {
        if (!asString(body.leaseId) || !Number.isSafeInteger(body.generation) || !asString(body.generationToken)) return fail("invalid_lease_credentials");
        const params = { deviceId: caller.id, leaseId: body.leaseId, generation: body.generation, generationToken: body.generationToken, now };
        result = renew ? renewLease(workspace, params) : releaseLease(workspace, params);
      }
      if (result.error) return fail(result.error, result.error === "lease_held" || result.error === "lease_stale" ? 409 : 404);
      await this.save(workspace);
      if (result.lease) return json(result.lease, 201);
      return json(result);
    }

    const seg = suffix.match(/^\/sessions\/([0-9a-f-]+)\/segments(?:\/([0-9a-f-]+))?$/i);
    if (seg && ((request.method === "POST" && !seg[2]) || (request.method === "PATCH" && seg[2]))) {
      let body; try { body = await readJson(request); } catch (e) { return parseFailure(e); }
      const lease = workspace.activeLease;
      if (!lease || lease.expiresAtMs <= now || lease.sessionId !== seg[1] || lease.deviceId !== caller.id ||
          body.leaseId !== lease.leaseId || body.generation !== lease.generation || body.generationToken !== lease.generationToken) return fail("lease_stale", 409);
      if (!workspace.sessions[seg[1]]) return fail("not_found", 404);
      if (request.method === "POST") {
        if (!isUuid(body.id) || !Number.isSafeInteger(body.startedAtMs) ||
            !(body.endedAtMs === null || Number.isSafeInteger(body.endedAtMs) && body.endedAtMs >= body.startedAtMs) ||
            !["recording", "complete", "interrupted"].includes(body.status)) return fail("invalid_segment");
        const record = { id: body.id, sessionId: seg[1], deviceId: caller.id, startedAtMs: body.startedAtMs, endedAtMs: body.endedAtMs, status: body.status };
        const old = workspace.segments[body.id];
        if (old) {
          const sameCreation = old.sessionId === record.sessionId && old.deviceId === record.deviceId && old.startedAtMs === record.startedAtMs;
          const exactReplay = JSON.stringify(old) === JSON.stringify(record);
          const replayAfterFinalize = record.status === "recording" && record.endedAtMs === null && sameCreation && old.status !== "recording";
          return exactReplay || replayAfterFinalize ? json(old) : fail("segment_conflict", 409);
        }
        if (Object.keys(workspace.segments).length >= LIMITS.segments) return fail("segment_limit", 409);
        workspace.segments[body.id] = record; await this.save(workspace); return json(record, 201);
      }
      const old = workspace.segments[seg[2]];
      if (!old || old.sessionId !== seg[1] || old.deviceId !== caller.id || !Number.isSafeInteger(body.endedAtMs) || body.endedAtMs < old.startedAtMs || !["complete", "interrupted"].includes(body.status)) return fail("invalid_segment");
      if ((body.id !== undefined && body.id !== seg[2]) || (body.sessionId !== undefined && body.sessionId !== old.sessionId) ||
          (body.deviceId !== undefined && body.deviceId !== old.deviceId) ||
          (body.startedAtMs !== undefined && body.startedAtMs !== old.startedAtMs)) return fail("segment_conflict", 409);
      if (old.endedAtMs !== null && (old.endedAtMs !== body.endedAtMs || old.status !== body.status)) return fail("segment_conflict", 409);
      if (old.status !== "recording" && old.status !== body.status) return fail("segment_conflict", 409);
      old.endedAtMs = body.endedAtMs; old.status = body.status;
      await this.save(workspace); return json(old);
    }
    return fail("not_found", 404);
  }

  async alarm() {
    return this.serialized(async () => {
      const workspace = await this.load();
      if (!workspace) return;
      const now = Date.now();
      if (now - workspace.lastActivityAtMs >= LIMITS.idleMs) { await this.state.storage.deleteAll(); await this.state.storage.deleteAlarm(); return; }
      for (const [hash, invite] of Object.entries(workspace.invites)) if (invite.expiresAtMs <= now) delete workspace.invites[hash];
      if (workspace.activeLease?.expiresAtMs <= now) workspace.activeLease = null;
      await this.save(workspace);
    });
  }
}

function isUuid(value) { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value); }
function isCiphertext(value) {
  if (typeof value !== "string" || value.length > 12_000 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) return false;
  try { return atob(value).length >= 28 && atob(value).length <= 8 * 1024 && btoa(atob(value)) === value; } catch { return false; }
}
