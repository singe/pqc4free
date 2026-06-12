#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"

PQC_GROUP_PRIMARY="X25519MLKEM768"
PQC_GROUPS="X25519MLKEM768:X25519:secp384r1"

QUIET=0
JSON=0
FAIL_IF_NOT_READY=0

EXIT_OK=0
EXIT_UPGRADE_REQUIRED=1
EXIT_NO_TLS_SITE=2
EXIT_UNKNOWN=3
EXIT_NO_WEBSERVER=4

OS_ID="unknown"
OS_LIKE=""
OS_VERSION_ID=""

IN_CONTAINER=0

OPENSSL_CLI_VERSION="unknown"
OPENSSL_CLI_PQC_STATUS="unknown"
OPENSSL_CLI_PQC_REASON="not checked"

NGINX_INSTALLED=0
NGINX_RUNNING=0
NGINX_BINARY=""
NGINX_VERSION=""
NGINX_OPENSSL=""
NGINX_PQC_STATUS="unknown"
NGINX_PQC_REASON="not checked"
NGINX_TLS_SITE_FOUND=0
NGINX_PQC_GROUPS_CONFIGURED=0
NGINX_SSL_CONF_COMMAND_FOUND=0
NGINX_PROTOCOLS_TLS13_FOUND=0
NGINX_CONFIG_TEST_PQC_STATUS="unknown"
NGINX_UPGRADE_RECOMMENDED=0
NGINX_CONFIG_CHANGE_RECOMMENDED=0

APACHE_INSTALLED=0
APACHE_RUNNING=0
APACHE_BINARY=""
APACHE_CTL=""
APACHE_MOD_SSL=""
APACHE_VERSION=""
APACHE_OPENSSL=""
APACHE_PQC_STATUS="unknown"
APACHE_PQC_REASON="not checked"
APACHE_TLS_SITE_FOUND=0
APACHE_PQC_GROUPS_CONFIGURED=0
APACHE_SSL_CONF_COMMAND_FOUND=0
APACHE_PROTOCOLS_TLS13_FOUND=0
APACHE_UPGRADE_RECOMMENDED=0
APACHE_CONFIG_CHANGE_RECOMMENDED=0

TLS_SITE_ANY=0
UPGRADE_ANY=0
UNKNOWN_ANY=0
WEBSERVER_ANY=0
READY_ANY=0

TMP_FILES=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Audit nginx/Apache readiness for hybrid post-quantum TLS 1.3 key exchange.

Options:
  --json               Print JSON summary only.
  --quiet              Reduce human-readable output.
  --fail-if-not-ready  Return non-zero if upgrade/config work is needed.
  -h, --help           Show this help.

Exit codes:
  0  Ready or audit completed without a hard failure.
  1  Upgrade required.
  2  No TLS-enabled site found.
  3  Unknown / insufficient evidence.
  4  Neither nginx nor Apache found.

Notes:
  - This script does not edit configuration.
  - PQC here means hybrid post-quantum TLS 1.3 key exchange.
  - Existing RSA/ECDSA certificates remain classical.
  - TLS 1.2 remains classical.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON=1
      QUIET=1
      ;;
    --quiet)
      QUIET=1
      ;;
    --fail-if-not-ready)
      FAIL_IF_NOT_READY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 3
      ;;
  esac
  shift
done

hr() {
  [ "$QUIET" -eq 0 ] && printf '%s\n' "----------------------------------------------------------------------"
}

say() {
  [ "$QUIET" -eq 0 ] && printf '%s\n' "$*"
}

info() {
  [ "$QUIET" -eq 0 ] && printf '[INFO] %s\n' "$*"
}

ok() {
  [ "$QUIET" -eq 0 ] && printf '[ OK ] %s\n' "$*"
}

warn() {
  [ "$QUIET" -eq 0 ] && printf '[WARN] %s\n' "$*"
}

bad() {
  [ "$QUIET" -eq 0 ] && printf '[FAIL] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

add_tmp_file() {
  TMP_FILES="${TMP_FILES} $1"
}

cleanup() {
  for p in $TMP_FILES; do
    [ -e "$p" ] && rm -rf "$p"
  done
}

trap cleanup EXIT INT TERM

json_escape() {
  # Minimal JSON string escaper.
  # shellcheck disable=SC2001
  printf '%s' "$1" \
    | sed \
      -e 's/\\/\\\\/g' \
      -e 's/"/\\"/g' \
      -e 's/	/\\t/g' \
      -e 's/\r/\\r/g' \
      -e ':a;N;$!ba;s/\n/\\n/g'
}

json_bool() {
  case "$1" in
    1|yes|true|ready|likely) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

run_maybe_sudo() {
  if "$@" >/tmp/pqc_audit_cmd.out 2>/tmp/pqc_audit_cmd.err; then
    cat /tmp/pqc_audit_cmd.out
    return 0
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ] && have_cmd sudo; then
    if sudo -n "$@" >/tmp/pqc_audit_cmd.out 2>/tmp/pqc_audit_cmd.err; then
      cat /tmp/pqc_audit_cmd.out
      return 0
    fi
  fi

  cat /tmp/pqc_audit_cmd.err >&2
  return 1
}

running_in_container() {
  [ -f /.dockerenv ] && return 0
  [ -f /run/.containerenv ] && return 0

  if [ -r /proc/1/cgroup ]; then
    grep -qaE 'docker|containerd|kubepods|podman|lxc' /proc/1/cgroup && return 0
  fi

  if [ -r /proc/1/environ ]; then
    tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -q '^container=' && return 0
  fi

  return 1
}

service_running() {
  svc="$1"

  if have_cmd systemctl && [ "$IN_CONTAINER" -eq 0 ]; then
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      return 0
    fi
  fi

  if have_cmd service && [ "$IN_CONTAINER" -eq 0 ]; then
    if service "$svc" status >/dev/null 2>&1; then
      return 0
    fi
  fi

  if have_cmd pgrep; then
    pgrep -x "$svc" >/dev/null 2>&1 && return 0
  fi

  if have_cmd pidof; then
    pidof "$svc" >/dev/null 2>&1 && return 0
  fi

  if have_cmd ps; then
    ps -eo comm= 2>/dev/null | grep -qx "$svc" && return 0
  fi

  for proc_comm in /proc/[0-9]*/comm; do
    [ -r "$proc_comm" ] || continue
    if [ "$(cat "$proc_comm" 2>/dev/null)" = "$svc" ]; then
      return 0
    fi
  done

  return 1
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
  fi

  if running_in_container; then
    IN_CONTAINER=1
  fi
}

openssl_cli_version() {
  if have_cmd openssl; then
    openssl version 2>/dev/null || printf 'unknown'
  else
    printf 'openssl CLI not found'
  fi
}

openssl_cli_supports_pqc() {
  have_cmd openssl || return 1

  # Correct OpenSSL 3.x syntax.
  openssl list -tls-groups -tls1_3 2>/dev/null \
    | grep -Fqi "${PQC_GROUP_PRIMARY}" && return 0

  openssl list -all-tls-groups -tls1_3 2>/dev/null \
    | grep -Fqi "${PQC_GROUP_PRIMARY}" && return 0

  # Weaker evidence: the provider has ML-KEM, but TLS group listing did not prove
  # the specific hybrid TLS group.
  openssl list -kem-algorithms 2>/dev/null \
    | grep -Eqi 'ML-?KEM|MLKEM' && return 2

  return 1
}

assess_openssl_cli() {
  OPENSSL_CLI_VERSION="$(openssl_cli_version)"

  if openssl_cli_supports_pqc; then
    OPENSSL_CLI_PQC_STATUS="yes"
    OPENSSL_CLI_PQC_REASON="openssl CLI lists ${PQC_GROUP_PRIMARY} as a TLS 1.3 group"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      OPENSSL_CLI_PQC_STATUS="likely"
      OPENSSL_CLI_PQC_REASON="openssl CLI lists ML-KEM algorithms, but the TLS group list did not prove ${PQC_GROUP_PRIMARY}"
    else
      OPENSSL_CLI_PQC_STATUS="no"
      OPENSSL_CLI_PQC_REASON="openssl CLI did not list ${PQC_GROUP_PRIMARY} or ML-KEM"
    fi
  fi
}

version_text_suggests_openssl_35() {
  text="$1"
  printf '%s\n' "$text" | grep -Eq 'OpenSSL[[:space:]]+3\.[5-9]\.|OpenSSL[[:space:]][4-9]\.'
}

extract_openssl_from_version_text() {
  text="$1"
  printf '%s\n' "$text" \
    | grep -Eo 'OpenSSL[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*([[:space:]][0-9A-Za-z]+)?([[:space:]][0-9]{4})?' \
    | head -n 1
}

find_linked_libssl() {
  bin="$1"

  if ! have_cmd ldd || [ ! -x "$bin" ]; then
    return 1
  fi

  ldd "$bin" 2>/dev/null \
    | awk '/libssl\.so/ { for (i=1; i<=NF; i++) if ($i ~ /^\//) print $i }' \
    | head -n 1
}

libssl_supports_pqc_by_strings() {
  lib="$1"

  if [ -n "$lib" ] && [ -r "$lib" ] && have_cmd strings; then
    strings "$lib" 2>/dev/null | grep -q "$PQC_GROUP_PRIMARY"
    return $?
  fi

  return 1
}

nginx_bin() {
  command -v nginx 2>/dev/null || true
}

apache_bin() {
  if command -v apache2 >/dev/null 2>&1; then
    command -v apache2
  elif command -v httpd >/dev/null 2>&1; then
    command -v httpd
  else
    true
  fi
}

apache_ctl() {
  if command -v apachectl >/dev/null 2>&1; then
    command -v apachectl
  elif command -v apache2ctl >/dev/null 2>&1; then
    command -v apache2ctl
  else
    true
  fi
}

find_apache_mod_ssl_module() {
  for p in \
    /usr/lib/apache2/modules/mod_ssl.so \
    /usr/lib64/httpd/modules/mod_ssl.so \
    /usr/lib/httpd/modules/mod_ssl.so \
    /etc/httpd/modules/mod_ssl.so \
    /usr/local/apache2/modules/mod_ssl.so
  do
    [ -r "$p" ] && printf '%s\n' "$p" && return 0
  done

  return 1
}

nginx_full_config_to_file() {
  out="$1"

  if have_cmd nginx; then
    if nginx -T >"$out" 2>&1; then
      return 0
    fi

    if [ "${EUID:-$(id -u)}" -ne 0 ] && have_cmd sudo; then
      sudo -n nginx -T >"$out" 2>&1 && return 0
    fi
  fi

  return 1
}

apache_vhost_summary_to_file() {
  out="$1"
  ctl="$(apache_ctl)"

  [ -n "$ctl" ] || return 1

  if "$ctl" -S >"$out" 2>&1; then
    return 0
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ] && have_cmd sudo; then
    sudo -n "$ctl" -S >"$out" 2>&1 && return 0
  fi

  return 1
}

apache_modules_to_file() {
  out="$1"
  ctl="$(apache_ctl)"

  [ -n "$ctl" ] || return 1

  if "$ctl" -M >"$out" 2>&1; then
    return 0
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ] && have_cmd sudo; then
    sudo -n "$ctl" -M >"$out" 2>&1 && return 0
  fi

  return 1
}

probe_apache_accepts_pqc_groups() {
  cmd=""

  if [ -d /etc/httpd ] && [ -n "$APACHE_BINARY" ]; then
    cmd="$APACHE_BINARY"
  elif [ -n "$APACHE_CTL" ]; then
    cmd="$APACHE_CTL"
  elif [ -n "$APACHE_BINARY" ]; then
    cmd="$APACHE_BINARY"
  else
    return 3
  fi

  if "$cmd" -t -c "SSLOpenSSLConfCmd Groups $PQC_GROUPS" >/dev/null 2>&1; then
    return 0
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ] && have_cmd sudo; then
    sudo -n "$cmd" -t -c "SSLOpenSSLConfCmd Groups $PQC_GROUPS" >/dev/null 2>&1 && return 0
  fi

  return 1
}

probe_nginx_accepts_pqc_groups() {
  nbin="$(nginx_bin)"
  [ -n "$nbin" ] || return 3
  have_cmd openssl || return 3

  tmpdir="$(mktemp -d)"
  add_tmp_file "$tmpdir"

  mkdir -p "$tmpdir/logs" "$tmpdir/client_body_temp" "$tmpdir/proxy_temp" \
           "$tmpdir/fastcgi_temp" "$tmpdir/uwsgi_temp" "$tmpdir/scgi_temp"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$tmpdir/key.pem" \
    -out "$tmpdir/cert.pem" \
    -days 1 \
    -subj "/CN=localhost" >/dev/null 2>&1 || return 3

  cat > "$tmpdir/nginx.conf" <<EOF
pid $tmpdir/nginx.pid;
error_log $tmpdir/logs/error.log;

events {
    worker_connections 16;
}

http {
    client_body_temp_path $tmpdir/client_body_temp;
    proxy_temp_path       $tmpdir/proxy_temp;
    fastcgi_temp_path     $tmpdir/fastcgi_temp;
    uwsgi_temp_path       $tmpdir/uwsgi_temp;
    scgi_temp_path        $tmpdir/scgi_temp;

    server {
        listen 127.0.0.1:9443 ssl;
        server_name localhost;

        ssl_certificate     $tmpdir/cert.pem;
        ssl_certificate_key $tmpdir/key.pem;

        ssl_protocols TLSv1.3 TLSv1.2;
        ssl_conf_command Groups $PQC_GROUPS;

        return 200 "ok\n";
    }
}
EOF

  "$nbin" -t -c "$tmpdir/nginx.conf" -p "$tmpdir" >/dev/null 2>&1
  rc=$?

  if [ "$rc" -eq 0 ]; then
    return 0
  fi

  return 1
}

assess_nginx_binary() {
  NGINX_BINARY="$(nginx_bin)"

  if [ -z "$NGINX_BINARY" ]; then
    NGINX_INSTALLED=0
    NGINX_PQC_STATUS="no"
    NGINX_PQC_REASON="nginx binary not found"
    return
  fi

  NGINX_INSTALLED=1
  WEBSERVER_ANY=1

  if service_running nginx; then
    NGINX_RUNNING=1
  fi

  nver="$(nginx -V 2>&1 || true)"
  NGINX_VERSION="$(printf '%s\n' "$nver" | sed -n 's/^nginx version: nginx\///p' | head -n 1)"
  NGINX_OPENSSL="$(extract_openssl_from_version_text "$nver")"

  if version_text_suggests_openssl_35 "$nver"; then
    NGINX_PQC_STATUS="yes"
    NGINX_PQC_REASON="nginx -V reports OpenSSL 3.5+"
  else
    libssl="$(find_linked_libssl "$NGINX_BINARY" || true)"
    if [ -n "$libssl" ] && libssl_supports_pqc_by_strings "$libssl"; then
      NGINX_PQC_STATUS="likely"
      NGINX_PQC_REASON="linked libssl appears to contain ${PQC_GROUP_PRIMARY}"
    elif [ "$OPENSSL_CLI_PQC_STATUS" = "yes" ]; then
      NGINX_PQC_STATUS="unknown"
      NGINX_PQC_REASON="openssl CLI supports ${PQC_GROUP_PRIMARY}, but nginx linkage could not be proven"
    else
      NGINX_PQC_STATUS="no"
      NGINX_PQC_REASON="nginx does not appear to be linked against OpenSSL 3.5+ or a libssl containing ${PQC_GROUP_PRIMARY}"
    fi
  fi

  # Configtest acceptance proves syntax only. It does not prove the linked
  # OpenSSL stack can negotiate X25519MLKEM768 at runtime, so keep it out of the
  # readiness classification.
  if probe_nginx_accepts_pqc_groups; then
    NGINX_CONFIG_TEST_PQC_STATUS="yes"
  else
    rc=$?
    if [ "$rc" -eq 3 ]; then
      NGINX_CONFIG_TEST_PQC_STATUS="unknown"
    else
      NGINX_CONFIG_TEST_PQC_STATUS="no"
      if [ "$NGINX_PQC_STATUS" = "yes" ] || [ "$NGINX_PQC_STATUS" = "likely" ]; then
        NGINX_PQC_STATUS="unknown"
        NGINX_PQC_REASON="nginx appears OpenSSL 3.5-capable, but a temporary configtest did not accept the Groups directive"
      fi
    fi
  fi
}

scan_nginx_config() {
  [ "$NGINX_INSTALLED" -eq 1 ] || return

  tmp="$(mktemp)"
  add_tmp_file "$tmp"

  if nginx_full_config_to_file "$tmp"; then
    if grep -Eiq 'listen[[:space:]][^;]*(443|ssl)' "$tmp" \
       && grep -Eiq 'ssl_certificate[[:space:]]+' "$tmp"; then
      NGINX_TLS_SITE_FOUND=1
      TLS_SITE_ANY=1
    fi

    grep -Eiq 'ssl_conf_command[[:space:]]+Groups[[:space:]]+.*X25519MLKEM768' "$tmp" \
      && NGINX_PQC_GROUPS_CONFIGURED=1

    grep -Eiq 'ssl_conf_command[[:space:]]+' "$tmp" \
      && NGINX_SSL_CONF_COMMAND_FOUND=1

    grep -Eiq 'ssl_protocols[[:space:]][^;]*TLSv1\.3' "$tmp" \
      && NGINX_PROTOCOLS_TLS13_FOUND=1

    if [ "$QUIET" -eq 0 ]; then
      say
      say "nginx TLS configuration signals:"
      if [ "$NGINX_TLS_SITE_FOUND" -eq 1 ]; then
        ok "Found at least one likely TLS-enabled nginx site."
      else
        warn "No nginx server block with both a 443/ssl listener and ssl_certificate was obvious from nginx -T."
      fi

      if [ "$NGINX_PQC_GROUPS_CONFIGURED" -eq 1 ]; then
        ok "Found existing nginx Groups directive containing ${PQC_GROUP_PRIMARY}."
      else
        info "No existing nginx Groups directive containing ${PQC_GROUP_PRIMARY} found."
      fi

      if [ "$NGINX_SSL_CONF_COMMAND_FOUND" -eq 1 ]; then
        warn "Existing nginx ssl_conf_command directives found. Inheritance can be surprising; add Groups at the same level as existing ssl_conf_command directives."
      fi

      if [ "$NGINX_PROTOCOLS_TLS13_FOUND" -eq 1 ]; then
        ok "Found nginx ssl_protocols enabling TLSv1.3."
      else
        info "No nginx ssl_protocols line enabling TLSv1.3 was obvious."
      fi

      say
      say "Relevant nginx config lines:"
      grep -nE 'server_name|listen[[:space:]].*(443|ssl)|ssl_certificate|ssl_protocols|ssl_conf_command[[:space:]]+' "$tmp" \
        | sed 's/^/  /' || true
    fi
  else
    warn "Could not run nginx -T. Falling back to grep in /etc/nginx."

    if [ -d /etc/nginx ]; then
      grep -RIEiq 'listen[[:space:]][^;]*(443|ssl)' /etc/nginx 2>/dev/null \
        && grep -RIEiq 'ssl_certificate[[:space:]]+' /etc/nginx 2>/dev/null \
        && NGINX_TLS_SITE_FOUND=1 \
        && TLS_SITE_ANY=1

      grep -RIEiq 'ssl_conf_command[[:space:]]+Groups[[:space:]]+.*X25519MLKEM768' /etc/nginx 2>/dev/null \
        && NGINX_PQC_GROUPS_CONFIGURED=1

      grep -RIEiq 'ssl_conf_command[[:space:]]+' /etc/nginx 2>/dev/null \
        && NGINX_SSL_CONF_COMMAND_FOUND=1

      grep -RIEiq 'ssl_protocols[[:space:]][^;]*TLSv1\.3' /etc/nginx 2>/dev/null \
        && NGINX_PROTOCOLS_TLS13_FOUND=1
    fi
  fi
}

assess_apache_binary() {
  APACHE_BINARY="$(apache_bin)"
  APACHE_CTL="$(apache_ctl)"
  APACHE_MOD_SSL=""

  if [ -z "$APACHE_BINARY" ] && [ -z "$APACHE_CTL" ]; then
    APACHE_INSTALLED=0
    APACHE_PQC_STATUS="no"
    APACHE_PQC_REASON="Apache binary/control command not found"
    return
  fi

  APACHE_INSTALLED=1
  WEBSERVER_ANY=1

  if service_running apache2 || service_running httpd; then
    APACHE_RUNNING=1
  fi

  if [ -n "$APACHE_BINARY" ]; then
    aver="$("$APACHE_BINARY" -V 2>&1 || true)"
  else
    aver="$("$APACHE_CTL" -V 2>&1 || true)"
  fi

  APACHE_VERSION="$(printf '%s\n' "$aver" | sed -n 's/^Server version: Apache\///p' | head -n 1)"
  APACHE_OPENSSL="$(extract_openssl_from_version_text "$aver")"

  # Apache often loads mod_ssl dynamically, so this is less conclusive than nginx.
  if version_text_suggests_openssl_35 "$aver"; then
    APACHE_PQC_STATUS="likely"
    APACHE_PQC_REASON="Apache -V reports OpenSSL 3.5+; mod_ssl linkage should still be validated"
  else
    libssl=""
    APACHE_MOD_SSL="$(find_apache_mod_ssl_module || true)"
    if [ -n "$APACHE_MOD_SSL" ]; then
      libssl="$(find_linked_libssl "$APACHE_MOD_SSL" || true)"
    elif [ -n "$APACHE_BINARY" ]; then
      libssl="$(find_linked_libssl "$APACHE_BINARY" || true)"
    fi

    if [ -n "$libssl" ] && libssl_supports_pqc_by_strings "$libssl"; then
      APACHE_PQC_STATUS="likely"
      if [ -n "$APACHE_MOD_SSL" ]; then
        APACHE_PQC_REASON="Apache mod_ssl links to a libssl that appears to contain ${PQC_GROUP_PRIMARY}"
      else
        APACHE_PQC_REASON="Apache linked libssl appears to contain ${PQC_GROUP_PRIMARY}; mod_ssl should still be validated"
      fi
    elif [ "$OPENSSL_CLI_PQC_STATUS" = "yes" ]; then
      APACHE_PQC_STATUS="unknown"
      APACHE_PQC_REASON="openssl CLI supports ${PQC_GROUP_PRIMARY}, but Apache/mod_ssl linkage could not be proven"
    else
      APACHE_PQC_STATUS="no"
      APACHE_PQC_REASON="Apache does not appear to be linked against OpenSSL 3.5+ or a libssl containing ${PQC_GROUP_PRIMARY}"
    fi
  fi

  # Apache configtest also validates syntax only. Keep it out of the readiness
  # classification so a host is not marked likely-ready without runtime/library
  # evidence.
  probe_apache_accepts_pqc_groups >/dev/null 2>&1 || true
}

scan_apache_config() {
  [ "$APACHE_INSTALLED" -eq 1 ] || return

  found_dir=0

  for d in /etc/apache2 /etc/httpd /usr/local/apache2/conf; do
    [ -d "$d" ] || continue
    found_dir=1

    grep -RIEiq '<VirtualHost[[:space:]][^>]*:443|SSLEngine[[:space:]]+on|SSLCertificateFile' "$d" 2>/dev/null \
      && APACHE_TLS_SITE_FOUND=1 \
      && TLS_SITE_ANY=1

    grep -RIEiq 'SSLOpenSSLConfCmd[[:space:]]+Groups[[:space:]]+.*X25519MLKEM768' "$d" 2>/dev/null \
      && APACHE_PQC_GROUPS_CONFIGURED=1

    grep -RIEiq 'SSLOpenSSLConfCmd[[:space:]]+' "$d" 2>/dev/null \
      && APACHE_SSL_CONF_COMMAND_FOUND=1

    grep -RIEiq 'SSLProtocol[[:space:]].*TLSv1\.3|\+TLSv1\.3' "$d" 2>/dev/null \
      && APACHE_PROTOCOLS_TLS13_FOUND=1
  done

  if [ "$QUIET" -eq 0 ]; then
    say
    say "Apache TLS configuration signals:"

    if [ "$found_dir" -eq 0 ]; then
      warn "No common Apache config directory was readable."
    fi

    if [ "$APACHE_TLS_SITE_FOUND" -eq 1 ]; then
      ok "Found likely Apache TLS/SSL vhost configuration."
    else
      warn "No Apache TLS-enabled vhost was obvious from common config directories."
    fi

    if [ "$APACHE_PQC_GROUPS_CONFIGURED" -eq 1 ]; then
      ok "Found existing Apache Groups directive containing ${PQC_GROUP_PRIMARY}."
    else
      info "No existing Apache Groups directive containing ${PQC_GROUP_PRIMARY} found."
    fi

    if [ "$APACHE_SSL_CONF_COMMAND_FOUND" -eq 1 ]; then
      info "Existing Apache SSLOpenSSLConfCmd directives found; merge Groups with existing OpenSSL config policy carefully."
    fi

    if [ "$APACHE_PROTOCOLS_TLS13_FOUND" -eq 1 ]; then
      ok "Found Apache SSLProtocol enabling TLSv1.3."
    else
      info "No Apache SSLProtocol line enabling TLSv1.3 was obvious."
    fi

    say
    say "Relevant Apache config lines:"
    for d in /etc/apache2 /etc/httpd /usr/local/apache2/conf; do
      [ -d "$d" ] || continue
      grep -RInE '<VirtualHost[[:space:]][^>]*:443|ServerName|SSLEngine[[:space:]]+on|SSLCertificateFile|SSLProtocol|SSLOpenSSLConfCmd[[:space:]]+' "$d" 2>/dev/null \
        | sed 's/^/  /' || true
    done
  fi
}

compute_recommendations() {
  if [ "$NGINX_INSTALLED" -eq 1 ]; then
    case "$NGINX_PQC_STATUS" in
      yes|likely)
        NGINX_UPGRADE_RECOMMENDED=0
        ;;
      no)
        NGINX_UPGRADE_RECOMMENDED=1
        UPGRADE_ANY=1
        ;;
      *)
        UNKNOWN_ANY=1
        ;;
    esac

    if [ "$NGINX_TLS_SITE_FOUND" -eq 0 ] || \
       [ "$NGINX_PQC_GROUPS_CONFIGURED" -eq 0 ] || \
       [ "$NGINX_PROTOCOLS_TLS13_FOUND" -eq 0 ]; then
      NGINX_CONFIG_CHANGE_RECOMMENDED=1
    fi

    if [ "$NGINX_PQC_STATUS" = "yes" ] || [ "$NGINX_PQC_STATUS" = "likely" ]; then
      READY_ANY=1
    fi
  fi

  if [ "$APACHE_INSTALLED" -eq 1 ]; then
    case "$APACHE_PQC_STATUS" in
      yes|likely)
        APACHE_UPGRADE_RECOMMENDED=0
        ;;
      no)
        APACHE_UPGRADE_RECOMMENDED=1
        UPGRADE_ANY=1
        ;;
      *)
        UNKNOWN_ANY=1
        ;;
    esac

    if [ "$APACHE_TLS_SITE_FOUND" -eq 0 ] || \
       [ "$APACHE_PQC_GROUPS_CONFIGURED" -eq 0 ] || \
       [ "$APACHE_PROTOCOLS_TLS13_FOUND" -eq 0 ]; then
      APACHE_CONFIG_CHANGE_RECOMMENDED=1
    fi

    if [ "$APACHE_PQC_STATUS" = "yes" ] || [ "$APACHE_PQC_STATUS" = "likely" ]; then
      READY_ANY=1
    fi
  fi
}

print_upgrade_hint() {
  [ "$UPGRADE_ANY" -eq 1 ] || return

  hr
  say "Upgrade hint for this host:"
  say

  case "$OS_ID:$OS_LIKE" in
    debian:*|ubuntu:*|*:debian*)
      cat <<'EOF'
Debian/Ubuntu-style system detected.

Suggested path:
  1. Check packaged versions:
       apt-cache policy openssl nginx apache2

  2. Try normal package upgrades first:
       sudo apt update
       sudo apt install --only-upgrade openssl nginx apache2

  3. If OpenSSL remains below 3.5 or the web server remains linked to an older libssl:
       - upgrade to a distribution release that packages OpenSSL 3.5+; or
       - use a trusted vendor/backports repository that provides nginx/apache linked to OpenSSL 3.5+; or
       - use a newer container image/base OS.

Do not merely install a newer openssl CLI. nginx/apache must be linked against a libssl that supports the PQC TLS group.
EOF
      ;;
    rhel:*|centos:*|fedora:*|rocky:*|almalinux:*|*:rhel*|*:fedora*)
      cat <<'EOF'
Red Hat/Fedora-style system detected.

Suggested path:
  1. Check packaged versions:
       rpm -q openssl nginx httpd
       dnf info openssl nginx httpd

  2. Try normal package upgrades first:
       sudo dnf upgrade openssl nginx httpd

     On older systems:
       sudo yum update openssl nginx httpd

  3. If OpenSSL remains below 3.5 or the web server remains linked to an older libssl:
       - move to a distro release that packages OpenSSL 3.5+; or
       - use a trusted vendor stream that ships httpd/nginx linked to OpenSSL 3.5+; or
       - use a newer container base.

Many enterprise releases intentionally keep OpenSSL conservative. That may require a platform or vendor-stream upgrade.
EOF
      ;;
    alpine:*|*:alpine*)
      cat <<'EOF'
Alpine system detected.

Suggested path:
  1. Check packaged versions:
       apk info -v openssl nginx apache2

  2. Try normal package upgrades first:
       sudo apk update
       sudo apk upgrade openssl nginx apache2

  3. If OpenSSL remains below 3.5 or the web server remains linked to an older libssl:
       - move to a newer Alpine release; or
       - use a newer container image/tag; or
       - rebuild nginx/apache against an OpenSSL 3.5+ package from a trusted repository.
EOF
      ;;
    *)
      cat <<'EOF'
Unknown or uncommon distribution.

Suggested path:
  1. Identify the package manager and installed packages for openssl plus nginx/apache.
  2. Upgrade the web server and OpenSSL packages from the OS/vendor repository.
  3. If linked libssl still lacks X25519MLKEM768, upgrade the distro/release or use a newer container base.
  4. Confirm the web server is linked against the new OpenSSL library.
EOF
      ;;
  esac
}

print_nginx_recommendation() {
  [ "$NGINX_INSTALLED" -eq 1 ] || return
  [ "$NGINX_CONFIG_CHANGE_RECOMMENDED" -eq 1 ] || return

  cat <<EOF

Recommended nginx change
------------------------

Add or merge these directives inside each HTTPS server block, or at http{} level
only if no lower-level ssl_conf_command directives override inheritance:

    ssl_protocols TLSv1.3 TLSv1.2;
    ssl_conf_command Groups $PQC_GROUPS;

If an ssl_protocols line already exists:
    - make sure TLSv1.3 is present;
    - keep TLSv1.2 only if you still need legacy client compatibility.

If an ssl_conf_command Groups line already exists:
    - replace or merge it so that $PQC_GROUP_PRIMARY is first;
    - keep classical fallbacks after it, for example X25519 and secp384r1.

Important nginx inheritance note:
    ssl_conf_command directives inherit from a higher level only when there are
    no ssl_conf_command directives at the current level. If a server block
    already has any ssl_conf_command directive, add Groups in that same block.

Example:

    server {
        listen 443 ssl;
        server_name example.com;

        ssl_certificate     /path/to/fullchain.pem;
        ssl_certificate_key /path/to/privkey.pem;

        ssl_protocols TLSv1.3 TLSv1.2;
        ssl_conf_command Groups $PQC_GROUPS;
    }

EOF

  if [ "$IN_CONTAINER" -eq 1 ]; then
    cat <<'EOF'
Validate/reload in a container:

    nginx -t
    nginx -s reload

In immutable container deployments, rebuild/redeploy the container instead of editing it in place.
EOF
  else
    cat <<'EOF'
Validate/reload on a systemd host:

    sudo nginx -t
    sudo systemctl reload nginx
EOF
  fi
}

print_apache_recommendation() {
  [ "$APACHE_INSTALLED" -eq 1 ] || return
  [ "$APACHE_CONFIG_CHANGE_RECOMMENDED" -eq 1 ] || return

  cat <<EOF

Recommended Apache change
-------------------------

Add or merge these directives inside each SSL VirtualHost, or in the global SSL
config if that matches your config style:

    SSLProtocol -all +TLSv1.3 +TLSv1.2
    SSLOpenSSLConfCmd Groups $PQC_GROUPS

If an SSLProtocol line already exists:
    - make sure TLSv1.3 is enabled;
    - keep TLSv1.2 only if you still need legacy client compatibility.

If an SSLOpenSSLConfCmd Groups line already exists:
    - replace or merge it so that $PQC_GROUP_PRIMARY is first;
    - keep classical fallbacks after it, for example X25519 and secp384r1.

Example:

    <VirtualHost *:443>
        ServerName example.com

        SSLEngine on
        SSLCertificateFile /path/to/fullchain.pem
        SSLCertificateKeyFile /path/to/privkey.pem

        SSLProtocol -all +TLSv1.3 +TLSv1.2
        SSLOpenSSLConfCmd Groups $PQC_GROUPS
    </VirtualHost>

EOF

  if [ "$IN_CONTAINER" -eq 1 ]; then
    cat <<'EOF'
Validate/reload in a container:

    apachectl configtest
    apachectl graceful

In immutable container deployments, rebuild/redeploy the container instead of editing it in place.
EOF
  else
    cat <<'EOF'
Validate/reload on Debian/Ubuntu:

    sudo apachectl configtest
    sudo systemctl reload apache2

Validate/reload on Red Hat-style systems:

    sudo apachectl configtest
    sudo systemctl reload httpd
EOF
  fi
}

print_runtime_test_hint() {
  cat <<EOF

Live negotiation test
---------------------

From a client with OpenSSL 3.5+:

    openssl s_client \\
      -connect example.com:443 \\
      -servername example.com \\
      -tls1_3 \\
      -groups $PQC_GROUP_PRIMARY:X25519

You want to confirm that the negotiated group is $PQC_GROUP_PRIMARY.
If the client or server OpenSSL does not know that group, the test will fail or fall back.

OpenSSL 3.5+ may already offer $PQC_GROUP_PRIMARY by default unless the application
or configuration overrides supported groups. Adding the Groups directive makes
the behaviour explicit and protects against older/custom group settings.
EOF
}

print_human_summary() {
  hr
  say "PQC TLS KEM readiness audit for nginx/Apache"
  hr
  say "Detected OS: $OS_ID $OS_VERSION_ID  ID_LIKE=\"$OS_LIKE\""
  if [ "$IN_CONTAINER" -eq 1 ]; then
    say "Environment: container detected"
  else
    say "Environment: non-container or not detected as container"
  fi
  say "System openssl CLI: $OPENSSL_CLI_VERSION"

  case "$OPENSSL_CLI_PQC_STATUS" in
    yes)
      ok "System openssl CLI lists ${PQC_GROUP_PRIMARY}."
      ;;
    likely)
      warn "System openssl CLI has ML-KEM evidence, but did not prove the ${PQC_GROUP_PRIMARY} TLS group."
      ;;
    no)
      warn "System openssl CLI does not list ${PQC_GROUP_PRIMARY}."
      ;;
    *)
      warn "System openssl CLI PQC status is unknown."
      ;;
  esac

  if [ "$NGINX_INSTALLED" -eq 1 ]; then
    say
    say "nginx:"
    say "  binary:                  $NGINX_BINARY"
    say "  version:                 ${NGINX_VERSION:-unknown}"
    say "  OpenSSL from nginx -V:    ${NGINX_OPENSSL:-unknown}"
    say "  running:                 $([ "$NGINX_RUNNING" -eq 1 ] && printf yes || printf no)"
    say "  PQC binary readiness:    $NGINX_PQC_STATUS"
    say "  PQC reason:              $NGINX_PQC_REASON"
    say "  Groups configtest:       $NGINX_CONFIG_TEST_PQC_STATUS"
    say "  TLS site found:          $([ "$NGINX_TLS_SITE_FOUND" -eq 1 ] && printf yes || printf no)"
    say "  PQC Groups configured:   $([ "$NGINX_PQC_GROUPS_CONFIGURED" -eq 1 ] && printf yes || printf no)"
    say "  TLSv1.3 configured:      $([ "$NGINX_PROTOCOLS_TLS13_FOUND" -eq 1 ] && printf yes || printf no)"
    say "  upgrade recommended:     $([ "$NGINX_UPGRADE_RECOMMENDED" -eq 1 ] && printf yes || printf no)"
    say "  config change needed:    $([ "$NGINX_CONFIG_CHANGE_RECOMMENDED" -eq 1 ] && printf yes || printf no)"

    if [ "$NGINX_RUNNING" -eq 0 ] && [ "$IN_CONTAINER" -eq 1 ]; then
      info "nginx is not running; that is normal if you started the container with an interactive shell instead of the default nginx command."
    elif [ "$NGINX_RUNNING" -eq 0 ]; then
      warn "nginx is installed but does not appear to be running."
    fi

    if [ "$NGINX_UPGRADE_RECOMMENDED" -eq 0 ] && \
       { [ "$NGINX_PQC_STATUS" = "yes" ] || [ "$NGINX_PQC_STATUS" = "likely" ]; }; then
      ok "No nginx/OpenSSL upgrade appears necessary for PQC group support."
    fi
  else
    warn "nginx binary not found."
  fi

  if [ "$APACHE_INSTALLED" -eq 1 ]; then
    say
    say "Apache:"
    say "  binary:                  ${APACHE_BINARY:-not found}"
    say "  control command:         ${APACHE_CTL:-not found}"
    say "  version:                 ${APACHE_VERSION:-unknown}"
    say "  OpenSSL from Apache -V:   ${APACHE_OPENSSL:-unknown}"
    say "  running:                 $([ "$APACHE_RUNNING" -eq 1 ] && printf yes || printf no)"
    say "  PQC binary readiness:    $APACHE_PQC_STATUS"
    say "  PQC reason:              $APACHE_PQC_REASON"
    say "  TLS site found:          $([ "$APACHE_TLS_SITE_FOUND" -eq 1 ] && printf yes || printf no)"
    say "  PQC Groups configured:   $([ "$APACHE_PQC_GROUPS_CONFIGURED" -eq 1 ] && printf yes || printf no)"
    say "  TLSv1.3 configured:      $([ "$APACHE_PROTOCOLS_TLS13_FOUND" -eq 1 ] && printf yes || printf no)"
    say "  upgrade recommended:     $([ "$APACHE_UPGRADE_RECOMMENDED" -eq 1 ] && printf yes || printf no)"
    say "  config change needed:    $([ "$APACHE_CONFIG_CHANGE_RECOMMENDED" -eq 1 ] && printf yes || printf no)"

    if [ "$APACHE_RUNNING" -eq 0 ] && [ "$IN_CONTAINER" -eq 1 ]; then
      info "Apache is not running; that may be normal in an interactive container."
    elif [ "$APACHE_RUNNING" -eq 0 ]; then
      warn "Apache is installed but does not appear to be running."
    fi

    if [ "$APACHE_UPGRADE_RECOMMENDED" -eq 0 ] && \
       { [ "$APACHE_PQC_STATUS" = "yes" ] || [ "$APACHE_PQC_STATUS" = "likely" ]; }; then
      ok "No Apache/OpenSSL upgrade appears necessary based on available evidence."
    fi
  else
    warn "Apache binary/control command not found."
  fi

  if [ "$WEBSERVER_ANY" -eq 0 ]; then
    bad "Neither nginx nor Apache appears to be installed."
  fi

  if [ "$TLS_SITE_ANY" -eq 0 ] && [ "$WEBSERVER_ANY" -eq 1 ]; then
    warn "No TLS-enabled nginx/Apache site was found. Configure an HTTPS site before testing PQC negotiation."
  fi

  if [ "$UPGRADE_ANY" -eq 0 ] && [ "$WEBSERVER_ANY" -eq 1 ]; then
    info "No upgrade advice will be printed because the installed web server evidence does not indicate an OpenSSL upgrade requirement."
  fi
}

print_json() {
  cat <<EOF
{
  "os": {
    "id": "$(json_escape "$OS_ID")",
    "version_id": "$(json_escape "$OS_VERSION_ID")",
    "id_like": "$(json_escape "$OS_LIKE")",
    "container": $(json_bool "$IN_CONTAINER")
  },
  "openssl_cli": {
    "version": "$(json_escape "$OPENSSL_CLI_VERSION")",
    "pqc_status": "$(json_escape "$OPENSSL_CLI_PQC_STATUS")",
    "reason": "$(json_escape "$OPENSSL_CLI_PQC_REASON")"
  },
  "nginx": {
    "installed": $(json_bool "$NGINX_INSTALLED"),
    "running": $(json_bool "$NGINX_RUNNING"),
    "binary": "$(json_escape "$NGINX_BINARY")",
    "version": "$(json_escape "$NGINX_VERSION")",
    "openssl": "$(json_escape "$NGINX_OPENSSL")",
    "pqc_status": "$(json_escape "$NGINX_PQC_STATUS")",
    "pqc_reason": "$(json_escape "$NGINX_PQC_REASON")",
    "configtest_accepts_pqc_groups": "$(json_escape "$NGINX_CONFIG_TEST_PQC_STATUS")",
    "tls_site_found": $(json_bool "$NGINX_TLS_SITE_FOUND"),
    "pqc_groups_configured": $(json_bool "$NGINX_PQC_GROUPS_CONFIGURED"),
    "tls13_configured": $(json_bool "$NGINX_PROTOCOLS_TLS13_FOUND"),
    "upgrade_recommended": $(json_bool "$NGINX_UPGRADE_RECOMMENDED"),
    "config_change_recommended": $(json_bool "$NGINX_CONFIG_CHANGE_RECOMMENDED")
  },
  "apache": {
    "installed": $(json_bool "$APACHE_INSTALLED"),
    "running": $(json_bool "$APACHE_RUNNING"),
    "binary": "$(json_escape "$APACHE_BINARY")",
    "control_command": "$(json_escape "$APACHE_CTL")",
    "version": "$(json_escape "$APACHE_VERSION")",
    "openssl": "$(json_escape "$APACHE_OPENSSL")",
    "pqc_status": "$(json_escape "$APACHE_PQC_STATUS")",
    "pqc_reason": "$(json_escape "$APACHE_PQC_REASON")",
    "tls_site_found": $(json_bool "$APACHE_TLS_SITE_FOUND"),
    "pqc_groups_configured": $(json_bool "$APACHE_PQC_GROUPS_CONFIGURED"),
    "tls13_configured": $(json_bool "$APACHE_PROTOCOLS_TLS13_FOUND"),
    "upgrade_recommended": $(json_bool "$APACHE_UPGRADE_RECOMMENDED"),
    "config_change_recommended": $(json_bool "$APACHE_CONFIG_CHANGE_RECOMMENDED")
  },
  "overall": {
    "webserver_found": $(json_bool "$WEBSERVER_ANY"),
    "tls_site_found": $(json_bool "$TLS_SITE_ANY"),
    "upgrade_recommended": $(json_bool "$UPGRADE_ANY"),
    "unknown_evidence": $(json_bool "$UNKNOWN_ANY"),
    "pqc_group_primary": "$(json_escape "$PQC_GROUP_PRIMARY")",
    "recommended_groups": "$(json_escape "$PQC_GROUPS")"
  }
}
EOF
}

determine_exit_code() {
  if [ "$WEBSERVER_ANY" -eq 0 ]; then
    printf '%s' "$EXIT_NO_WEBSERVER"
    return
  fi

  if [ "$UPGRADE_ANY" -eq 1 ]; then
    printf '%s' "$EXIT_UPGRADE_REQUIRED"
    return
  fi

  if [ "$TLS_SITE_ANY" -eq 0 ]; then
    printf '%s' "$EXIT_NO_TLS_SITE"
    return
  fi

  if [ "$UNKNOWN_ANY" -eq 1 ]; then
    printf '%s' "$EXIT_UNKNOWN"
    return
  fi

  printf '%s' "$EXIT_OK"
}

main() {
  detect_os
  assess_openssl_cli

  assess_nginx_binary
  scan_nginx_config

  assess_apache_binary
  scan_apache_config

  compute_recommendations

  if [ "$JSON" -eq 1 ]; then
    print_json
  else
    print_human_summary
    print_nginx_recommendation
    print_apache_recommendation
    print_upgrade_hint
    print_runtime_test_hint

    hr
    say "Summary notes:"
    cat <<EOF
  - This script does not edit configuration.
  - PQC here means hybrid post-quantum TLS 1.3 key exchange.
  - Existing RSA/ECDSA certificates remain classical.
  - TLS 1.2 remains classical; the PQC KEM group is relevant to TLS 1.3.
  - The web server must be linked against a PQC-capable OpenSSL library; a newer openssl CLI alone is not enough.
EOF
  fi

  rc="$(determine_exit_code)"

  if [ "$FAIL_IF_NOT_READY" -eq 1 ]; then
    exit "$rc"
  fi

  # Without --fail-if-not-ready, behave like a normal audit command:
  # report findings but do not fail shells/pipelines unless there is no webserver.
  if [ "$rc" -eq "$EXIT_NO_WEBSERVER" ]; then
    exit "$rc"
  fi

  exit 0
}

main "$@"
