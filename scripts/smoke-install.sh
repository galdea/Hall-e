#!/bin/bash
# Fresh-profile launch check on disposable GitHub macOS runners only.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
  echo 'This check only runs on a disposable GitHub macOS runner.' >&2; exit 1;
}
[[ $# == 1 && -f "$1" ]] || { echo 'Pass one release ZIP or DMG.' >&2; exit 1; }
PACKAGE="$1"
STAGING="$(mktemp -d "$RUNNER_TEMP/halle-install.XXXXXX")"
DATA_DIR="$HOME/Library/Application Support/Hall-e"
INSTALL_DIR="$HOME/Applications/Hall-e.app"
[[ ! -e "$INSTALL_DIR" ]] || { echo 'Refusing to replace an existing app.' >&2; exit 1; }
if pgrep -x Hall-e >/dev/null; then
  echo 'Refusing to run while another Hall-e process is active.' >&2; exit 1
fi
APP_PID=''
MOUNTED=0
cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    for attempt in {1..10}; do
      if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
      sleep 1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then kill -9 "$APP_PID" 2>/dev/null || true; fi
  fi
  if [[ "$MOUNTED" == 1 ]]; then
    hdiutil detach "$STAGING/mount" -quiet || hdiutil detach "$STAGING/mount" -force -quiet || true
  fi
  rm -rf "$INSTALL_DIR"
  rm -rf "$DATA_DIR"
  if [[ -e "$STAGING/previous-test-data" ]]; then mv "$STAGING/previous-test-data" "$DATA_DIR"; fi
  defaults delete cl.gabriel.hall-e >/dev/null 2>&1 || true
  if [[ -f "$STAGING/previous-preferences.plist" ]]; then
    defaults import cl.gabriel.hall-e "$STAGING/previous-preferences.plist" >/dev/null
  fi
}
trap cleanup EXIT
# Unit tests can leave preferences as well as data. Preserve both, then prove
# each archive starts onboarding with a clean profile on this disposable runner.
if [[ -e "$DATA_DIR" ]]; then mv "$DATA_DIR" "$STAGING/previous-test-data"; fi
defaults export cl.gabriel.hall-e "$STAGING/previous-preferences.plist" >/dev/null 2>&1 || true
defaults delete cl.gabriel.hall-e >/dev/null 2>&1 || true

case "$PACKAGE" in
  *.zip)
    mkdir -p "$STAGING/unpacked"
    ditto -x -k "$PACKAGE" "$STAGING/unpacked"
    SOURCE_APP="$STAGING/unpacked/Hall-e.app"
    ;;
  *.dmg)
    hdiutil verify "$PACKAGE" >/dev/null
    mkdir -p "$STAGING/mount"
    hdiutil attach "$PACKAGE" -quiet -readonly -noverify -nobrowse -mountpoint "$STAGING/mount"
    MOUNTED=1
    [[ -L "$STAGING/mount/Applications" && "$(readlink "$STAGING/mount/Applications")" == /Applications ]] || {
      echo 'DMG is missing the Applications drag target.' >&2; exit 1;
    }
    SOURCE_APP="$STAGING/mount/Hall-e.app"
    ;;
  *) echo 'Release package must be a ZIP or DMG.' >&2; exit 1;;
esac
[[ -d "$SOURCE_APP" ]] || { echo 'Hall-e.app is missing from the package.' >&2; exit 1; }
mkdir -p "$HOME/Applications"
ditto "$SOURCE_APP" "$INSTALL_DIR"
if [[ "$MOUNTED" == 1 ]]; then
  hdiutil detach "$STAGING/mount" -quiet
  MOUNTED=0
fi
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
print('Fresh-profile launch passed: installed app running, valid database, empty projects, no recordings.')
PY
