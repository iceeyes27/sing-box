# sing-box 一键部署

本项目提供基于 `sing-box` 的自动化部署及配置管理脚本，支持多种网络协议栈的一键安装与系统服务管理。

> ⚠️ **免责声明**  
> 本项目属于个人网络协议原理学习与测试的开源项目。工具及代码仅供网络技术和安全协议的学习、研究及合法合规的内部网络架构测试使用。  
> 严禁将本项目包含的任何代码或工具用于任何构成违反国家网络信息安全相关法律法规的非法用途。任何使用者因违法使用本项目引发的全部法律责任和后果，完全由使用者自行承担，与项目原作者无关。一旦您获取、下载或使用本项目代码，即视为充分了解并完全同意本声明。

## ✨ 说明

- 🚀 **自动化安装** — 自动拉取官方核心并配置 sing-box + cloudflared 为系统服务。
- 🔧 **多协议链路框架** — 预置支持 VLESS Reality、VLESS WebSocket over Argo 以及 Hysteria2，兼容 TCP、WebSocket 与 UDP(QUIC) 等传输路径。
- 🎯 **网络测速工具集** — 内置辅助脚本可自动侦测服务器到指定域名的网络连通性，自动择优分配高连通率测试节点。
- 🎛️ **交互式管理方案** — 内置终端管理控制面板，支持实时快捷修改端口参数、HTTPS 订阅链接、Argo 订阅链接、重载配置、监控日志与开机自启。
- 📡 **本地订阅网关** — 生成带 token 的订阅文件，并通过本地监听的订阅服务配合 Argo 暴露 HTTPS 订阅地址。

## 📦 一键安装配置

```bash
wget -qO- https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh | sh
```

如需先审查脚本再执行，也可以使用：

```bash
wget -O install.sh https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh
bash -n install.sh
sudo bash install.sh
```

固定版本和 checksum 校验方式见 [发布流程](docs/release.md)。

> 需要 root 权限，支持 Ubuntu / Debian / CentOS / RHEL / Fedora / Alpine。
> Alpine 初始系统会自动补齐 Bash 和 curl 后继续安装。
> 脚本会按实际 CPU、内存和 swap 状态选择安装策略：低内存且无 swap 时仅安装关键依赖，低内存有 swap 时分批补齐缺失依赖，标准/高内存会正常安装缺失依赖；单核 CPU 会降低探测并发并使用低优先级安装；VPS 已存在的命令和时间同步服务会直接复用，不重复安装。

## 🎛️ 管理面板使用指南

安装完成后，可随时在服务器终端输入系统快捷命令运行管理面板：

```bash
sbm
```

**面板概览：**
```text
╔══════════════════════════════════════════════╗
║     sing-box 管理面板  v2.6.27             ║
╚══════════════════════════════════════════════╝

 1) 部署目标选择
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

如果不希望进入交互面板，也支持直接带参数快速执行：

```bash
sbm install    # 直接执行主节点完整部署流程
sbm relay      # 根据主节点 Argo 配置生成线路机部署脚本
sbm links      # 重新计算并查看服务连接参数与凭证
sbm restart    # 重启系统后台的所有相关运行服务
sbm status     # 查看当前各个核心组件的系统运行状态
sbm uninstall  # 完全卸载本项目及其生成的所有缓存与配置
```

## 🌐 IPv4 / IPv6 VPS

脚本会按 VPS 实际公网网络自动生成节点链接：IPv4-only 生成 IPv4 直连链接和 Argo 链接，IPv6-only 仅保留 `VLESS + WS + Argo` 节点链接，IPv4 + IPv6 双栈会生成 IPv4 直连链接，并同时输出 IPv4 / IPv6 两条 Argo 链接。

## 🧭 部署目标

主菜单的 `部署目标选择` 提供两个入口：`主节点完整部署` 保持原安装流程；`生成线路机部署脚本` 会读取当前主节点的 Argo 参数，生成独立的 Reality 线路机安装脚本，路径类似 `/tmp/sbm-relay-install.XXXXXX.sh`，以脚本最终输出为准。

## 📁 生成文件清单

脚本运行后可能创建或更新以下文件：

- `/etc/sing-box/config.json` — sing-box 主配置。
- `/etc/sing-box/.params` — 安装参数、端口、UUID、Reality key、订阅 token 等本地状态。
- `/etc/sing-box/share-links.txt` — 最近一次生成的节点分享链接。
- `/etc/sing-box/subscription.txt` — 订阅服务读取的订阅内容。
- `/etc/sing-box/sbm-subscription.env` — 订阅服务环境变量，包含订阅 token。
- `/etc/sing-box/argo-tunnel.env` — Argo Tunnel 运行参数。
- `/usr/local/bin/sbm`、`/usr/local/bin/sing-box-manager` — 管理面板快捷命令。
- `/usr/local/bin/sbm-subscription-server.py` — 本地订阅服务脚本。
- `/etc/systemd/system/sing-box.service`、`/etc/systemd/system/argo-tunnel.service`、`/etc/systemd/system/sbm-subscription.service` — systemd 服务文件。
- `/etc/init.d/sing-box`、`/etc/init.d/argo-tunnel`、`/etc/init.d/sbm-subscription` — OpenRC 服务文件。

## 🔐 安全与暴露面

- 订阅服务默认只监听 `127.0.0.1`，公网订阅地址通过 Argo HTTPS 入口访问。
- 订阅地址包含随机 token；如怀疑泄露，建议重新生成 UUID / token / Reality key。
- 脚本会在确认端口后按系统环境尝试放行 sing-box 入站端口；订阅服务端口不应直接对公网开放。
- Argo token、订阅 token 和节点密钥均存放在本机配置文件中，请限制文件读取权限并避免公开日志输出。
- Hysteria2 直连分享链接默认使用服务器证书的固定指纹 `pinSHA256`，不再依赖 `allowInsecure` / `insecure=1` 跳过证书验证。

## 🧩 开发与构建

本仓库保留一键分发用的 [install.sh](install.sh)，同时将开发态源码拆分在 [src/](src/) 中。修改源码后可运行：

```bash
make build    # 由 src/ 重新生成 install.sh
make test     # 构建并运行 Bash 语法检查与回归测试
make lint     # 运行 ShellCheck，未安装时跳过
make check    # build + test + lint + checksum
```

CI 会在 Debian、Ubuntu、Fedora、Alpine 容器中运行 smoke checks；兼容性矩阵见 [docs/compatibility.md](docs/compatibility.md)。

## 📄 License

MIT
