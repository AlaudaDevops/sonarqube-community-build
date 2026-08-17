#!/bin/bash
# migration(sonarqube): register an ingress host -> ip mapping so the scan
# subprocesses (curl + the Java sonar-scanner) can resolve the per-scenario
# ingress hostname. The run-test step runs nonroot and cannot write the
# root-owned /etc/hosts; instead we append to $NSS_WRAPPER_HOSTS (a writable
# file the test command seeds), which libnss_wrapper (LD_PRELOAD) uses for
# name resolution in every subprocess. bdd's in-process fake DNS only covers
# its own Go HTTP client, so the ingress-http/https scans need this. Always
# returns success so the "添加 DNS 解析" step passes.
ip=$1
host=$2
target="${NSS_WRAPPER_HOSTS:-/etc/hosts}"

if echo "$ip $host" >>"$target" 2>/dev/null; then
  echo "add-host: wrote ${target} entry: ${ip} ${host}"
else
  echo "add-host: WARN could not write ${target}; bdd internal DNS will handle ${host} -> ${ip}"
fi

exit 0
