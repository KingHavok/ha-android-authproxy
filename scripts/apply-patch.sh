#!/usr/bin/env bash
#
# apply-patch.sh — apply the auth-proxy patch to a checked-out upstream tree.
#
# Part of: KingHavok/ha-android-authproxy
# Purpose : Robustly 3-way-apply patches/0001-auth-proxy-redirect-support.patch
#           onto a freshly cloned home-assistant/android working tree. On failure
#           it prints the full conflict / reject detail and exits non-zero so the
#           calling workflow can open a "patch no longer applies" issue.
#
# Usage   : scripts/apply-patch.sh [UPSTREAM_TREE]
#             UPSTREAM_TREE  Path to the checked-out upstream git repo.
#                            Defaults to the current directory (".").
#
# Env     : PATCH_FILE   Override the patch path (default:
#                        <repo-of-this-script>/patches/0001-auth-proxy-redirect-support.patch)
#
# Exit    : 0  patch applied (or already applied — see idempotency note below)
#           1  usage / environment error
#           2  patch failed to apply (conflict detail printed to stderr)
#
# Notes   : - Requires only git (plus coreutils). No network access needed.
#           - Strategy: try `git am --3way` first (preserves the patch author and
#             commit message, since the patch is a `git format-patch` file). If
#             `git am` cannot proceed it is aborted cleanly and we fall back to
#             `git apply --3way`, which applies the diff without committing.
#           - Idempotent-ish: if the patch is already present in the tree we detect
#             that with `git apply --reverse --check` and exit 0 instead of failing.
#           - Safe under `set -euo pipefail`: every command whose non-zero exit is
#             expected is guarded explicitly.
#
set -euo pipefail

# --- locate this script and the patch ---------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

UPSTREAM_TREE="${1:-.}"
PATCH_FILE="${PATCH_FILE:-${REPO_ROOT}/patches/0001-auth-proxy-redirect-support.patch}"

# --- small helpers ----------------------------------------------------------
log()  { printf '[apply-patch] %s\n' "$*" >&2; }
die()  { printf '[apply-patch] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# --- preflight checks -------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git is required but was not found on PATH." 1

[ -e "${UPSTREAM_TREE}" ] || die "upstream tree '${UPSTREAM_TREE}' does not exist." 1
[ -d "${UPSTREAM_TREE}" ] || die "upstream tree '${UPSTREAM_TREE}' is not a directory." 1

[ -f "${PATCH_FILE}" ] || die "patch file not found: '${PATCH_FILE}'." 1
[ -s "${PATCH_FILE}" ] || die "patch file is empty: '${PATCH_FILE}'." 1

# Resolve to an absolute patch path *before* we cd, so it stays valid.
PATCH_FILE="$(cd -- "$(dirname -- "${PATCH_FILE}")" >/dev/null 2>&1 && pwd -P)/$(basename -- "${PATCH_FILE}")"

# Move into the upstream tree; all git commands below operate there.
cd -- "${UPSTREAM_TREE}"

# Confirm we are really inside a git work tree (3-way apply needs the index/objects).
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "'${UPSTREAM_TREE}' is not inside a git work tree (3-way apply needs git history)." 1

log "upstream tree : $(pwd -P)"
log "patch file    : ${PATCH_FILE}"
log "upstream HEAD : $(git rev-parse --short HEAD 2>/dev/null || echo '<unknown>')"

# --- idempotency: is the patch already applied? -----------------------------
# If reversing the patch would apply cleanly, the changes are already in the tree.
if git apply --reverse --check "${PATCH_FILE}" >/dev/null 2>&1; then
  log "patch already present in tree (reverse-check succeeded) — nothing to do."
  exit 0
fi

# --- print a conflict report and exit 2 -------------------------------------
fail_with_conflict_detail() {
  local stage="$1"
  {
    printf '\n'
    printf '================================================================\n'
    printf 'PATCH FAILED TO APPLY (%s)\n' "${stage}"
    printf '================================================================\n'
    printf 'Patch : %s\n' "${PATCH_FILE}"
    printf 'Tree  : %s\n' "$(pwd -P)"
    printf 'HEAD  : %s\n' "$(git rev-parse HEAD 2>/dev/null || echo '<unknown>')"
    printf '----------------------------------------------------------------\n'

    # Per-hunk diagnosis: which hunks/files cannot be located in the tree.
    printf 'Hunk-level diagnosis (git apply --3way --check):\n'
    git apply --3way --check --verbose "${PATCH_FILE}" 2>&1 || true
    printf '----------------------------------------------------------------\n'

    # Any conflict markers / unmerged paths left in the work tree.
    local unmerged
    unmerged="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
    if [ -n "${unmerged}" ]; then
      printf 'Files with unresolved merge conflicts:\n%s\n' "${unmerged}"
      printf '----------------------------------------------------------------\n'
      printf 'Conflict markers:\n'
      # shellcheck disable=SC2086
      grep -nE '^(<<<<<<<|=======|>>>>>>>)' ${unmerged} 2>/dev/null || true
      printf '----------------------------------------------------------------\n'
    fi

    # *.rej reject files, if `git apply` left any behind.
    local rejects
    rejects="$(git ls-files --others --exclude-standard 2>/dev/null | grep -E '\.rej$' || true)"
    if [ -n "${rejects}" ]; then
      printf 'Reject files:\n%s\n' "${rejects}"
      printf '----------------------------------------------------------------\n'
    fi
    printf '================================================================\n'
  } >&2
  die "patch did not apply cleanly — see conflict detail above. The upstream files likely changed; the patch must be refreshed." 2
}

# --- attempt 1: git am --3way (keeps authorship + commit message) -----------
log "attempting 'git am --3way' ..."
if git am --3way --keep-cr "${PATCH_FILE}" >/dev/null 2>&1; then
  log "applied via 'git am --3way' (commit created, authorship preserved)."
  log "new HEAD: $(git rev-parse --short HEAD)"
  exit 0
fi

# git am failed: abort cleanly so the tree/index are usable for the fallback.
log "'git am --3way' did not apply cleanly; aborting it and trying 'git apply --3way'."
git am --abort >/dev/null 2>&1 || true

# --- attempt 2: git apply --3way (applies the diff, no commit) --------------
log "attempting 'git apply --3way' ..."
if git apply --3way --verbose "${PATCH_FILE}" 2>/dev/null; then
  # `git apply --3way` can exit 0 yet leave conflict markers on partial merges;
  # treat any unmerged path as a hard failure.
  if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null || true)" ]; then
    fail_with_conflict_detail "git apply --3way left unresolved conflicts"
  fi
  log "applied via 'git apply --3way' (working tree modified, not committed)."
  exit 0
fi

# Both strategies failed — emit the full diagnosis and exit non-zero.
fail_with_conflict_detail "git am --3way AND git apply --3way both failed"
