#!/usr/bin/env bash
# Ausgehender Verkehr nur zu einer Positivliste (HTTPS) plus DNS.
set -euo pipefail

ALLOWED_DOMAINS=(
  api.anthropic.com
  claude.ai
  console.anthropic.com
  proxy.golang.org
  sum.golang.org
  storage.googleapis.com
  objects.githubusercontent.com
)

# Zusätzliche Domains zur Laufzeit, durch Leerzeichen getrennt (dazu aber container wenigstens restarten, ist dann wieder unveränderlich)
read -r -a EXTRA <<< "${FW_EXTRA_ALLOWED_DOMAINS:-}"
ALLOWED_DOMAINS+=("${EXTRA[@]}")

ipset destroy allowed 2>/dev/null || true
ipset create allowed hash:net

# GitHub-Adressbereiche (Web, API, Git) aus der offiziellen Meta-API
curl -fsS --max-time 10 https://api.github.com/meta \
  | jq -r '(.web + .api + .git)[] | select(contains(":") | not)' \
  | while read -r cidr; do ipset add allowed "$cidr" -exist; done

# Domains einmalig auflösen (IP-Adressen von CDNs ändern. Ja nu.)
for d in "${ALLOWED_DOMAINS[@]}"; do
  for ip in $(dig +short A "$d" | grep -E '^[0-9]+(\.[0-9]+){3}$'); do
    ipset add allowed "$ip" -exist
  done
done

DNS=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)

iptables -F
iptables -X
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp -d "$DNS" --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d "$DNS" --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# IPv6 komplett sperren, falls vorhanden
if command -v ip6tables >/dev/null && ip6tables -L >/dev/null 2>&1; then
  ip6tables -F
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
fi

# Selbsttest
if curl -s -o /dev/null --max-time 5 https://example.com; then
  echo "Firewall-Test fehlgeschlagen: example.com erreichbar" >&2; exit 1
fi
if ! curl -s -o /dev/null --max-time 5 https://api.anthropic.com; then
  echo "Firewall-Test fehlgeschlagen: api.anthropic.com nicht erreichbar" >&2; exit 1
fi
echo "Firewall aktiv."
