# 兼容性矩阵

| 系统 | 包管理器 | 服务管理器 | 支持状态 |
|---|---|---|---|
| Ubuntu / Debian | `apt-get` | systemd | 支持 |
| CentOS / RHEL | `yum` / `dnf` | systemd | 支持 |
| Fedora | `dnf` | systemd | 支持 |
| Alpine | `apk` | OpenRC | 支持 |

## 架构

脚本会按 sing-box / cloudflared 官方发布包名称转换当前机器架构。主要覆盖：

| 机器架构 | sing-box 架构 | 说明 |
|---|---|---|
| `x86_64` / `amd64` | `amd64` | 常见 x86_64 VPS |
| `aarch64` / `arm64` | `arm64` | ARM64 VPS |
| `armv7l` / `armhf` | `armv7` | 32 位 ARM |

## 服务与网络暴露面

| 组件 | 默认监听 / 暴露方式 | 说明 |
|---|---|---|
| VLESS Reality | 公网端口 | 用户确认后尝试放行防火墙 |
| VLESS WebSocket | `127.0.0.1:${WS_PORT}` | 作为 Argo / 订阅网关上游 |
| Hysteria2 | 公网 UDP/TCP 端口 | 用户确认后尝试放行防火墙 |
| 订阅服务 | `127.0.0.1:24630` | 只供 Argo 本地回源，不直接开放公网 |
| Argo Tunnel | Cloudflare HTTPS 入口 | 临时域名或固定 token 模式 |

## 本地验证

```bash
make check
```

等价于：

```bash
bash scripts/build-install.sh
bash scripts/test.sh
bash scripts/lint.sh
bash scripts/checksum.sh
```
