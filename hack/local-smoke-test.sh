#!/bin/bash
set -euo pipefail

# End-to-end smoke test for a locally-built SonarQube image:
#   1. Boot it against a throwaway Postgres on a private docker network.
#   2. Wait for /api/system/status == UP.
#   3. Grep the container logs for known-fatal patterns Trivy can't see.
#   4. Re-run Trivy against both images and assert a vulnerability budget.
#   5. Drive a real SonarQube analysis against testing/repos/python-example
#      using the official sonarsource/sonar-scanner-cli image, then fetch the
#      project measures and assert ncloc > 0 + analysis status SUCCESS.
#
# Step 5 is the only thing that catches "the image came up but it can't
# actually analyse code anymore" regressions (broken plugin classpath,
# missing scanner endpoints, etc.).
#
# Usage:
#   ./hack/local-smoke-test.sh [--main-image IMG] [--plugin-image IMG]
#                              [--max-vulns N] [--max-severity SEV]
#                              [--timeout SECONDS]
#                              [--scan-project-dir PATH] [--scan-project-key KEY]
#                              [--scanner-image IMG] [--skip-scan]
#                              [--keep]
#
# Defaults:
#   --main-image        sonarqube-main:local-fix
#   --plugin-image      sonarqube-plugins:local-fix
#   --max-vulns         0          (vulnerability budget)
#   --max-severity      ""         (empty = consider every severity)
#   --timeout           420        (seconds to wait for SonarQube to be UP)
#   --scan-project-dir  testing/repos/python-example   (relative to repo root)
#   --scan-project-key  smoke-<basename of project dir>
#   --scanner-image     sonarsource/sonar-scanner-cli:latest
#   --skip-scan         skip step 5 (trivy-only smoke)
#   --keep              leave containers running on exit (useful for manual poking)
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
SCAN_PROJECT_DIR="testing/repos/python-example"
SCAN_PROJECT_KEY=""
SCANNER_IMAGE="sonarsource/sonar-scanner-cli:latest"
SKIP_SCAN=false
NETWORK="sonar-smoke-net"
PG_CONTAINER="sonar-smoke-pg"
SQ_CONTAINER="sonar-smoke"
ADMIN_PASSWORD="AlaudaDevops!SmokeTest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --main-image)        MAIN_IMAGE="$2"; shift 2 ;;
    --plugin-image)      PLUGIN_IMAGE="$2"; shift 2 ;;
    --max-vulns)         MAX_VULNS="$2"; shift 2 ;;
    --max-severity)      MAX_SEVERITY="$2"; shift 2 ;;
    --timeout)           TIMEOUT="$2"; shift 2 ;;
    --scan-project-dir)  SCAN_PROJECT_DIR="$2"; shift 2 ;;
    --scan-project-key)  SCAN_PROJECT_KEY="$2"; shift 2 ;;
    --scanner-image)     SCANNER_IMAGE="$2"; shift 2 ;;
    --skip-scan)         SKIP_SCAN=true; shift ;;
    --keep)              KEEP=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: local-smoke-test.sh [options]

  --main-image        IMG  SonarQube image to smoke-test (default: sonarqube-main:local-fix)
  --plugin-image      IMG  Plugin image to scan alongside (default: sonarqube-plugins:local-fix)
  --max-vulns         N    Fail if Trivy reports more than N vulnerabilities (default: 0)
  --max-severity      SEV  Restrict the scan to severities >= SEV (empty = all severities)
  --timeout           SEC  Seconds to wait for SonarQube to be operational (default: 420)
  --scan-project-dir  DIR  Path (relative to repo root) of the project to analyse with sonar-scanner
                            (default: testing/repos/python-example)
  --scan-project-key  KEY  Project key to use in SonarQube (default: smoke-<basename of dir>)
  --scanner-image     IMG  Scanner CLI image (default: sonarsource/sonar-scanner-cli:latest)
  --skip-scan              Skip the SonarQube analysis step (trivy + boot only)
  --keep                   Leave containers running on exit (otherwise auto-clean)
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SCAN_PROJECT_KEY" ]; then
  SCAN_PROJECT_KEY="smoke-$(basename "$SCAN_PROJECT_DIR")"
fi

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

if [ "$SKIP_SCAN" = true ]; then
  echo "==> --skip-scan set: skipping SonarQube analysis step."
  echo "==> PASS — image is operational and vulnerability budget is met."
  exit 0
fi

# --- Step 5: drive a real SonarQube analysis -------------------------------

PROJECT_PATH="${REPO_ROOT}/${SCAN_PROJECT_DIR}"
[ -d "$PROJECT_PATH" ] || { echo "ERROR: scan project dir not found: $PROJECT_PATH" >&2; exit 1; }

echo "==> Initialising admin credentials"
# First call resets default admin/admin; subsequent calls would 401 — that's expected
# after a previous run reused the same Postgres volume, so swallow it and try the
# already-rotated password before giving up.
if ! curl -fsS -u admin:admin -X POST \
       "http://localhost:19000/api/users/change_password?login=admin&previousPassword=admin&password=${ADMIN_PASSWORD}" \
       >/dev/null 2>&1; then
  if ! curl -fsS -u "admin:${ADMIN_PASSWORD}" "http://localhost:19000/api/system/ping" >/dev/null 2>&1; then
    echo "==> Cannot authenticate to SonarQube as admin (default password not 'admin' and rotated password not '${ADMIN_PASSWORD}')." >&2
    exit 1
  fi
fi

echo "==> Generating analysis token"
TOKEN=$(curl -fsS -u "admin:${ADMIN_PASSWORD}" -X POST \
  "http://localhost:19000/api/user_tokens/generate?name=smoke-$(date +%s)&type=USER_TOKEN" \
  | jq -r '.token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "==> Failed to generate user token" >&2
  exit 1
fi

echo "==> Running sonar-scanner against ${SCAN_PROJECT_DIR} (key=${SCAN_PROJECT_KEY})"
docker run --rm --network "$NETWORK" \
  ${PLATFORM:+--platform "$PLATFORM"} \
  -v "${PROJECT_PATH}:/usr/src" \
  -e SONAR_HOST_URL="http://${SQ_CONTAINER}:9000" \
  -e SONAR_TOKEN="$TOKEN" \
  "$SCANNER_IMAGE" \
  -Dsonar.projectKey="$SCAN_PROJECT_KEY" \
  -Dsonar.projectName="Smoke ${SCAN_PROJECT_KEY}" \
  -Dsonar.scm.disabled=true

echo "==> Waiting for compute engine to process the analysis"
ce_deadline=$(( $(date +%s) + 180 ))
ce_status="NONE"
while :; do
  if [ "$(date +%s)" -ge "$ce_deadline" ]; then
    echo "==> Timed out waiting for compute engine" >&2
    exit 1
  fi
  ce_json=$(curl -fsS -u "${TOKEN}:" \
    "http://localhost:19000/api/ce/component?component=${SCAN_PROJECT_KEY}" || true)
  pending=$(echo "$ce_json" | jq -r '.queue | length' 2>/dev/null || echo 0)
  ce_status=$(echo "$ce_json" | jq -r '.current.status // "NONE"' 2>/dev/null || echo "NONE")
  if [ "$pending" = "0" ]; then
    case "$ce_status" in
      SUCCESS) echo "    compute engine: SUCCESS"; break ;;
      FAILED|CANCELED) echo "==> Analysis ended with $ce_status" >&2; exit 1 ;;
      NONE) sleep 3 ;;          # task hasn't appeared yet
      *)    sleep 3 ;;
    esac
  else
    sleep 3
  fi
done

echo "==> Fetching project measures"
measures_json=$(curl -fsS -u "${TOKEN}:" \
  "http://localhost:19000/api/measures/component?component=${SCAN_PROJECT_KEY}&metricKeys=ncloc,bugs,vulnerabilities,code_smells,coverage,security_hotspots")
echo "$measures_json" | jq -r '.component.measures[] | "    \(.metric)=\(.value)"'

ncloc=$(echo "$measures_json" | jq -r '.component.measures[] | select(.metric=="ncloc") | .value')
if [ -z "$ncloc" ] || ! [ "$ncloc" -gt 0 ] 2>/dev/null; then
  echo "==> Expected ncloc > 0, got '${ncloc}' — analysis may not have parsed any source." >&2
  exit 1
fi

echo "==> PASS — image is operational, vulnerability budget met, and SonarQube analysis succeeded (ncloc=${ncloc})."
