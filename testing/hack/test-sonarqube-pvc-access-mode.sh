#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PVC_FIXTURE="${TESTING_DIR}/testdata/resources/sonarqube-pvc.yaml"
CHART_VALUES="${TESTING_DIR}/../chart/values.yaml"
FEATURE="${TESTING_DIR}/features/sonarqube-deploy.feature"

grep -Eq '^[[:space:]]+- ReadWriteOnce$' "${PVC_FIXTURE}"
if grep -Fq 'ReadWriteMany' "${PVC_FIXTURE}"; then
  echo "SonarQube PVC fixture must not request ReadWriteMany" >&2
  exit 1
fi
grep -Eq '^[[:space:]]*storageClassName: <storage-class>$' "${PVC_FIXTURE}"
grep -Eq '^[[:space:]]*accessMode: ReadWriteOnce$' "${CHART_VALUES}"
grep -Eq '^[[:space:]]*type: Recreate$' "${CHART_VALUES}"
grep -Fq '| PersistentVolumeClaim | v1 | sonarqube-pvc | $.spec.accessModes[0] | ReadWriteOnce |' "${FEATURE}"
grep -Fq '| Deployment  | apps/v1    | sonarqube-test-sonarqube   | $.spec.strategy.type | Recreate |' "${FEATURE}"

echo "SonarQube PVC access mode tests passed"
