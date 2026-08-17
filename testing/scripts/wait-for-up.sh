#!/bin/bash
# Wait for SonarQube to be fully operational (status=UP) before the token / scan /
# analysis steps. bdd's "可以正常访问" readiness passes on the STARTING page (HTTP 200
# while the DB migration + ES come up), after which the token POST returns EOF and
# the (non-retrying) bdd get-token step fails. Poll the status API until UP; curl
# resolves the ingress host via nss_wrapper (LD_PRELOAD + $NSS_WRAPPER_HOSTS).
URL="$1"
for i in $(seq 1 120); do
  status="$(curl -s -k --max-time 10 "${URL}/api/system/status" | jq -r '.status // empty' 2>/dev/null)"
  echo "wait-for-up (${i}/120): ${URL} status=${status:-<none>}"
  [ "$status" = "UP" ] && { echo "SonarQube is UP"; exit 0; }
  sleep 5
done
echo "wait-for-up: timed out waiting for SonarQube UP at ${URL}"
exit 1
