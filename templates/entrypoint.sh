#!/bin/sh
set -eu
/usr/local/bin/link-login.sh
exec claude "$@"
