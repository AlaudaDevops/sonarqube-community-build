#!/bin/bash
set -euo pipefail

# Smoke-test a locally-built SonarQube image: boot it against a throwaway
# Postgres, wait for ES + Web + CE to come up, then re-scan with Trivy and
# fail unless the image meets the expected vulnerability budget.
#
# Usage:
#   ./hack/local-smoke-test.sh [--main-image IMG] [--plugin-image IMG]
#                              [--max-vulns N] [--max-severity SEV]
#                              [--timeout SECONDS] [--keep]
#
# Defaults:
#   --main-image    sonarqube-main:local-fix
#   --plugin-image  sonarqube-plugins:local-fix
#   --max-vulns     0          (assert this many vulnerabilities or fewer)
#   --max-severity  ""         (empty = consider every severity; or set HIGH,CRITICAL etc.)
#   --timeout       420        (seconds to wait for SonarQube to come up)
#   --keep          do not stop the containers on exit (useful for manual poking)
#
# Notes:
#   - On Apple Silicon, the public Elasticsearch tarball used by the source
#     build only ships x86_64 native libs. To smoke-test there, build with
#     `docker buildx build --platform linux/amd64` and rerun this script with
#     PLATFORM=linux/amd64 (Rosetta must be enabled in Docker Desktop).
#   - The Postgres container is wiped at the end (unless --keep).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MAIN_IMAGE="sonarqube-main:local-fix"
PLUGIN_IMAGE="sonarqube-plugins:local-fix"
MAX_VULNS=0
MAX_SEVERITY=""
TIMEOUT=420
KEEP=false
PLATFORM="${PLATFORM:-}"
NETWORK="sonar-smoke-net"
PG_CONTAINER="sonar-smoke-pg"
SQ_CONTAINER="sonar-smoke"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --main-image)    MAIN_IMAGE="$2"; shift 2 ;;
    --plugin-image)  PLUGIN_IMAGE="$2"; shift 2 ;;
    --max-vulns)     MAX_VULNS="$2"; shift 2 ;;
    --max-severity)  MAX_SEVERITY="$2"; shift 2 ;;
    --timeout)       TIMEOUT="$2"; shift 2 ;;
    --keep)          KEEP=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: local-smoke-test.sh [options]

  --main-image    IMG  SonarQube image to smoke-test (default: sonarqube-main:local-fix)
  --plugin-image  IMG  Plugin image to scan alongside (default: sonarqube-plugins:local-fix)
  --max-vulns     N    Fail if Trivy reports more than N vulnerabilities (default: 0)
  --max-severity  SEV  Restrict the scan to severities >= SEV (empty = all severities)
  --timeout       SEC  Seconds to wait for SonarQube to be operational (default: 420)
  --keep               Leave containers running on exit (otherwise auto-clean)
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

cleanup() {
  if [ "$KEEP" = true ]; then
    echo "==> --keep set: leaving containers running"
    echo "    docker logs $SQ_CONTAINER     # SonarQube"
    echo "    docker logs $PG_CONTAINER     # Postgres"
    return
  fi
  docker rm -f "$SQ_CONTAINER" "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ensure_image() {
  local img="$1"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "ERROR: image not found locally: $img" >&2
    echo "       build with: ./hack/build-images.sh --tag ${img##*:}" >&2
    exit 1
  fi
}

ensure_image "$MAIN_IMAGE"
ensure_image "$PLUGIN_IMAGE"

# --- Step 1: bring up infra -------------------------------------------------

echo "==> Cleaning previous smoke containers (if any)"
docker rm -f "$SQ_CONTAINER" "$PG_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true

echo "==> Creating network $NETWORK"
docker network create "$NETWORK" >/dev/null

echo "==> Starting Postgres ($PG_CONTAINER)"
docker run -d --name "$PG_CONTAINER" --network "$NETWORK" \
  -e POSTGRES_USER=sonar -e POSTGRES_PASSWORD=sonar -e POSTGRES_DB=sonar \
  postgres:16-alpine >/dev/null

# Wait for Postgres ready before launching SonarQube — saves several restarts.
for _ in $(seq 1 30); do
  if docker exec "$PG_CONTAINER" pg_isready -U sonar -d sonar >/dev/null 2>&1; then
    echo "==> Postgres ready"
    break
  fi
  sleep 1
done

echo "==> Starting SonarQube ($SQ_CONTAINER) using $MAIN_IMAGE${PLATFORM:+ (--platform $PLATFORM)}"
docker run -d --name "$SQ_CONTAINER" --network "$NETWORK" \
  ${PLATFORM:+--platform "$PLATFORM"} \
  -p 19000:9000 \
  -e SONAR_JDBC_URL="jdbc:postgresql://${PG_CONTAINER}:5432/sonar" \
  -e SONAR_JDBC_USERNAME=sonar \
  -e SONAR_JDBC_PASSWORD=sonar \
  "$MAIN_IMAGE" >/dev/null

# --- Step 2: wait for /api/system/status == UP ------------------------------

echo "==> Waiting up to ${TIMEOUT}s for SonarQube to be operational..."
deadline=$(( $(date +%s) + TIMEOUT ))
status=""
last_status=""
while :; do
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "==> Timed out waiting for SonarQube" >&2
    docker logs --tail 80 "$SQ_CONTAINER" >&2 || true
    exit 1
  fi

  if ! docker inspect -f '{{.State.Running}}' "$SQ_CONTAINER" 2>/dev/null | grep -q true; then
    echo "==> SonarQube container exited unexpectedly" >&2
    docker logs --tail 80 "$SQ_CONTAINER" >&2 || true
    exit 1
  fi

  status=$(curl -fsS http://localhost:19000/api/system/status 2>/dev/null | jq -r '.status' 2>/dev/null || true)

  if [ -n "$status" ] && [ "$status" != "$last_status" ]; then
    echo "    /api/system/status -> $status"
    last_status="$status"
  fi

  case "$status" in
    UP) echo "==> SonarQube is UP"; break ;;
    DB_MIGRATION_NEEDED|DB_MIGRATION_RUNNING|STARTING|"") sleep 5 ;;
    *) echo "==> Unexpected status: $status" >&2; docker logs --tail 80 "$SQ_CONTAINER" >&2 || true; exit 1 ;;
  esac
done

# --- Step 3: scan logs for known-fatal patterns -----------------------------

echo "==> Inspecting logs for known-fatal patterns"
fatal_lines=$(docker logs "$SQ_CONTAINER" 2>&1 \
  | grep -E "java\.lang\.NoSuchMethodError|java\.lang\.NoClassDefFoundError|java\.lang\.IllegalArgumentException: Invalid Configuration class|UnsatisfiedLinkError" \
  || true)
if [ -n "$fatal_lines" ]; then
  echo "==> Fatal log lines detected:" >&2
  echo "$fatal_lines" | head -20 >&2
  exit 1
fi

# --- Step 4: full Trivy scan and threshold assertion -----------------------

scan_main_json="$(mktemp)"
scan_plugin_json="$(mktemp)"

echo "==> Scanning $MAIN_IMAGE"
"${SCRIPT_DIR}/scan-image.sh" --image "$MAIN_IMAGE" --format json --out "$scan_main_json" >/dev/null
echo "==> Scanning $PLUGIN_IMAGE"
"${SCRIPT_DIR}/scan-image.sh" --image "$PLUGIN_IMAGE" --format json --out "$scan_plugin_json" >/dev/null

count_vulns() {
  local file="$1" sev="$2"
  if [ -z "$sev" ]; then
    jq '[.Results[]?.Vulnerabilities[]?] | length' "$file"
  else
    # SEV is comma-separated severity allowlist (e.g. HIGH,CRITICAL)
    jq --arg sev "$sev" '
      ($sev | ascii_upcase | split(",")) as $allow
      | [.Results[]?.Vulnerabilities[]? | select(.Severity as $s | $allow | index($s))] | length
    ' "$file"
  fi
}

main_count=$(count_vulns "$scan_main_json" "$MAX_SEVERITY")
plugin_count=$(count_vulns "$scan_plugin_json" "$MAX_SEVERITY")
total_count=$((main_count + plugin_count))

echo "==> Trivy results"
echo "    main   ($MAIN_IMAGE)   : $main_count   vulnerabilities${MAX_SEVERITY:+ (severity in $MAX_SEVERITY)}"
echo "    plugin ($PLUGIN_IMAGE) : $plugin_count   vulnerabilities${MAX_SEVERITY:+ (severity in $MAX_SEVERITY)}"
echo "    total                                : $total_count (budget: $MAX_VULNS)"

if [ "$total_count" -gt "$MAX_VULNS" ]; then
  echo "==> FAIL — vulnerability count $total_count exceeds budget $MAX_VULNS" >&2
  echo "    Detailed offenders:" >&2
  for f in "$scan_main_json" "$scan_plugin_json"; do
    jq -r --arg sev "$MAX_SEVERITY" '
      ($sev | ascii_upcase | split(",")) as $allow
      | .Results[]?.Vulnerabilities[]?
      | select($allow | length == 0 or (.Severity as $s | $allow | index($s)))
      | "    [\(.Severity)] \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion // "no fix") (\(.VulnerabilityID))"
    ' "$f" >&2
  done
  rm -f "$scan_main_json" "$scan_plugin_json"
  exit 1
fi

rm -f "$scan_main_json" "$scan_plugin_json"
echo "==> PASS — image is operational and vulnerability budget is met."
