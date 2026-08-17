#!/usr/bin/env bash
set -Eeuo pipefail

LYNX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LYNX_LIB_DIR="${LYNX_LIB_DIR:-${LYNX_ROOT}/lynx}"
for module in common auth operator diagnostics e2e; do
  # shellcheck source=/dev/null
  source "${LYNX_LIB_DIR}/${module}.sh"
done

API_URL="${API_URL:-}"
API_URL="${API_URL%/}"
RESULT_DIR="$(resolve_result_dir)"
CLEANUP_AFTER_TEST="${CLEANUP_AFTER_TEST:-false}"
LYNX_E2E_TAGS="${LYNX_E2E_TAGS:-@sonarqube-e2e}"
LYNX_E2E_CONCURRENCY="${LYNX_E2E_CONCURRENCY:-2}"
LYNX_TEST_COMMAND="${LYNX_TEST_COMMAND:-/app/bin/sonarqube-e2e.test}"
LYNX_TEST_WORKDIR="${LYNX_TEST_WORKDIR:-/app/testing}"
LYNX_OPERATOR_PACKAGE="${LYNX_OPERATOR_PACKAGE:-sonarqube-ce-operator}"
LYNX_OPERATOR_NAMESPACE="${LYNX_OPERATOR_NAMESPACE:-sonarqube-ce-operator}"
LYNX_OPERATOR_CHANNEL="${LYNX_OPERATOR_CHANNEL:-}"
LYNX_PACKAGE_TIMEOUT="${LYNX_PACKAGE_TIMEOUT:-600}"
LYNX_INSTALL_TIMEOUT="${LYNX_INSTALL_TIMEOUT:-1200}"
LYNX_TEST_TIMEOUT="${LYNX_TEST_TIMEOUT:-1200}"
LYNX_TOTAL_TIMEOUT="${LYNX_TOTAL_TIMEOUT:-2400}"
LYNX_WAIT_HEARTBEAT="${LYNX_WAIT_HEARTBEAT:-30}"
LYNX_INSECURE_SKIP_TLS_VERIFY="${LYNX_INSECURE_SKIP_TLS_VERIFY:-false}"
LYNX_CURL_TLS_ARGS=()

on_exit() {
  local rc=$?
  set +e
  if ((rc != 0)) && [[ -s "${KUBECONFIG:-}" ]]; then
    collect_diagnostics
  fi
  cleanup_test_files
  cleanup_auth
  exit "${rc}"
}
trap on_exit EXIT

main() {
  require_env API_URL
  require_env USERNAME
  require_env PASSWORD
  require_env REGION_NAME
  require_env LYNX_EXPECTED_OPERATOR_VERSION
  for command_name in bash curl jq openssl base64 kubectl allure timeout; do
    require_command "${command_name}"
  done
  [[ -x "${LYNX_TEST_COMMAND}" ]] || fatal "test program is not executable: ${LYNX_TEST_COMMAND}"
  mkdir -p "${RESULT_DIR}"
  # Referenced by sourced modules; ShellCheck cannot follow the runtime module loop above.
  # shellcheck disable=SC2034
  LYNX_DEADLINE=$((SECONDS + LYNX_TOTAL_TIMEOUT))
  LYNX_OWNED_KUBECONFIG="$(mktemp /tmp/sonarqube-lynx-kubeconfig.XXXXXX)"
  KUBECONFIG="${LYNX_OWNED_KUBECONFIG}"
  export KUBECONFIG
  if [[ "${LYNX_INSECURE_SKIP_TLS_VERIFY}" == "true" ]]; then
    # shellcheck disable=SC2034
    LYNX_CURL_TLS_ARGS=(-k)
    log "[PREFLIGHT] WARNING: ACP TLS certificate verification is disabled"
  fi

  log "[PREFLIGHT] validating ACP access and region"
  login_and_write_kubeconfig
  log "[SETUP] installing Operator"
  install_operator
  log "[TEST] starting E2E"
  run_e2e

  if [[ "${CLEANUP_AFTER_TEST}" == "true" ]]; then
    log "[CLEANUP] full Operator cleanup is intentionally not performed; test CR cleanup is owned by E2E"
  fi
}

main "$@"
