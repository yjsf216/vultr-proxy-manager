# Vultr Proxy Manager

用一个脚本创建、重建或删除 Vultr 代理服务器，并自动维护 Cloudflare DNS 与 Clash/Mihomo 订阅。

服务器会部署：

- Trojan over WebSocket + Cloudflare CDN
- Trojan 直连
- Hysteria2 直连
- Shadowsocks 诊断备用
- 带月流量信息的 HTTPS Clash/Mihomo 订阅

> 仅用于合法的网络访问和技术研究。Vultr、Cloudflare 及当地法律的使用限制仍然适用。

## 准备

macOS 需要 `bash`、`curl`、`dig`、`jq`、`openssl`、`sed`、`ssh-keygen`。真实代理测试还需要 Clash Party，或通过 `MIHOMO_BIN` 指定 Mihomo。

```bash
cp config.env.example config.env
mkdir -p .secrets/ssh
```

编辑 `config.env`，填写你托管在 Cloudflare 的域名。然后创建以下只含一行内容的文件：

- `.secrets/vultr-api-key.txt`：Vultr API Key
- `.secrets/cloudflare-api-token.txt`：仅授予目标 Zone 的 `DNS / Edit` 权限

```bash
chmod 600 .secrets/vultr-api-key.txt .secrets/cloudflare-api-token.txt
./self-test.sh
```

SSH 密钥会在首次创建时自动生成到 `.secrets/ssh/`。所有凭据、随机代理密码、订阅路径和运行状态均被 Git 忽略。

## 使用

```bash
./vultr-proxy.sh create     # 创建并部署；会要求输入 CREATE
./vultr-proxy.sh status     # 查看实例与本月出站流量
./vultr-proxy.sh test       # 验证订阅
./vultr-proxy.sh url        # 复制订阅地址
./vultr-proxy.sh rebuild    # 新机通过 CDN 测试后才切换并删除旧机
./vultr-proxy.sh delete     # 永久删除实例；会要求输入 DELETE
```

自动化时可追加 `--yes`。实例创建后立即按小时计费；关机通常仍计费，删除实例才停止实例费用。

`rebuild` 使用候选域名验证新机的 CDN 节点，验证失败会保留旧服务器。直连 Trojan、Hysteria2 和 Shadowsocks 是否可用取决于本地运营商到 Vultr 公网 IP 的线路；CDN 测试通过不代表直连一定可用。

默认地区、套餐和 Cloudflare Anycast IP 可在 `config.env` 中覆盖。`scheduled-run.sh` 可由你自己的定时器调用，但仓库不会默认安装自动删除任务。

## 自检

```bash
./self-test.sh          # 仅检查本地文件，不产生费用
./self-test.sh --live   # 额外检查 Vultr 状态和线上订阅
```

## License

[MIT](LICENSE)
