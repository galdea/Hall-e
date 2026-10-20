# Hall E shared session coordinator

This is the optional, cross-network pairing, lease, and encrypted phone-to-Mac audio relay service for Hall E. It contains no microphone integration and cannot decrypt client payloads. Shared project/session data is client-encrypted; the registered-device audio flow relays encrypted chunks and a signed durable-transcript receipt, without exposing plaintext audio or transcript content to the coordinator.

Read [PROTOCOL.md](./PROTOCOL.md) before implementing a client. A protocol change must be coordinated with both clients.

## Local checks

From this directory, run `npm test` (Node's built-in test runner; no dependencies are needed). The Worker targets Cloudflare Workers and one SQLite-backed Durable Object per workspace. `wrangler.jsonc` defines the local/deployment shape but does not deploy or create any remote resources.

## Safety behavior

- Endpoints accept bounded encrypted audio chunks and opaque receipt/transfer metadata for the registered Mac recipient. No endpoint accepts plaintext audio, transcript text, calendar contents, or client encryption keys.
- Request and chunk bounds are enforced by the transfer routes; encrypted chunks are relayed to the paired recipient and are not interpreted by the Worker. Session ciphertext remains capped at 8 KiB decoded.
- Credentials are generated with Web Crypto; invite/device bearer credentials are hashed before persistence.
- Lease mutations are serialized per workspace and durable before success is returned. Every claim checks expiry; alarms only clean up.
- A handoff request comes from the target device itself. It cannot grant a lease or start recording. The current holder must stop locally and release; the new holder must separately claim and start with local user consent.
- Expired or stale lease generations cannot be renewed or released. Client watchdogs must stop by their local monotonic deadline if renewal does not succeed.
- No wildcard CORS is enabled and auth secrets are never written to logs.
- The phone queues eligible post-stop transfers through Android's OS job scheduler. The Mac writes the transcript durably and purges its audio before returning the signed receipt; after receipt validation, the phone persists the receipt and purges its audio before acknowledging relay completion. Historical phone recordings without explicit transfer enrollment are not automatically purged.
- Public workspace creation and pairing are capped by the configured Workers Rate Limiting binding (20 calls/minute per Cloudflare location, shared by those two routes). Cloudflare documents these counters as permissive/eventually consistent, so this is abuse friction rather than precise accounting.

Before deployment, verify that the rate-limit `namespace_id` in `wrangler.jsonc` is unique within the owner's Cloudflare account; Cloudflare shares counters when IDs collide. This candidate's implementation and local build instructions do not authorize or claim a production release. Preserve the production release gate: deployment requires a reviewed privacy notice, production account/billing check, and an explicit owner release decision. The config is not a deployment request.
