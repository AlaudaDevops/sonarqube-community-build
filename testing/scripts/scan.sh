#! /bin/bash
set -x

REPO_PATH=$1
shift

echo "Scanning $REPO_PATH"

# use temp dir to avoid data race
TEMP_DIR=$(mktemp -d)
echo "Using temp dir: $TEMP_DIR"
cp -R "$REPO_PATH" "$TEMP_DIR/repo"

# Check if -Dsonar.token is present in the array
SONAR_TOKEN_PRESENT=false

for arg in "$@"; do
    if [[ "$arg" == -Dsonar.token* ]]; then
        SONAR_TOKEN_PRESENT=true
    fi
done

# If neither is present, generate a token
if ! $SONAR_TOKEN_PRESENT; then
    echo "Generating token"

    # Wait for the SonarQube web API to be operational before minting a token.
    # A freshly-deployed instance reports STARTING while the DB migration / ES
    # come up and the change-admin-password post-install hook runs; generating a
    # token then returns an empty body and the scan fails (flaky per-scenario).
    for i in $(seq 1 60); do
        STATUS=$(curl -s -k "${SONAR_HOST}/api/system/status" | jq -r '.status // empty')
        echo "SonarQube status ($i/60): ${STATUS:-<none>}"
        [ "$STATUS" = "UP" ] && break
        sleep 5
    done

    # Retry token generation: the admin password (set by the post-install hook)
    # may still be propagating even after status=UP. Each name must be unique.
    TOKEN=""
    for i in $(seq 1 12); do
        url="${SONAR_HOST}/api/user_tokens/generate?name=my-token-$(date +%s)-$i"
        RESP=$(curl -s -k -X POST -u "${SONAR_USER}:${SONAR_PWD}" "$url")
        TOKEN=$(echo "$RESP" | jq -r '.token // empty')
        [ -n "$TOKEN" ] && break
        echo "token attempt $i/12 failed: $(echo "$RESP" | head -c 200)"
        sleep 5
    done
    if [ -z "$TOKEN" ]; then
        echo "Failed to generate token"
        exit 1
    fi
    set -- "$@" "-Dsonar.token=$TOKEN"
fi

cd "$TEMP_DIR/repo"
echo "Running command: $@"
eval "$@"
