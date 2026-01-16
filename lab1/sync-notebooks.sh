#!/bin/bash
# Sync FROM markdown TO notebook (markdown is authoritative)
# 
# Usage:
#   ./sync-notebooks.sh           - Sync all paired notebooks
#   ./sync-notebooks.sh <file>    - Sync specific file

set -e

if [ -z "$1" ]; then
    echo "🔄 Syncing all notebooks FROM markdown..."
    jupytext --to notebook lab1-*.md
    echo "✓ All notebooks synced from markdown"
else
    echo "🔄 Syncing $1 FROM markdown..."
    jupytext --to notebook "$1"
    echo "✓ Synced $1 from markdown"
fi

echo ""
echo "💡 Tips:"
echo "  - Edit the .md file (markdown is authoritative)"
echo "  - Run this script to update the .ipynb from .md"
echo "  - nbstripout will strip outputs before git commit"
