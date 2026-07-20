#!/bin/sh
# install.sh
# One-line bootstrap for corpus-engine on macOS (experimental):
#
#   curl -fsSL https://github.com/marcdlagarde/corpus-engine/releases/latest/download/install.sh | sh
#
# corpus-engine is PowerShell-based. On macOS the importers, curation, and
# corpus-ask run under PowerShell 7 (pwsh). The live Claude Code capture hook
# and the scheduled backup task are still Windows-only; on macOS your Claude
# Code history is backfilled from ~/.claude/history.jsonl on every refresh
# instead, so you lose nothing except full pasted-content capture.
#
# This script only clones/updates ~/corpus-engine and runs setup.ps1.
# It installs nothing else; missing prerequisites are printed as commands
# for you to review and run yourself.

set -eu

REPO_URL="https://github.com/marcdlagarde/corpus-engine"
DEST="${CORPUS_ENGINE_HOME:-$HOME/corpus-engine}"
# Install the latest RELEASE by default (deliberately tagged + reviewed code),
# falling back to main if the API is unreachable. CORPUS_ENGINE_REF overrides
# with any tag or branch.
REF="${CORPUS_ENGINE_REF:-}"
if [ -z "$REF" ]; then
    REF=$(curl -fsSL https://api.github.com/repos/marcdlagarde/corpus-engine/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/\1/')
    [ -n "$REF" ] || REF=main
fi

echo ""
echo "===== corpus-engine bootstrap (macOS, experimental) ====="
echo "Install location: $DEST"
echo ""

if ! command -v pwsh >/dev/null 2>&1; then
    echo "PowerShell 7 (pwsh) is required. Install it, then re-run this script:"
    echo "  brew install powershell/tap/powershell"
    echo "(No Homebrew? https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos)"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "git is required. Run 'xcode-select --install' (or 'brew install git'), then re-run."
    exit 1
fi

if [ -d "$DEST/.git" ]; then
    if git -C "$DEST" symbolic-ref -q HEAD >/dev/null 2>&1; then
        echo "Existing clone found - updating..."
        git -C "$DEST" pull --ff-only
    else
        # Tag-pinned clones are detached; there is nothing to pull.
        echo "Existing clone is pinned to a release tag - leaving it as-is."
        echo "To install a different version: remove $DEST, set CORPUS_ENGINE_REF, re-run."
    fi
elif [ -e "$DEST" ]; then
    echo "$DEST exists but is not a corpus-engine clone. Move it aside or set"
    echo "CORPUS_ENGINE_HOME to a different location, then re-run."
    exit 1
else
    git clone --branch "$REF" "$REPO_URL" "$DEST"
fi

echo ""
pwsh -NoProfile -File "$DEST/setup.ps1"

echo ""
pwsh -NoProfile -File "$DEST/tools/doctor.ps1"
