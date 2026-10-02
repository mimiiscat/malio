# Hysteria2（hy2）支持说明

本项目已在面板侧支持 Hysteria2 节点，包括节点管理、订阅生成与 Clash Meta 配置输出。

## 1. 添加节点

后台「节点管理」→「添加节点」，节点类型选择 **Hysteria2**（`sort = 15`）。

节点地址（server）支持可选参数，格式：

```
地址;port=443|sni=example.com|insecure=1|obfs=salamander|obfs-password=xxx|up=100|down=100
```

除 `地址` 外的参数都可以省略，`;` 之后的参数使用 `|` 分隔、`=` 赋值。各参数含义：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `port` | 监听端口 | `443` |
| `sni` / `host` | TLS SNI | 节点地址 |
| `insecure` | 是否跳过证书校验，`1` 为跳过 | `0` |
| `obfs` | 混淆类型，例如 `salamander` | 无 |
| `obfs-password` | 混淆密码 | 无 |
| `up` / `down` | 客户端上下行速率（Mbps） | 不输出 |
| `auth` | `uuid`（默认）或 `passwd`，决定订阅中使用哪种用户凭据作为认证密码 | `uuid` |

## 2. 订阅链接

| 订阅 | 链接 |
| --- | --- |
| 原始分享链接（base64 订阅） | `{订阅域名}/link/{token}?sub=6` |
| 原始分享链接列表（不 base64） | `{订阅域名}/link/{token}?list=hysteria2` |
| Clash Meta / Mihomo | `{订阅域名}/link/{token}?clash=1`，会自动包含 Hysteria2 节点 |
| Shadowrocket | `{订阅域名}/link/{token}?list=shadowrocket` |

`sub=6` 输出的单条链接形如：

```
hysteria2://密码@地址:端口/?sni=example.com&insecure=1&obfs=salamander&obfs-password=xxx#节点名称
```

> Clash（原版）不支持 Hysteria2，只有 Clash Meta / Mihomo 及基于其内核的客户端（Clash Verge、ClashX Meta 等）支持。

## 3. 服务端对接

面板侧只负责下发节点与用户信息，Hysteria2 服务端通过以下两个接口完成鉴权与流量上报：

- 用户认证：`POST /hysteria2/auth?key={muKey}&node_id={id}`，请求体为 Hysteria2 HTTP 认证的标准 JSON（`{"addr":"...","auth":"...","tx":0}`），`auth` 支持用户 `uuid` 或连接密码，成功返回 `{"ok":true,"id":"用户ID"}`
- 流量上报：`POST /hysteria2/traffic?key={muKey}`，请求体 `{"node_id":id,"data":[{"user_id":1,"u":123,"d":456}]}`，其中 `u` 为上行、`d` 为下行（字节）

完成对接后，节点心跳、在线状态与用户流量统计即可在面板中正常显示。

## 4. 一键对接脚本

仓库提供了 Hysteria2 服务端一键安装对接脚本：`deploy/hysteria2/install-hysteria2.sh`。

先在后台添加 Hysteria2 节点并记下节点 ID，然后在节点服务器上执行：

```bash
sudo ./install-hysteria2.sh \
  --panel-url http://面板地址 \
  --node-id 5 \
  --sni www.bing.com
```

脚本会自动安装 Hysteria2、生成自签证书、写入 systemd 服务、放行防火墙，并注册每分钟一次的流量上报 cron。常用参数：

- `--panel-url`：面板地址（必填）
- `--node-id`：面板中 Hysteria2 节点的 ID（必填）
- `--mu-key`：面板 muKey，同机部署会自动从 `/opt/malio/config/.config.php` 读取
- `--port`：监听端口，默认 `443`
- `--sni`：自签证书 SNI，默认 `www.bing.com`
- `--cert` / `--key`：使用已有证书时指定
- `--uninstall`：卸载脚本写入的组件

自签证书对应客户端需要 `insecure=1`；配置正式域名证书后可去掉该参数。

## 5. 显示设置

在 `config/.malio_config.php` 的 `support_sub_type` 中加入 `hysteria2`，首页会显示「复制 Hysteria2 原生订阅（非 Clash）」按钮；Clash Verge / Mihomo 用户请使用「复制 Clash 融合订阅链接」（`?clash=1`），一个地址即可包含所有协议节点：

```php
$Malio_Config['support_sub_type'] = ['ss', 'ssr', 'v2ray', 'hysteria2'];
```
