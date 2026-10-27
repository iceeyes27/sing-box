# sing-box 一键部署

本项目提供基于 `sing-box` 的自动化部署及配置管理脚本，支持多种网络协议栈的一键安装与系统服务管理。

> ⚠️ **免责声明**  
> 本项目属于个人网络协议原理学习与测试的开源项目。工具及代码仅供网络技术和安全协议的学习、研究及合法合规的内部网络架构测试使用。  
> 严禁将本项目包含的任何代码或工具用于任何构成违反国家网络信息安全相关法律法规的非法用途。任何使用者因违法使用本项目引发的全部法律责任和后果，完全由使用者自行承担，与项目原作者无关。一旦您获取、下载或使用本项目代码，即视为充分了解并完全同意本声明。

## ✨ 说明

- 🚀 **自动化安装** — 自动拉取官方核心并配置 sing-box；官方渠道不可用时改用本仓库 [vendor/sing-box/](vendor/sing-box/) 内置的版本。启用 Argo 时安装 cloudflared 与本地订阅网关依赖。
- 🔧 **稳定优先链路** — 新安装 IPv4-only / 双栈默认启用 VLESS Reality；IPv6-only 默认启用 Reality 与 Argo。安装时可直接勾选 Argo 和带认证 SOCKS5，Hysteria2 保持默认关闭。
- 🎯 **网络测速工具集** — 内置辅助脚本可自动侦测服务器到指定域名的网络连通性，自动择优分配高连通率测试节点。
- 🎛️ **交互式管理方案** — 内置终端管理控制面板，支持实时快捷修改端口参数、HTTPS 订阅链接、Argo 订阅链接、重载配置、监控日志与开机自启。
- 📡 **Argo 订阅网关** — 勾选 Argo 后默认创建 `trycloudflare.com` 临时隧道并提供 HTTPS 订阅，也支持切换为固定域名 Tunnel Token 模式。
- 🛡️ **Reality 域名检查** — 从多个候选域名实测 TLS 1.3 与 HTTP/2，按握手成功率和延迟择优，并排除 Cloudflare 地址；不依赖 ASN 查询，允许 CNAME、多 IP 和 IPv6。全部失败时报错；CF 优选域名仅用于 Argo。Hysteria2 使用本地静态伪装响应。
- 🌐 **CF 地址优选** — Argo 按 IPv4/IPv6 分别实测优选地址；节点的 SNI 与 Host 始终保持真实 Argo 域名。
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
  sing-box 管理面板  v3.1.6
  ────────────────────────────────────────
  sing-box: ● 运行中    argo-tunnel: ● 运行中

  主菜单
   1) 节点与协议     安装 / Reality / Hysteria2 / SOCKS5 / Argo / 节点身份
   2) 连接与订阅     Argo / NAT / IPv4 / 链接与订阅
   3) 服务与诊断     启动 / 停止 / 重启 / 状态 / 日志 / 自启 / 协议自检
   4) 系统维护       更新 / 配置同步 / 卸载
   0) 退出
```

在“节点与协议 → Argo 隧道”中可启用、停用或修改 Argo，“连接与订阅”保留原入口。Argo 是可选的 Cloudflare 隧道；Reality、Hysteria2 和 SOCKS5 使用独立直连入口，Reality 伪装域名继续排除 Cloudflare 地址。

## ⌨️ 命令行快捷操作

如果不希望进入交互面板，也支持直接带参数快速执行：

```bash
sbm install         # 直接执行主节点完整部署流程
sbm links           # 重新计算并查看服务连接参数与凭证
sbm resni           # 手动重新选择 Reality 伪装域名 (SNI) 并重启生效
sbm apply           # 升级脚本后一键同步：按新版本模板重写配置并重启、刷新链接
sbm restart         # 重启系统后台的所有相关运行服务
sbm status          # 查看当前各个核心组件的系统运行状态
sbm verify          # 对已启用协议进行限时认证与流量自检（不代替外部客户端测试）
sbm uninstall       # 完全卸载本项目及其生成的所有缓存与配置
```

## 🌐 IPv4 / IPv6 VPS

脚本会按 VPS 实际公网网络生成节点链接：IPv4-only 和双栈 VPS 默认生成 IPv4 Reality 直连链接；IPv6-only VPS 通过默认启用的 Argo 生成外部节点链接。Reality 与 Argo 是独立入口。Argo 会从内置列表分别实测 IPv4/IPv6 连接地址，只生成当前 VPS 能用对应地址族完成 WebSocket 握手的链接；TLS SNI、WebSocket Host 和路径始终使用当前 `ARGO_DOMAIN`。

NAT VPS 会使用面板分配的公网 TCP/UDP 端口生成链接，同时保持服务使用本机监听端口。Reality 的公网端口与本机监听端口可在“修改 Reality 端口”中一次确认；其他协议的公网端口可在“修改 NAT 公网映射”中更新。脚本会检查 Reality 新端口在本机监听，但无法修改或验证服务商面板的实际映射。

代理访问目标网站时走 IPv4 还是 IPv6，与客户端用哪种 IP 连入无关，可在“连接与订阅”→“公网与 NAT”→“修改出站 IP 优先级”中设置：默认、优先 IPv4、优先 IPv6、仅 IPv4、仅 IPv6；安装时也可用环境变量 `OUTBOUND_IP_STRATEGY=prefer_ipv6` 等指定。非默认值会写入 sing-box `direct` 出站的 `domain_resolver`（系统 DNS + `strategy`），重新生成配置时保持不变。该设置只对客户端交给服务端解析的域名生效（远程 DNS / `socks5h`），不影响由 Xray 承载的 Reality。

## 🔌 可选 SOCKS5 代理

主节点安装完成后运行 `sbm`，依次进入“节点与协议”→“SOCKS5”→“管理 SOCKS5 代理”。启用后脚本会：

- 使用独立随机高位 TCP 端口和强随机密码；
- 写入带用户名密码认证的 sing-box SOCKS 入站；
- 放行对应 TCP 端口并重启 sing-box；
- 输出可直接粘贴到代理池的 `socks5://用户名:密码@IP:端口` 链接。

双栈 VPS 仅在本机网卡已分配可用公网 IPv6 时输出 IPv6 SOCKS5 链接：`socks5://用户名:密码@[IPv6]:端口`。IPv6 使用本机 SOCKS5 监听端口，不套用 IPv4 NAT 映射端口。仅能通过 IPv6 上网的 NAT66 环境不会生成 IPv6 入口链接；需先由服务商分配可入站公网 IPv6。`sbm verify` 分别验证 IPv4、IPv6 本机认证与流量，公网入站仍需从外部客户端确认。

SOCKS5 不会加入 VLESS/Hysteria2 订阅内容，只写入终端输出和 `/etc/sing-box/share-links.txt`。公网使用时应在 VPS 安全组中把 SOCKS5 端口限制为业务服务器的固定出口 IP。

## 🧭 部署方式

管理面板和 `sbm install` 仅保留主节点完整部署。选择主菜单 `1) 节点与协议`→`1) 安装节点` 后会直接开始主节点安装，不再显示部署目标选择。

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

脚本先检测网络类型并显示协议选择页；输入 `1,2` 可同时启用 Argo 与 SOCKS5，输入 `1` 或 `2` 单选，按 Enter 使用当前网络类型的默认组合。随后配置 Reality/SOCKS5 端口、NAT 公网映射、Reality 伪装域名、节点名称，以及已选的 Argo 模式，并自动生成 UUID、Reality 密钥与订阅凭据。

新安装仅由 sing-box 承载 Reality；旧配置中已部署的 Xray Reality 继续保留原有管理路径。临时 Argo 隧道遇到已有 `.cloudflared/config.yaml` 时会停止配置并提示冲突，不会改动该文件。

### 步骤 3：查看链接

安装完成后按已启用功能输出节点链接；启用 Argo 时提供 HTTPS 订阅地址。SOCKS5 可在安装时勾选，也可在“节点与协议”→“SOCKS5”中启用。

安装完成及配置更新后会对已启用协议尝试限时认证与流量测试；`sbm verify` 可随时重新执行。显示“本机通过”不代表 NAT 面板映射或外部客户端通过，公网仍需从另一网络实际验证。Hysteria2 默认未启用，未启用时不展示端口和密码。

```bash
sbm links
```

开发环境具备网络、`openssl` 与 `python3` 时，可执行 `bash tests/protocol-integration.sh`：使用官方 sing-box 二进制检查生成配置，并在独立临时目录中验证 Reality、Hysteria2 和 SOCKS5 的本机认证与流量；Argo 仍需有真实隧道和外部客户端验证。

## 🛡️ 安全建议

1. 优先使用 HTTPS 订阅地址，不要公开订阅调试地址。
2. 不要公开 Argo token、订阅 token、UUID 或 Reality 私钥。
3. 怀疑凭据泄露时，应重新生成对应凭据。
4. 订阅服务保持监听 `127.0.0.1`；SOCKS5 端口应限制允许访问的来源 IP。
5. 域名检查不能消除 Reality 未认证转发或保证流量账单上限。

## 🔄 旧用户升级兼容说明

- 现有 `/etc/sing-box/.params` 参数文件继续兼容，升级后无需重新安装。
- 主节点、订阅、Argo、Reality、Hysteria2 和 SOCKS5 配置继续保留。
- 脚本升级不自动重写运行配置。使用旧 CDN SNI 的节点可执行 `sbm resni` 重新优选，再执行 `sbm apply` 应用静态 Hysteria2 伪装。
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
make lint     # 运行 ShellCheck (warning 级别即失败)，未安装时跳过
make check    # build + test + lint + checksum
```

`install.sh` 和 `dist/install.sh.sha256` 是生成文件，修改 `src/` 后需一并提交；CI 会检查两者是否与源码一致。

内置 sing-box 备份位于 [vendor/sing-box/](vendor/sing-box/)。更新到最新官方版本：在 GitHub Actions 手动运行 “Update vendored sing-box”，或在本地执行 `bash scripts/update-vendored-singbox.sh [版本号]` 后提交。
CI 会在 Debian、Ubuntu、Fedora、Alpine 容器中运行 smoke checks；兼容性矩阵见 [docs/compatibility.md](docs/compatibility.md)。

## 📄 License

MIT
