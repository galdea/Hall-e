import { createHash } from "node:crypto";

const MiB = 1024 * 1024;
const PART_SIZE = 8 * MiB;
const MAX_AUDIO = 256 * MiB;
const INLINE_TRANSCRIPT = 512 * 1024;
const STORED_TRANSCRIPT = 8 * MiB;
const MINUTE = 60_000;
const STALE_UPLOAD = 7 * 24 * 60 * MINUTE;
const CLAIM_TTL = 15 * MINUTE;
const liveMeeting = `EXISTS (SELECT 1 FROM account_meetings m
  WHERE m.user_id = account_recordings.user_id AND m.id = account_recordings.meeting_id AND m.deleted = 0)`;

function json(value, status = 200) {
  return Response.json(value, { status, headers: { "Cache-Control": "private, no-store" } });
}
const error = (code, status) => json({ error: code }, status);
const key = (blob, index) => `recordings/${blob}/${index}`;
const transcriptKey = (blob) => `recordings/${blob}/transcript`;
const parts = (row) => Math.ceil(row.size / PART_SIZE);
const partBytes = (row, index) => Math.min(PART_SIZE, row.size - index * PART_SIZE);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
// Every R2 object under a recording's prefix: its audio parts and a separately stored transcript.
const objectKeys = (row) => [...Array.from({ length: parts(row) }, (_, i) => key(row.blob_id, i)), transcriptKey(row.blob_id)];
const withStored = `account_recordings LEFT JOIN account_recording_transcripts stored USING (blob_id)`;

function view(row) {
  const result = {
    id: row.id,
    meetingId: row.meeting_id,
    status: row.status,
    detail: row.detail,
    transcript: row.transcript,
    partSize: PART_SIZE,
    provider: row.provider,
    region: row.region || null,
  };
  // Older clients keep the same shape; text kept in R2 is read from the transcript endpoint.
  if (row.stored_bytes != null) result.transcriptStoredSeparately = true;
  return result;
}

function lazyView(row) {
  const { transcriptStoredSeparately, ...result } = view({ ...row, transcript: null });
  const bytes = row.stored_bytes ?? row.text_bytes;
  return { ...result, transcriptAvailable: bytes != null, transcriptBytes: bytes ?? null };
}

// Lazy listings never read transcript text from D1, only its size.
export async function recordingsFor(env, userId, { lazy = false } = {}) {
  const text = lazy ? "length(CAST(transcript AS BLOB)) AS text_bytes" : "transcript";
  const { results } = await env.ACCOUNT_DB.prepare(
    `SELECT id, meeting_id, status, detail, ${text}, provider, region, stored.bytes AS stored_bytes
    FROM ${withStored} WHERE user_id=? AND status!='disposing' AND ${liveMeeting} ORDER BY consent_at, id`,
  )
    .bind(userId)
    .all();
  return results.map(lazy ? lazyView : view);
}

async function find(db, ids) {
  return db
    .prepare(
      `SELECT account_recordings.*, stored.bytes AS stored_bytes FROM ${withStored}
    WHERE user_id=? AND meeting_id=? AND id=? AND status!='disposing' AND ${liveMeeting}`,
    )
    .bind(...ids)
    .first();
}

// The owner's transcript text, wherever it is kept; null when the recording has none.
export async function recordingTranscript(env, ids) {
  const row = await find(env.ACCOUNT_DB, ids);
  if (!row || row.stored_bytes == null) return row?.transcript ?? null;
  const object = await env.ACCOUNT_AUDIO.get(transcriptKey(row.blob_id));
  if (!object) throw new Error("missing_transcript");
  return object.text();
}

async function isDisposing(db, ids) {
  return Boolean(
    await db
      .prepare(
        `SELECT 1 FROM account_recordings WHERE user_id=? AND meeting_id=? AND id=?
      AND status='disposing' AND ${liveMeeting}`,
      )
      .bind(...ids)
      .first(),
  );
}

// Keep input bounded even when the sender omits or understates Content-Length.
async function bytesAtMost(body, limit) {
  if (!body) return new Uint8Array(0);
  const reader = body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new RangeError("body_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (chunks.length === 1) return chunks[0];
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

async function initialize(request, db, ids) {
  let spec;
  try {
    spec = JSON.parse(new TextDecoder().decode(await bytesAtMost(request.body, 2048)));
  } catch {
    return error("invalid_manifest", 400);
  }
  const region = spec?.region ?? "";
  if (
    !spec ||
    spec.consent !== true ||
    !Number.isSafeInteger(spec.size) ||
    spec.size < 1 ||
    spec.size > MAX_AUDIO ||
    typeof spec.sha256 !== "string" ||
    !/^[a-f0-9]{64}$/.test(spec.sha256) ||
    !["audio/mp4", "audio/wav"].includes(spec.mimeType) ||
    !(
      (spec.provider === "deepgram" && region === "") ||
      (spec.provider === "speechmatics" && ["eu1", "us1"].includes(region))
    )
  ) {
    return error("invalid_manifest", 400);
  }
  const now = Date.now();
  await db
    .prepare(
      `INSERT INTO account_recordings(user_id,meeting_id,id,blob_id,size,sha256,mime_type,provider,region,consent_at,status,updated_at)
    SELECT ?,?,?,?,?,?,?,?,?,?,'uploading',? WHERE EXISTS
    (SELECT 1 FROM account_meetings WHERE user_id=? AND id=? AND deleted=0)
    ON CONFLICT(user_id,meeting_id,id) DO NOTHING`,
    )
    .bind(
      ...ids,
      crypto.randomUUID(),
      spec.size,
      spec.sha256,
      spec.mimeType,
      spec.provider,
      region,
      now,
      now,
      ids[0],
      ids[1],
    )
    .run();
  const row = await find(db, ids);
  if (!row) return (await isDisposing(db, ids)) ? error("upload_disposing", 503) : error("not_found", 404);
  if (
    row.size !== spec.size ||
    row.sha256 !== spec.sha256 ||
    row.mime_type !== spec.mimeType ||
    row.provider !== spec.provider ||
    row.region !== region
  )
    return error("manifest_conflict", 409);
  return json(view(row));
}

async function putPart(request, env, row, index) {
  const count = parts(row);
  if (!Number.isSafeInteger(index) || index < 0 || index >= count) return error("unknown_part", 400);
  const expected = partBytes(row, index);
  const length = request.headers.get("Content-Length");
  if (length !== null && Number(length) !== expected) return error("part_length", 400);
  let bytes;
  try {
    bytes = await bytesAtMost(request.body, expected);
  } catch (e) {
    if (e instanceof RangeError) return error("part_length", 400);
    throw e;
  }
  if (bytes.byteLength !== expected) return error("part_length", 400);
  const digest = hash(bytes);
  const db = env.ACCOUNT_DB;
  // Reserve the immutable digest before R2 IO; a crash between operations is repairable by replay.
  await db
    .prepare(
      `INSERT INTO account_recording_parts(blob_id,part_index,digest)
    SELECT blob_id,?,? FROM account_recordings WHERE blob_id=? AND status='uploading' AND ${liveMeeting}
    ON CONFLICT(blob_id,part_index) DO NOTHING`,
    )
    .bind(index, digest, row.blob_id)
    .run();
  const saved = await db
    .prepare("SELECT * FROM account_recording_parts WHERE blob_id=? AND part_index=?")
    .bind(row.blob_id, index)
    .first();
  if (!saved || saved.digest !== digest) return error("part_conflict", 409);
  if (!saved.stored) {
    const objectKey = key(row.blob_id, index);
    await env.ACCOUNT_AUDIO.put(objectKey, bytes);
    const [updated] = await db.batch([
      db
        .prepare(
          `UPDATE account_recording_parts SET stored=1 WHERE blob_id=? AND part_index=?
        AND EXISTS (SELECT 1 FROM account_recordings WHERE blob_id=? AND status!='disposing' AND ${liveMeeting})`,
        )
        .bind(row.blob_id, index, row.blob_id),
      db
        .prepare("UPDATE account_recordings SET updated_at=? WHERE blob_id=? AND status='uploading'")
        .bind(Date.now(), row.blob_id),
    ]);
    if (!updated.meta.changes) {
      await env.ACCOUNT_AUDIO.delete(objectKey);
      return error("not_found", 404);
    }
  }
  return json({ index });
}

async function* audioParts(bucket, row) {
  for (let i = 0; i < parts(row); i++) {
    const object = await bucket.get(key(row.blob_id, i));
    if (!object || object.size !== partBytes(row, i)) throw new Error("missing_audio");
    for await (const bytes of object.body) yield bytes;
  }
}

// D1 can record a part that R2 no longer holds. Ask the sender for those parts again; their
// reserved digests stay, so only the same bytes are accepted. Present objects are never deleted.
async function lostParts(env, row) {
  const lost = [];
  for (let i = 0; i < parts(row); i++) {
    const object = await env.ACCOUNT_AUDIO.head(key(row.blob_id, i));
    if (object?.size !== partBytes(row, i)) lost.push(i);
  }
  if (!lost.length) return false;
  const db = env.ACCOUNT_DB;
  await db.batch([
    db
      .prepare(
        `UPDATE account_recording_parts SET stored=0 WHERE blob_id=? AND part_index IN (SELECT value FROM json_each(?))
      AND EXISTS (SELECT 1 FROM account_recordings WHERE blob_id=? AND status='uploading')`,
      )
      .bind(row.blob_id, JSON.stringify(lost), row.blob_id),
    db
      .prepare("UPDATE account_recordings SET updated_at=? WHERE blob_id=? AND status='uploading'")
      .bind(Date.now(), row.blob_id),
  ]);
  return true;
}

async function complete(env, row, ids) {
  if (row.status !== "uploading") return json(view(row));
  const db = env.ACCOUNT_DB;
  const saved = await db
    .prepare("SELECT COUNT(*) AS n FROM account_recording_parts WHERE blob_id=? AND stored=1")
    .bind(row.blob_id)
    .first();
  if (saved.n !== parts(row) || (await lostParts(env, row))) return error("missing_parts", 409);
  const digest = createHash("sha256");
  for await (const bytes of audioParts(env.ACCOUNT_AUDIO, row)) digest.update(bytes);
  if (digest.digest("hex") !== row.sha256) return error("digest_mismatch", 409);
  // The verified manifest and parts are immutable. This row is also the persistent, unique job.
  await db
    .prepare(
      `UPDATE account_recordings SET status='queued',updated_at=?
    WHERE blob_id=? AND status='uploading' AND ${liveMeeting}`,
    )
    .bind(Date.now(), row.blob_id)
    .run();
  const current = await find(db, ids);
  return current ? json(view(current)) : error("not_found", 404);
}

const discarded = () => new Response(null, { status: 204, headers: { "Cache-Control": "private, no-store" } });

// Only the owner may end a recording the service stopped on; nothing else disposes of a paid result.
async function discard(db, row) {
  const ended = await db
    .prepare(
      `UPDATE account_recordings SET status='disposing',transcript=NULL,claim=NULL,updated_at=?
    WHERE blob_id=? AND status IN ('review','failed') AND ${liveMeeting} RETURNING blob_id`,
    )
    .bind(Date.now(), row.blob_id)
    .first();
  return ended ? discarded() : error("recording_active", 409);
}

export async function handleRecording(request, env, userId, meetingId, recordingId, tail) {
  const ids = [userId, meetingId, recordingId];
  if (!tail && request.method === "PUT") return initialize(request, env.ACCOUNT_DB, ids);
  const row = await find(env.ACCOUNT_DB, ids);
  const part = /^parts\/(0|[1-9]\d{0,3})$/.exec(tail);
  if (!row) {
    if (!tail && request.method === "DELETE" && (await isDisposing(env.ACCOUNT_DB, ids))) return discarded();
    const write = (part && request.method === "PUT") || (tail === "complete" && request.method === "POST");
    return write && (await isDisposing(env.ACCOUNT_DB, ids)) ? error("upload_disposing", 503) : error("not_found", 404);
  }
  if (!tail && request.method === "GET") return json(view(row));
  if (!tail && request.method === "DELETE") return discard(env.ACCOUNT_DB, row);
  if (part && request.method === "PUT") return putPart(request, env, row, Number(part[1]));
  if (tail === "complete" && request.method === "POST") return complete(env, row, ids);
  return error("not_found", 404);
}

// Send a bounded stream with a known length, including the Speechmatics multipart envelope.
function streamBody(iterable, length) {
  const iterator = iterable[Symbol.asyncIterator]();
  const body = new ReadableStream({
    async pull(controller) {
      const { done, value } = await iterator.next();
      if (done) controller.close();
      else controller.enqueue(value);
    },
    cancel() {
      return iterator.return?.();
    },
  });
  if (typeof FixedLengthStream === "undefined") return body;
  const fixed = new FixedLengthStream(length);
  // A source error also errors the readable end consumed by fetch.
  body.pipeTo(fixed.writable).catch(() => {});
  return fixed.readable;
}

function ready(env, row) {
  if (env.ACCOUNT_ENABLE_TRANSCRIPTION !== "yes") return false;
  if (row.provider === "deepgram") return Boolean(env.ACCOUNT_DEEPGRAM_KEY);
  return (
    Boolean(env.ACCOUNT_SPEECHMATICS_KEY) &&
    env.ACCOUNT_SPEECHMATICS_REGION === row.region &&
    env.ACCOUNT_SPEECHMATICS_TRAINING_OPT_OUT === "confirmed"
  );
}

async function jsonBody(response, maxSize) {
  return JSON.parse(new TextDecoder().decode(await bytesAtMost(response.body, maxSize)));
}

function resultText(text) {
  // Keep one D1 row bounded and move longer text to R2; report a review state instead of publishing a truncated result.
  const bytes = typeof text === "string" ? new TextEncoder().encode(text) : null;
  if (!bytes || bytes.length > STORED_TRANSCRIPT) {
    return { status: "review", detail: "transcript_unreadable_or_oversize" };
  }
  return bytes.length > INLINE_TRANSCRIPT ? { status: "completed", stored: bytes } : { status: "completed", transcript: text };
}

function timeLabel(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "";
  const ms = Math.round(seconds * 1000);
  const hours = Math.floor(ms / 3_600_000);
  const minutes = String(Math.floor(ms / 60_000) % 60).padStart(2, "0");
  const remainder = String(Math.floor(ms / 1000) % 60).padStart(2, "0");
  return `${hours}:${minutes}:${remainder}.${String(ms % 1000).padStart(3, "0")}`;
}

function segmentLine(text, speaker, start, end) {
  const range = [timeLabel(start), timeLabel(end)].filter(Boolean).join("–");
  const label = [range, speaker].filter(Boolean).join(" · ");
  return label ? `[${label}] ${text}` : text;
}

// Publish readable turns while retaining the provider's actual time boundaries and speaker IDs.
function wordTurns(tokens) {
  const lines = [];
  let speaker,
    start,
    end,
    words = "";
  function flush() {
    if (words) lines.push(segmentLine(words, speaker, start, end));
    words = "";
    start = undefined;
    end = undefined;
  }
  for (const token of tokens) {
    if (typeof token.text !== "string") throw new Error("invalid_word");
    if (!token.punctuation) {
      if (speaker !== token.speaker) flush();
      speaker = token.speaker;
    }
    start ??= token.start;
    end = token.end ?? end;
    words += (words && !token.attach ? " " : "") + token.text;
    if (token.eos) flush();
  }
  flush();
  return lines.join("\n");
}

function deepgramText(data) {
  const alternative = data.results?.channels?.[0]?.alternatives?.[0];
  if (typeof alternative?.transcript !== "string") throw new Error("invalid_result");
  const utterances = data.results.utterances;
  const speakerLabel = (id) => (Number.isInteger(id) ? `S${id}` : undefined);
  if (Array.isArray(utterances) && utterances.length) {
    return utterances
      .map((turn) => {
        if (typeof turn.transcript !== "string") throw new Error("invalid_utterance");
        return segmentLine(turn.transcript, speakerLabel(turn.speaker), turn.start, turn.end);
      })
      .join("\n");
  }
  if (Array.isArray(alternative.words) && alternative.words.length) {
    return wordTurns(
      alternative.words.map((word) => ({
        text: word.punctuated_word ?? word.word,
        speaker: speakerLabel(word.speaker),
        start: word.start,
        end: word.end,
      })),
    );
  }
  return alternative.transcript;
}

function speechmaticsText(data) {
  if (!Array.isArray(data.results)) throw new Error("invalid_result");
  return wordTurns(
    data.results
      .filter((item) => item.type === "word" || item.type === "punctuation")
      .map((item) => {
        const first = item.alternatives?.[0];
        const punctuation = item.type === "punctuation";
        const speaker =
          typeof first?.speaker === "string" && first.speaker && first.speaker !== "UU"
            ? first.speaker
            : undefined;
        return {
          text: first?.content,
          speaker,
          start: item.start_time,
          end: item.end_time,
          punctuation,
          attach: item.attaches_to === "previous",
          eos: item.is_eos,
        };
      }),
  );
}

function failure(response, polling) {
  const transient = response.status === 429 || (polling && (response.status === 408 || response.status >= 500));
  if (transient) {
    const seconds = Number(response.headers.get("retry-after"));
    return {
      status: polling ? "processing" : "queued",
      detail: "provider_busy",
      delay: Math.max(MINUTE, Math.min(3600, Number.isFinite(seconds) ? seconds : 60) * 1000),
    };
  }
  if (!polling && (response.status === 408 || response.status >= 500)) {
    return { status: "review", detail: "submission_uncertain" };
  }
  return { status: "failed", detail: "provider_rejected" };
}

const providerReference = (value) => (typeof value === "string" && value && value.length <= 200 ? value : undefined);

async function publishedTranscript(response, provider) {
  // An unpublishable result keeps the provider reference, so the paid job stays traceable.
  const header = provider === "deepgram" ? providerReference(response.headers.get("dg-request-id")) : undefined;
  try {
    const data = await jsonBody(response, 12 * MiB);
    if (provider === "speechmatics") return resultText(speechmaticsText(data));
    const result = resultText(deepgramText(data));
    const requestId = providerReference(data.metadata?.request_id) ?? header;
    if (requestId) result.job = requestId;
    return result;
  } catch {
    return { status: "review", detail: "transcript_unreadable_or_oversize", job: header };
  }
}

async function submit(env, row, send) {
  const audio = audioParts(env.ACCOUNT_AUDIO, row);
  const options = { method: "POST", redirect: "manual", duplex: "half", signal: AbortSignal.timeout(10 * MINUTE) };
  if (row.provider === "deepgram") {
    const url = new URL("https://api.deepgram.com/v1/listen");
    url.search = new URLSearchParams({
      model: "nova-3",
      language: "multi",
      smart_format: "true",
      utterances: "true",
      diarize_model: "v2",
      mip_opt_out: "true",
    }).toString();
    const response = await send(url, {
      ...options,
      headers: { Authorization: `Token ${env.ACCOUNT_DEEPGRAM_KEY}`, "Content-Type": row.mime_type },
      body: streamBody(audio, row.size),
    });
    if (!response.ok) return failure(response, false);
    return publishedTranscript(response, "deepgram");
  }
  const encoder = new TextEncoder();
  const boundary = `hall-e-${crypto.randomUUID()}`;
  const config = {
    type: "transcription",
    transcription_config: {
      model: "melia-1",
      language: "multi",
      diarization: "speaker",
      speaker_diarization_config: { prefer_current_speaker: true },
    },
    tracking: { reference: row.blob_id },
  };
  const prefix = encoder.encode(
    `--${boundary}\r\nContent-Disposition: form-data; name="config"\r\nContent-Type: application/json\r\n\r\n${JSON.stringify(config)}\r\n--${boundary}\r\nContent-Disposition: form-data; name="data_file"; filename="recording.${row.mime_type === "audio/wav" ? "wav" : "m4a"}"\r\nContent-Type: ${row.mime_type}\r\n\r\n`,
  );
  const suffix = encoder.encode(`\r\n--${boundary}--\r\n`);
  async function* multipart() {
    yield prefix;
    yield* audio;
    yield suffix;
  }
  const url = `https://${row.region}.asr.api.speechmatics.com/v2/jobs/?wait=0&format=json-v2`;
  const response = await send(url, {
    ...options,
    headers: {
      Authorization: `Bearer ${env.ACCOUNT_SPEECHMATICS_KEY}`,
      "Content-Type": `multipart/form-data; boundary=${boundary}`,
    },
    body: streamBody(multipart(), prefix.length + row.size + suffix.length),
  });
  if (response.status !== 201) return failure(response, false);
  const data = await jsonBody(response, MiB);
  if (typeof data.id !== "string" || !/^[a-zA-Z0-9_-]{1,200}$/.test(data.id))
    return { status: "review", detail: "submission_uncertain" };
  return { status: "processing", job: data.id, delay: MINUTE };
}

async function pollSpeechmatics(env, row, send) {
  const url = `https://${row.region}.asr.api.speechmatics.com/v2/jobs/${encodeURIComponent(row.provider_job)}`;
  const options = {
    headers: { Authorization: `Bearer ${env.ACCOUNT_SPEECHMATICS_KEY}` },
    redirect: "manual",
    signal: AbortSignal.timeout(30_000),
  };
  const response = await send(url, options);
  if (!response.ok) return failure(response, true);
  const { job } = await jsonBody(response, MiB);
  const reference = job?.tracking?.reference ?? job?.config?.tracking?.reference;
  if (job?.id !== row.provider_job || (reference && reference !== row.blob_id))
    return { status: "review", detail: "job_identity_mismatch" };
  if (["rejected", "deleted", "expired"].includes(job.status))
    return { status: "failed", detail: "provider_rejected" };
  if (job.status !== "done") return { status: "processing", delay: MINUTE };
  const transcript = await send(`${url}/transcript?format=json-v2`, options);
  if (!transcript.ok) return failure(transcript, true);
  return publishedTranscript(transcript, "speechmatics");
}

async function disposeOne(env, now) {
  const db = env.ACCOUNT_DB;
  // Claim first. Deletion can be resumed after a crash at any point, including after R2 deletion.
  const row = await db
    .prepare(
      `UPDATE account_recordings SET status='disposing',transcript=NULL WHERE blob_id=(
    SELECT blob_id FROM account_recordings WHERE status='disposing' OR NOT ${liveMeeting}
      OR (status='uploading' AND updated_at<?) ORDER BY updated_at LIMIT 1) RETURNING blob_id,size`,
    )
    .bind(now - STALE_UPLOAD)
    .first();
  if (!row) return false;
  await env.ACCOUNT_AUDIO.delete(objectKeys(row));
  await db
    .prepare("DELETE FROM account_recordings WHERE blob_id=? AND status='disposing'")
    .bind(row.blob_id)
    .run();
  return true;
}

// Objects of a deleted account. The queue row goes only after R2 confirms; repeating a delete is harmless.
async function disposeQueued(env) {
  const db = env.ACCOUNT_DB;
  const row = await db.prepare("SELECT blob_id, size FROM account_disposals ORDER BY queued_at, blob_id LIMIT 1").first();
  if (!row) return false;
  await env.ACCOUNT_AUDIO.delete(objectKeys(row));
  await db.prepare("DELETE FROM account_disposals WHERE blob_id=?").bind(row.blob_id).run();
  return true;
}

// Run after a delete is acknowledged. The cron remains the fallback for anything left or failed.
export async function disposeRemoved(env, { now = Date.now, limit = 16 } = {}) {
  for (let i = 0; i < limit && ((await disposeQueued(env)) || (await disposeOne(env, now()))); i++);
}

// A scheduled invocation consumes at most one job. Calls can overlap: the conditional claim is persisted before POST.
export async function processPending(
  env,
  { fetch: send = globalThis.fetch.bind(globalThis), now: clock = Date.now, selectLocalProcessor } = {},
) {
  const now = clock();
  const db = env.ACCOUNT_DB;
  await disposeOne(env, now);
  for (let i = 0; i < 16 && (await disposeQueued(env)); i++);
  await db
    .prepare(
      `UPDATE account_recordings SET status='review',detail='submission_uncertain'
    WHERE status='submitting' AND next_at<=?`,
    )
    .bind(now)
    .run();
  let row = null;
  let localProcessor;
  for (let skipped = 0; skipped < 16; skipped++) {
    const candidate = await db
      .prepare(
        `SELECT * FROM account_recordings WHERE status IN ('queued','processing')
      AND next_at<=? AND ${liveMeeting} ORDER BY next_at,updated_at,blob_id LIMIT 1`,
      )
      .bind(now)
      .first();
    if (!candidate) return;
    const local = candidate.status === "queued" ? selectLocalProcessor?.(candidate) : undefined;
    if (local || ready(env, candidate)) {
      row = candidate;
      localProcessor = local;
      break;
    }
    await db
      .prepare(
        `UPDATE account_recordings SET detail='provider_unconfigured',next_at=?
      WHERE blob_id=? AND status=? AND next_at=?`,
      )
      .bind(now + MINUTE, candidate.blob_id, candidate.status, candidate.next_at)
      .run();
  }
  if (!row) return;
  const polling = row.status === "processing";
  const claim = crypto.randomUUID();
  const leased = await db
    .prepare(
      `UPDATE account_recordings SET status=?,claim=?,next_at=?,detail=NULL
    WHERE blob_id=? AND status=? AND next_at=? AND ${liveMeeting}`,
    )
    .bind(polling ? "processing" : "submitting", claim, now + CLAIM_TTL, row.blob_id, row.status, row.next_at)
    .run();
  if (!leased.meta.changes) return;
  let result;
  try {
    if (localProcessor) result = await localProcessor(audioParts(env.ACCOUNT_AUDIO, row));
    else result = polling ? await pollSpeechmatics(env, row, send) : await submit(env, row, send);
  } catch {
    // A network failure after POST cannot distinguish a rejected connection from a paid, accepted job.
    result = polling
      ? { status: "processing", detail: "poll_retry", delay: MINUTE }
      : { status: "review", detail: "submission_uncertain" };
  }
  const owned = `blob_id=? AND claim=? AND status!='disposing' AND ${liveMeeting}`;
  const writes = [];
  if (result.stored) {
    // Write the object before publishing it. The marker and the result commit together, or neither does.
    await env.ACCOUNT_AUDIO.put(transcriptKey(row.blob_id), result.stored, {
      httpMetadata: { contentType: "text/plain; charset=utf-8" },
    });
    writes.push(
      db
        .prepare(
          `INSERT INTO account_recording_transcripts(blob_id,bytes) SELECT blob_id,? FROM account_recordings
      WHERE ${owned} ON CONFLICT(blob_id) DO UPDATE SET bytes=excluded.bytes`,
        )
        .bind(result.stored.length, row.blob_id, claim),
    );
  }
  writes.push(
    db
      .prepare(
        `UPDATE account_recordings SET status=?,detail=?,transcript=?,provider_job=COALESCE(?,provider_job),
    claim=NULL,next_at=?,updated_at=? WHERE ${owned}`,
      )
      .bind(
        result.status,
        result.detail ?? null,
        result.transcript ?? null,
        result.job ?? null,
        clock() + (result.delay ?? 0),
        clock(),
        row.blob_id,
        claim,
      ),
  );
  const updated = (await db.batch(writes)).at(-1);
  if (!result.stored || updated.meta.changes) return;
  // A removal won the race and its disposal may already have run. A live row can still publish this key.
  const live = await db
    .prepare(`SELECT 1 FROM account_recordings WHERE blob_id=? AND status!='disposing' AND ${liveMeeting}`)
    .bind(row.blob_id)
    .first();
  if (!live) await env.ACCOUNT_AUDIO.delete(transcriptKey(row.blob_id));
}
