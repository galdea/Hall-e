#!/bin/zsh
# Reads one short-lived sign-in code from the private Hall-e Staging mailbox.
# Requires Node and a Wrangler login with administrative access to the staging D1 database.
# Only the two synthetic staging identities are accepted.
set -u
repo="${0:A:h:h:h}"
export HALLE_STAGE_CONFIG="${HALLE_STAGE_CONFIG:-$repo/coordinator/wrangler.account.staging.jsonc}"
if [[ -z "${WRANGLER_BIN:-}" ]]; then
  if command -v wrangler >/dev/null 2>&1; then
    export WRANGLER_BIN="$(command -v wrangler)"
  else
    print -u2 'Wrangler was not found. Install it or set WRANGLER_BIN, then reopen this file.'
    read -r
    exit 1
  fi
fi
if ! command -v node >/dev/null 2>&1; then
  print -u2 'Node was not found on PATH.'
  read -r
  exit 1
fi
print 'Request a code in Hall-e Staging using halle-owner@example.test.'
print 'Press Return to view that code, or type 2 for halle-other@example.test.'
read -r choice
address='halle-owner@example.test'
[[ "$choice" != 2 ]] || address='halle-other@example.test'
node "$repo/coordinator/scripts/staging-code.mjs" "$address"
result=$?
print 'Press Return to close this window.'
read -r
exit "$result"
