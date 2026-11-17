# 兼容性矩阵

| 系统 | 包管理器 | 服务管理器 | CI smoke | 支持状态 |
|---|---|---|---|---|
| Ubuntu 24.04 | `apt-get` | systemd / 容器内可能为 none | 是 | 支持 |
| Debian 12 | `apt-get` | systemd / 容器内可能为 none | 是 | 支持 |
| Fedora latest | `dnf` | systemd / 容器内可能为 none | 是 | 支持 |
| CentOS / RHEL | `yum` / `dnf` | systemd | 逻辑覆盖 | 支持 |
| Alpine latest | `apk` | OpenRC / 容器内可能为 none | 是 | 支持 |

> CI 容器 smoke 验证脚本语法、系统识别、架构映射、资源档位和订阅监听默认值。专用 Alpine OpenRC 测试验证旧服务迁移、崩溃自动重启、残留状态恢复和启动后立即退出；真实代理流量仍需另外验证。

## 架构

脚本会按 sing-box / cloudflared 官方发布包名称转换当前机器架构。主要覆盖：

| 机器架构 | sing-box 架构 | cloudflared 架构 | 说明 |
|---|---|---|---|
| `x86_64` / `amd64` | `amd64` | `amd64` | 常见 x86_64 VPS |
| `aarch64` / `arm64` | `arm64` | `arm64` | ARM64 VPS |
| `armv7l` / `armhf` | `armv7` | `arm` | 32 位 ARM |
| `i386` / `i686` | `386` | `386` | 32 位 x86 |

## sing-box 安装来源

按顺序尝试，前一个失败才使用下一个：

1. 系统软件包：Alpine 使用 `apk`，其他系统使用 `sing-box.app` 官方安装脚本（deb / rpm）。
2. 官方 GitHub release 的 `linux-<arch>-musl` 二进制包。
3. 本仓库 [vendor/sing-box/](../vendor/sing-box/) 内置的同名 musl 包（版本见 `VERSION`）：从仓库检出运行时直接读取本地文件，否则从本仓库 raw 地址下载。

第 2、3 步安装到 `/usr/local/bin/sing-box`；systemd 系统上若没有软件包提供的 `sing-box.service`，脚本会写入带 `# Managed by sbm` 标记的 `/etc/systemd/system/sing-box.service`。之后若改用软件包安装成功，会移除这两个文件，避免遮蔽软件包版本。`sbm` 更新 sing-box 时，内置包只在版本高于当前已安装版本时才会使用。

## 低资源策略

| 场景 | 行为 |
|---|---|
| 内存小于 768MB 且 swap 小于 128MB | 标记为 `low-noswap`，优先尝试创建 512MB 临时 swap |
| 低内存且无法创建临时 swap | 保留核心依赖安装，跳过可选依赖 |
| 低内存但已有 swap | 分批安装缺失依赖 |
| 单核 CPU | 依赖安装使用 `ionice -c 3 nice -n 19` 降低优先级 |
| 缺少 `python3` | 核心代理继续运行；订阅服务会提示无法启动 |
| 缺少 `ss` / `netstat` / `lsof` | 跳过端口占用检查并提示 |

## 端口设置

安装和协议设置仅管理本机监听端口。新安装生成的链接使用本机端口；已有配置中的链接端口继续保留，以兼容旧链接。Hysteria2 未启用时修改端口仅保存参数，启用时检查 UDP 端口占用。

## 服务与网络暴露面

| 组件 | 默认监听 / 暴露方式 | 说明 |
|---|---|---|
| VLESS Reality | 公网端口 | 用户确认后尝试放行防火墙 |
| VLESS WebSocket | `127.0.0.1:${WS_PORT}` | 作为 Argo / 订阅网关上游 |
| Hysteria2 | 本机 UDP 端口 | 启用时尝试放行本机防火墙 |
| SOCKS5 | 默认关闭；启用后监听公网 TCP 端口 | 强制用户名密码认证；建议在外部防火墙中限制来源 IP |
| 订阅服务 | `127.0.0.1:24630` | 只供 Argo 本地回源，不直接开放公网 |
| Argo Tunnel | Cloudflare HTTPS 入口 | 支持临时域名和固定域名 Token；IPv4/双栈默认关闭，IPv6-only 默认开启，安装时可切换 |

## Alpine 兼容性

- 初始用 `sh` 执行时会自动安装 Bash 并重新执行脚本。
- sing-box 优先尝试 `apk add sing-box`，失败后使用官方 `linux-*-musl.tar.gz`。
- cloudflared 优先尝试 `apk add cloudflared`，失败后使用官方二进制。
- sing-box、Argo 和订阅网关使用 OpenRC `supervise-daemon` 监督进程；异常退出后间隔 5 秒重试，60 秒内最多重试 5 次。
- 启动和重启会恢复已确认的 `crashed` / `unsupervised` 状态，并在启动后连续检查服务状态；恢复和检查共用 30 秒超时。
- 升级脚本后执行 `sbm apply` 更新服务文件；旧后台进程会在切换监督器前停止，现有端口和凭证继续使用。

## 本地验证

### 受管 sing-box 版本

`sbm doctor` 为独立只读入口，不触发管理命令自安装或旧参数迁移。版本事务使用 Python 标准库，保留系统软件包文件和数据库；实际服务必须属于明确支持的 systemd 启动契约或本项目 OpenRC 模板，未知自定义配置会在修改前拒绝。

版本校验支持明确的 `-c` / `-C` / `-D` 路径及本项目常用配置结构；日志文件、缓存、自动签发证书、远程规则集和未知代理入站/出站尚不接管。受管模式下的模板配置修改只接受默认的单个 `config.json`，避免覆盖额外配置片段。版本目录和恢复状态分别位于 `/usr/local/libexec/sbm/sing-box/` 与 `/var/lib/sbm/`。

静态检查、运行验证和公网连接分别报告。原服务停止时不启动它；本机验证不能替代外部连接验证。平台 smoke、模拟事务测试与真实服务集成测试是不同层次的证据，不能互相替代。

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
