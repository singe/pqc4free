#!/bin/sh
set -eu

if command -v apache2ctl >/dev/null 2>&1; then
  exec apache2ctl -D FOREGROUND
fi

if [ -d /etc/httpd ] && command -v httpd >/dev/null 2>&1; then
  exec httpd -X
fi

if command -v apachectl >/dev/null 2>&1; then
  exec apachectl -D FOREGROUND
fi

exec httpd -X
