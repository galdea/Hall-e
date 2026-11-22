import { createHash } from "node:crypto";
import accountWorker from "./account-worker.mjs";
import { processPending } from "./account-recording.mjs";

// Only this dedicated staging entrypoint recognizes coordinator/test-support/phone-tone.mp4.
const toneHash = "adc686f32a313ed2ef31ace3988a86dc2431b0ab98ca96a176a3ac09734de77a";
const toneSize = 2852;

function selectToneProcessor(row) {
  if (row.sha256 !== toneHash || row.size !== toneSize || row.mime_type !== "audio/mp4" || row.provider !== "deepgram") return;
  return async function verifyTone(parts) {
    const hash = createHash("sha256");
    for await (const part of parts) hash.update(part);
    if (hash.digest("hex") !== toneHash) return { status: "failed", detail: "staging_fixture_mismatch" };
    return {
      status: "completed", detail: "staging_synthetic_fixture",
      transcript: "[STAGING SYNTHETIC] Verified 440 Hz test tone. No speech recognition was performed.",
    };
  };
}

function runStagingProcessor(env) {
  return processPending({ ...env, ACCOUNT_ENABLE_TRANSCRIPTION: "no" }, {
    selectLocalProcessor: env.ACCOUNT_STAGING_FIXTURE === "yes" ? selectToneProcessor : undefined,
  });
}

export default {
  async fetch(request, env, ctx) {
    const response = await accountWorker.fetch(request, env, ctx);
    if (request.method === "POST" && response.ok &&
        /^\/account\/v1\/meetings\/[\da-f-]{36}\/recordings\/[\da-f-]{36}\/complete$/i.test(new URL(request.url).pathname)) {
      // The cron retries; log only the error class so no account data reaches the logs.
      ctx.waitUntil(runStagingProcessor(env).catch(error => console.error("staging_processor_failed", error?.name ?? "Error")));
    }
    return response;
  },
  scheduled(_event, env) {
    return runStagingProcessor(env);
  },
};
