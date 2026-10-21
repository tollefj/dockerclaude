#!/bin/sh
set -eu
shared=/opt/claude-auth/.credentials.json
creds=/home/node/.claude/.credentials.json
mkdir -p /home/node/.claude
if [ -f "$creds" ] && [ ! -L "$creds" ]; then
  if [ ! -e "$shared" ] || [ "$creds" -nt "$shared" ]; then mv -f "$creds" "$shared"; else rm -f "$creds"; fi
fi
ln -sfn "$shared" "$creds"
if [ -s "$shared" ] && [ ! -e /home/node/.claude.json ]; then printf '{"hasCompletedOnboarding":true}\n' >/home/node/.claude.json; fi
