#!/bin/bash
set -euo pipefail

umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
[ ! -f "$SCRIPT_DIR/config.env" ] || . "$SCRIPT_DIR/config.env"
STATE_DIR=${VULTR_PROXY_STATE_DIR:-"$SCRIPT_DIR/.state"}
SECRETS_FILE="$STATE_DIR/secrets.json"
URL_FILE="$STATE_DIR/subscription-url.txt"
VULTR_KEY_FILE=${VULTR_API_KEY_FILE:-"$SCRIPT_DIR/.secrets/vultr-api-key.txt"}
CLOUDFLARE_KEY_FILE=${CLOUDFLARE_API_TOKEN_FILE:-"$SCRIPT_DIR/.secrets/cloudflare-api-token.txt"}
CLOUD_INIT="$SCRIPT_DIR/cloud-init.sh"

LABEL=${VULTR_PROXY_LABEL:-vultr-proxy-1}
TAG=${VULTR_PROXY_TAG:-production-proxy}
REGION=${VULTR_PROXY_REGION:-sjc}
PLAN=${VULTR_PROXY_PLAN:-vc2-1c-1gb}
ZONE=${CLOUDFLARE_ZONE:-example.com}
DNS_NAME=${VULTR_PROXY_DNS_NAME:-edge.$ZONE}
DIRECT_DNS_NAME=${VULTR_PROXY_DIRECT_DNS_NAME:-direct.$ZONE}
CANDIDATE_DNS_NAME=${VULTR_PROXY_CANDIDATE_DNS_NAME:-candidate.$ZONE}
CDN_IP=${VULTR_PROXY_CDN_IP:-172.67.152.211}
SSH_KEY_NAME=${VULTR_PROXY_SSH_KEY_NAME:-vultr-proxy-manager}
SSH_PRIVATE="$SCRIPT_DIR/.secrets/ssh/vultr_proxy_ed25519"
MIHOMO=${MIHOMO_BIN:-"/Applications/Clash Party.app/Contents/Resources/sidecar/mihomo"}
VULTR_API=https://api.vultr.com/v2
CLOUDFLARE_API=https://api.cloudflare.com/client/v4

die() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Missing command: $1"; }

validate_config() {
  [ "$ZONE" != example.com ] || die "Copy config.env.example to config.env and set your domain"
  if printf '%s\n' "$ZONE" "$DNS_NAME" "$DIRECT_DNS_NAME" "$CANDIDATE_DNS_NAME" |
    grep -Eq '[^A-Za-z0-9.-]'; then
    die "Invalid DNS name in config.env"
  fi
  printf '%s' "$CDN_IP" | grep -Eq '^[0-9a-fA-F:.]+$' || die "Invalid CDN IP in config.env"
}

for command_name in curl dig jq openssl sed ssh-keygen; do need "$command_name"; done
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

read_secret_file() {
  local file=$1
  [ -s "$file" ] || die "Missing credential file: $file"
  tr -d '\r\n' < "$file"
}

vultr_get() {
  local path=$1 token
  token=$(read_secret_file "$VULTR_KEY_FILE")
  curl -4 -fsS --max-time 30 -H "Authorization: Bearer $token" "$VULTR_API/$path"
}

vultr_json() {
  local method=$1 path=$2 payload=$3 token
  token=$(read_secret_file "$VULTR_KEY_FILE")
  printf '%s' "$payload" | curl -4 -fsS --max-time 45 -X "$method" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data-binary @- "$VULTR_API/$path"
}

cloudflare_get() {
  local path=$1 token
  token=$(read_secret_file "$CLOUDFLARE_KEY_FILE")
  curl -4 -fsS --max-time 30 -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' "$CLOUDFLARE_API/$path"
}

cloudflare_json() {
  local method=$1 path=$2 payload=$3 token
  token=$(read_secret_file "$CLOUDFLARE_KEY_FILE")
  printf '%s' "$payload" | curl -4 -fsS --max-time 30 -X "$method" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data-binary @- "$CLOUDFLARE_API/$path"
}

ensure_secrets() {
  if [ ! -s "$SECRETS_FILE" ]; then
    local password subscription_token
    password=$(openssl rand -base64 24 | tr -d '\n')
    subscription_token=$(openssl rand -hex 24)
    jq -n --arg password "$password" --arg token "$subscription_token" \
      '{proxy_password:$password,subscription_token:$token}' > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
  fi
}

proxy_password() { ensure_secrets; jq -er '.proxy_password' "$SECRETS_FILE"; }
subscription_token() { ensure_secrets; jq -er '.subscription_token' "$SECRETS_FILE"; }

instance_json() {
  vultr_get 'instances?per_page=100' | jq -cer --arg label "$LABEL" --arg tag "$TAG" \
    '.instances[] | select(.label==$label and ((.tags // []) | index($tag)))' 2>/dev/null || true
}

candidate_json() {
  vultr_get 'instances?per_page=100' | jq -cer \
    '.instances[] | select(((.tags // []) | index("proxy-rebuild-candidate")))' 2>/dev/null || true
}

ensure_ssh_key() {
  mkdir -p "$HOME/.ssh" "$(dirname "$SSH_PRIVATE")"
  chmod 700 "$HOME/.ssh"
  if [ ! -s "$SSH_PRIVATE" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "$SSH_KEY_NAME" -f "$SSH_PRIVATE"
  fi
  chmod 600 "$SSH_PRIVATE"

  local public_key keys key_id response payload
  public_key=$(tr -d '\r\n' < "$SSH_PRIVATE.pub")
  keys=$(vultr_get 'ssh-keys?per_page=100')
  key_id=$(printf '%s' "$keys" | jq -r --arg name "$SSH_KEY_NAME" \
    '.ssh_keys[] | select(.name==$name) | .id' | head -1)
  if [ -z "$key_id" ]; then
    payload=$(jq -n --arg name "$SSH_KEY_NAME" --arg key "$public_key" '{name:$name,ssh_key:$key}')
    response=$(vultr_json POST ssh-keys "$payload")
    key_id=$(printf '%s' "$response" | jq -er '.ssh_key.id')
  fi
  printf '%s' "$key_id"
}

cloudflare_zone_id() {
  cloudflare_get "zones?name=$ZONE" | jq -er '.result[0].id'
}

set_dns_a_record() {
  local name=$1 ip=$2 proxied=$3 zone_id records record_id payload response
  [ -s "$CLOUDFLARE_KEY_FILE" ] || die "Create a scoped Cloudflare token at $CLOUDFLARE_KEY_FILE"
  zone_id=$(cloudflare_zone_id)
  records=$(cloudflare_get "zones/$zone_id/dns_records?type=A&name=$name")
  record_id=$(printf '%s' "$records" | jq -r '.result[0].id // empty')
  payload=$(jq -n --arg name "$name" --arg content "$ip" --argjson proxied "$proxied" \
    '{type:"A",name:$name,content:$content,ttl:1,proxied:$proxied}')
  if [ -n "$record_id" ]; then
    response=$(cloudflare_json PUT "zones/$zone_id/dns_records/$record_id" "$payload")
  else
    response=$(cloudflare_json POST "zones/$zone_id/dns_records" "$payload")
  fi
  [ "$(printf '%s' "$response" | jq -r '.success')" = true ] || die "Cloudflare DNS update failed"
}

set_dns_record() { set_dns_a_record "$DNS_NAME" "$1" true; }
set_direct_dns_record() { set_dns_a_record "$DIRECT_DNS_NAME" "$1" false; }
set_candidate_dns_record() { set_dns_a_record "$CANDIDATE_DNS_NAME" "$1" true; }

delete_dns_a_record() {
  local name=$1 expected_ip=${2:-} zone_id records record_id content response
  zone_id=$(cloudflare_zone_id)
  records=$(cloudflare_get "zones/$zone_id/dns_records?type=A&name=$name")
  record_id=$(printf '%s' "$records" | jq -r '.result[0].id // empty')
  content=$(printf '%s' "$records" | jq -r '.result[0].content // empty')
  [ -n "$record_id" ] || return 0
  [ -z "$expected_ip" ] || [ "$content" = "$expected_ip" ] || return 0
  response=$(cloudflare_json DELETE "zones/$zone_id/dns_records/$record_id" '{}')
  [ "$(printf '%s' "$response" | jq -r '.success')" = true ] || die "Cloudflare DNS delete failed"
}

delete_candidate_dns_record() { delete_dns_a_record "$CANDIDATE_DNS_NAME"; }

delete_dns_record() {
  local expected_ip=$1
  [ -s "$CLOUDFLARE_KEY_FILE" ] || return 0
  delete_dns_a_record "$DNS_NAME" "$expected_ip"
  delete_dns_a_record "$DIRECT_DNS_NAME" "$expected_ip"
}

render_cloud_init() {
  sed -e "s|__PASSWORD__|$(proxy_password)|g" \
    -e "s|__SUB_TOKEN__|$(subscription_token)|g" \
    -e "s|__DNS_NAME__|$DNS_NAME|g" \
    -e "s|__DIRECT_DNS_NAME__|$DIRECT_DNS_NAME|g" \
    -e "s|__CDN_IP__|$CDN_IP|g" "$CLOUD_INIT"
}

write_url_file() {
  printf 'https://%s/%s/config.yaml\n' "$DNS_NAME" "$(subscription_token)" > "$URL_FILE"
  chmod 600 "$URL_FILE"
}

subscription_url() {
  write_url_file
  tr -d '\r\n' < "$URL_FILE"
}

subscription_body() {
  local url ip
  url=$(subscription_url)
  curl -fsS --retry 2 --retry-all-errors --max-time 15 "$url" 2>/dev/null && return
  for ip in $(dig +short A "$DNS_NAME"); do
    curl -fsS --retry 2 --retry-all-errors --max-time 15 --resolve "$DNS_NAME:443:$ip" "$url" 2>/dev/null && return
  done
  return 1
}

subscription_headers() {
  local url ip
  url=$(subscription_url)
  curl -I -fsS --retry 2 --retry-all-errors --max-time 15 "$url" 2>/dev/null && return
  for ip in $(dig +short A "$DNS_NAME"); do
    curl -I -fsS --retry 2 --retry-all-errors --max-time 15 --resolve "$DNS_NAME:443:$ip" "$url" 2>/dev/null && return
  done
  return 1
}

acquire_lock() {
  LOCK_DIR="$STATE_DIR/lock"
  mkdir "$LOCK_DIR" 2>/dev/null || die "Another create/delete operation is running"
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

wait_for_instance() {
  local id=$1 tries=0 instance state
  while [ "$tries" -lt 60 ]; do
    instance=$(vultr_get "instances/$id")
    state=$(printf '%s' "$instance" | jq -r '.instance | "\(.status)|\(.power_status)|\(.server_status)|\(.main_ip)"')
    echo "Waiting for instance: $state"
    if printf '%s' "$state" | grep -Eq '^active\|running\|ok\|[0-9]'; then
      printf '%s' "$instance" | jq -er '.instance.main_ip'
      return
    fi
    tries=$((tries + 1))
    sleep 5
  done
  echo "Instance did not become ready" >&2
  return 1
}

wait_for_subscription() {
  local ip=$1 token tries=0 body count
  token=$(subscription_token)
  while [ "$tries" -lt 120 ]; do
    body=$(curl -k -fsS --max-time 5 "https://$ip:2053/$token/config.yaml" -H "Host: $DNS_NAME" 2>/dev/null || true)
    count=$(printf '%s' "$body" | grep -c '^  - name: Vultr-SJC-' || true)
    if [ "$count" -eq 3 ]; then
      echo "Subscription service is ready"
      return
    fi
    tries=$((tries + 1))
    sleep 5
  done
  echo "Subscription service did not become ready" >&2
  return 1
}

vultr_delete_id() {
  local id=$1 token code
  token=$(read_secret_file "$VULTR_KEY_FILE")
  code=$(curl -4 -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $token" "$VULTR_API/instances/$id")
  [ "$code" = 204 ] || [ "$code" = 404 ] || die "Vultr delete failed: HTTP $code"
}

test_direct_ip() {
  local ip=$1 node=${2:-Vultr-SJC-Trojan} attempts=${3:-3} tmp config pid code=000 payload i
  [ -x "$MIHOMO" ] || die "Mihomo not found: $MIHOMO"
  if [ "$node" != Vultr-SJC-CDN ]; then
    nc -z -G 8 -w 8 "$ip" 443 || return 1
  fi
  tmp=$(mktemp -d)
  config="$tmp/config.yaml"
  cp '/Applications/Clash Party.app/Contents/Resources/files/country.mmdb' "$tmp/"
  cp '/Applications/Clash Party.app/Contents/Resources/files/geosite.dat' "$tmp/"
  candidate_subscription_body > "$tmp/remote.yaml" || return 1
  sed -e '1i\
mixed-port: 17891\
external-controller: 127.0.0.1:19091\
mode: rule\
log-level: silent' "$tmp/remote.yaml" > "$config"
  "$MIHOMO" -d "$tmp" -f "$config" > "$tmp/mihomo.log" 2>&1 &
  pid=$!
  for i in 1 2 3 4 5; do
    nc -z 127.0.0.1 19091 >/dev/null 2>&1 && break
    sleep 1
  done
  payload=$(jq -n --arg name "$node" '{name:$name}')
  if curl -fsS -X PUT -H 'Content-Type: application/json' --data "$payload" \
    http://127.0.0.1:19091/proxies/PROXY >/dev/null; then
    for i in $(seq 1 "$attempts"); do
      code=$(curl -sS --max-time 20 --proxy http://127.0.0.1:17891 \
        -o /dev/null -w '%{http_code}' https://chatgpt.com/cdn-cgi/trace || true)
      [ "$code" != 000 ] || break
      [ "$i" -eq "$attempts" ] || sleep 30
    done
  fi
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  [ "$code" != 000 ]
}

test_cdn() {
  local cdn_host=${1:-$DNS_NAME} password edge_ip tmp pid code i
  password=$(proxy_password)
  edge_ip=$CDN_IP
  [ -n "$edge_ip" ] || return 1
  tmp=$(mktemp -d)
  cat > "$tmp/config.yaml" <<EOF
mixed-port: 17897
mode: rule
log-level: silent
proxies:
  - name: CDN
    type: trojan
    server: $edge_ip
    port: 443
    password: "$password"
    sni: $cdn_host
    skip-cert-verify: false
    network: ws
    alpn: [http/1.1]
    client-fingerprint: chrome
    ws-opts:
      path: /api/v1/edge-sync
      headers:
        Host: $cdn_host
proxy-groups:
  - name: PROXY
    type: select
    proxies: [CDN]
rules:
  - MATCH,PROXY
EOF
  "$MIHOMO" -d "$tmp" -f "$tmp/config.yaml" > "$tmp/mihomo.log" 2>&1 &
  pid=$!
  for i in 1 2 3 4 5; do
    nc -z 127.0.0.1 17897 >/dev/null 2>&1 && break
    sleep 1
  done
  code=$(curl -sS --max-time 25 --proxy http://127.0.0.1:17897 \
    -o /dev/null -w '%{http_code}' https://chatgpt.com/cdn-cgi/trace || true)
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  [ "$code" != 000 ]
}

candidate_subscription_body() {
  local token url edge_ip
  token=$(subscription_token)
  url="https://$CANDIDATE_DNS_NAME:2053/$token/config.yaml"
  curl -4 -fsS --max-time 15 "$url" 2>/dev/null && return
  for edge_ip in $(dig +short A "$CANDIDATE_DNS_NAME"); do
    curl -4 -fsS --max-time 15 --resolve "$CANDIDATE_DNS_NAME:2053:$edge_ip" \
      "$url" 2>/dev/null && return
  done
  return 1
}

wait_for_candidate_subscription() {
  local tries=0 body count
  while [ "$tries" -lt 60 ]; do
    body=$(candidate_subscription_body || true)
    count=$(printf '%s' "$body" | grep -c '^  - name: Vultr-SJC-' || true)
    if [ "$count" -eq 3 ]; then
      echo "Candidate subscription service is ready"
      return
    fi
    tries=$((tries + 1))
    sleep 5
  done
  echo "Candidate subscription service did not become ready" >&2
  return 1
}

wait_for_cloudflare_subscription() {
  local expected_ip=$1 tries=0 body
  while [ "$tries" -lt 60 ]; do
    body=$(subscription_body || true)
    if [ "$(printf '%s' "$body" | grep -c '^  - name: Vultr-SJC-' || true)" -eq 3 ]; then
      echo "Cloudflare subscription is ready for $expected_ip"
      return
    fi
    tries=$((tries + 1))
    sleep 5
  done
  echo "Cloudflare subscription did not switch to $expected_ip" >&2
  return 1
}

confirm_create() {
  [ "${1:-}" = --yes ] && return
  echo "This creates a billable Vultr instance: $PLAN in $REGION (about USD 5/month cap)."
  read -r -p "Type CREATE to continue: " answer
  [ "$answer" = CREATE ] || die "Cancelled"
}

create_instance() {
  local assume_yes=${1:-} existing password token user_data ssh_id os_id payload response id ip
  acquire_lock
  validate_config
  existing=$(instance_json)
  if [ -n "$existing" ]; then
    id=$(printf '%s' "$existing" | jq -er '.id')
    ip=$(printf '%s' "$existing" | jq -r '.main_ip // empty')
    if [ -z "$ip" ] || [ "$ip" = 0.0.0.0 ]; then
      ip=$(wait_for_instance "$id" | tail -1)
    fi
    echo "Finishing existing instance: $ip"
    set_dns_record "$ip"
    set_direct_dns_record "$ip"
    write_url_file
    wait_for_cloudflare_subscription "$ip"
    test_cdn
    echo "Instance is ready: $ip"
    return
  fi
  [ -s "$CLOUDFLARE_KEY_FILE" ] || die "Missing Cloudflare API token: $CLOUDFLARE_KEY_FILE"
  confirm_create "$assume_yes"
  [ -s "$CLOUD_INIT" ] || die "Missing cloud-init template: $CLOUD_INIT"
  password=$(proxy_password)
  token=$(subscription_token)
  ssh_id=$(ensure_ssh_key)
  os_id=$(vultr_get 'os?per_page=500' | jq -er '.os[] | select(.name=="Debian 12 x64 (bookworm)") | .id' | head -1)
  vultr_get 'plans?type=vc2&per_page=100' | jq -e --arg plan "$PLAN" --arg region "$REGION" \
    '.plans[] | select(.id==$plan and (.locations | index($region)))' >/dev/null || die "Plan unavailable"
  user_data=$(render_cloud_init | base64 | tr -d '\n')
  payload=$(jq -n --arg ud "$user_data" --arg sid "$ssh_id" --arg region "$REGION" --arg plan "$PLAN" \
    --arg label "$LABEL" --arg tag "$TAG" --argjson os "$os_id" \
    '{region:$region,plan:$plan,os_id:$os,label:$label,hostname:$label,tags:[$tag],sshkey_id:[$sid],enable_ipv6:false,backups:"disabled",ddos_protection:false,activation_email:false,user_data:$ud}')
  response=$(vultr_json POST instances "$payload")
  id=$(printf '%s' "$response" | jq -er '.instance.id')
  ip=$(wait_for_instance "$id" | tail -1)
  echo "Updating Cloudflare: $DNS_NAME -> $ip"
  set_dns_record "$ip"
  set_direct_dns_record "$ip"
  write_url_file
  wait_for_cloudflare_subscription "$ip"
  if ! test_cdn; then
    die "New server kept, but CDN real ChatGPT test failed"
  fi
  echo "Created $LABEL at $ip"
  echo "Subscription URL saved to $URL_FILE"
}

confirm_delete() {
  [ "${1:-}" = --yes ] && return
  echo "This permanently deletes $LABEL and its disk."
  read -r -p "Type DELETE to continue: " answer
  [ "$answer" = DELETE ] || die "Cancelled"
}

delete_instance() {
  local assume_yes=${1:-} instance id ip
  acquire_lock
  instance=$(instance_json)
  [ -n "$instance" ] || { echo "No managed instance exists"; return; }
  confirm_delete "$assume_yes"
  id=$(printf '%s' "$instance" | jq -er '.id')
  ip=$(printf '%s' "$instance" | jq -er '.main_ip')
  vultr_delete_id "$id"
  delete_dns_record "$ip"
  [ ! -f "$URL_FILE" ] || mv "$URL_FILE" "$URL_FILE.deleted"
  echo "Deleted $LABEL ($ip); data is not recoverable"
}

rebuild_instance() {
  local assume_yes=${1:-} old old_id old_ip stale password token user_data ssh_id os_id
  local payload response candidate_id candidate_ip promote
  acquire_lock
  validate_config
  old=$(instance_json)
  [ -n "$old" ] || die "No managed instance exists; use create"
  confirm_create "$assume_yes"
  old_id=$(printf '%s' "$old" | jq -er '.id')
  old_ip=$(printf '%s' "$old" | jq -er '.main_ip')

  stale=$(candidate_json)
  if [ -n "$stale" ]; then
    echo "Removing stale candidate"
    vultr_delete_id "$(printf '%s' "$stale" | jq -er '.id')"
  fi
  delete_candidate_dns_record

  password=$(proxy_password)
  token=$(subscription_token)
  ssh_id=$(ensure_ssh_key)
  os_id=$(vultr_get 'os?per_page=500' | jq -er '.os[] | select(.name=="Debian 12 x64 (bookworm)") | .id' | head -1)
  user_data=$(render_cloud_init | base64 | tr -d '\n')
  payload=$(jq -n --arg ud "$user_data" --arg sid "$ssh_id" --arg region "$REGION" --arg plan "$PLAN" \
    --arg label "sjc-proxy-candidate" --argjson os "$os_id" \
    '{region:$region,plan:$plan,os_id:$os,label:$label,hostname:$label,tags:["proxy-rebuild-candidate"],sshkey_id:[$sid],enable_ipv6:false,backups:"disabled",ddos_protection:false,activation_email:false,user_data:$ud}')
  response=$(vultr_json POST instances "$payload")
  candidate_id=$(printf '%s' "$response" | jq -er '.instance.id')
  candidate_ip=$(wait_for_instance "$candidate_id" | tail -1) || {
    vultr_delete_id "$candidate_id"
    die "Candidate instance did not become active"
  }
  echo "Candidate IP: $candidate_ip"
  set_candidate_dns_record "$candidate_ip"

  if ! wait_for_candidate_subscription || ! test_cdn "$CANDIDATE_DNS_NAME"; then
    delete_candidate_dns_record
    vultr_delete_id "$candidate_id"
    die "Candidate CDN failed; old instance kept at $old_ip"
  fi
  echo "Candidate CDN real ChatGPT test passed"

  set_dns_record "$candidate_ip"
  if ! wait_for_cloudflare_subscription "$candidate_ip"; then
    set_dns_record "$old_ip"
    delete_candidate_dns_record
    vultr_delete_id "$candidate_id"
    die "Cloudflare switch failed; DNS restored to old instance"
  fi
  if ! test_cdn "$DNS_NAME"; then
    set_dns_record "$old_ip"
    delete_candidate_dns_record
    vultr_delete_id "$candidate_id"
    die "Production CDN test failed; DNS restored to old instance"
  fi

  set_direct_dns_record "$candidate_ip"

  promote=$(jq -n --arg label "$LABEL" --arg tag "$TAG" '{label:$label,tags:[$tag]}')
  vultr_json PATCH "instances/$candidate_id" "$promote" >/dev/null
  vultr_delete_id "$old_id"
  delete_candidate_dns_record
  write_url_file
  echo "Rebuild complete: $old_ip -> $candidate_ip"
  echo "Subscription URL unchanged: $URL_FILE"
}

status_instance() {
  local instance id ip month used=0 bandwidth headers
  instance=$(instance_json)
  [ -n "$instance" ] || { echo "Instance: absent"; return; }
  id=$(printf '%s' "$instance" | jq -er '.id')
  ip=$(printf '%s' "$instance" | jq -er '.main_ip')
  printf '%s' "$instance" | jq -r '"Instance: \(.label) \(.region) \(.main_ip) \(.status)/\(.power_status) plan=\(.plan)"'
  month=$(date '+%Y-%m')
  bandwidth=$(vultr_get "instances/$id/bandwidth" 2>/dev/null || true)
  if [ -n "$bandwidth" ]; then
    used=$(printf '%s' "$bandwidth" | jq --arg month "$month" '[.bandwidth | to_entries[] | select(.key | startswith($month)) | .value.outgoing_bytes] | add // 0')
  fi
  echo "Vultr outgoing this month: $used bytes / 1099511627776 bytes"
  write_url_file
  headers=$(subscription_headers || true)
  printf '%s\n' "$headers" | grep -i '^subscription-userinfo:' || echo "Subscription: not reachable"
  echo "Subscription URL file: $URL_FILE"
}

test_subscription() {
  local body headers node
  body=$(subscription_body) || die "Subscription fetch failed"
  headers=$(subscription_headers) || die "Subscription headers unavailable"
  for node in Vultr-SJC-CDN Vultr-SJC-Trojan Vultr-SJC-Hysteria2; do
    printf '%s' "$body" | grep -q "^  - name: $node$" || die "Missing required node: $node"
  done
  [ "$(printf '%s' "$body" | grep -c '^  - DOMAIN-SUFFIX\|^  - IP-CIDR\|^  - GEOSITE\|^  - GEOIP\|^  - MATCH')" -eq 14 ] || die "Expected fourteen rules"
  printf '%s\n' "$headers" | grep -qi '^subscription-userinfo:' || die "Missing traffic header"
  echo "Subscription test passed: required proxy nodes, 14 rules, traffic header present"
}

copy_url() {
  write_url_file
  if command -v pbcopy >/dev/null; then
    pbcopy < "$URL_FILE"
    echo "Subscription URL copied to clipboard"
  else
    echo "Subscription URL saved to $URL_FILE"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") COMMAND [--yes]

Commands:
  create       Create and fully provision the proxy server
  rebuild      Create/test a replacement, switch DNS, then delete the old server
  delete       Permanently delete the managed server and matching DNS record
  status       Show instance and traffic status
  test         Validate the HTTPS subscription
  url          Copy the subscription URL to the clipboard
EOF
}

case ${1:-} in
  create) create_instance "${2:-}" ;;
  rebuild) rebuild_instance "${2:-}" ;;
  delete) delete_instance "${2:-}" ;;
  status) status_instance ;;
  test) test_subscription ;;
  url) copy_url ;;
  *) usage; [ -z "${1:-}" ] || exit 1 ;;
esac
