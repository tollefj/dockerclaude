#!/bin/bash
# Default-deny egress, modeled on the claude-code reference dev container.
set -euo pipefail

DOMAINS_FILE=/workspace/.dockerclaude/allowed-domains.txt
IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'

add_ip() {
  [[ "$1" =~ $IPV4_RE ]] && ipset add allowed "$1" -exist
  return 0
}

ipset create allowed hash:net -exist
ipset flush allowed

while IFS= read -r line || [ -n "$line" ]; do
  entry=${line%%#*}
  entry=${entry//[[:space:]]/}
  [ -n "$entry" ] || continue
  if [ "$entry" = "@github" ]; then
    while read -r cidr; do add_ip "$cidr"; done < <(curl -fsS --connect-timeout 10 https://api.github.com/meta |
      jq -r '(.web + .api + .git)[]')
    continue
  fi
  ips=$(dig +short A "$entry" | grep -E "$IPV4_RE" || true)
  [ -n "$ips" ] || echo "Warning: could not resolve $entry"
  for ip in $ips; do add_ip "$ip"; done
done <"$DOMAINS_FILE"

iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d 169.254.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
iptables -A OUTPUT -m set --match-set allowed dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

ip6tables -F 2>/dev/null || true
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
for chain in INPUT FORWARD OUTPUT; do ip6tables -P "$chain" DROP 2>/dev/null || true; done

if curl -fsS --connect-timeout 5 -o /dev/null https://example.com 2>/dev/null; then
  echo "Firewall check failed: example.com is reachable"
  exit 1
fi
if ! curl -sS --connect-timeout 10 -o /dev/null https://api.anthropic.com; then
  echo "Firewall check failed: api.anthropic.com is unreachable"
  exit 1
fi
echo "Firewall active. Allowlist: .dockerclaude/allowed-domains.txt"
