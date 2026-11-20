import { spawn } from "node:child_process";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const swiftArgs = ["test", "--jobs", "2", "--disable-automatic-resolution", "--filter", "NativeAccountInteropTests"];
function run(temp, command, args, extraEnv = {}) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, {
      cwd: repo, stdio: "inherit", env: {
        ...process.env, HALL_E_NATIVE_QA: join(temp, "fixture.json"), HALLE_DEBUG_FIXTURES: "1",
        HALLE_DEBUG_DATA_DIR: join(temp, "data"), ...extraEnv,
      },
    });
    child.once("error", reject);
    child.once("exit", (status, signal) => {
      if (status === 0) resolveRun();
      else reject(new Error(`${command} failed (${signal || status})`));
    });
  });
}

export function createNativeMeeting(temp) {
  return run(temp, "swift", swiftArgs, { HALL_E_NATIVE_PHASE: "create" });
}

export function editFromAndroid(temp) {
  return run(temp, resolve(repo, "android/gradlew"), [
    "--offline", "--no-daemon", "--max-workers=1", "-Dorg.gradle.jvmargs=-Xmx768m",
    "-Pkotlin.compiler.execution.strategy=in-process", ":app:testDebugUnitTest", "--tests", "app.halle.companion.NativeAccountInteropTest", "--rerun",
  ]);
}

export function verifyFromMac(temp) {
  return run(temp, "swift", [...swiftArgs, "--skip-build"], { HALL_E_NATIVE_PHASE: "verify" });
}
