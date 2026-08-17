#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lynx/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lynx/e2e.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

TEST_RESULT_DIR="${tmp_dir}/shared/testresult/0"
RESULT_DIR="${tmp_dir}/pod-local"
[[ "$(resolve_result_dir)" == "${TEST_RESULT_DIR}" ]]
unset TEST_RESULT_DIR
[[ "$(resolve_result_dir)" == "${RESULT_DIR}" ]]
unset RESULT_DIR
[[ "$(resolve_result_dir)" == "/tmp/test-results" ]]

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/work"
cat >"${tmp_dir}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"registryAddress"* ]]; then
  printf '%s' 'registry.example.test'
else
  printf '%s\n' 'apiVersion: v1' 'kind: Namespace' 'metadata:' '  name: bdd-testing'
fi
EOF
cat >"${tmp_dir}/bin/allure" <<'EOF'
#!/usr/bin/env bash
input_dir="$2"
output_dir="$5"
[[ -f "${input_dir}/failed-result.json" ]]
mkdir -p "${output_dir}"
printf '%s\n' '<html>failed test report</html>' >"${output_dir}/index.html"
EOF
cat >"${tmp_dir}/bin/failing-test" <<'EOF'
#!/usr/bin/env bash
mkdir -p allure-results
printf '%s\n' '{"status":"failed"}' >allure-results/failed-result.json
exit 1
EOF
chmod +x "${tmp_dir}/bin/kubectl" "${tmp_dir}/bin/allure" "${tmp_dir}/bin/failing-test"

PATH="${tmp_dir}/bin:${PATH}"
export PATH
export RESULT_DIR="${tmp_dir}/shared/testresult/0"
export LYNX_TEST_WORKDIR="${tmp_dir}/work"
export LYNX_TEST_COMMAND="${tmp_dir}/bin/failing-test"
export LYNX_TEST_TIMEOUT=60
export LYNX_TOTAL_TIMEOUT=120
export LYNX_DEADLINE=$((SECONDS + LYNX_TOTAL_TIMEOUT))
export LYNX_E2E_CONCURRENCY=1
export LYNX_E2E_TAGS='@sonarqube-e2e'

if run_e2e; then
  echo "expected the fake E2E command to fail" >&2
  exit 1
else
  test_rc=$?
fi

[[ "${test_rc}" -eq 1 ]]
[[ -f "${RESULT_DIR}/allure-result/failed-result.json" ]]
[[ -f "${RESULT_DIR}/allure-report/index.html" ]]

echo "lynx report path tests passed"
