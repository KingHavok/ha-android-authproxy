#!/usr/bin/env bash
#
# derive-version.sh — echo the upstream human version string (YYYY.M.P).
#
# Part of: KingHavok/ha-android-authproxy
# Purpose : Parse the FIRST "- Main" release from upstream's
#           app/src/main/res/xml/changelog_master.xml and print its version,
#           e.g. "2026.6.5". Used by the workflow to name the tag/release.
#
# Usage   : scripts/derive-version.sh [UPSTREAM_TREE]
#             UPSTREAM_TREE  Path to the checked-out upstream git repo.
#                            Defaults to the current directory (".").
#
# Output  : the bare version string on stdout (no leading "v", no " - Main"),
#           e.g.  2026.6.5
#
# Exit    : 0  version printed
#           1  usage / file error, or no parseable "- Main" release found
#
# Notes   : - No deps beyond grep/sed/awk (and coreutils). No network.
#           - The changelog lists several "<release ...>" lines per version
#             (Main / Wear / Automotive). We deliberately match only the "Main"
#             variant and take the FIRST one, which is the newest release.
#           - Expected line shape:
#               <release version="2026.6.5 - Main" versioncode="3">
#
set -euo pipefail

log() { printf '[derive-version] %s\n' "$*" >&2; }
die() { printf '[derive-version] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

UPSTREAM_TREE="${1:-.}"
CHANGELOG_REL="app/src/main/res/xml/changelog_master.xml"
CHANGELOG="${UPSTREAM_TREE%/}/${CHANGELOG_REL}"

# --- preflight --------------------------------------------------------------
[ -d "${UPSTREAM_TREE}" ] || die "upstream tree '${UPSTREAM_TREE}' is not a directory." 1
[ -f "${CHANGELOG}" ]     || die "changelog not found: '${CHANGELOG}'." 1
[ -s "${CHANGELOG}" ]     || die "changelog is empty: '${CHANGELOG}'." 1

# --- parse the first '<release version="YYYY.M.P - Main" ...>' ---------------
# 1. grep   : keep only release lines whose version ends in '- Main'.
# 2. head   : take the first (newest) such line.
# 3. sed    : extract the version digits that sit before ' - Main' inside the
#             version="..." attribute. Captures YYYY.M.P (1+ dot-separated nums).
VERSION="$(
  grep -E '<release[[:space:]][^>]*version="[0-9]+(\.[0-9]+)*[[:space:]]*-[[:space:]]*Main"' "${CHANGELOG}" \
    | head -n 1 \
    | sed -E 's/.*version="([0-9]+(\.[0-9]+)*)[[:space:]]*-[[:space:]]*Main".*/\1/' \
)" || true

# --- validate ---------------------------------------------------------------
[ -n "${VERSION}" ] \
  || die "no '<release version=\"YYYY.M.P - Main\" ...>' entry found in '${CHANGELOG}'." 1

# Guard against a malformed capture (e.g. sed returned the whole line unchanged).
printf '%s' "${VERSION}" | grep -Eq '^[0-9]+(\.[0-9]+)*$' \
  || die "parsed version '${VERSION}' is not in the expected YYYY.M.P form." 1

log "upstream version: ${VERSION} (from ${CHANGELOG})"
printf '%s\n' "${VERSION}"
