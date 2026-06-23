#!/bin/bash
set -euo pipefail

# Sync .trivyignore from the Thanos exemptions API.
#
# Usage:
#   ./hack/sync-trivyignore.sh [--plugin PLUGIN] [--branch BRANCH] [--api-host HOST] [--dry-run]
#
# Resolution order for each setting:
#   1. CLI flag
#   2. environment variable (loaded from .env at the repo root if present)
#   3. built-in default
#
# THANOS_PLUGIN must be confirmed once with the Thanos owner — the API returns
# `{"data":[]}` for any plugin name (existent or not), so a typo is silent.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIVYIGNORE="$REPO_ROOT/.trivyignore"

# Resolution order:
#   1. CLI flag
#   2. environment variable (loaded from .env if present)
#   3. (BRANCH only) the current git branch
# THANOS_API_HOST and THANOS_PLUGIN have no built-in default; set them in .env
# (see .env.example) or via CLI.

PLUGIN=""
BRANCH=""
API_HOST=""
DRY_RUN=false

# shellcheck disable=SC1091
[ -f "$REPO_ROOT/.env" ] && source "$REPO_ROOT/.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin)   PLUGIN="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    --api-host) API_HOST="$2"; shift 2 ;;
    --api-key)  API_KEY="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: sync-trivyignore.sh [--plugin PLUGIN] [--branch BRANCH] [--api-host HOST] [--dry-run]

  --plugin PLUGIN   Thanos plugin name   (default: $THANOS_PLUGIN from .env)
  --branch BRANCH   Thanos branch        (default: $THANOS_BRANCH from .env, else current git branch)
  --api-host HOST   Thanos API host      (default: $THANOS_API_HOST from .env)
  --api-key KEY     Thanos API key       (default: $THANOS_API_KEY from .env)
  --dry-run         Print the rendered .trivyignore to stdout instead of writing it
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

PLUGIN="${PLUGIN:-${THANOS_PLUGIN:-}}"
BRANCH="${BRANCH:-${THANOS_BRANCH:-$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)}}"
API_HOST="${API_HOST:-${THANOS_API_HOST:-}}"
API_KEY="${API_KEY:-${THANOS_API_KEY:-}}"

if [ -z "$API_HOST" ]; then
  echo "ERROR: Thanos API host not set. Define THANOS_API_HOST in .env (see .env.example) or pass --api-host" >&2
  exit 1
fi
if [ -z "$PLUGIN" ]; then
  echo "ERROR: Thanos plugin name not set. Define THANOS_PLUGIN in .env (see .env.example) or pass --plugin" >&2
  exit 1
fi
if [ -z "$BRANCH" ]; then
  echo "ERROR: Thanos branch not resolvable. Define THANOS_BRANCH in .env or pass --branch" >&2
  exit 1
fi
if [ -z "$API_KEY" ]; then
  echo "ERROR: Thanos API key not set. Define THANOS_API_KEY in .env (see .env.example) or pass --api-key" >&2
  exit 1
fi

API_URL="https://${API_HOST}/api/v1/plugins/${PLUGIN}/branches/${BRANCH}/exemptions?issue_type=vulnerability"

echo "==> Fetching exemptions from $API_URL"
RESPONSE=$(curl -sf --max-time 30 "$API_URL" -H "Authorization: Bearer $API_KEY") || {
  echo "ERROR: failed to fetch exemptions from $API_URL" >&2
  exit 1
}

if ! echo "$RESPONSE" | python3 -m json.tool > /dev/null 2>&1; then
  echo "ERROR: invalid JSON response" >&2
  exit 1
fi

CONTENT=$(THANOS_PLUGIN="$PLUGIN" THANOS_BRANCH="$BRANCH" python3 <(cat <<'PY'
import json, os, sys
from collections import defaultdict

plugin = os.environ["THANOS_PLUGIN"]
branch = os.environ["THANOS_BRANCH"]
data = json.loads(sys.stdin.read())
exemptions = data if isinstance(data, list) else data.get("data") or data.get("items") or data.get("exemptions") or []

print("# Trivy ignore list synced from Thanos.")
print(f"# plugin: {plugin}   branch: {branch}")
print("# Re-run ./hack/sync-trivyignore.sh to refresh.")
print()

if not exemptions:
    print("# (no approved exemptions for this branch)")
    sys.exit(0)

groups = defaultdict(list)
for item in exemptions:
    issue = item.get("issue_data", {}) or {}
    cve = item.get("issue_id") or issue.get("id") or item.get("id") or ""
    if not cve:
        continue
    severity = (issue.get("severity") or item.get("severity") or "Unknown").upper()
    reason = item.get("reason") or item.get("description") or "No reason provided"
    purl = issue.get("purl") or ""
    component = item.get("component") or item.get("package") or purl or "Other"
    groups[component].append((cve, severity, reason.strip().splitlines()[0]))

for component in sorted(groups):
    print("# " + "=" * 60)
    print(f"# {component}")
    print("# " + "=" * 60)
    for cve, sev, reason in sorted(set(groups[component])):
        print(f"# [{sev}] {reason}")
        print(cve)
        print()
PY
) <<<"$RESPONSE")

if [ -z "$CONTENT" ]; then
  echo "==> Empty response — keeping existing .trivyignore"
  exit 0
fi

if [ "$DRY_RUN" = true ]; then
  echo "==> Dry run — would write:"
  echo "----------------------------------------"
  echo "$CONTENT"
  echo "----------------------------------------"
  exit 0
fi

echo "$CONTENT" > "$TRIVYIGNORE"
CVE_COUNT=$(grep -cE '^(CVE-|GHSA-)' "$TRIVYIGNORE" 2>/dev/null || true)
echo "==> Wrote $TRIVYIGNORE ($CVE_COUNT entries)"

if git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
  if git -C "$REPO_ROOT" diff --quiet -- "$TRIVYIGNORE" 2>/dev/null; then
    echo "==> No changes since last sync"
  else
    echo "==> Changed — review with: git diff .trivyignore"
  fi
fi
