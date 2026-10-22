#!/usr/bin/env bash
# Import the SonarSource language analyzers into a running SonarQube pod, the same
# way a customer would (docs/sonarqube-plugin-import-plan.md). The released plugins
# image no longer bundles them (SSALv1), and no image of ours carries
# them either, so every test that needs to analyse code runs this after deployment.
#
# Usage: import-official-plugins.sh <namespace> <sonarqube-url> <admin-user> <admin-password>
#
# The release must keep plugins.deleteDefaultPlugins=false (the chart default), otherwise the
# container start script removes the imported JARs on the next pod start.
#
# Env:
#   MAVEN_REPO_URL  where to download the JARs from (default: Maven Central)
#   MANIFEST        analyzer list with versions, default hack/official-plugins-26.1.txt
#   CONTAINER       container name (default: sonarqube)
# <sonarqube-url> is kept for the callers' sake; the checks run inside the pod.
set -euo pipefail

NAMESPACE=${1:?namespace required}
# shellcheck disable=SC2034  # kept for callers; the checks run inside the pod
SONAR_URL=${2:?sonarqube url required}
SONAR_USER=${3:?admin user required}
SONAR_PWD=${4:?admin password required}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Inside the test image everything lives under /app; from a checkout, relative to the repo.
first_existing() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
MANIFEST=${MANIFEST:-$(first_existing "$SCRIPT_DIR/../../hack/official-plugins-26.1.txt" /app/hack/official-plugins-26.1.txt)}
[ -f "${MANIFEST:-}" ] || { echo "official-plugins-26.1.txt not found (set MANIFEST)" >&2; exit 1; }

MAVEN_REPO_URL=${MAVEN_REPO_URL:-https://repo1.maven.org/maven2}
CONTAINER=${CONTAINER:-sonarqube}
# SonarQube 26.1 status poll: 120 x 5s, same budget as wait-for-up.sh.
READY_ATTEMPTS=${READY_ATTEMPTS:-120}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
K="kubectl -n $NAMESPACE"

find_pod() {
  # newest running, non-terminating pod that has the SonarQube container
  $K get pods -o json | jq -r --arg c "$CONTAINER" '
    [.items[] | select(.status.phase == "Running" and .metadata.deletionTimestamp == null
                       and any(.spec.containers[]; .name == $c))]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

wait_up() {
  local pod=$1 i status
  for i in $(seq 1 "$READY_ATTEMPTS"); do
    status=$($K exec "$pod" -c "$CONTAINER" -- curl -s --max-time 10 http://localhost:9000/api/system/status 2>/dev/null \
      | sed -n 's/.*"status":"\([A-Z_]*\)".*/\1/p' || true)
    echo "import-plugins: wait UP (${i}/${READY_ATTEMPTS}) pod=${pod} status=${status:-<none>}"
    [ "$status" = "UP" ] && return 0
    sleep 5
  done
  echo "import-plugins: timed out waiting for $pod to be UP" >&2
  return 1
}

POD=$(find_pod)
[ -n "$POD" ] || { echo "no running SonarQube pod in $NAMESPACE" >&2; exit 1; }
wait_up "$POD"

# sonar-javascript-plugin's `multi` classifier has no linux-arm64 Node runtime.
ARCH=$($K exec "$POD" -c "$CONTAINER" -- uname -m)
case "$ARCH" in aarch64|arm64) JS_CLASSIFIER=linux-arm64 ;; *) JS_CLASSIFIER= ;; esac

# 1. download + verify against the .sha1 Maven Central publishes next to each JAR
mkdir -p "$WORK/plugins"
expected=0
while IFS=: read -r group artifact version classifier; do
  [[ -z "${group:-}" || "$group" == \#* ]] && continue
  if [ "$artifact" = "sonar-javascript-plugin" ] && [ -n "$JS_CLASSIFIER" ]; then classifier=$JS_CLASSIFIER; fi
  file="${artifact}-${version}${classifier:+-${classifier}}.jar"
  url="${MAVEN_REPO_URL}/${group//.//}/${artifact}/${version}/${file}"
  echo "import-plugins: download $url"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 600 -o "$WORK/plugins/$file" "$url"
  want=$(curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 600 "$url.sha1" | cut -c1-40)
  echo "$want  $file" > "$WORK/plugins/$file.sha1"
  (cd "$WORK/plugins" && sha1sum -c "$file.sha1")
  rm -f "$WORK/plugins/$file.sha1"
  expected=$((expected + 1))
done < "$MANIFEST"
[ "$expected" -gt 0 ] || { echo "no analyzers listed in $MANIFEST" >&2; exit 1; }
(cd "$WORK/plugins" && sha256sum ./*.jar | sed 's#\./##') > "$WORK/official-plugins.sha256"
tar -czf "$WORK/plugins.tgz" -C "$WORK/plugins" .
[ "$(ls "$WORK"/plugins/*.jar | wc -l | tr -d ' ')" -eq "$expected" ] \
  || { echo "downloaded JAR count != manifest entries ($expected)" >&2; exit 1; }

# 2. copy into the pod and install (steps 4-5 of the import plan)
copy_and_install() {
  local pod=$1
  $K cp "$WORK/plugins.tgz" "$pod:/tmp/plugins.tgz" -c "$CONTAINER"
  $K cp "$WORK/official-plugins.sha256" "$pod:/tmp/official-plugins.sha256" -c "$CONTAINER"
  $K exec "$pod" -c "$CONTAINER" -- sh -eu -c '
    HOME_DIR=${SONARQUBE_HOME:-/opt/sonarqube}
    incoming=$(mktemp -d)
    tar -xzf /tmp/plugins.tgz -C "$incoming"
    (cd "$incoming" && sha256sum -c /tmp/official-plugins.sha256)
    cp "$incoming"/*.jar "$HOME_DIR/extensions/plugins/"
    chmod 0644 "$HOME_DIR"/extensions/plugins/*.jar
    rm -rf "$incoming" /tmp/plugins.tgz /tmp/official-plugins.sha256
  '
}
copy_and_install "$POD"

# 3. restart so SonarQube loads them (extensions/plugins must be on a persistent volume,
#    as the import plan requires)
$K delete pod "$POD" --wait=true
for _ in $(seq 1 60); do
  NEW=$(find_pod || true)
  [ -n "$NEW" ] && [ "$NEW" != "$POD" ] && break
  sleep 5
done
[ -n "${NEW:-}" ] && [ "$NEW" != "$POD" ] || { echo "replacement pod did not appear" >&2; exit 1; }
$K wait --for=condition=Ready "pod/$NEW" --timeout=600s || true
$K exec "$NEW" -c "$CONTAINER" -- sh -c 'ls /opt/sonarqube/extensions/plugins/sonar-java-plugin-*.jar >/dev/null 2>&1' \
  || { echo "imported JARs are gone after the restart: extensions/plugins is not persistent in this deployment" >&2; exit 1; }
wait_up "$NEW"

# 4. verify through the API (step 7): every imported plugin loaded, no duplicates
# Ask the pod itself: right after the restart the ingress / NodePort path can still answer with an
# error page (the endpoint list lags behind the Ready condition), and that is not what is being tested.
installed=
for i in $(seq 1 30); do
  installed=$($K exec "$NEW" -c "$CONTAINER" -- curl -s --max-time 30 -u "$SONAR_USER:$SONAR_PWD" \
    http://localhost:9000/api/plugins/installed 2>/dev/null || true)
  echo "$installed" | jq -e '.plugins' >/dev/null 2>&1 && break
  echo "import-plugins: /api/plugins/installed not ready (${i}/30): $(echo "$installed" | head -c 120)"
  installed=
  sleep 5
done
[ -n "$installed" ] || { echo "could not read /api/plugins/installed from $NEW" >&2; exit 1; }
echo "$installed" | jq -r '.plugins[] | "\(.key) \(.version)"' | sort
dups=$(echo "$installed" | jq -r '.plugins[].key' | sort | uniq -d)
[ -z "$dups" ] || { echo "duplicate plugins: $dups" >&2; exit 1; }
# every JAR we copied must still be in the new pod's plugin directory
for jar in "$WORK"/plugins/*.jar; do
  $K exec "$NEW" -c "$CONTAINER" -- test -f "/opt/sonarqube/extensions/plugins/$(basename "$jar")" \
    || { echo "$(basename "$jar") is missing from extensions/plugins after the restart" >&2; exit 1; }
done
# ...and the server must have loaded every one of them: /api/plugins/installed reports the
# JAR each plugin came from
loaded=$(echo "$installed" | jq -r '.plugins[].filename')
for jar in "$WORK"/plugins/*.jar; do
  echo "$loaded" | grep -qxF "$(basename "$jar")" \
    || { echo "$(basename "$jar") was copied but SonarQube did not load it" >&2; exit 1; }
done
for key in java python javascript php xml text; do
  echo "$installed" | jq -e --arg k "$key" '.plugins[] | select(.key == $k)' >/dev/null \
    || { echo "analyzer '$key' not loaded after import" >&2; exit 1; }
done
echo "import-plugins: ${expected} analyzers imported into $NEW"
