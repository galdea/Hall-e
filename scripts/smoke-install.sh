#!/bin/bash
# Fresh-profile launch check on disposable GitHub macOS runners only.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS ]] || {
  echo 'This check only runs on a disposable GitHub macOS runner.' >&2; exit 1;
}
[[ $# == 1 && -f "$1" ]] || { echo 'Pass one release ZIP.' >&2; exit 1; }
STAGING="$(mktemp -d "$RUNNER_TEMP/halle-install.XXXXXX")"
DATA_DIR="$HOME/Library/Application Support/Hall-e"
INSTALL_DIR="$HOME/Applications/Hall-e.app"
[[ ! -e "$INSTALL_DIR" ]] || { echo 'Refusing to replace an existing app.' >&2; exit 1; }
# Unit tests can leave local test data; preserve it while checking a clean profile.
if [[ -e "$DATA_DIR" ]]; then mv "$DATA_DIR" "$STAGING/previous-test-data"; fi
APP_PID=''
cleanup() {
  if [[ -n "$APP_PID" ]]; then kill "$APP_PID" 2>/dev/null || true; fi
  rm -rf "$INSTALL_DIR"
}
trap cleanup EXIT
ditto -x -k "$1" "$STAGING/unpacked"
mkdir -p "$HOME/Applications"
ditto "$STAGING/unpacked/Hall-e.app" "$INSTALL_DIR"
codesign --verify --deep --strict "$INSTALL_DIR"
open -n "$INSTALL_DIR"
for attempt in {1..30}; do
  APP_PID="$(pgrep -x Hall-e | head -n 1 || true)"
  if [[ -n "$APP_PID" && -f "$DATA_DIR/halle.sqlite" ]]; then break; fi
  sleep 1
done
[[ -n "$APP_PID" ]] || { echo 'Installed app did not stay running.' >&2; exit 1; }
sleep 3
kill -0 "$APP_PID"
python3 - "$DATA_DIR" <<'PY'
import json, pathlib, sqlite3, sys
root = pathlib.Path(sys.argv[1])
# The project directory is lazily created when first used. Absence is empty.
projects = root / 'aliases.json'
assert not projects.exists() or json.loads(projects.read_text()) == [], 'Fresh projects are not empty'
assert (root / 'halle.sqlite').is_file(), 'Fresh launch did not create its database'
with sqlite3.connect(str(root / 'halle.sqlite')) as db:
    assert db.execute('pragma quick_check').fetchone()[0] == 'ok', 'Database validation failed'
assert not list((root / 'Recordings').rglob('session.json')), 'Fresh launch unexpectedly started a recording'
print('Fresh-profile launch passed: relocated app running, valid database, empty projects, no recordings.')
PY
