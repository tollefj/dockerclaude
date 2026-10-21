#!/bin/sh
# Runs as root only long enough to set up the firewall, then drops to node.
set -eu

su-exec node /usr/local/bin/link-login.sh
[ "${AGENT_FIREWALL:-0}" = 1 ] && /usr/local/bin/init-firewall.sh

if [ "${1:-}" = claude ]; then
  if ! su-exec node /usr/local/bin/agent-check.sh --brief --audit; then
    if [ "${AGENT_ALLOW_FAIL:-0}" != 1 ]; then
      echo "Refusing to start: agent-check reported FAIL. Fix the findings or run with AGENT_ALLOW_FAIL=1."
      exit 1
    fi
    echo "AGENT_ALLOW_FAIL=1 set, starting despite failed controls."
  fi
fi
exec su-exec node "$@"
