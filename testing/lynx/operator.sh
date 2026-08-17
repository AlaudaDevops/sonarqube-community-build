#!/usr/bin/env bash

webhook_service_ready() {
  local namespace="$1" name="$2"
  kubectl -n "${namespace}" get endpoints "${name}" -o json 2>/dev/null | \
    jq -r 'if any(.subsets[]?.addresses[]?; .ip != null) then "True" else "False" end'
}

wait_for_csv_webhooks() {
  local csv="$1" namespace name timeout_seconds
  while IFS=$'\t' read -r namespace name; do
    [[ -n "${namespace}" && -n "${name}" ]] || continue
    timeout_seconds="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
    wait_for_value "Webhook service ${namespace}/${name}" True "${timeout_seconds}" \
      webhook_service_ready "${namespace}" "${name}"
  done < <(kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get csv "${csv}" -o json | \
    jq -r '.spec.webhookdefinitions[]?.clientConfig.service | [.namespace, .name] | @tsv')
}

select_operator_channel() {
  local expected="$1" requested_channel="${2:-}"
  jq -er --arg expected "${expected}" --arg requested "${requested_channel}" '
    .status.defaultChannel as $default |
    [.status.channels[] |
      select(((.currentCSVDesc.version // "") | ltrimstr("v")) == $expected)] as $matches |
    if $requested != "" then
      [$matches[] | select(.name == $requested)] |
      if length == 1 then .[0].name else empty end
    elif ($default // "") != "" and any($matches[]; .name == $default) then
      $default
    elif ($matches | length) == 1 then
      $matches[0].name
    else
      empty
    end'
}

discover_operator_package() {
  local package_timeout deadline package_json candidates candidate_count expected_normalized
  package_timeout="$(remaining_timeout "${LYNX_PACKAGE_TIMEOUT}")"
  deadline=$((SECONDS + package_timeout))
  expected_normalized="$(normalize_version "${LYNX_EXPECTED_OPERATOR_VERSION}")"

  while ((SECONDS < deadline)); do
    candidates="$(kubectl --request-timeout=30s get packagemanifests -A -o json 2>/dev/null | \
      jq -c --arg package "${LYNX_OPERATOR_PACKAGE}" --arg expected "${expected_normalized}" \
      --arg source "${LYNX_CATALOG_SOURCE_FILTER:-}" \
      --arg source_namespace "${LYNX_CATALOG_NAMESPACE_FILTER:-}" '
        [.items[] |
          select(.status.packageName == $package) |
          select($source == "" or .status.catalogSource == $source) |
          select($source_namespace == "" or .status.catalogSourceNamespace == $source_namespace) |
          select(any(.status.channels[]?; ((.currentCSVDesc.version // "") | ltrimstr("v")) == $expected))]')"
    candidate_count="$(jq 'length' <<<"${candidates}")"
    if [[ "${candidate_count}" == "1" ]]; then
      package_json="$(jq -c '.[0]' <<<"${candidates}")"
      break
    fi
    if ((candidate_count > 1)); then
      fatal "multiple PackageManifests expose ${LYNX_EXPECTED_OPERATOR_VERSION}; set catalog filters"
    fi
    log "[WAIT] PackageManifest ${LYNX_OPERATOR_PACKAGE} ${LYNX_EXPECTED_OPERATOR_VERSION} is not visible yet"
    sleep 15
  done
  [[ -n "${package_json:-}" ]] \
    || fatal "PackageManifest ${LYNX_OPERATOR_PACKAGE} ${LYNX_EXPECTED_OPERATOR_VERSION} was not listed by Violet"

  LYNX_PACKAGE_NAME="$(jq -er '.status.packageName' <<<"${package_json}")"
  LYNX_CATALOG_SOURCE="$(jq -er '.status.catalogSource' <<<"${package_json}")"
  LYNX_CATALOG_NAMESPACE="$(jq -er '.status.catalogSourceNamespace' <<<"${package_json}")"
  LYNX_OPERATOR_CHANNEL="$(select_operator_channel \
    "${expected_normalized}" "${LYNX_OPERATOR_CHANNEL:-}" <<<"${package_json}")" \
    || fatal "requested/default PackageManifest channel does not expose ${LYNX_EXPECTED_OPERATOR_VERSION} uniquely"
  LYNX_EXPECTED_CSV="$(jq -er --arg channel "${LYNX_OPERATOR_CHANNEL}" \
    '.status.channels[] | select(.name == $channel) | .currentCSV' <<<"${package_json}")" \
    || fatal "PackageManifest channel has no currentCSV"

  log "[PREFLIGHT] found ${LYNX_PACKAGE_NAME} ${LYNX_EXPECTED_OPERATOR_VERSION} in ${LYNX_CATALOG_SOURCE}"
}

install_operator() {
  local phase_timeout old_install_plan old_installed_csv
  local deadline install_plan="" approved csv installed_version deployment

  discover_operator_package
  phase_timeout="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
  wait_for_value "CatalogSource ${LYNX_CATALOG_SOURCE}" READY "${phase_timeout}" \
    kubectl -n "${LYNX_CATALOG_NAMESPACE}" get catalogsource "${LYNX_CATALOG_SOURCE}" \
    -o jsonpath='{.status.connectionState.lastObservedState}'

  old_install_plan="$(kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get subscription \
    "${LYNX_OPERATOR_PACKAGE}" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
  old_installed_csv="$(kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get subscription \
    "${LYNX_OPERATOR_PACKAGE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"

  log "[SETUP] applying OperatorGroup and Subscription for ${LYNX_EXPECTED_CSV}"
  kubectl create namespace "${LYNX_OPERATOR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${LYNX_OPERATOR_PACKAGE}
  namespace: ${LYNX_OPERATOR_NAMESPACE}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${LYNX_OPERATOR_PACKAGE}
  namespace: ${LYNX_OPERATOR_NAMESPACE}
spec:
  channel: ${LYNX_OPERATOR_CHANNEL}
  installPlanApproval: Manual
  name: ${LYNX_PACKAGE_NAME}
  source: ${LYNX_CATALOG_SOURCE}
  sourceNamespace: ${LYNX_CATALOG_NAMESPACE}
EOF

  if [[ "${old_installed_csv}" != "${LYNX_EXPECTED_CSV}" ]]; then
    phase_timeout="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
    deadline=$((SECONDS + phase_timeout))
    while ((SECONDS < deadline)); do
      install_plan="$(kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get subscription \
        "${LYNX_OPERATOR_PACKAGE}" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
      if [[ -n "${install_plan}" && "${install_plan}" != "${old_install_plan}" ]]; then
        approved="$(kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get installplan "${install_plan}" \
          -o jsonpath='{.spec.approved}' 2>/dev/null || true)"
        if [[ "${approved}" != "true" ]]; then
          log "[SETUP] approving InstallPlan ${install_plan}"
          kubectl -n "${LYNX_OPERATOR_NAMESPACE}" patch installplan "${install_plan}" \
            --type merge -p '{"spec":{"approved":true}}' >/dev/null
        fi
        break
      fi
      sleep 5
    done
    [[ -n "${install_plan}" && "${install_plan}" != "${old_install_plan}" ]] \
      || fatal "Subscription did not resolve a new InstallPlan for ${LYNX_EXPECTED_CSV}"

    phase_timeout="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
    wait_for_value "InstallPlan ${install_plan}" Complete "${phase_timeout}" \
      kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get installplan "${install_plan}" \
      -o jsonpath='{.status.phase}'
  fi

  phase_timeout="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
  wait_for_value "Subscription installedCSV" "${LYNX_EXPECTED_CSV}" "${phase_timeout}" \
    kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get subscription "${LYNX_OPERATOR_PACKAGE}" \
    -o jsonpath='{.status.installedCSV}'
  csv="${LYNX_EXPECTED_CSV}"
  phase_timeout="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
  wait_for_value "CSV ${csv}" Succeeded "${phase_timeout}" \
    kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get csv "${csv}" -o jsonpath='{.status.phase}'

  installed_version="$(kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get csv "${csv}" \
    -o jsonpath='{.spec.version}')"
  [[ "$(normalize_version "${installed_version}")" == \
      "$(normalize_version "${LYNX_EXPECTED_OPERATOR_VERSION}")" ]] \
    || fatal "installed CSV version ${installed_version} does not match ${LYNX_EXPECTED_OPERATOR_VERSION}"

  phase_timeout="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
  kubectl wait --for=condition=Established crd/sonarqubes.operator.alaudadevops.io \
    --timeout="${phase_timeout}s" >/dev/null
  while read -r deployment; do
    [[ -n "${deployment}" ]] || continue
    phase_timeout="$(remaining_timeout "${LYNX_INSTALL_TIMEOUT}")"
    kubectl -n "${LYNX_OPERATOR_NAMESPACE}" rollout status deployment/"${deployment}" \
      --timeout="${phase_timeout}s"
    log "[WAIT] operator Deployment ${deployment} is Available"
  done < <(kubectl -n "${LYNX_OPERATOR_NAMESPACE}" get csv "${csv}" -o json | \
    jq -r '.spec.install.spec.deployments[].name')
  wait_for_csv_webhooks "${csv}"
}
