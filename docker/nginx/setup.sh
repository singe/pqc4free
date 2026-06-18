#!/bin/sh
set -eu

family="${1:?base family required}"
variant="${2:?variant required}"

conf_dir="/etc/nginx/conf.d"

install_packages() {
  case "${family}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update
      apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends ca-certificates nginx openssl
      rm -rf /var/lib/apt/lists/*
      ;;
    alpine)
      apk add --no-cache ca-certificates nginx openssl bash
      conf_dir="/etc/nginx/http.d"
      ;;
    rhel)
      dnf install -y ca-certificates nginx openssl
      dnf clean all
      rm -rf /var/cache/dnf
      ;;
    *)
      echo "unsupported base family: ${family}" >&2
      exit 1
      ;;
  esac
}

write_config() {
  groups_line=""
  default_server_suffix=" default_server"

  if [ "${family}" = "rhel" ]; then
    # UBI/RHEL nginx images already ship a default server on port 80.
    # Use ordinary listeners so our test config can coexist with the base config.
    default_server_suffix=""
  fi

  if [ "${variant}" = "pqc" ]; then
    groups_line="    ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;"
  fi

  rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf /etc/nginx/http.d/default.conf
  mkdir -p /run/nginx /var/www/html "${conf_dir}"
  cat > /var/www/html/index.html <<EOF
${family} nginx ${variant}
EOF

  cat > "${conf_dir}/pqc4free.conf" <<EOF
server {
    listen 80${default_server_suffix};
    listen [::]:80${default_server_suffix};
    server_name localhost;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl${default_server_suffix};
    listen [::]:443 ssl${default_server_suffix};
    server_name localhost;

    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;
    ssl_protocols TLSv1.3 TLSv1.2;
${groups_line}

    location / {
        default_type text/plain;
        root /var/www/html;
    }
}
EOF
}

install_packages
/usr/local/bin/generate-cert.sh /etc/nginx/certs localhost
write_config
nginx -t
