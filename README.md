# sing-box 一键部署

- **协议支持**：VLESS + Reality (TCP), VLESS + WS + Argo (CDN), Hysteria2 (UDP/QUIC)
- **端口独占/聚合**：支持 Hysteria2 与 Reality 共用 443 端口 (TCP+UDP)，提高伪装度
- **智能交互**：一键安装、多协议分享链接生成、内置管理面板。

## ✨ 特性

- 🚀 **一键安装** — 自动安装 sing-box + cloudflared，生成全部配置
- 🔒 **VLESS + Reality** — 抗主动探测，高性能直连
- ☁️ **VLESS + WS + Argo** — 经 Cloudflare CDN，抗 IP 封锁
- ⚡ **Hysteria2** — 基于 QUIC/UDP 暴力加速，极致抗封锁
- 🎯 **优选伪装域名** — 自动对 30+ 常见大厂域名测速，选出最低延迟 SNI
- 📋 **v2ray 链接** — 直接输出可导入 v2rayN / v2rayNG 的分享链接
- 🎛️ **交互式管理** — 修改配置、重启、升级、查看状态等

## 📦 一键安装

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh")
```

> 需要 root 权限，支持 Ubuntu / Debian / CentOS / RHEL / Fedora

## 🎛️ 管理面板

安装后可随时运行管理面板：

```bash
sbm
```

```text
╔══════════════════════════════════════════════╗
║     sing-box 管理面板  v2.3.0              ║
╚══════════════════════════════════════════════╝

 1) 安装 / 重新安装
 2) 修改配置 (端口/域名/UUID)
 3) 查看节点链接
 4) 启动服务
 5) 停止服务
 6) 重启服务
 7) 查看运行状态
 8) 查看日志
 9) 开机自启设置
10) 更新 (sing-box/cloudflared/脚本)
11) 卸载
 0) 退出
```

## ⌨️ 命令行快捷操作

```bash
sbm install    # 直接安装
sbm links      # 查看链接
sbm restart    # 重启服务
sbm status     # 查看状态
sbm uninstall  # 卸载
```

## 🔗 节点类型

| 节点 | 协议 | 传输 | 安全 | 特点 |
| :--- | :--- | :--- | :--- | :--- |
| 直连 | VLESS + Vision | TCP       | Reality  | 低延迟，抗探测，自动优选最低延迟 SNI |
| CDN  | VLESS          | WebSocket | TLS (CF) | 抗 IP 封锁，经 Cloudflare 隧道转发   |
| 高速 | Hysteria2      | QUIC (UDP) | TLS (自签) | UDP 暴力加速，极致抗封锁，自动生成证书 |

## 📄 License

MIT
