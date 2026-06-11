#!/bin/sh
set -eu

family="${1:?base family required}"
variant="${2:?variant required}"

apache_cert_dir="/etc/apache2/certs"
apache_docroot="/var/www/html"

install_packages() {
  case "${family}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends apache2 openssl ca-certificates
      rm -rf /var/lib/apt/lists/*
      ;;
    alpine)
      apk add --no-cache apache2 apache2-ctl apache2-ssl openssl ca-certificates
      apache_cert_dir="/etc/ssl/apache2"
      apache_docroot="/var/www/localhost/htdocs"
      ;;
    rhel)
      dnf install -y httpd mod_ssl openssl ca-certificates
      dnf clean all
      rm -rf /var/cache/dnf
      apache_cert_dir="/etc/pki/tls/private/pqc4free"
      ;;
    *)
      echo "unsupported base family: ${family}" >&2
      exit 1
      ;;
  esac
}

write_marker_page() {
  mkdir -p "${apache_docroot}"
  cat > "${apache_docroot}/index.html" <<EOF
${family} apache ${variant}
EOF
}

configure_debian_apache() {
  groups_line=""
  if [ "${variant}" = "pqc" ]; then
    groups_line="    SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1"
  fi

  mkdir -p /var/run/apache2 /var/lock/apache2 "${apache_cert_dir}"
  /usr/local/bin/generate-cert.sh "${apache_cert_dir}" localhost

  a2enmod ssl headers >/dev/null
  a2dissite 000-default default-ssl >/dev/null 2>&1 || true

  cat > /etc/apache2/sites-available/pqc4free.conf <<EOF
<VirtualHost *:80>
    ServerName localhost
    Redirect permanent / https://localhost/
</VirtualHost>

<VirtualHost *:443>
    ServerName localhost
    DocumentRoot ${apache_docroot}

    SSLEngine on
    SSLCertificateFile ${apache_cert_dir}/server.crt
    SSLCertificateKeyFile ${apache_cert_dir}/server.key
    SSLProtocol -all +TLSv1.3 +TLSv1.2
${groups_line}

    Header always set Content-Type "text/plain"
</VirtualHost>
EOF

  cat > /etc/apache2/ports.conf <<'EOF'
Listen 80
Listen 443
EOF

  a2ensite pqc4free >/dev/null
  apache2ctl configtest
}

configure_alpine_apache() {
  groups_line=""
  if [ "${variant}" = "pqc" ]; then
    groups_line="    SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1"
  fi

  mkdir -p /run/apache2 "${apache_cert_dir}"
  /usr/local/bin/generate-cert.sh "${apache_cert_dir}" localhost

  rm -f /etc/apache2/conf.d/ssl.conf
  cat > /etc/apache2/conf.d/00-pqc4free-ssl-modules.conf <<'EOF'
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
Listen 443
EOF

  cat > /etc/apache2/conf.d/pqc4free.conf <<EOF
ServerName localhost

<VirtualHost *:80>
    ServerName localhost
    Redirect permanent / https://localhost/
</VirtualHost>

<VirtualHost *:443>
    ServerName localhost
    DocumentRoot ${apache_docroot}

    SSLEngine on
    SSLCertificateFile ${apache_cert_dir}/server.crt
    SSLCertificateKeyFile ${apache_cert_dir}/server.key
    SSLProtocol -all +TLSv1.3 +TLSv1.2
${groups_line}

    Header always set Content-Type "text/plain"
</VirtualHost>
EOF

  httpd -t
}

configure_rhel_apache() {
  groups_line=""
  if [ "${variant}" = "pqc" ]; then
    groups_line="    SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1"
  fi

  mkdir -p /run/httpd "${apache_cert_dir}"
  /usr/local/bin/generate-cert.sh "${apache_cert_dir}" localhost

  rm -f /etc/httpd/conf.d/ssl.conf
  cat > /etc/httpd/conf.d/00-pqc4free-ssl-listen.conf <<'EOF'
Listen 443
EOF

  cat > /etc/httpd/conf.d/pqc4free.conf <<EOF
ServerName localhost

<VirtualHost *:80>
    ServerName localhost
    Redirect permanent / https://localhost/
</VirtualHost>

<VirtualHost *:443>
    ServerName localhost
    DocumentRoot ${apache_docroot}

    SSLEngine on
    SSLCertificateFile ${apache_cert_dir}/server.crt
    SSLCertificateKeyFile ${apache_cert_dir}/server.key
    SSLProtocol -all +TLSv1.3 +TLSv1.2
${groups_line}

    Header always set Content-Type "text/plain"
</VirtualHost>
EOF

  httpd -t
}

install_packages
write_marker_page

case "${family}" in
  debian|ubuntu)
    configure_debian_apache
    ;;
  alpine)
    configure_alpine_apache
    ;;
  rhel)
    configure_rhel_apache
    ;;
esac
