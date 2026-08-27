#!/usr/bin/env bash
#
# derive-version.sh — echo the upstream human version string (YYYY.M.P).
#
# Part of: KingHavok/ha-android-authproxy
# Purpose : Report which upstream Home Assistant release a build is based on, so
#           the release tag/title/asset can be named after it. Used by the
#           build-and-release workflow.
#
# Usage   : scripts/derive-version.sh [UPSTREAM_TREE]
#             UPSTREAM_TREE  Path to the checked-out upstream git repo.
#                            Defaults to the current directory (".").
#
# Output  : the bare version string on stdout (no leading "v"), e.g.  2026.8.3
#           Diagnostics go to stderr, so `$(derive-version.sh)` is clean.
#
# Exit    : 0  version printed
#           1  usage/tree error, or no version could be determined
#
# Strategy:
#   1. PRIMARY — the nearest release-style git tag (YYYY.M.P) that is an
#      ancestor of the checked-out commit. Upstream tags every release this way,
#      so this answers "which release is this commit built on top of". It needs
#      the clone to include tags; the workflow does a full clone (also required
#      by the reckon Gradle plugin), so they are present.
#   2. FALLBACK — the legacy app/src/main/res/xml/changelog_master.xml, for
#      older commits. Upstream DELETED that file when it moved the changelog to
#      Kotlin ("Modernize changelog UI", home-assistant/android#7279), which is
#      why the tag lookup is now primary.
#
#   Note the two sources differ by one release: the XML was pre-bumped to the
#   UPCOMING version, while a tag marks the LAST SHIPPED release. The tag is the
#   more truthful claim for a build made from main after that release.
#
set -euo pipefail

log() { printf '[derive-version] %s\n' "$*" >&2; }
die() { printf '[derive-version] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

UPSTREAM_TREE="${1:-.}"
# Release tags look like 2026.8.3 (also tolerates a 4th component).
TAG_GLOB='[0-9][0-9][0-9][0-9].[0-9]*.[0-9]*'

[ -d "${UPSTREAM_TREE}" ] || die "upstream tree '${UPSTREAM_TREE}' is not a directory." 1

VERSION=""

# --- 1. primary: nearest release tag reachable from HEAD ---------------------
if git -C "${UPSTREAM_TREE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VERSION="$(
    git -C "${UPSTREAM_TREE}" describe --tags --abbrev=0 --match "${TAG_GLOB}" HEAD 2>/dev/null || true
  )"
  if [ -n "${VERSION}" ]; then
    log "upstream version: ${VERSION} (nearest release tag reachable from HEAD)"
  else
    log "no release-style tag reachable from HEAD; falling back to the legacy changelog"
  fi
else
  log "'${UPSTREAM_TREE}' is not a git work tree; falling back to the legacy changelog"
fi

# --- 2. fallback: legacy changelog_master.xml (pre-#7279 commits) ------------
if [ -z "${VERSION}" ]; then
  CHANGELOG="${UPSTREAM_TREE%/}/app/src/main/res/xml/changelog_master.xml"
  if [ -s "${CHANGELOG}" ]; then
    VERSION="$(
      grep -E '<release[[:space:]][^>]*version="[0-9]+(\.[0-9]+)*[[:space:]]*-[[:space:]]*Main"' "${CHANGELOG}" \
        | head -n 1 \
        | sed -E 's/.*version="([0-9]+(\.[0-9]+)*)[[:space:]]*-[[:space:]]*Main".*/\1/' \
    )" || true
    [ -n "${VERSION}" ] && log "upstream version: ${VERSION} (from legacy ${CHANGELOG})"
  fi
fi

# --- validate ---------------------------------------------------------------
[ -n "${VERSION}" ] || die "could not determine the upstream version: no release-style git tag (${TAG_GLOB}) reachable from HEAD, and no legacy changelog_master.xml to fall back on. If the clone is shallow or tag-less, fetch tags." 1

printf '%s' "${VERSION}" | grep -Eq '^[0-9]+(\.[0-9]+)*$' \
  || die "derived version '${VERSION}' is not in the expected YYYY.M.P form." 1

printf '%s\n' "${VERSION}"
