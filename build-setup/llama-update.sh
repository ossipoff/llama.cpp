#!/bin/sh
# llama-update: catch the local build up to upstream, automatically.
#
# This is the "one command updates me" driver. It does the whole catch-up and
# stops the moment something needs a human, leaving a clean, resumable state:
#
#    1. git fetch origin
#    2. if local source is current with upstream AND installed matches source
#       -> "up to date", stop
#    3. git rebase origin/master    (on the local branch)
#           -> on conflict: abort, print it, STOP (you resolve, re-run)
#    4. cmake --build               -> on failure: print log tail, STOP
#    5. cmake --install + llama-reinstall
#    6. report the new commit
#
# Re-running picks up where a stop left off. It never leaves a broken or
# half-rebased tree without telling you.
#
# Drift model: we carry local commits, so "up to date with upstream" means
# origin/master is an ANCESTOR of HEAD (not that the hashes are equal), and
# "installed is current" is a prefix test (the installed commit may be 7+
# chars while HEAD is shown at 7).
#
# Usage:
#    llama-update             # check + do it (default)
#    llama-update --check     # just report drift, make no changes
#    llama-update --no-build  # rebase only, skip the rebuild
set -e

SRC_DIR="${LLAMA_SRC_DIR:-$HOME/Documents/code/llama.cpp}"
LOCAL_BIN="$HOME/.local/bin"
BUILD_DIR="$SRC_DIR/build"
PREFIX="$HOME/.local"
LOG="/tmp/llama-update.log"

MODE="do"
[ "$1" = "--check" ] && MODE="check"
[ "$1" = "--no-build" ] && MODE="no-build"

die() { printf '\n[llama-update] %s\n' "$*" >&2; exit 1; }

cd "$SRC_DIR" || die "source dir not found: $SRC_DIR"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $SRC_DIR"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
INSTALLED="$(llama --version 2>/dev/null | grep -oE 'commit [a-f0-9]{7,}' | awk '{print $2}')"
LOCAL="$(git rev-parse --short=7 HEAD)"

echo "[llama-update] branch:        $BRANCH"
echo "[llama-update] installed:     ${INSTALLED:-unknown}"
echo "[llama-update] local source:  $LOCAL"

git fetch origin master --quiet 2>/dev/null || die "git fetch failed (offline?)"
UPSTREAM="$(git rev-parse --short=7 origin/master)"
UPSTREAM_FULL="$(git rev-parse origin/master)"
echo "[llama-update] upstream:      $UPSTREAM"

# --- drift tests -------------------------------------------------------------
behind_upstream=false
if ! git merge-base --is-ancestor "$UPSTREAM_FULL" HEAD 2>/dev/null; then
      behind_upstream=true
fi
installed_current=false
if [ -n "$INSTALLED" ] && [ "${INSTALLED:0:7}" = "$LOCAL" ]; then
      installed_current=true
fi

# --- 2. nothing to do? -------------------------------------------------------
if [ "$behind_upstream" = false ] && [ "$installed_current" = true ]; then
      echo "[llama-update] up to date."
      exit 0
fi

if [ "$MODE" = "check" ]; then
      echo "[llama-update] drift detected (no changes made):"
      [ "$installed_current" = false ] && echo "     - installed ($INSTALLED) != local source ($LOCAL): needs rebuild"
      [ "$behind_upstream" = true ] && echo "     - upstream ($UPSTREAM) is ahead of local source ($LOCAL): needs rebase"
      echo "[llama-update] re-run without --check to update."
      exit 2
fi

# --- 3. rebase onto upstream (only if upstream is ahead) ---------------------
if [ "$behind_upstream" = true ]; then
      echo "[llama-update] rebasing $BRANCH onto origin/master ..."
      if ! git rebase origin/master 2>&1 | tee -a "$LOG"; then
            # a conflicted rebase must be resolved by a human
            git rebase --abort 2>/dev/null || true
            die "REBASE CONFLICT (aborted, tree left clean).
   Resolve it manually, then re-run 'llama-update':
      cd $SRC_DIR
      git rebase origin/master         # fix conflicts as prompted
      git rebase --continue
   Then run:  cmake --build build --config Release -j\$(nproc)
              cmake --install build --prefix \$HOME/.local
              llama-reinstall"
      fi
      LOCAL="$(git rev-parse --short=7 HEAD)"
      echo "[llama-update] rebased to $LOCAL"
fi

# --- 4-5. rebuild + install + rewrap ----------------------------------------
if [ "$MODE" = "no-build" ]; then
      echo "[llama-update] --no-build: skipping rebuild. Run manually:"
      echo "     cmake --build build --config Release -j\$(nproc)"
      echo "     cmake --install build --prefix \$HOME/.local"
      echo "     llama-reinstall"
      exit 0
fi

echo "[llama-update] building (this is the slow step) ..."
if ! cmake --build "$BUILD_DIR" --config Release -j"$(nproc)" 2>&1 | tee -a "$LOG"; then
      die "BUILD FAILED. Last lines of the log:
$(tail -n 25 "$LOG")
   Fix the error, then re-run 'llama-update' (it will skip the rebase if
   already done and just rebuild)."
fi

echo "[llama-update] installing + rewrapping ..."
cmake --install "$BUILD_DIR" --prefix "$PREFIX" >/dev/null 2>&1 || die "cmake --install failed"
"$LOCAL_BIN/llama-reinstall" >/dev/null 2>&1 || die "llama-reinstall failed"

NEW="$(llama --version 2>/dev/null | grep -oE 'commit [a-f0-9]{7,}' | awk '{print $2}')"
echo "[llama-update] done. installed build is now ${NEW:-?}"
[ "${NEW:0:7}" = "$LOCAL" ] || echo "[llama-update] note: installed ($NEW) != source ($LOCAL); re-run if unexpected"