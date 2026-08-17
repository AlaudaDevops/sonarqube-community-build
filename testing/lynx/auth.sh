#!/usr/bin/env bash

query_value() {
  local url="$1" key="$2" query
  query="${url#*\?}"
  [[ "${query}" != "${url}" ]] || return 0
  printf '%s' "${query%%#*}" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -1
}

login_and_write_kubeconfig() {
  local auth_dir cookie_jar login_json auth_url auth_query authorize_json auth_req
  local pubkey_json password_payload encrypted_password local_login_json redirect_json
  local redirect_url callback_code callback_state token_json token_type access_token

  auth_dir="$(mktemp -d /tmp/sonarqube-lynx-auth.XXXXXX)"
  LYNX_AUTH_DIR="${auth_dir}"
  cookie_jar="${auth_dir}/cookies"

  log "[PREFLIGHT] contacting ACP token endpoint"
  login_json="$(curl -fsS "${LYNX_CURL_TLS_ARGS[@]}" --max-time 30 -c "${cookie_jar}" --get \
    "${API_URL}/console-platform/api/v1/token/login" \
    --data-urlencode "redirect_uri=${API_URL}/console-platform")" \
    || fatal "ACP token endpoint is not reachable"
  auth_url="$(jq -er '.auth_url' <<<"${login_json}")" || fatal "token response has no auth_url"
  auth_query="${auth_url#*\?}"
  [[ "${auth_query}" != "${auth_url}" ]] || fatal "auth_url has no query string"

  authorize_json="$(curl -fsS "${LYNX_CURL_TLS_ARGS[@]}" --max-time 30 -b "${cookie_jar}" -c "${cookie_jar}" \
    "${API_URL}/dex/api/v1/authorize?${auth_query}")" || fatal "Dex authorize request failed"
  auth_req="$(jq -er '.req' <<<"${authorize_json}")" || fatal "Dex authorize response has no req"

  pubkey_json="$(curl -fsS "${LYNX_CURL_TLS_ARGS[@]}" --max-time 30 -b "${cookie_jar}" "${API_URL}/dex/pubkey")" \
    || fatal "Dex public key request failed"
  jq -er '.pubkey' <<<"${pubkey_json}" >"${auth_dir}/public.pem" \
    || fatal "Dex public key response is invalid"
  password_payload="$(jq -cn --argjson ts "$(jq -c '.ts' <<<"${pubkey_json}")" \
    --arg password "${PASSWORD}" '{ts:$ts,password:$password}')"
  encrypted_password="$(openssl pkeyutl -encrypt -pubin -inkey "${auth_dir}/public.pem" \
    -pkeyopt rsa_padding_mode:pkcs1 <<<"${password_payload}" | base64 -w0)" \
    || fatal "password encryption failed"
  local_login_json="$(jq -cn --arg account "${USERNAME}" --arg password "${encrypted_password}" \
    '{account:$account,password:$password}')"

  redirect_json="$(curl -fsS "${LYNX_CURL_TLS_ARGS[@]}" --max-time 30 -b "${cookie_jar}" -c "${cookie_jar}" \
    -H 'Content-Type: application/json' -X POST --data-binary "${local_login_json}" \
    "${API_URL}/dex/api/v1/authorize/local?req=${auth_req}")" || fatal "ACP login failed"
  redirect_url="$(jq -er '.redirect_url' <<<"${redirect_json}")" \
    || fatal "ACP login response has no redirect_url"
  callback_code="$(query_value "${redirect_url}" code)"
  callback_state="$(query_value "${redirect_url}" state)"
  [[ -n "${callback_code}" && -n "${callback_state}" ]] \
    || fatal "ACP login redirect has no code/state"

  token_json="$(curl -fsS "${LYNX_CURL_TLS_ARGS[@]}" --max-time 30 -b "${cookie_jar}" --get \
    "${API_URL}/console-platform/api/v1/token/callback" \
    --data-urlencode "code=${callback_code}" --data-urlencode "state=${callback_state}")" \
    || fatal "ACP token callback failed"
  token_type="$(jq -er '.token_type' <<<"${token_json}")" || fatal "token_type is missing"
  access_token="$(jq -er '.access_token' <<<"${token_json}")" || fatal "access_token is missing"

  log "[PREFLIGHT] downloading kubeconfig for region ${REGION_NAME}"
  curl -fsS "${LYNX_CURL_TLS_ARGS[@]}" --max-time 60 \
    -H "Authorization: $(awk '{print toupper(substr($0,1,1)) substr($0,2)}' <<<"${token_type}") ${access_token}" \
    "${API_URL}/auth/v1/clusters/${REGION_NAME}/kubeconfig" | \
    jq '(.clusters[]?.cluster."certificate-authority-data") |= @base64' >"${KUBECONFIG}" \
    || fatal "failed to obtain kubeconfig for region ${REGION_NAME}"
  chmod 0600 "${KUBECONFIG}"

  unset PASSWORD password_payload encrypted_password local_login_json access_token token_json
  kubectl --request-timeout=30s -n kube-public get configmap global-info >/dev/null \
    || fatal "region ${REGION_NAME} is not reachable through its kubeconfig"
}

cleanup_auth() {
  rm -rf "${LYNX_AUTH_DIR:-}" "${LYNX_OWNED_KUBECONFIG:-}" 2>/dev/null || true
}
