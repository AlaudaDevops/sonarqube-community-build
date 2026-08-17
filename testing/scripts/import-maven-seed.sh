#!/usr/bin/env bash

set -u

MAVEN_SEED_DIR=${MAVEN_SEED_DIR:-/opt/sonarqube-e2e/maven-seed}
IMPORT_RETRIES=${IMPORT_RETRIES:-3}
IMPORT_RETRY_DELAY_SECONDS=${IMPORT_RETRY_DELAY_SECONDS:-1}
CURL_CONNECT_TIMEOUT_SECONDS=${CURL_CONNECT_TIMEOUT_SECONDS:-10}
CURL_MAX_TIME_SECONDS=${CURL_MAX_TIME_SECONDS:-300}
NEXUS_UPLOAD_CONCURRENCY=${NEXUS_UPLOAD_CONCURRENCY:-4}

die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

require_variable() {
    variable_name=$1
    variable_value=${!variable_name-}
    [ -n "$variable_value" ] || die "$variable_name is required"
}

for required_variable in NEXUS_URL NEXUS_REPOSITORY NEXUS_USERNAME NEXUS_PASSWORD; do
    require_variable "$required_variable"
done

case $IMPORT_RETRIES in
    ''|*[!0-9]*) die 'IMPORT_RETRIES must be a non-negative integer' ;;
esac
case $IMPORT_RETRY_DELAY_SECONDS in
    ''|*[!0-9]*) die 'IMPORT_RETRY_DELAY_SECONDS must be a non-negative integer' ;;
esac

validate_positive_integer() {
    variable_name=$1
    maximum=$2
    value=${!variable_name-}
    case $value in
        ''|*[!0-9]*) die "$variable_name must be a positive integer" ;;
    esac
    [ "$value" -ge 1 ] && [ "$value" -le "$maximum" ] ||
        die "$variable_name must be between 1 and $maximum"
}

validate_positive_integer CURL_CONNECT_TIMEOUT_SECONDS 300
validate_positive_integer CURL_MAX_TIME_SECONDS 3600
validate_positive_integer NEXUS_UPLOAD_CONCURRENCY 16
[ "$CURL_CONNECT_TIMEOUT_SECONDS" -le "$CURL_MAX_TIME_SECONDS" ] ||
    die 'CURL_CONNECT_TIMEOUT_SECONDS must not exceed CURL_MAX_TIME_SECONDS'

valid_optional_port() {
    port=$1
    [ -z "$port" ] && return 0
    [[ $port =~ ^[0-9]{1,5}$ ]] || return 1
    [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ]
}

is_loopback_authority() {
    authority=$1
    case $authority in
        localhost) return 0 ;;
        localhost:*) valid_optional_port "${authority#localhost:}" && [ -n "${authority#localhost:}" ]; return ;;
        '[::1]') return 0 ;;
        '[::1]':*) valid_optional_port "${authority#'[::1]:'}" && [ -n "${authority#'[::1]:'}" ]; return ;;
    esac

    host=${authority%%:*}
    if [ "$host" = "$authority" ]; then
        port=
    else
        port=${authority#*:}
    fi
    [[ $host =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    valid_optional_port "$port" || return 1
    IFS=. read -r first second third fourth <<<"$host"
    [ "$((10#$first))" -le 255 ] && [ "$((10#$second))" -le 255 ] &&
        [ "$((10#$third))" -le 255 ] && [ "$((10#$fourth))" -le 255 ]
}

case $NEXUS_URL in
    https://*) ;;
    http://*)
        # Test-only escape hatch for the loopback mock server.
        [ "${NEXUS_ALLOW_INSECURE_HTTP:-false}" = true ] ||
            die 'NEXUS_URL must use HTTPS (insecure HTTP is test-only)'
        http_authority=${NEXUS_URL#http://}
        http_authority=${http_authority%%/*}
        is_loopback_authority "$http_authority" ||
            die 'insecure HTTP test override is restricted to loopback hosts'
        ;;
    *) die 'NEXUS_URL must use HTTPS' ;;
esac
case ${NEXUS_URL#*://} in
    *@*) die 'NEXUS_URL must not contain credentials' ;;
esac

repository_dir=$MAVEN_SEED_DIR/repository
[ -d "$repository_dir" ] || die "repository directory is missing from $MAVEN_SEED_DIR"

uploaded=0
already_present=0
failed=0
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/import-maven-seed.XXXXXX") || die 'cannot create temporary directory'
batch_pids=
stopping=false

cleanup() {
    rm -rf "$work_dir"
}

handle_signal() {
    signal_name=$1
    exit_status=$2
    trap '' INT TERM
    stopping=true
    for worker_pid in $batch_pids; do
        kill -"$signal_name" "$worker_pid" 2>/dev/null || true
    done
    for worker_pid in $batch_pids; do
        wait "$worker_pid" 2>/dev/null || true
    done
    batch_pids=
    exit "$exit_status"
}

trap cleanup EXIT
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

validation_failure() {
    printf 'error: %s\n' "$1" >&2
    printf 'uploaded=0 already-present=0 failed=1\n'
    exit 1
}

artifact_list=$work_dir/artifact-list
: >"$artifact_list"
canonical_repository=$(readlink -f "$repository_dir") || validation_failure 'cannot resolve repository directory'
[ -n "$canonical_repository" ] || validation_failure 'cannot resolve repository directory'
[ ! -L "$repository_dir" ] || validation_failure 'repository directory must not be a symlink'
if find "$repository_dir" -type l -print -quit | grep -q .; then
    validation_failure 'repository contains a symlink'
fi
if find "$repository_dir" ! -type d ! -type f -print -quit | grep -q .; then
    validation_failure 'repository contains a non-regular file'
fi
while IFS= read -r -d '' source_file; do
    canonical_source=$(readlink -f "$source_file") || validation_failure "cannot resolve source path: $source_file"
    case $canonical_source in
        "$canonical_repository"/*) ;;
        *) validation_failure "source path escapes repository: $source_file" ;;
    esac
    relative_path=repository/${source_file#"$repository_dir"/}
    case $relative_path in
        *$'\n'*) validation_failure 'repository paths must not contain newlines' ;;
    esac
    expected_digest=$(sha256sum "$source_file")
    expected_digest=${expected_digest%% *}
    printf '%s  %s\n' "$expected_digest" "$relative_path" >>"$artifact_list"
done < <(find "$repository_dir" -type f -print0 | LC_ALL=C sort -z)
[ -s "$artifact_list" ] || validation_failure 'repository does not contain any artifacts'

url_encode_path() {
    LC_ALL=C
    input=$1
    output=
    while [ -n "$input" ]; do
        character=${input%"${input#?}"}
        input=${input#?}
        case $character in
            [a-zA-Z0-9._~/-]) output=$output$character ;;
            *)
                printf -v encoded '%%%02X' "'$character"
                output=$output$encoded
                ;;
        esac
    done
    printf '%s' "$output"
}

curl_request() {
    method=$1
    url=$2
    output_file=$3
    upload_file=${4:-}
    request_retries=${5:-$IMPORT_RETRIES}
    attempt=0
    maximum_attempts=$((request_retries + 1))
    curl_options=(--silent --show-error --user "$NEXUS_USERNAME:$NEXUS_PASSWORD"
        --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" --max-time "$CURL_MAX_TIME_SECONDS")
    if [ -n "${NEXUS_CA_FILE:-}" ]; then
        curl_options+=(--cacert "$NEXUS_CA_FILE")
    fi

    while [ "$attempt" -lt "$maximum_attempts" ]; do
        attempt=$((attempt + 1))
        http_status_file=$output_file.http-status
        : >"$http_status_file"
        if [ -n "$upload_file" ]; then
            curl "${curl_options[@]}" --output "$output_file" --write-out '%{http_code}' \
                --request "$method" --upload-file "$upload_file" \
                "$url" >"$http_status_file" &
        else
            curl "${curl_options[@]}" --output "$output_file" --write-out '%{http_code}' \
                --request "$method" "$url" >"$http_status_file" &
        fi
        current_curl_pid=$!
        wait "$current_curl_pid"
        curl_status=$?
        current_curl_pid=
        status=$(cat "$http_status_file")

        transient=false
        [ "$curl_status" -ne 0 ] && transient=true
        case $status in
            429|5??) transient=true ;;
        esac
        if [ "$transient" = false ] || [ "$attempt" -ge "$maximum_attempts" ]; then
            CURL_HTTP_STATUS=$status
            CURL_EXIT_STATUS=$curl_status
            return 0
        fi
        sleep "$IMPORT_RETRY_DELAY_SECONDS"
    done
}

base_url=${NEXUS_URL%/}/repository/$(url_encode_path "$NEXUS_REPOSITORY")

terminate_worker() {
    worker_signal=$1
    worker_exit_status=$2
    trap '' INT TERM
    if [ -n "$current_curl_pid" ]; then
        kill -"$worker_signal" "$current_curl_pid" 2>/dev/null || true
        wait "$current_curl_pid" 2>/dev/null || true
    fi
    exit "$worker_exit_status"
}

process_artifact() {
    expected_digest=$1
    relative_path=$2
    artifact_number=$3
    current_curl_pid=
    trap 'terminate_worker INT 130' INT
    trap 'terminate_worker TERM 143' TERM
    artifact_path=${relative_path#repository/}

    artifact_url=$base_url/$(url_encode_path "$artifact_path")
    response_file=$work_dir/response-$artifact_number
    remote_file=$work_dir/remote-$artifact_number
    result_file=$work_dir/result-$artifact_number
    upload_attempt=0
    maximum_upload_attempts=$((IMPORT_RETRIES + 1))

    while [ "$upload_attempt" -lt "$maximum_upload_attempts" ]; do
        upload_attempt=$((upload_attempt + 1))
        curl_request GET "$artifact_url" "$remote_file"
        if [ "$CURL_EXIT_STATUS" -ne 0 ]; then
            printf 'failed\n' >"$result_file"
            return
        fi
        case $CURL_HTTP_STATUS in
            2??)
                remote_digest=$(sha256sum "$remote_file")
                remote_digest=${remote_digest%% *}
                if [ "$remote_digest" = "$expected_digest" ]; then
                    printf 'already-present\n' >"$result_file"
                else
                    printf 'conflict: %s exists with a different digest\n' "$relative_path" >&2
                    printf 'failed\n' >"$result_file"
                fi
                return
                ;;
            404) ;;
            *)
                printf 'failed\n' >"$result_file"
                return
                ;;
        esac

        curl_request PUT "$artifact_url" "$response_file" "$MAVEN_SEED_DIR/$relative_path" 0
        if [ "$CURL_EXIT_STATUS" -ne 0 ]; then
            [ "$upload_attempt" -lt "$maximum_upload_attempts" ] && continue
            printf 'failed\n' >"$result_file"
            return
        fi
        case $CURL_HTTP_STATUS in
            2??)
                printf 'uploaded\n' >"$result_file"
                return
                ;;
            429|5??)
                [ "$upload_attempt" -lt "$maximum_upload_attempts" ] && continue
                printf 'failed\n' >"$result_file"
                return
                ;;
        esac

        # A deterministic rejection may be a race with another uploader.
        curl_request GET "$artifact_url" "$remote_file"
        if [ "$CURL_EXIT_STATUS" -eq 0 ]; then
            case $CURL_HTTP_STATUS in
                2??)
                    remote_digest=$(sha256sum "$remote_file")
                    remote_digest=${remote_digest%% *}
                    if [ "$remote_digest" = "$expected_digest" ]; then
                        printf 'already-present\n' >"$result_file"
                        return
                    fi
                    printf 'conflict: %s exists with a different digest\n' "$relative_path" >&2
                    ;;
            esac
        fi
        printf 'failed\n' >"$result_file"
        return
    done
}

wait_for_batch() {
    for worker_pid in $batch_pids; do
        wait "$worker_pid" || true
    done
    batch_pids=
    batch_size=0
}

artifact_count=0
batch_size=0
while IFS= read -r artifact_line || [ -n "$artifact_line" ]; do
    [ "$stopping" = false ] || break
    [ -n "$artifact_line" ] || continue
    expected_digest=${artifact_line%% *}
    relative_path=${artifact_line#*  }
    artifact_count=$((artifact_count + 1))
    process_artifact "$expected_digest" "$relative_path" "$artifact_count" &
    batch_pids="$batch_pids $!"
    batch_size=$((batch_size + 1))
    if [ "$batch_size" -eq "$NEXUS_UPLOAD_CONCURRENCY" ]; then
        wait_for_batch
    fi
done <"$artifact_list"
wait_for_batch

artifact_number=1
while [ "$artifact_number" -le "$artifact_count" ]; do
    result_file=$work_dir/result-$artifact_number
    if [ ! -f "$result_file" ]; then
        failed=$((failed + 1))
    else
        result=$(cat "$result_file")
        case $result in
            uploaded) uploaded=$((uploaded + 1)) ;;
            already-present) already_present=$((already_present + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    fi
    artifact_number=$((artifact_number + 1))
done

printf 'uploaded=%d already-present=%d failed=%d\n' "$uploaded" "$already_present" "$failed"
[ "$failed" -eq 0 ]
