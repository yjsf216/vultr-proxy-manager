#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

bash -n vultr-proxy.sh
sh -n cloud-init.sh
bash -n scheduled-run.sh

json_file=$(mktemp)
trap 'rm -f "$json_file"' EXIT
awk '/cat > \/etc\/sing-box\/config.json <<'\''EOF'\''/{copy=1; next} copy && /^EOF$/{exit} copy' cloud-init.sh \
  | sed 's/__PASSWORD__/self-test-password/g' > "$json_file"
jq -e . "$json_file" >/dev/null

for placeholder in __PASSWORD__ __SUB_TOKEN__ __PUBLIC_IP__ __DNS_NAME__ __DIRECT_DNS_NAME__ __CDN_IP__; do
  grep -q "$placeholder" cloud-init.sh || {
    echo "Missing template placeholder: $placeholder" >&2
    exit 1
  }
done

grep -q 'Vultr-SJC-CDN' cloud-init.sh
grep -q 'Vultr-SJC-Trojan' cloud-init.sh
grep -q 'Vultr-SJC-Hysteria2' cloud-init.sh
grep -q -- '- DIRECT' cloud-init.sh
grep -q '^ipv6: false$' cloud-init.sh
grep -q '^tcp-concurrent: true$' cloud-init.sh
grep -q '^  - GEOSITE,CN,DIRECT$' cloud-init.sh
./vultr-proxy.sh | grep -q 'rebuild'
./vultr-proxy.sh >/dev/null

if [ "${1:-}" = --live ]; then
  ./vultr-proxy.sh status
  ./vultr-proxy.sh test
fi

echo "Self-test passed"
