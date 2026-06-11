#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

entries=(
  "nginx|pqc|debian|debian:trixie|10443"
  "nginx|vanilla|debian|debian:trixie|10444"
  "nginx|pqc|ubuntu|ubuntu:26.04|10445"
  "nginx|vanilla|ubuntu|ubuntu:26.04|10446"
  "nginx|pqc|alpine|alpine:3.22|10447"
  "nginx|vanilla|alpine|alpine:3.22|10448"
  "nginx|pqc|rhel|registry.access.redhat.com/ubi10/ubi|10449"
  "nginx|vanilla|rhel|registry.access.redhat.com/ubi10/ubi|10450"
  "apache|pqc|debian|debian:trixie|11443"
  "apache|vanilla|debian|debian:trixie|11444"
  "apache|pqc|ubuntu|ubuntu:26.04|11445"
  "apache|vanilla|ubuntu|ubuntu:26.04|11446"
  "apache|pqc|alpine|alpine:3.22|11447"
  "apache|vanilla|alpine|alpine:3.22|11448"
  "apache|pqc|rhel|registry.access.redhat.com/ubi10/ubi|11449"
  "apache|vanilla|rhel|registry.access.redhat.com/ubi10/ubi|11450"
)

cleanup() {
  if [ -n "${current_container:-}" ]; then
    docker rm -f "${current_container}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd openssl
require_cmd python3

wait_for_https() {
  local port="$1"
  local i
  for i in $(seq 1 30); do
    if curl -sk --max-time 2 "https://127.0.0.1:${port}/" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

handshake_group() {
  local port="$1"
  local group
  group="$(
    openssl s_client \
      -connect "127.0.0.1:${port}" \
      -servername localhost \
      -tls1_3 \
      -groups X25519MLKEM768:X25519 \
      </dev/null 2>&1 \
      | sed -n 's/^Negotiated TLS1\.3 group: //p' \
      | head -n 1
  )"
  printf '%s' "${group:-unknown}"
}

check_expected_config() {
  local server="$1"
  local variant="$2"
  local container="$3"
  if [ "${server}" = "nginx" ]; then
    if [ "${variant}" = "pqc" ]; then
      docker exec "${container}" sh -lc "nginx -T 2>&1 | grep -q 'ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;'" >/dev/null
    else
      ! docker exec "${container}" sh -lc "nginx -T 2>&1 | grep -q 'ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;'" >/dev/null
    fi
  else
    if [ "${variant}" = "pqc" ]; then
      docker exec "${container}" sh -lc "grep -R -q 'SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1' /etc/apache2 /etc/httpd 2>/dev/null" >/dev/null
    else
      ! docker exec "${container}" sh -lc "grep -R -q 'SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1' /etc/apache2 /etc/httpd 2>/dev/null" >/dev/null
    fi
  fi
}

run_audit() {
  local container="$1"
  docker exec "${container}" sh -lc "/bin/sh /pqc4free.sh --json"
}

printf 'server,variant,family,image,body,group,pqc_status,config_ok\n'

for entry in "${entries[@]}"; do
  IFS='|' read -r server variant family base_image port <<<"${entry}"
  image_tag="pqc4free-${server}-${family}-${variant}"
  container_name="${image_tag}-test"
  current_container=""

  docker rm -f "${container_name}" >/dev/null 2>&1 || true

  docker build \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "BASE_FAMILY=${family}" \
    --build-arg "VARIANT=${variant}" \
    -f "${ROOT_DIR}/Dockerfile.${server}" \
    -t "${image_tag}" \
    "${ROOT_DIR}" >/dev/null

  current_container="${container_name}"
  docker run -d --rm \
    --name "${container_name}" \
    -p "127.0.0.1:${port}:443" \
    -v "${ROOT_DIR}/pqc4free.sh:/pqc4free.sh:ro" \
    "${image_tag}" >/dev/null

  wait_for_https "${port}"
  body="$(curl -sk "https://127.0.0.1:${port}/")"
  group="$(handshake_group "${port}")"
  check_expected_config "${server}" "${variant}" "${container_name}"
  audit_json="$(run_audit "${container_name}")"
  pqc_status="$(python3 -c 'import json,sys; data=json.load(sys.stdin); key=sys.argv[1]; print(data[key]["pqc_status"])' "${server}" <<<"${audit_json}")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${server}" \
    "${variant}" \
    "${family}" \
    "${base_image}" \
    "${body}" \
    "${group}" \
    "${pqc_status}" \
    "yes"

  docker rm -f "${container_name}" >/dev/null
  current_container=""
done
