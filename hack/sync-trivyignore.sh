#!/bin/bash
set -euo pipefail

# This path is retained as a migration guard for callers of the old sync
# helper. Exemptions are maintained in the checked-in .trivyignore snapshot;
# never fetch or regenerate them automatically.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIVYIGNORE="$REPO_ROOT/.trivyignore"

usage() {
  cat <<'EOF'
Usage: sync-trivyignore.sh --check

The remote exemption sync has been retired. Maintain .trivyignore in the
repository and review changes manually.
EOF
}

if [[ "${1:-}" == "--check" && $# -eq 1 ]]; then
  if [[ ! -f "$TRIVYIGNORE" ]]; then
    echo "ERROR: .trivyignore is missing from the repository" >&2
    exit 1
  fi
  echo "==> Using checked-in exemption snapshot: $TRIVYIGNORE"
  exit 0
fi

usage >&2
echo "ERROR: remote exemption synchronization is disabled; edit .trivyignore manually after review" >&2
exit 2
