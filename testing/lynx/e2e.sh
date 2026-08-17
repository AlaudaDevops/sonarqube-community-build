#!/usr/bin/env bash

write_test_config() {
  local registry_host
  registry_host="$(kubectl --request-timeout=30s -n kube-public get configmap global-info \
    -o jsonpath='{.data.registryAddress}')"
  [[ -n "${registry_host}" ]] || fatal "target registry address is empty"

  LYNX_TEST_CONFIG_DIR="$(mktemp -d /tmp/sonarqube-testing-config.XXXXXX)"
  LYNX_TEST_CONFIG="${LYNX_TEST_CONFIG_DIR}/config.yaml"
  printf 'registry:\n  test: %s\n' "${registry_host}" >"${LYNX_TEST_CONFIG}"
  chmod 0600 "${LYNX_TEST_CONFIG}"
  export TESTING_CONFIG="${LYNX_TEST_CONFIG}"
}

run_e2e() {
  local test_rc report_rc=0
  kubectl create namespace bdd-testing --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  write_test_config
  mkdir -p "${RESULT_DIR}/allure-result" "${RESULT_DIR}/allure-report"

  log "[TEST] running SonarQube E2E tags: ${LYNX_E2E_TAGS}"
  pushd "${LYNX_TEST_WORKDIR}" >/dev/null
  set +e
  timeout --signal=TERM "$(remaining_timeout "${LYNX_TEST_TIMEOUT}")" \
    "${LYNX_TEST_COMMAND}" \
    --godog.concurrency="${LYNX_E2E_CONCURRENCY}" \
    --godog.format=allure \
    --godog.tags="${LYNX_E2E_TAGS}"
  test_rc=$?
  set -e

  if [[ -d allure-results ]]; then
    cp -a allure-results/. "${RESULT_DIR}/allure-result/"
  fi
  popd >/dev/null

  allure generate "${RESULT_DIR}/allure-result" --clean -o "${RESULT_DIR}/allure-report" \
    || report_rc=$?
  if ((test_rc != 0)); then
    log "[TEST] E2E failed with exit code ${test_rc}"
    return "${test_rc}"
  fi
  if ((report_rc != 0)); then
    fatal "Allure report generation failed with exit code ${report_rc}"
  fi
  log "[DONE] E2E and Allure completed successfully"
}

cleanup_test_files() {
  rm -rf "${LYNX_TEST_CONFIG_DIR:-}" 2>/dev/null || true
}
