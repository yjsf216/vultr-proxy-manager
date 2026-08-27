---
name: vultr-proxy-manager
description: Safely create, inspect, test, rebuild, or delete the managed Vultr proxy server using the vultr-proxy-manager project. Use for requests about this project's Vultr instance, Cloudflare DNS, Clash/Mihomo subscription, proxy traffic, or proxy availability. Do not use for unrelated Vultr resources or general VPN advice.
---

# Vultr Proxy Manager

Use the project scripts as the single source of deployment logic. Do not recreate API calls or server configuration inside the skill.

## Locate the project

Use the first directory containing executable `vultr-proxy.sh`:

1. `$VULTR_PROXY_MANAGER_DIR`, when set.
2. The current working directory.
3. `~/Documents/Codex/vultr-proxy-manager`.
4. `~/.local/share/vultr-proxy-manager`.

If none exists, clone `https://github.com/yjsf216/vultr-proxy-manager` into the fourth location. Never overwrite an existing directory. Do not update an existing checkout unless the user asks.

## Safety

- Never print, copy, commit, or inspect the contents of `.secrets/`, `.state/secrets.json`, or `.state/subscription-url.txt`.
- Do not alter Clash Party or another client configuration unless explicitly requested. Testing via its Mihomo binary is allowed.
- Run `./self-test.sh` before any billable or destructive operation.
- `create` and `rebuild` create billable instances. Run them only after the user explicitly requests that operation.
- `delete` permanently removes the managed instance and disk. Run `status` first, report the exact managed label and IP, and proceed only when deletion is explicitly requested.
- Operate only on resources selected by the project's label and tag. Never broaden deletion to other Vultr instances or DNS records.
- After one failed create or rebuild attempt, stop and report the failure. Preserve the currently working CDN/server whenever the project supports rollback.

If `config.env`, the Vultr key, or the scoped Cloudflare token is missing, explain the required file path and stop. Never invent credentials.

## Commands

Run from the project directory:

- Inspect without changing infrastructure: `./vultr-proxy.sh status`
- Validate local files: `./self-test.sh`
- Validate the online subscription: `./vultr-proxy.sh test`
- Create after explicit authorization: `./vultr-proxy.sh create --yes`
- Rebuild after explicit authorization: `./vultr-proxy.sh rebuild --yes`
- Delete after explicit authorization and target verification: `./vultr-proxy.sh delete --yes`

Do not run `url` unless the user asks to copy the subscription URL. Never include that URL in the response.

Report the observable outcome: instance state, whether the subscription test passed, and which proxy paths were actually verified. Do not claim Trojan, Hysteria2, Shadowsocks, or CDN works unless the corresponding real test succeeded.
