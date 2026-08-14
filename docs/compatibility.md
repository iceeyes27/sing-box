# 兼容性矩阵

| 系统 | 包管理器 | 服务管理器 | CI smoke | 支持状态 |
|---|---|---|---|---|
| Ubuntu 24.04 | `apt-get` | systemd / 容器内可能为 none | 是 | 支持 |
| Debian 12 | `apt-get` | systemd / 容器内可能为 none | 是 | 支持 |
| Fedora latest | `dnf` | systemd / 容器内可能为 none | 是 | 支持 |
| CentOS / RHEL | `yum` / `dnf` | systemd | 逻辑覆盖 | 支持 |
| Alpine latest | `apk` | OpenRC / 容器内可能为 none | 是 | 支持 |

> CI 容器 smoke 重点验证脚本语法、包管理器识别、服务管理器识别、架构映射、资源档位和订阅监听默认值；真实服务启动仍建议在完整 VPS / VM 上验证。

## 架构

脚本会按 sing-box / cloudflared 官方发布包名称转换当前机器架构。主要覆盖：

| 机器架构 | sing-box 架构 | cloudflared 架构 | 说明 |
|---|---|---|---|
| `x86_64` / `amd64` | `amd64` | `amd64` | 常见 x86_64 VPS |
| `aarch64` / `arm64` | `arm64` | `arm64` | ARM64 VPS |
| `armv7l` / `armhf` | `armv7` | `arm` | 32 位 ARM |
| `i386` / `i686` | `386` | 默认 `amd64` 不保证 | sing-box 支持，cloudflared 需实机确认 |

## 低资源策略

| 场景 | 行为 |
|---|---|
| 内存小于 768MB 且 swap 小于 128MB | 标记为 `low-noswap`，优先尝试创建 512MB 临时 swap |
| 低内存且无法创建临时 swap | 保留核心依赖安装，跳过可选依赖 |
| 低内存但已有 swap | 分批安装缺失依赖 |
| 单核 CPU | 依赖安装使用 `ionice -c 3 nice -n 19` 降低优先级 |
| 缺少 `python3` | 核心代理继续运行；订阅服务会提示无法启动 |
| 缺少 `ss` / `netstat` / `lsof` | 跳过端口占用检查并提示 |

## NAT VPS

| 场景 | 行为 |
|---|---|
| 公网 IPv4 不在本机网卡 | 自动启用 NAT 模式并保存检测到的公网 IPv4 |
| 公网端口与本机端口不同 | Reality/Hysteria2/SOCKS5 链接使用各自公网映射端口，sing-box 配置继续使用本机监听端口 |
| 面板不提供 UDP 映射 | 安装时输入 `0` 禁用 Hysteria2，仅部署 Reality |
| 映射端口后续变化 | 通过管理面板“修改 NAT 公网映射”更新，不重启 sing-box |

## 服务与网络暴露面

| 组件 | 默认监听 / 暴露方式 | 说明 |
|---|---|---|
| VLESS Reality | 公网端口 | 用户确认后尝试放行防火墙 |
| VLESS WebSocket | `127.0.0.1:${WS_PORT}` | 作为 Argo / 订阅网关上游 |
| Hysteria2 | 公网 UDP 端口 | 用户确认后尝试放行防火墙；NAT 无 UDP 映射时可禁用 |
| SOCKS5 | 默认关闭；启用后监听公网 TCP 端口 | 强制用户名密码认证；建议在外部防火墙中限制来源 IP |
| 订阅服务 | `127.0.0.1:24630` | 只供 Argo 本地回源，不直接开放公网 |
| Argo Tunnel | Cloudflare HTTPS 入口 | 仅支持固定域名与 Tunnel Token，默认关闭 |

## Alpine 兼容性

- 初始用 `sh` 执行时会自动安装 Bash 并重新执行脚本。
- sing-box 优先尝试 `apk add sing-box`，失败后使用官方 `linux-*-musl.tar.gz`。
- cloudflared 优先尝试 `apk add cloudflared`，失败后使用官方二进制。
- 服务文件使用 OpenRC。

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

容器 smoke 检查可单独运行：

```bash
bash scripts/smoke.sh
```
