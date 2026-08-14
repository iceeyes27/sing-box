# sing-box 一键部署

本项目提供基于 `sing-box` 的自动化部署及配置管理脚本，支持多种网络协议栈的一键安装与系统服务管理。

> ⚠️ **免责声明**  
> 本项目属于个人网络协议原理学习与测试的开源项目。工具及代码仅供网络技术和安全协议的学习、研究及合法合规的内部网络架构测试使用。  
> 严禁将本项目包含的任何代码或工具用于任何构成违反国家网络信息安全相关法律法规的非法用途。任何使用者因违法使用本项目引发的全部法律责任和后果，完全由使用者自行承担，与项目原作者无关。一旦您获取、下载或使用本项目代码，即视为充分了解并完全同意本声明。

## ✨ 说明

- 🚀 **自动化安装** — 自动拉取官方核心并配置 sing-box；启用 Argo 时安装 cloudflared 与本地订阅网关依赖。
- 🔧 **稳定优先链路** — 新安装默认仅启用 VLESS Reality 与临时域名 Argo；Hysteria2 和带认证 SOCKS5 默认关闭，可在管理面板中启用。
- 🎯 **网络测速工具集** — 内置辅助脚本可自动侦测服务器到指定域名的网络连通性，自动择优分配高连通率测试节点。
- 🎛️ **交互式管理方案** — 内置终端管理控制面板，支持实时快捷修改端口参数、HTTPS 订阅链接、Argo 订阅链接、重载配置、监控日志与开机自启。
- 📡 **Argo 订阅网关** — 默认创建 `trycloudflare.com` 临时隧道并提供 HTTPS 订阅，也支持切换为固定域名 Tunnel Token 模式。
- 🧩 **NAT VPS 适配** — 自动识别公网 IPv4 不在本机网卡的环境，分别保存本机监听端口与面板公网映射端口；没有 UDP 映射时可直接禁用 Hysteria2。
- 🎯 **单一部署路径** — 仅提供主节点完整部署，主菜单安装入口直接开始主节点配置。

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
  sing-box 管理面板  v3.0.0
  ────────────────────────────────────────
  sing-box: ● 运行中    argo-tunnel: ● 运行中

  部署 & 配置
   1) 部署 / 安装节点
   2) 修改配置 (端口 / 域名 / UUID / SNI / SOCKS5)
   3) 节点链接与订阅

  服务管理
   4) 启动     5) 停止     6) 重启
   7) 状态     8) 日志     9) 自启

  系统维护
  10) 更新     11) 卸载     0) 退出
```

## ⌨️ 命令行快捷操作

如果不希望进入交互面板，也支持直接带参数快速执行：

```bash
sbm install         # 直接执行主节点完整部署流程
sbm links           # 重新计算并查看服务连接参数与凭证
sbm resni           # 手动重新选择 Reality 伪装域名 (SNI) 并重启生效
sbm apply           # 升级脚本后一键同步：按新版本模板重写配置并重启、刷新链接
sbm restart         # 重启系统后台的所有相关运行服务
sbm status          # 查看当前各个核心组件的系统运行状态
sbm uninstall       # 完全卸载本项目及其生成的所有缓存与配置
```

## 🌐 IPv4 / IPv6 VPS

脚本会按 VPS 实际公网网络生成节点链接：IPv4-only 和双栈 VPS 默认生成 IPv4 Reality 直连链接；IPv6-only VPS 通过默认启用的 Argo 生成外部节点链接。固定域名 Argo 始终直接使用自有域名，不使用第三方 CF 优选域名。

NAT VPS 会使用面板分配的公网 TCP/UDP 端口生成链接，同时保持 sing-box 使用本机监听端口。Reality、Hysteria2 和已启用的 SOCKS5 分别保存公网映射端口；映射变化后可在 `sbm` 的“修改 NAT 公网映射”中更新。

## 🔌 可选 SOCKS5 代理

主节点安装完成后运行 `sbm`，进入“修改配置”并选择“管理 SOCKS5 代理”。启用后脚本会：

- 使用独立随机高位 TCP 端口和强随机密码；
- 写入带用户名密码认证的 sing-box SOCKS 入站；
- 放行对应 TCP 端口并重启 sing-box；
- 输出可直接粘贴到代理池的 `socks5://用户名:密码@IP:端口` 链接。

SOCKS5 不会加入 VLESS/Hysteria2 订阅内容，只写入终端输出和 `/etc/sing-box/share-links.txt`。公网使用时应在 VPS 安全组中把 SOCKS5 端口限制为业务服务器的固定出口 IP。

## 🧭 部署方式

管理面板和 `sbm install` 仅保留主节点完整部署。选择主菜单 `1) 部署 / 安装节点` 后会直接开始主节点安装，不再显示部署目标选择。

## 📘 主节点部署

### 步骤 1：下载安装脚本

```bash
wget -O install.sh https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh
sudo bash install.sh
```

也可以在已经安装管理命令的服务器上直接执行：

```bash
sbm install
```

### 步骤 2：按提示完成安装

脚本会引导确认 Reality 端口、NAT 公网映射、Reality 伪装域名、节点名称和 Argo 模式，并自动生成 UUID、Reality 密钥与订阅凭据。

### 步骤 3：查看链接

安装完成后会输出 Reality、Argo 和 HTTPS 订阅地址。SOCKS5 默认关闭，可在主菜单 `2) 修改配置` 的 `17) 管理 SOCKS5 代理` 中启用。

```bash
sbm links
```

## 🛡️ 安全建议

1. 优先使用 HTTPS 订阅地址，不要公开订阅调试地址。
2. 不要公开 Argo token、订阅 token、UUID 或 Reality 私钥。
3. 怀疑凭据泄露时，应重新生成对应凭据。
4. 订阅服务保持监听 `127.0.0.1`；SOCKS5 端口应限制允许访问的来源 IP。

## 🔄 旧用户升级兼容说明

- 现有 `/etc/sing-box/.params` 参数文件继续兼容，升级后无需重新安装。
- 主节点、订阅、Argo、Reality、Hysteria2 和 SOCKS5 配置继续保留。
- `relay-install`、`relay` 及线路机脚本生成功能已移除。
- 更新管理脚本后可执行 `sbm apply`，按当前版本模板刷新配置并重启服务。

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
- SOCKS5 强制配置用户名密码；仍建议通过云安全组或厂商防火墙限制允许访问该端口的来源 IP。
- Argo token、订阅 token 和节点密钥均存放在本机配置文件中，请限制文件读取权限并避免公开日志输出。
- Hysteria2 直连分享链接同时提供 `insecure=1` 与证书固定指纹 `pinSHA256`：v2rayN 可导入自签证书节点，支持证书固定的客户端仍可校验指纹。

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
