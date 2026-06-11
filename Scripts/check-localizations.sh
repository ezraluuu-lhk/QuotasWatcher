#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$ROOT_DIR/Sources/QuotasWatcher/Resources"
REFERENCE="$RESOURCES_DIR/en.lproj/Localizable.strings"

if [[ ! -f "$REFERENCE" ]]; then
  echo "Missing reference localization: $REFERENCE" >&2
  exit 1
fi

plutil -lint "$RESOURCES_DIR"/*/*.strings

reference_keys="$(mktemp)"
candidate_keys="$(mktemp)"
trap 'rm -f "$reference_keys" "$candidate_keys"' EXIT

sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' "$REFERENCE" | sort > "$reference_keys"

for candidate in "$RESOURCES_DIR"/*.lproj/Localizable.strings; do
  [[ "$candidate" == "$REFERENCE" ]] && continue

  sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' "$candidate" | sort > "$candidate_keys"

  if ! diff -u "$reference_keys" "$candidate_keys"; then
    echo "Localization keys do not match: $candidate" >&2
    exit 1
  fi
done

echo "Localization files are valid."
