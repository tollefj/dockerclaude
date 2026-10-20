#!/bin/sh
set -eu
[ -r /run/claude-token ] && export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/claude-token)"
exec claude "$@"
