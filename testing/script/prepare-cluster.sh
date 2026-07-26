#!/usr/bin/env bash
# migration(sonarqube) DEVOPS-44461: prepare the throwaway ctyun-vm k3s cluster for the
# sonarqube-chart smoke suite. Adapted from the proven-green gitlab-chart sibling
# (gitlab-chart@migration-alauda-18.8.6 modules/gitlab-chart/testing/script/prepare-cluster.sh)
# -- same VM harness (ctyun-vm-integration-test), same two gaps (RWO-only local-path SC,
# ingress controller never publishing a status IP). Best-effort by DESIGN: the pipeline's
# `deploy` param runs BEFORE run-test with no onError:continue, so a hard failure here would
# skip run-test entirely and burn the whole VM cycle with zero test signal -- every step is
# allowed to fail and the script always returns 0.
#
# Env: SOURCE_PATH (workspace source root, required). KUBECONFIG is derived from SOURCE_PATH.
set -ux
: "${SOURCE_PATH:?SOURCE_PATH required}"
export KUBECONFIG="${SOURCE_PATH}/.git/ctyun-vm/kubeconfig"

# ---- RWX storage for the storage-pvc smoke scenario --------------------------------------
# (rationale in testdata/resources/rwx-hostpath.yaml) A no-provisioner `nfs` StorageClass +
# a loop-generated hostPath PV pool advertising all access modes: on the single-node VM
# hostPath is shared RW by all pods, a real RWX equivalent without an NFS client on the node.
rwx_storage() {
  kubectl apply -f "${SOURCE_PATH}/testing/testdata/resources/rwx-hostpath.yaml" || echo "WARN: rwx-hostpath apply failed"
  __pool="${RWX_PV_POOL:-20}"
  { __i=0; while [ "$__i" -lt "$__pool" ]; do __n=$(printf '%02d' "$__i"); cat <<PVEOF
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: sonarqube-rwx-${__n}
  labels:
    pool: nfs-rwx
spec:
  capacity:
    storage: 10Gi
  storageClassName: nfs
  accessModes: [ReadWriteOnce, ReadWriteMany, ReadOnlyMany]
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/sonarqube-rwx-${__n}
    type: DirectoryOrCreate
PVEOF
  __i=$((__i+1)); done; } | kubectl apply -f - || echo "WARN: PV pool apply failed"
  # make nfs the sole default SC: bdd's <storage-class.rwm> returns the default first, and
  # local-path (RWO) can't back the storage-pvc scenario's RWX PVC.
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
  kubectl patch storageclass nfs -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
  kubectl get storageclass || true
  echo "nfs RWX PVs: $(kubectl get pv -l pool=nfs-rwx --no-headers 2>/dev/null | wc -l)"
}

# ---- make the ingress controller publish a status IP -------------------------------------
# bdd's StepExistIngressController / ingress-ip generator polls .status.loadBalancer.ingress
# for the network-http/https scenarios; the baked controller has no cloud LB / MetalLB to
# hand it a real address, so it never publishes one. Annotate the nginx IngressClass default
# + add --publish-status-address=<node ip> --watch-ingress-without-class=true, then roll out.
fix_ingress() {
  local NS=ingress-nginx NODE_IP ICLASS CDEPLOY CARGS SVC
  echo "=== live cluster state before run-test (diagnostic) ==="
  kubectl get pods -A || true
  kubectl get ingressclass || true

  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  echo "VM node InternalIP: ${NODE_IP:-<none>}"
  SVC=$(kubectl get svc -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E 'controller$' | head -1 || true)
  ICLASS=$(kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE 'nginx' | head -1 || true)
  echo "nginx IngressClass: ${ICLASS:-<none>} / controller Service: ${NS}/${SVC:-<not found>}"
  [ -n "${ICLASS:-}" ] && kubectl annotate ingressclass "${ICLASS}" ingressclass.kubernetes.io/is-default-class=true --overwrite || echo "WARN: default-class annotate skipped/failed"

  CDEPLOY=$(kubectl get deploy -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E 'controller$' | head -1 || true)
  echo "ingress-nginx controller Deployment: ${NS}/${CDEPLOY:-<not found>}"
  if [ -n "${CDEPLOY:-}" ] && [ -n "${NODE_IP:-}" ]; then
    CARGS=$(kubectl get deploy "${CDEPLOY}" -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)
    case "${CARGS}" in
      *publish-status-address*) echo "controller already has --publish-status-address, skipping arg patch" ;;
      *) kubectl patch deploy "${CDEPLOY}" -n "${NS}" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--publish-status-address=${NODE_IP}\"},{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--watch-ingress-without-class=true\"}]" || echo "WARN: controller args patch failed" ;;
    esac
    kubectl rollout status deploy/"${CDEPLOY}" -n "${NS}" --timeout=120s || echo "WARN: controller rollout not complete"
  fi
}

# ---- also make port 80/443 reachable on the node IP + belt-and-suspenders status IP ------
publish_service_status() {
  local NS=ingress-nginx SVC NODE_IP ip i
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  SVC=$(kubectl get svc -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E 'controller$' | head -1 || true)
  [ -n "${SVC:-}" ] && [ -n "${NODE_IP:-}" ] || { echo "WARN: no ingress controller Service or node IP -- skipping externalIPs patch"; return 0; }
  kubectl patch svc "${SVC}" -n "${NS}" --type=merge -p "{\"spec\":{\"externalIPs\":[\"${NODE_IP}\"]}}" || echo "WARN: externalIPs patch failed"
  kubectl patch svc "${SVC}" -n "${NS}" --type=merge -p "{\"spec\":{\"type\":\"LoadBalancer\"}}" || echo "WARN: type=LoadBalancer patch failed"
  kubectl patch svc "${SVC}" -n "${NS}" --type=merge --subresource=status -p "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"${NODE_IP}\"}]}}}" || echo "WARN: status.loadBalancer.ingress patch failed"
  # migration(sonarqube): the "evil" reliability hack ported from gitlab-chart's
  # proven-green prepare-cluster.sh -- BLOCK here until a throwaway classless Ingress
  # actually gets a .status.loadBalancer.ingress[0].ip (mirrors bdd's
  # StepExistIngressController). Without this wait, prepare-cluster returns right after
  # the patches while the controller hasn't re-synced yet, so the bdd ingress check
  # retries many times / times out (scenarios 147/158 "ingress resource has no ingress ip").
  echo "=== verifying a throwaway Ingress gets a status IP (mirrors StepExistIngressController) ==="
  kubectl create ingress deploy-step-ingress-probe -n default --rule="deploy-step-probe.example.com/=example-service:80" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - || echo "WARN: probe ingress create failed"
  for i in $(seq 1 12); do
    ip=$(kubectl get ingress deploy-step-ingress-probe -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "${ip}" ] && { echo "PROBE OK: ingress status IP = ${ip}"; break; }
    echo "probe wait $i (no status IP yet)"; sleep 5
  done
  kubectl delete ingress deploy-step-ingress-probe -n default --ignore-not-found || true
}

rwx_storage
fix_ingress
publish_service_status
exit 0
