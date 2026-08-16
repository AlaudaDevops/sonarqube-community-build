#!/usr/bin/env bash

collect_diagnostics() {
  mkdir -p "${RESULT_DIR}"
  log "[DIAG] collecting non-secret failure diagnostics"
  kubectl get subscription,installplan,csv -A >"${RESULT_DIR}/olm-status.txt" 2>&1 || true
  kubectl get deployments,pods -A >"${RESULT_DIR}/workloads.txt" 2>&1 || true
  kubectl get events -A --sort-by=.lastTimestamp >"${RESULT_DIR}/events.txt" 2>&1 || true
}
