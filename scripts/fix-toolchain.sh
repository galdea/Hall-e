#!/bin/bash
# Workaround for a broken Command Line Tools install on this machine (CLT 16.2
# carrying stale files from older CLT versions). Two faults block Swift builds:
#
#   Fault 1 (no sudo needed): a stale Swift 5.10 *.private.swiftinterface for
#     PackageDescription shadows the correct 6.0 public interface, so SwiftPM
#     manifests fail to link. Fixed here by copying the pm libs to
#     .toolchain-fix/ with the private interfaces stripped; builds then run with
#     SWIFTPM_CUSTOM_LIBS_DIR pointing at that copy.
#
#   Fault 2 (needs sudo, once): usr/include/swift/module.modulemap (stale, 2023)
#     duplicates bridging.modulemap (current), both defining `module
#     SwiftBridging`, so every compile that imports Foundation fails with
#     "redefinition of module". SwiftPM compiles each dependency's Package.swift
#     with swift-frontend at a hardcoded path and its own VFS overlay, so this
#     cannot be worked around per-invocation — the stale file must be removed.
#
# The whole thing is unnecessary after a clean CLT reinstall:
#   sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
set -euo pipefail
cd "$(dirname "$0")/.."

FIX="$PWD/.toolchain-fix"
SRC="/Library/Developer/CommandLineTools/usr/lib/swift/pm"
STALE_MODULEMAP="/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap"

# Fault 1
mkdir -p "$FIX"
if [ ! -d "$FIX/ManifestAPI" ]; then
  cp -R "$SRC/"* "$FIX/"
  find "$FIX" -name "*.private.swiftinterface" -delete
  echo "✓ Patched ManifestAPI copy created (.toolchain-fix)."
fi

# Fault 2 — can only be fixed with sudo; fail fast with a clear instruction.
if [ -f "$STALE_MODULEMAP" ]; then
  cat >&2 <<EOF

✗ Swift cannot compile until a stale duplicate modulemap is removed.
  This machine's Command Line Tools left an obsolete file behind:

      $STALE_MODULEMAP   (2023, duplicate)
      .../bridging.modulemap                                   (current, keep)

  Both define 'module SwiftBridging', so every build fails. Remove the stale
  duplicate (one time; it also repairs Swift for other projects):

      sudo rm -f "$STALE_MODULEMAP"

  Then re-run your build. (Nothing is lost — the two files are identical, and
  the current bridging.modulemap remains.)

EOF
  exit 1
fi

echo "✓ Toolchain ready."
