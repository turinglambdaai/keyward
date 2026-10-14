#!/usr/bin/env bash
# Release preflight: the tag, rivet.rktd and the CHANGELOG must agree.
# There is no VERSION file and no in-app updater yet — rivet.rktd is
# the single version source; the CHANGELOG entry is cross-checked so a
# bump cannot ship unnamed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"

fail() {
  echo "release preflight: $*" >&2
  exit 1
}

RIVET_RKTD_VERSION="$(sed -n 's/.* (version . "\([^"]*\)").*/\1/p' "$ROOT/rivet.rktd" | head -n1)"
[[ -n "$RIVET_RKTD_VERSION" ]] || fail "cannot read a version from rivet.rktd"
[[ "$RIVET_RKTD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || \
  fail "rivet.rktd version '$RIVET_RKTD_VERSION' is not a supported semantic version"

if [[ -n "$TAG" ]]; then
  TAG_VERSION="${TAG#v}"
  [[ "$TAG_VERSION" == "$RIVET_RKTD_VERSION" ]] || \
    fail "tag '$TAG' does not match rivet.rktd version '$RIVET_RKTD_VERSION'"
fi

grep -qE "^## ${RIVET_RKTD_VERSION//./\\.} - " "$ROOT/CHANGELOG.md" || \
  fail "CHANGELOG.md has no dated entry for version '$RIVET_RKTD_VERSION'"

echo "release preflight: version $RIVET_RKTD_VERSION is aligned (rivet.rktd == tag == CHANGELOG)"
