#!/usr/bin/env bash

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

fatal() {
  log "ERROR: $*"
  return 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fatal "missing required variable: ${name}"
  fi
}

require_command() {
  local name="$1"
  command -v "${name}" >/dev/null 2>&1 || fatal "required command is unavailable: ${name}"
}

resolve_result_dir() {
  if [[ -n "${TEST_RESULT_DIR:-}" ]]; then
    printf '%s' "${TEST_RESULT_DIR}"
  else
    printf '%s' "${RESULT_DIR:-/tmp/test-results}"
  fi
}

wait_for_value() {
  local description="$1" expected="$2" timeout_seconds="$3"
  shift 3

  local deadline=$((SECONDS + timeout_seconds))
  local current="" previous="__unset__" next_heartbeat=0
  while ((SECONDS < deadline)); do
    current="$("$@" 2>/dev/null || true)"
    if [[ "${current}" == "${expected}" ]]; then
      log "[WAIT] ${description}: ${expected}"
      return 0
    fi
    if [[ "${current}" != "${previous}" ]] || ((SECONDS >= next_heartbeat)); then
      log "[WAIT] ${description}: current='${current:-<empty>}', expected='${expected}'"
      previous="${current}"
      next_heartbeat=$((SECONDS + LYNX_WAIT_HEARTBEAT))
    fi
    sleep 5
  done

  fatal "timed out waiting for ${description}; last value='${current:-<empty>}'"
}

normalize_version() {
  printf '%s' "$1" | sed 's/^v//'
}

remaining_timeout() {
  local requested="$1" remaining=$((LYNX_DEADLINE - SECONDS))
  ((remaining > 0)) || fatal "Lynx total timeout of ${LYNX_TOTAL_TIMEOUT}s was exhausted"
  if ((requested < remaining)); then
    printf '%s' "${requested}"
  else
    printf '%s' "${remaining}"
  fi
}
