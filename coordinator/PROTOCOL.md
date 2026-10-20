# Shared session coordinator protocol v1

This protocol coordinates already-paired Hall E devices across networks. The coordinator never receives audio, calendar data, event identifiers, titles, attendee names, join links, or transcript text. Meeting payloads are encrypted by clients and stored as opaque base64 ciphertext. It is not an audio relay and it never starts a recorder remotely.

## Limits and credentials

- One SQLite-backed Durable Object represents one workspace and is the authority for its devices, sessions, segments, and its single active recording lease.
- A workspace has at most 4 device records total (including revoked devices, which retain their slot) and 100 sessions. A workspace has at most 500 segment metadata records across all sessions. Request bodies are limited to 16 KiB. Audio bytes are never accepted.
- Workspace IDs, device IDs, session IDs, invite tokens, device tokens, lease IDs, and lease generation tokens are cryptographically random. Invite and device tokens contain 32 random bytes, are returned only once, and are stored server-side only as SHA-256 hashes. Device tokens expire no later than 90 days after issuance.
- Pairing invitations are single use and expire 10 minutes after creation. A creator's response includes a QR-ready invite token; QR encoding is a client responsibility.
- All endpoints use HTTPS. There is no wildcard CORS. Authorization headers and token values must never be logged.

## HTTP API

All paths are rooted at `/v1`. JSON request and response bodies use UTF-8. Errors have `{ "error": "stable_code" }` and an appropriate 4xx/5xx status. Authenticated routes use `Authorization: Bearer <deviceToken>`; the workspace is inferred from the route and token ownership is checked on every request.

### Create and join

`POST /workspaces` (no auth), `{ "deviceName": string }` creates a workspace and its first owner device. Returns `201`:

```json
{
  "workspaceId": "opaque-id",
  "deviceId": "opaque-id",
  "deviceToken": "secret-returned-once",
  "inviteToken": "secret-returned-once",
  "inviteExpiresAtMs": 0
}
```

`POST /workspaces/:workspaceId/join` (no auth), `{ "inviteToken": string, "deviceName": string }` consumes the invite once and returns `201` with `{ "workspaceId", "deviceId", "deviceToken" }`. Replays and expired invites fail. Device names are display-only, trimmed, and capped at 80 characters.

`POST /workspaces/:workspaceId/invites` (owner auth), `{}` creates a new single-use invite expiring in 10 minutes and invalidates all previous invites. Returns `{ "inviteToken", "inviteExpiresAtMs" }`.

### Workspace state and devices

`GET /workspaces/:workspaceId/state` (auth) returns `{ "ownerDeviceId", "devices": [{"id", "name", "createdAtMs", "lastSeenAtMs", "revokedAtMs"}], "sessions": [{"id", "encryptedPayload", "revision", "createdAtMs", "updatedAtMs"}], "activeLease": null | {"sessionId", "deviceId", "leaseId", "generation", "generationToken", "expiresAtMs", "handoffRequestedDeviceId"}, "segments": [{"id", "sessionId", "deviceId", "startedAtMs", "endedAtMs", "status"}] }`. Only the lease holder receives its generation token; other devices see the lease fields with `generationToken` omitted. The response contains no private client-side decryption key.

`DELETE /workspaces/:workspaceId/devices/:deviceId` (owner device only) revokes another device immediately. `POST /workspaces/:workspaceId/leave` revokes the caller's own credential. The owner cannot leave while other active devices remain; it must revoke them first. A revoked device cannot call any authenticated endpoint, and revoking the current lease holder makes the lease unclaimable only after the old lease is released or expires.

### Sessions and segment metadata

`POST /workspaces/:workspaceId/sessions` (auth), `{ "id": UUID, "encryptedPayload": string }` creates a session record at revision 1 and returns `201` with the session. `encryptedPayload` is canonical base64 of client-side AES-GCM ciphertext (nonce and ciphertext/tag packaged by the client); the service treats it as opaque and validates a maximum decoded size of 8 KiB. The session ID is a client-generated UUID so clients can safely retry creation. Reuse with the same payload is idempotent; reuse with different payload fails `409`.

`PATCH /workspaces/:workspaceId/sessions/:sessionId` (auth), `{ "encryptedPayload": string, "expectedRevision": integer }` updates client-encrypted project details using optimistic concurrency. On success, increments revision and returns the session. Revision mismatch returns `409 revision_conflict`; session ID and creation time never change.

`POST /workspaces/:workspaceId/sessions/:sessionId/segments` (lease holder only) accepts `{ "id": UUID, "startedAtMs": integer, "endedAtMs": integer | null, "status": "recording" | "complete" | "interrupted", "leaseId": string, "generation": integer, "generationToken": string }`. This stores metadata only. Segment writes require current lease credentials below. Invalid timestamps, a segment from another device, or more than 500 records fail. Segment metadata may be created as `recording`, then finalized as `complete` or `interrupted` by a `PATCH` with the same segment ID and lease credentials. The update must preserve session ID, device ID, and start time; an ended timestamp, once set, cannot change; terminal status cannot regress. Exact replays are idempotent.

### Exclusive recording lease

There is exactly one active lease per workspace, shared across its sessions. Lease TTL is 20 seconds. Clients use a conservative local deadline of 15 seconds from the monotonic time immediately before a renew request; they stop and finalize local capture by that deadline unless a successful response arrives. Wall-clock time is for displaying server expiry only. Every claim checks expiry itself; cleanup alarms are not a source of lease authority.

`POST /workspaces/:workspaceId/lease/claim`, auth, `{ "sessionId": UUID }` claims only when no unexpired lease exists. A successful `201` returns `{ "sessionId", "deviceId", "leaseId", "generation", "generationToken", "expiresAtMs" }`. Claiming while another unexpired lease exists returns `409 lease_held`. Claim after expiry increments generation and creates a new lease ID/token.

`POST /workspaces/:workspaceId/lease/renew`, auth, `{ "leaseId": string, "generation": integer, "generationToken": string }` extends a matching, unexpired lease to 20 seconds from server receipt. Returns `{ "expiresAtMs", "handoffRequested": boolean }`. If handoff was requested, renew returns `handoffRequested: true` and MUST NOT extend expiry. Expired, revoked, or stale generation credentials fail `409 lease_stale` and never revive a lease.

`POST /workspaces/:workspaceId/lease/handoff`, auth, `{ "requestedDeviceId": string }` asks the current holder to stop. `requestedDeviceId` must equal the caller's device ID, proving the target user's local action. This only changes the visible request state; it neither grants a lease nor starts a recorder. The holder stops and finalizes locally, then releases. A target may claim only after release or expiry.

`POST /workspaces/:workspaceId/lease/release`, auth, `{ "leaseId": string, "generation": integer, "generationToken": string }` releases only the matching current generation and returns `{ "released": true }`. Stale releases fail and cannot affect a newer lease. A release is sent only after local capture has stopped and its local segment finalization attempt has completed. On failure, clients stop capture and rely on expiry; they must not assume ownership.

## Storage, cleanup, and client safety

The object serializes lease mutation and persists state durably before returning success. It stores device-token hashes, invite-token hashes, opaque encrypted payloads, device/session identifiers, timestamps, segment metadata, and lease fields only. Do not store encryption keys, plaintext event metadata, transcript text, or audio. Keep activity within bounded limits and expire an idle workspace after 7 days; credential lifetime is at most 90 days. Alarms may clean expired invitations and old workspaces, but requests must enforce expiry synchronously.

Clients poll state every 2 seconds while a handoff is active and every 10 seconds while merely viewing. Polling is advisory; the lease API remains authoritative. Network failure never grants or renews ownership. A remote handoff request is only a prompt to a local user; each device requires its own explicit local user action and OS permission before recording. No push, poll result, or coordinator response can invoke microphone APIs or start capture.
