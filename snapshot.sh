#!/usr/bin/env bash
#
# ============================================================================
#  snapshot.sh  —  Save & restore a Claude.ai code-sandbox working session
# ============================================================================
#
#  WHY THIS EXISTS
#    Claude.ai runs your code in a temporary sandbox. The sandbox container
#    resets on its own (after idle time, a long session, or behind-the-scenes
#    maintenance), and when it does, every file and installed package is wiped
#    and CANNOT be recovered afterward. This script packages the full working
#    state into a single .tar.gz so it can be rebuilt in a fresh sandbox later.
#
#  ----------------------------------------------------------------------------
#  TO SAVE YOUR WORK   (run inside a Claude.ai chat where you've been working)
#  ----------------------------------------------------------------------------
#    Upload this file and paste to Claude:
#      "Run the snapshot.sh I uploaded to save my work. If my files aren't in
#       the default directory, set SNAPSHOT_DIRS to the right path first, then
#       give me the .tar.gz to download."
#    Then DOWNLOAD the .tar.gz it produces and keep it somewhere safe.
#
#  ----------------------------------------------------------------------------
#  TO RESTORE LATER   (in a new chat, or after the sandbox has reset)
#  ----------------------------------------------------------------------------
#    1. Turn ON network access for the chat (in Settings) so packages can
#       reinstall.
#    2. Upload the .tar.gz snapshot and paste to Claude:
#       "I uploaded a snapshot archive made by snapshot.sh. Extract it and run
#        the restore.sh inside it to rebuild my files and reinstall packages,
#        then read STATE.md and tell me where we left off."
#    (Each archive also contains a README_RESTORE.txt repeating these steps.)
#
#  NOTE TO CLAUDE: This file and the archives it creates implement a
#  save/restore workflow for the ephemeral sandbox. To snapshot: run this
#  script and return the resulting .tar.gz. To restore: extract an uploaded
#  snapshot and run its restore.sh, then summarize STATE.md for the user.
#
#  Usage:   bash snapshot.sh [label]
#  Env:     SNAPSHOT_DIRS   dirs/files to capture   (default: current dir, $PWD)
#           OUT_DIR         where to write archive  (default: outputs dir)
# ============================================================================
set -euo pipefail

SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
LABEL="${1:-snapshot}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="${LABEL}_${STAMP}"
SNAPSHOT_DIRS="${SNAPSHOT_DIRS:-$PWD}"

if [ -z "${OUT_DIR:-}" ]; then
  if [ -d /mnt/user-data/outputs ]; then OUT_DIR=/mnt/user-data/outputs; else OUT_DIR="$PWD"; fi
fi
mkdir -p "$OUT_DIR"

STAGE="$(mktemp -d)"
BUNDLE="$STAGE/$NAME"
mkdir -p "$BUNDLE/files" "$BUNDLE/meta"

echo "==> Capturing files from: $SNAPSHOT_DIRS"
# Files are stored under their absolute path (leading / stripped) so restore is faithful.
for p in $SNAPSHOT_DIRS; do
  if [ -d "$p" ]; then
    ap="$(realpath "$p")"
    mkdir -p "$BUNDLE/files/${ap#/}"
    ( cd "$ap" && tar --exclude='./node_modules' --exclude='*/node_modules' \
                      --exclude='./.git' --exclude='__pycache__' --exclude='*.pyc' \
                      -cf - . ) | ( cd "$BUNDLE/files/${ap#/}" && tar -xf - )
  elif [ -f "$p" ]; then
    ap="$(realpath "$p")"
    mkdir -p "$BUNDLE/files/$(dirname "${ap#/}")"
    cp -a "$ap" "$BUNDLE/files/$(dirname "${ap#/}")/"
  else
    echo "    (skip, not found: $p)"
  fi
done

echo "==> Recording environment manifest"
{
  echo "# Environment captured ${STAMP} (UTC)"
  echo;  echo "## OS";     uname -a 2>&1 || true
  echo;  echo "## Python"; (python3 --version 2>&1) || echo "python3: not found"
  echo;  echo "## Node";   (node --version 2>&1) || echo "node: not installed"
  echo;  echo "## Captured paths"; echo "$SNAPSHOT_DIRS"
} > "$BUNDLE/meta/env-info.txt"

if   command -v pip3 >/dev/null 2>&1; then pip3 freeze > "$BUNDLE/meta/requirements.txt" 2>/dev/null || true
elif command -v pip  >/dev/null 2>&1; then pip  freeze > "$BUNDLE/meta/requirements.txt" 2>/dev/null || true; fi
command -v npm      >/dev/null 2>&1 && npm ls --all --json   > "$BUNDLE/meta/npm-packages.json" 2>/dev/null || true
command -v apt-mark >/dev/null 2>&1 && apt-mark showmanual   > "$BUNDLE/meta/apt-manual.txt"    2>/dev/null || true

echo "==> Building file inventory (sha256)"
( cd "$BUNDLE/files" && find . -type f -print0 | xargs -0 sha256sum 2>/dev/null ) > "$BUNDLE/meta/inventory.sha256" || true

# Carry over an existing STATE.md if one was captured; otherwise drop in a template.
if ! find "$BUNDLE/files" -iname 'STATE.md' 2>/dev/null | grep -q .; then
  cat > "$BUNDLE/STATE.md" <<'EOF'
# Project state

<!-- Fill this in so a fresh chat (with no memory of this work) can resume cleanly.
     Edit it, then re-run snapshot.sh so the latest version is baked into the bundle. -->

## Goal
What we're ultimately building.

## Current status
Where things stand; what works, what's broken, what's half-done.

## Files
- path/to/file — what it is and why it exists

## Key decisions & parameters
Anything chosen deliberately that must NOT be re-guessed (versions, seeds, configs, API choices).

## Next step
The very next thing to do.
EOF
fi

# Plain-English restore guide, so the archive is usable even with no other context.
cat > "$BUNDLE/README_RESTORE.txt" <<'README_EOF'
HOW TO RESTORE THIS SNAPSHOT
============================

This archive is a saved snapshot of a working session from Claude.ai's code
sandbox. That sandbox is temporary: its container resets and wipes all files and
installed packages, and they can't be recovered afterward. This bundle exists so
the work can be rebuilt in a fresh sandbox.

WHAT'S IN HERE
  files/                 your working files, stored under their original paths
  meta/requirements.txt  Python packages to reinstall
  meta/inventory.sha256  checksums used to verify the restore
  restore.sh             the script that rebuilds everything
  snapshot.sh            the tool that made this bundle (use it to snapshot again)
  STATE.md               plain-English summary of the project and where it stands

TO RESTORE (in a Claude.ai chat):
  1. Upload this entire .tar.gz file.
  2. Enable network access in the chat's Settings (needed so the Python packages
     can be reinstalled).
  3. Paste this to Claude:
       "I've uploaded a snapshot archive made by snapshot.sh. Please extract it
        and run the restore.sh inside it to rebuild my files and reinstall the
        packages, then read STATE.md and tell me where we left off."

TO RESTORE (by hand, if you have a terminal):
       tar -xzf THIS_FILE.tar.gz
       cd THE_EXTRACTED_FOLDER
       bash restore.sh            # restores to original paths
       # or restore under a different folder:  bash restore.sh /some/dir

TO MAKE A NEW SNAPSHOT after doing more work:
  snapshot.sh is included in this bundle. Upload it and ask Claude to run it again.
README_EOF

# Self-copy so the snapshot tool itself survives a reset.
cp "$SELF" "$BUNDLE/snapshot.sh" 2>/dev/null || true

# Embed a restore script so the archive is self-describing.
cat > "$BUNDLE/restore.sh" <<'RESTORE_EOF'
#!/usr/bin/env bash
#
# restore.sh — rebuild a fresh Claude.ai sandbox from this snapshot bundle.
#
# IN A CLAUDE.AI CHAT: upload the .tar.gz this came from and ask Claude to
#   "extract it and run restore.sh, then read STATE.md." Make sure network
#   access is ON first so packages can reinstall. See README_RESTORE.txt.
#
# BY HAND: run from inside the extracted bundle dir:   bash restore.sh [prefix]
#   prefix  Where to restore (default "/", i.e. the original absolute paths).
#           Pass a directory to restore under it instead (useful for testing).
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:-/}"
mkdir -p "$PREFIX"

echo "==> Restoring files under: $PREFIX"
if [ -d "$HERE/files" ]; then
  ( cd "$HERE/files" && tar -cf - . ) | ( cd "$PREFIX" && tar -xf - )
fi

if [ -f "$HERE/meta/requirements.txt" ]; then
  echo "==> Reinstalling Python packages (REQUIRES network access to be ON)"
  pip3 install --break-system-packages -r "$HERE/meta/requirements.txt" 2>/dev/null \
    || pip install --break-system-packages -r "$HERE/meta/requirements.txt" 2>/dev/null \
    || echo "    !! pip install failed — check that network access is enabled."
fi

if [ -f "$HERE/meta/inventory.sha256" ]; then
  echo "==> Verifying restored files"
  ( cd "$PREFIX" && sha256sum -c "$HERE/meta/inventory.sha256" --quiet ) \
    && echo "    OK: all files match the snapshot" \
    || echo "    NOTE: some files differ or are missing (see above)."
fi
echo "==> Done. Open STATE.md to get oriented."
RESTORE_EOF
chmod +x "$BUNDLE/restore.sh"

ARCHIVE="$OUT_DIR/${NAME}.tar.gz"
tar -C "$STAGE" -czf "$ARCHIVE" "$NAME"
rm -rf "$STAGE"

echo
echo "==> Snapshot written to: $ARCHIVE"
du -h "$ARCHIVE" 2>/dev/null | awk '{print "    size: "$1}'
echo "    Restore later: upload this file, extract it, then run restore.sh from inside."
echo "    (Full instructions are in README_RESTORE.txt inside the archive.)"
