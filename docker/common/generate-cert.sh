#!/bin/sh
set -eu

cert_dir="${1:?cert dir required}"
common_name="${2:-localhost}"

mkdir -p "${cert_dir}"

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -keyout "${cert_dir}/server.key" \
  -out "${cert_dir}/server.crt" \
  -days 30 \
  -sha256 \
  -subj "/CN=${common_name}" \
  -addext "subjectAltName=DNS:${common_name},IP:127.0.0.1"
