# pqc4free.sh

`pqc4free.sh` is a read-only audit and recommendation script for checking whether an existing **nginx** or **Apache HTTP Server** deployment is ready to enable **hybrid post-quantum TLS 1.3 key exchange** using OpenSSL’s `X25519MLKEM768` group.

It is intended to answer a practical operational question:

> “Can this web server enable hybrid PQC TLS key exchange with a small configuration change, or does the platform need an OpenSSL/web-server upgrade first?”

The script does **not** modify system configuration. It detects, assesses, and recommends.

---

## Table of contents

- [Installation](#Installation)
- [Basic usage](#Basic-usage)
- [Options](#Options)
- [Testing matrix](#Confirmed-matrix)

---

## What problem does this solve?

OpenSSL 3.5 introduced native support for ML-KEM and hybrid TLS groups such as:

```text
X25519MLKEM768
```

Modern nginx and Apache can pass TLS group configuration through to OpenSSL. This means that, on a sufficiently new platform, enabling hybrid post-quantum TLS key exchange may be as simple as adding one OpenSSL group configuration directive to the web-server TLS configuration.

For nginx:

```nginx
ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;
```

For Apache:

```apache
SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1
```

However, this only works when the web server is actually linked against an OpenSSL library that understands the group.

This script checks that distinction.

---

## What “PQC support” means here

In this README and script, **PQC support** means:

> Hybrid post-quantum TLS 1.3 key exchange using `X25519MLKEM768`.

This is **not** the same as having a post-quantum certificate.

An existing RSA or ECDSA certificate remains classical. The intended deployment model is:

```text
Classical certificate authentication
+
TLS 1.3 hybrid post-quantum forward-secret key exchange
```

In practical terms, this mitigates the main “harvest now, decrypt later” concern for TLS key exchange, assuming the client and server successfully negotiate the hybrid group.

---

## What the script checks

The script checks four broad areas.

### 1. Whether nginx or Apache is installed and running

It detects:

- whether `nginx` is installed;
- whether Apache is installed as `apache2` or `httpd`;
- whether the detected service appears to be running;
- whether the script appears to be running inside a container.

Running status is informational. A web server can be installed and correctly configured even if it is not currently running, especially inside a Docker container launched with an interactive shell.

### 2. Whether the relevant OpenSSL stack is PQC-capable

The script checks:

- the system `openssl` CLI version;
- whether the CLI can list `X25519MLKEM768`;
- whether nginx reports OpenSSL 3.5+ via `nginx -V`;
- whether Apache reports OpenSSL 3.5+ via its version output;
- whether a linked `libssl` appears to contain `X25519MLKEM768`;
- whether nginx accepts the exact PQC group directive in a temporary config test.

For nginx, the strongest evidence is usually:

```bash
nginx -V
```

showing OpenSSL 3.5 or newer.

For Apache, the result can be less conclusive because Apache often loads TLS support through `mod_ssl` dynamically. The script therefore treats Apache evidence more conservatively.

### 3. Whether SSL/TLS sites are configured

The script tries to identify whether there are existing SSL-enabled sites.

For nginx, it looks for indicators such as:

```nginx
listen 443 ssl;
ssl_certificate ...
```

For Apache, it looks for indicators such as:

```apache
<VirtualHost *:443>
SSLEngine on
SSLCertificateFile ...
```

If no TLS-enabled site is found, the script will not claim the deployment is fully configured. It will instead recommend creating or updating an HTTPS site.

### 4. Whether PQC groups are already configured

The script checks for existing group directives.

For nginx:

```nginx
ssl_conf_command Groups ...
```

For Apache:

```apache
SSLOpenSSLConfCmd Groups ...
```

If a directive already exists, the script recommends merging or editing it rather than blindly adding a duplicate directive.

---

## Installation

Download or copy the script to the target system.

```bash
chmod +x pqc4free.sh
```

Run it locally:

```bash
./pqc4free.sh
```

The script is read-only. It does not edit files, restart services, reload web servers, or install packages.

---

## Basic usage

Run the audit:

```bash
./pqc4free.sh
```

Run with JSON output:

```bash
./pqc4free.sh --json
```

Use in automation and return a non-zero exit code when the host is not ready:

```bash
./pqc4free.sh --fail-if-not-ready
```

Show help:

```bash
./pqc4free.sh --help
```

---

## Options

### `--json`

Prints a machine-readable JSON summary.

Example:

```bash
./pqc4free.sh --json
```

This is useful for fleet checks, CI jobs, configuration management, or ingestion into another tool.

### `--quiet`

Reduces human-readable output.

Example:

```bash
./pqc4free.sh --quiet
```

### `--fail-if-not-ready`

Makes the script return meaningful non-zero exit codes when the deployment needs attention.

Example:

```bash
./pqc4free.sh --fail-if-not-ready
```

Without this flag, the script behaves more like an advisory audit command and exits successfully unless no supported web server is found.

### `-h`, `--help`

Displays usage information.

---

## Exit codes

When `--fail-if-not-ready` is used, the script may return:

| Exit code | Meaning |
|---:|---|
| `0` | Ready or audit completed without a hard failure |
| `1` | Upgrade required |
| `2` | No TLS-enabled site found |
| `3` | Unknown or insufficient evidence |
| `4` | Neither nginx nor Apache found |

Without `--fail-if-not-ready`, the script usually exits `0` after printing its findings, unless neither nginx nor Apache is found.

---

## Recommended nginx configuration

For an existing nginx HTTPS server block, the recommended change is:

```nginx
ssl_protocols TLSv1.3 TLSv1.2;
ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;
```

Example:

```nginx
server {
    listen 443 ssl;
    server_name example.com;

    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;

    ssl_protocols TLSv1.3 TLSv1.2;
    ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;
}
```

Validate before reloading:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Inside a container:

```bash
nginx -t
nginx -s reload
```

For immutable container deployments, rebuild and redeploy the container rather than editing a running container in place.

---

## Recommended Apache configuration

For an existing Apache SSL virtual host, the recommended change is:

```apache
SSLProtocol -all +TLSv1.3 +TLSv1.2
SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1
```

Example:

```apache
<VirtualHost *:443>
    ServerName example.com

    SSLEngine on
    SSLCertificateFile /path/to/fullchain.pem
    SSLCertificateKeyFile /path/to/privkey.pem

    SSLProtocol -all +TLSv1.3 +TLSv1.2
    SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:secp384r1
</VirtualHost>
```

Validate before reloading:

```bash
sudo apachectl configtest
```

On Debian/Ubuntu:

```bash
sudo systemctl reload apache2
```

On Red Hat-style systems:

```bash
sudo systemctl reload httpd
```

Inside a container:

```bash
apachectl configtest
apachectl graceful
```

---

## Why `X25519MLKEM768:X25519:secp384r1`?

The group list is ordered by preference.

```text
X25519MLKEM768:X25519:secp384r1
```

This means:

1. Prefer the hybrid post-quantum/classical group `X25519MLKEM768`.
2. Fall back to classical `X25519` for clients that do not support the hybrid group.
3. Fall back to `secp384r1` as another classical option.

This gives a practical compatibility path:

| Client capability | Expected result |
|---|---|
| TLS 1.3 client supports `X25519MLKEM768` | Hybrid PQC key exchange |
| TLS 1.3 client does not support PQC groups | Classical fallback |
| TLS 1.2 client | Classical TLS only |
| Server OpenSSL lacks the group | Config test should fail |

---

## Important nginx inheritance warning

nginx has an important configuration inheritance behaviour for `ssl_conf_command`.

If you add:

```nginx
http {
    ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;
}
```

it may not apply to a lower-level `server` block if that server block already has any `ssl_conf_command` directive.

For example:

```nginx
http {
    ssl_conf_command Groups X25519MLKEM768:X25519:secp384r1;

    server {
        listen 443 ssl;
        ssl_conf_command Options PrioritizeChaCha;
    }
}
```

In this situation, the server-level `ssl_conf_command` may prevent inheritance of the higher-level `Groups` directive.

The safer recommendation is:

> If a TLS server block already contains any `ssl_conf_command` directive, add the `Groups` directive at that same level.

---

## Upgrade recommendations

The script only prints upgrade guidance when it believes the web server does not have suitable OpenSSL support.

The key point is:

> Installing a newer `openssl` CLI is not enough. nginx or Apache must be linked against a suitable OpenSSL library.

### Debian and Ubuntu

Check versions:

```bash
apt-cache policy openssl nginx apache2
```

Try normal package upgrades:

```bash
sudo apt update
sudo apt install --only-upgrade openssl nginx apache2
```

If OpenSSL remains too old, upgrade the distribution release, use a trusted vendor/backports repository, or move to a newer container base.

### Red Hat, CentOS, Rocky, AlmaLinux, Fedora

Check versions:

```bash
rpm -q openssl nginx httpd
dnf info openssl nginx httpd
```

Upgrade packages:

```bash
sudo dnf upgrade openssl nginx httpd
```

On older systems:

```bash
sudo yum update openssl nginx httpd
```

Enterprise distributions may intentionally keep OpenSSL versions conservative. In that case, enabling this may require a newer distro release, a supported vendor stream, or a container-based deployment.

### Alpine

Check versions:

```bash
apk info -v openssl nginx apache2
```

Upgrade packages:

```bash
sudo apk update
sudo apk upgrade openssl nginx apache2
```

If the packaged OpenSSL is still too old, move to a newer Alpine release or use a newer container image.

---

## Testing live negotiation

After applying the configuration and reloading the web server, test from a client that has OpenSSL 3.5 or newer:

```bash
openssl s_client \
  -connect example.com:443 \
  -servername example.com \
  -tls1_3 \
  -groups X25519MLKEM768:X25519
```

You want to confirm that the negotiated group is:

```text
X25519MLKEM768
```

If the client or server does not know that group, the test may fail or fall back to a classical group.

---

## Expected result on a modern nginx container

On a recent `nginx:latest` container based on a modern Debian release, you may see something like:

```text
nginx:
  OpenSSL from nginx -V:    OpenSSL 3.5.1
  PQC binary readiness:    yes
  TLS site found:          no
  PQC Groups configured:   no
  upgrade recommended:     no
  config change needed:    yes
```

This means:

- nginx is new enough;
- OpenSSL is new enough;
- no OpenSSL/nginx upgrade is required;
- the default container does not yet have an HTTPS site configured;
- you need to add an HTTPS server block or mount one into the container.

---

## What this script does not do

The script does not:

- edit nginx configuration;
- edit Apache configuration;
- install packages;
- restart services;
- reload services;
- generate certificates;
- prove browser support;
- make certificates post-quantum;
- make TLS 1.2 post-quantum;
- guarantee that every virtual host is correctly configured.

It is an audit and recommendation tool, not an automatic remediation tool.

---

## Limitations

### Apache detection is less definitive than nginx detection

nginx usually reports its OpenSSL build information clearly through:

```bash
nginx -V
```

Apache can be more complex because TLS functionality is often provided by a dynamically loaded `mod_ssl` module. The script therefore treats Apache OpenSSL detection as “likely” or “unknown” more often than nginx.

The final validation step for Apache is still:

```bash
apachectl configtest
```

followed by a live TLS negotiation test.

### Config parsing is heuristic

The script uses practical grep-based detection for TLS-enabled sites and existing TLS directives. This is intentionally simple and portable, but it is not a full nginx or Apache parser.

Complex configurations may need manual review.

Examples include:

- generated configs;
- deeply nested includes;
- templated deployments;
- Kubernetes ingress controllers;
- reverse proxies managed by control panels;
- custom Apache module layouts;
- non-standard paths.

### PQC support depends on both sides

Even if the server is configured correctly, the client must also support the hybrid group. Older clients will fall back to classical groups if fallback groups are allowed.

---

## Security model

Enabling `X25519MLKEM768` helps protect against passive “record now, decrypt later” attacks against TLS key exchange.

It does not protect against:

- compromised web servers;
- compromised clients;
- stolen certificate private keys used for future impersonation;
- malicious or compromised certificate authorities;
- application-layer vulnerabilities;
- traffic analysis;
- denial-of-service;
- logging of plaintext at endpoints;
- misconfigured TLS termination elsewhere in the path.

The deployment should be described as:

```text
Classically authenticated TLS 1.3 with hybrid post-quantum key exchange.
```

---

## Suggested workflow

1. Run the audit.

   ```bash
   ./pqc4free.sh
   ```

2. Confirm whether the web server is PQC-capable.

3. If no TLS site exists, configure HTTPS first.

4. Add or merge the recommended group directive.

5. Validate configuration.

   nginx:

   ```bash
   nginx -t
   ```

   Apache:

   ```bash
   apachectl configtest
   ```

6. Reload or redeploy the service.

7. Test live negotiation with an OpenSSL 3.5+ client.

   ```bash
   openssl s_client \
     -connect example.com:443 \
     -servername example.com \
     -tls1_3 \
     -groups X25519MLKEM768:X25519
   ```

8. Confirm that the negotiated group is `X25519MLKEM768`.

---

## Example JSON output

```json
{
  "os": {
    "id": "debian",
    "version_id": "13",
    "id_like": "",
    "container": true
  },
  "openssl_cli": {
    "version": "OpenSSL 3.5.1 1 Jul 2025",
    "pqc_status": "yes",
    "reason": "openssl CLI lists X25519MLKEM768 as a TLS 1.3 group"
  },
  "nginx": {
    "installed": true,
    "running": false,
    "binary": "/usr/sbin/nginx",
    "version": "1.29.2",
    "openssl": "OpenSSL 3.5.1",
    "pqc_status": "yes",
    "pqc_reason": "nginx -V reports OpenSSL 3.5+",
    "configtest_accepts_pqc_groups": "yes",
    "tls_site_found": false,
    "pqc_groups_configured": false,
    "tls13_configured": false,
    "upgrade_recommended": false,
    "config_change_recommended": true
  },
  "apache": {
    "installed": false,
    "running": false
  },
  "overall": {
    "webserver_found": true,
    "tls_site_found": false,
    "upgrade_recommended": false,
    "unknown_evidence": false,
    "pqc_group_primary": "X25519MLKEM768",
    "recommended_groups": "X25519MLKEM768:X25519:secp384r1"
  }
}
```

---

## Container test matrix

This repository now includes two parametrized Dockerfiles plus a matrix runner:

- `Dockerfile.nginx`
- `Dockerfile.apache`
- `scripts/test-matrix.sh`

The Dockerfiles accept:

- `BASE_IMAGE`
- `BASE_FAMILY`
- `VARIANT` (`pqc` or `vanilla`)

The matrix runner builds, starts, and validates:

- nginx on Debian, Ubuntu, Alpine, and Red Hat UBI
- Apache on Debian, Ubuntu, Alpine, and Red Hat UBI
- both a `pqc` image and a `vanilla` image for each combination

Run the full matrix:

```bash
bash scripts/test-matrix.sh
```

The script verifies, for each container:

- image build succeeds;
- the container stays up;
- `https://127.0.0.1:<port>/` serves the expected marker page;
- the live TLS 1.3 handshake completes;
- `pqc4free.sh --json` reports the expected readiness state.

### Confirmed matrix

As tested in this repository, the following combinations all built and served correctly:

| Server | Base OS | PQC image | Vanilla image |
|---|---|---|---|
| nginx | Debian 13 (`debian:trixie`) | yes | yes |
| nginx | Ubuntu 26.04 (`ubuntu:26.04`) | yes | yes |
| nginx | Alpine 3.22 (`alpine:3.22`) | yes | yes |
| nginx | Red Hat UBI 10 (`registry.access.redhat.com/ubi10/ubi`) | yes | yes |
| Apache | Debian 13 (`debian:trixie`) | yes | yes |
| Apache | Ubuntu 26.04 (`ubuntu:26.04`) | yes | yes |
| Apache | Alpine 3.22 (`alpine:3.22`) | yes | yes |
| Apache | Red Hat UBI 10 (`registry.access.redhat.com/ubi10/ubi`) | yes | yes |

### Important observation from live testing

On all tested OpenSSL 3.5+ bases, the live TLS 1.3 handshake negotiated:

```text
X25519MLKEM768
```

for both the `pqc` and `vanilla` images when the client offered:

```text
X25519MLKEM768:X25519
```

That means:

- the `pqc` images prove that explicit web-server `Groups` directives work;
- the `vanilla` images prove that modern OpenSSL may already negotiate the hybrid group by default;
- absence of `ssl_conf_command Groups ...` or `SSLOpenSSLConfCmd Groups ...` does **not** necessarily mean the live handshake will be classical-only.

The practical difference is policy explicitness:

- `pqc` images pin the server configuration explicitly;
- `vanilla` images rely on the OpenSSL/web-server defaults of that platform.

```text
MIT License
```
