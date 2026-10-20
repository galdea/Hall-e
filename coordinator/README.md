# Hall E shared session coordinator

This is the optional, cross-network pairing and lease service for Hall E shared sessions. It contains no microphone integration. The worker coordinates metadata and opaque client-encrypted project payloads only; all audio and transcript content stay on each device.

Read [PROTOCOL.md](./PROTOCOL.md) before implementing a client. A protocol change must be coordinated with both clients.

## Local checks

From this directory, run `npm test` (Node's built-in test runner; no dependencies are needed). The Worker targets Cloudflare Workers and one SQLite-backed Durable Object per workspace. `wrangler.jsonc` defines the local/deployment shape but does not deploy or create any remote resources.

## Safety behavior

- No endpoint accepts audio, transcript text, calendar metadata, or client encryption keys.
- Each request is bounded to 16 KiB; ciphertext per session is capped at 8 KiB decoded.
- Credentials are generated with Web Crypto; invite/device bearer credentials are hashed before persistence.
- Lease mutations are serialized per workspace and durable before success is returned. Every claim checks expiry; alarms only clean up.
- A handoff request comes from the target device itself. It cannot grant a lease or start recording. The current holder must stop locally and release; the new holder must separately claim and start with local user consent.
- Expired or stale lease generations cannot be renewed or released. Client watchdogs must stop by their local monotonic deadline if renewal does not succeed.
- No wildcard CORS is enabled and auth secrets are never written to logs.
- Public workspace creation and pairing are capped by the configured Workers Rate Limiting binding (20 calls/minute per Cloudflare location, shared by those two routes). Cloudflare documents these counters as permissive/eventually consistent, so this is abuse friction rather than precise accounting.

Before deployment, verify that the rate-limit `namespace_id` in `wrangler.jsonc` is unique within the owner's Cloudflare account; Cloudflare shares counters when IDs collide. Do not deploy without a reviewed privacy notice, production account/billing check, and an explicit owner release decision. The config is not a deployment request.
