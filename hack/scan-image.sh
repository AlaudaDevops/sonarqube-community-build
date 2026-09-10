#!/bin/bash
set -euo pipefail

# Run trivy against one or more local images using the project's standard flags.
#
# Usage:
#   ./hack/scan-image.sh [--image IMAGE]... [--format FMT] [--full] [--out PATH] [--summary-only]
#
# Defaults:
#   - severity         : ALL (Trivy CLI doesn't filter, but we surface every level)
#   - --ignore-unfixed : on (mirrors .tekton/pipeline/sonar-image-build.yaml)
#   - --ignorefile     : ./.trivyignore if present
#   - format           : table  (use --format json --out FILE for machine-readable scans)
#
# When more than one --image is passed, the script prints a per-image summary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIVYIGNORE="$REPO_ROOT/.trivyignore"

IMAGES=()
FORMAT="table"
IGNORE_UNFIXED="--ignore-unfixed"
OUT=""
SUMMARY_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)        IMAGES+=("$2"); shift 2 ;;
    --format)       FORMAT="$2"; shift 2 ;;
    --full)         IGNORE_UNFIXED=""; shift ;;
    --out)          OUT="$2"; shift 2 ;;
    --summary-only) SUMMARY_ONLY=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--image IMAGE]... [--format FMT] [--full] [--out PATH] [--summary-only]

  --image IMAGE     Image to scan (repeat for multiple targets).
                    Default: both production tags from chart/values.yaml.
  --format FMT      table | json | sarif (default: table)
  --full            Include vulnerabilities without a fix version
  --out PATH        Write trivy output to PATH instead of stdout (single-image runs)
  --summary-only    Print only "Target | Class | vulns" lines (no per-CVE detail)
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC1091
[ -f "$REPO_ROOT/.env" ] && source "$REPO_ROOT/.env"

# Trivy does not resolve Docker CLI contexts automatically.
if [ -z "${DOCKER_HOST:-}" ] && command -v docker > /dev/null; then
  DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || DOCKER_HOST=""
  export DOCKER_HOST
fi

if [ "${#IMAGES[@]}" -eq 0 ]; then
  if ! command -v yq > /dev/null; then
    echo "ERROR: --image not given and yq missing — cannot parse chart/values.yaml" >&2
    exit 1
  fi
  REGISTRY="${HARBOR_REGISTRY_HOST:-$(yq -r '.global.registry.address' "$REPO_ROOT/chart/values.yaml")}"
  if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "null" ]; then
    echo "ERROR: could not read registry from chart/values.yaml" >&2
    exit 1
  fi
  for KEY in sonarqube pluginPackage; do
    REPOSITORY=$(yq -r ".global.images.${KEY}.repository" "$REPO_ROOT/chart/values.yaml")
    TAG=$(yq -r ".global.images.${KEY}.tag" "$REPO_ROOT/chart/values.yaml")
    if [ -z "$REPOSITORY" ] || [ "$REPOSITORY" = "null" ] || [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
      echo "ERROR: could not read $KEY repository/tag from chart/values.yaml" >&2
      exit 1
    fi
    IMAGES+=("${REGISTRY%/}/${REPOSITORY}:${TAG}")
  done
fi

IGNORE_FLAG=""
if [ -f "$TRIVYIGNORE" ]; then
  IGNORE_FLAG="--ignorefile $TRIVYIGNORE"
  IGNORED=$(awk '/^(CVE-|GHSA-)/ { count++ } END { print count+0 }' "$TRIVYIGNORE")
  echo "==> Using $TRIVYIGNORE ($IGNORED entries)"
fi

for IMAGE in "${IMAGES[@]}"; do
  echo "==> Scanning $IMAGE"
  if [ "$SUMMARY_ONLY" = true ]; then
    JSON=$(mktemp)
    trivy image $IGNORE_FLAG $IGNORE_UNFIXED --scanners vuln --format json --output "$JSON" "$IMAGE"
    jq -r '.Results[]? | "  \(.Target | sub(".*/"; "")) | \(.Class) | vulns: \((.Vulnerabilities//[]) | length)"' "$JSON"
    rm -f "$JSON"
  elif [ -n "$OUT" ] && [ "${#IMAGES[@]}" -eq 1 ]; then
    trivy image $IGNORE_FLAG $IGNORE_UNFIXED --scanners vuln --format "$FORMAT" --output "$OUT" "$IMAGE"
    echo "    -> $OUT"
  else
    trivy image $IGNORE_FLAG $IGNORE_UNFIXED --scanners vuln --format "$FORMAT" "$IMAGE"
  fi
  echo
done
