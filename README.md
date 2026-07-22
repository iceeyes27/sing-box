# sing-box 一键部署

本项目提供基于 `sing-box` 的自动化部署及配置管理脚本，支持多种网络协议栈的一键安装与系统服务管理。

> ⚠️ **免责声明**  
> 本项目属于个人网络协议原理学习与测试的开源项目。工具及代码仅供网络技术和安全协议的学习、研究及合法合规的内部网络架构测试使用。  
> 严禁将本项目包含的任何代码或工具用于任何构成违反国家网络信息安全相关法律法规的非法用途。任何使用者因违法使用本项目引发的全部法律责任和后果，完全由使用者自行承担，与项目原作者无关。一旦您获取、下载或使用本项目代码，即视为充分了解并完全同意本声明。

## ✨ 说明

- 🚀 **自动化安装** — 自动拉取官方核心并配置 sing-box；仅在启用固定域名 Argo 时安装 cloudflared。
- 🔧 **稳定优先链路** — 默认使用固定 SNI 的 VLESS Reality 直连；Hysteria2 和固定域名 Argo 作为附加链路。
- 🎯 **网络测速工具集** — 内置辅助脚本可自动侦测服务器到指定域名的网络连通性，自动择优分配高连通率测试节点。
- 🎛️ **交互式管理方案** — 内置终端管理控制面板，支持实时快捷修改端口参数、HTTPS 订阅链接、Argo 订阅链接、重载配置、监控日志与开机自启。
- 📡 **可选订阅网关** — 仅在配置固定域名 Argo 时启动本地订阅服务并暴露 HTTPS 订阅地址。
- 🧩 **NAT VPS 适配** — 自动识别公网 IPv4 不在本机网卡的环境，分别保存本机监听端口与面板公网映射端口；没有 UDP 映射时可直接禁用 Hysteria2。
- 🔀 **三种部署路径** — 支持主节点完整部署、当前机器直接部署线路机 / 落地机、以及导出独立线路机脚本。

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
  sing-box 管理面板  v2.6.34
  ────────────────────────────────────────
  sing-box: ● 运行中    argo-tunnel: ● 运行中

  部署 & 配置
   1) 部署 / 安装节点
   2) 修改配置 (端口 / 域名 / UUID / SNI)
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
sbm relay-install   # 直接把当前机器部署为线路机 / 落地机
sbm relay           # 根据主节点 Argo 配置生成线路机部署脚本
sbm links           # 重新计算并查看服务连接参数与凭证
sbm resni           # 手动重新选择 Reality 伪装域名 (SNI) 并重启生效
sbm apply           # 升级脚本后一键同步：按新版本模板重写配置并重启、刷新链接
sbm restart         # 重启系统后台的所有相关运行服务
sbm status          # 查看当前各个核心组件的系统运行状态
sbm uninstall       # 完全卸载本项目及其生成的所有缓存与配置
```

## 🌐 IPv4 / IPv6 VPS

脚本会按 VPS 实际公网网络生成节点链接：IPv4-only 和双栈 VPS 默认生成 IPv4 Reality/Hysteria2 直连链接；IPv6-only VPS 仅在配置固定域名 Argo 后生成外部节点链接。固定域名 Argo 始终直接使用自有域名，不使用第三方 CF 优选域名。

NAT VPS 会使用面板分配的公网 TCP/UDP 端口生成链接，同时保持 sing-box 使用本机监听端口。映射变化后可在 `sbm` 的“修改 NAT 公网映射”中更新，无需重写协议参数。

## 🧭 部署目标

主菜单的 `部署目标选择` 现在提供三种入口：

1. **主节点完整部署** — 默认安装 Reality/Hysteria2；固定域名 Argo 及订阅服务按需启用。
2. **只搭建线路机 / 落地机** — 直接在当前机器部署 relay，接入现有主节点。
3. **生成线路机部署脚本** — 读取当前主节点的 Argo 参数，导出独立安装脚本给另一台机器执行。

其中第 2 种模式支持两种参数来源：

- **手动输入**：逐项填写主节点接入地址、Argo Host、UUID、WS Path、本机监听端口、Reality 伪装域名和节点名称。
- **粘贴链接自动解析**：直接粘贴现有 `VLESS + WS + Argo` 链接，脚本会自动解析 UUID / server / host / path，再允许你确认和修正。
## 📘 完整教程

下面分别给出三种常见场景的完整操作流程。

### 教程一：从零搭建主节点

适合：你手上只有一台主 VPS，想优先部署稳定的 Reality 直连节点。

#### 步骤 1：下载安装脚本

```bash
wget -O install.sh https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh
sudo bash install.sh
```

#### 步骤 2：进入部署目标选择

在菜单里选择：

- `1) 部署目标选择`
- `1) 主节点完整部署`

#### 步骤 3：按提示完成主节点安装

脚本会依次引导你：

- 选择单端口或分端口模式
- NAT VPS 填写面板分配的公网 TCP/UDP 映射端口
- 启用固定域名 Argo 时设置订阅服务端口
- 确认固定的 Reality 伪装域名
- 设置节点名称
- 选择不启用 Argo，或配置固定域名和 Tunnel Token
- 自动生成 UUID、Reality 密钥、Hysteria2 参数
- 自动写入服务并启动

#### 步骤 4：获取结果

安装完成后，脚本会输出：

- Reality 直连链接
- 固定域名 Argo 链接（启用时）
- Hysteria2 链接
- HTTPS 订阅地址（启用固定域名 Argo 时）

后续可随时执行：

```bash
sbm links
```

重新查看链接和订阅地址。

---

### 教程二：当前机器直接部署线路机 / 落地机

适合：你已经有一个现成主节点，现在要把另一台机器直接部署成线路机 / 落地机。

#### 方式 A：最简单命令行方式

在目标机器上执行：

```bash
sbm relay-install
```

或者如果还没安装快捷命令，也可以：

```bash
sudo bash install.sh relay-install
```

#### 方式 B：从菜单进入

在管理面板选择：

- `1) 部署目标选择`
- `2) 只搭建线路机 / 落地机`

#### 步骤 1：优先用自动识别

现在脚本默认更偏向“小白化”操作，优先推荐：

1. **粘贴节点链接 / 订阅内容自动识别**
2. **手动输入全部参数**

自动识别支持三种常见输入：

- 单条 `VLESS + WS + Argo` 链接
- 多行订阅文本
- base64 编码的订阅内容

如果你已经有主节点分享出来的一条 Argo 节点，或者一整段订阅内容，直接粘贴即可。

#### 步骤 2：脚本自动列出可用 Argo 节点并让你选择

如果你粘贴的内容里包含多条可识别的 `VLESS + WS + Argo` 节点，脚本现在会：

1. 自动列出每一条候选节点
2. 显示每条节点的：
   - server
   - host
   - path
   - 节点名称
3. 让你直接输入编号选择要使用的那一条

如果只识别到 1 条，则会自动选中，不需要你额外操作。

#### 步骤 3：确认上游参数

脚本会把识别出来的内容展示出来，你只需要：

- 确认主节点接入地址
- 确认主节点 Argo Host / SNI
- 确认 UUID
- 确认 WS Path

如果有哪一项不对，直接改掉即可；留空则继续使用已识别的值。

#### 步骤 4：填写本机参数

接着只需要补 3 项：

- 本机监听端口
- 本机 Reality 伪装域名
- 节点名称

其中监听端口默认是 `443`，更适合简单部署。

#### 步骤 5：确认并开始部署

确认参数后，脚本会自动：

- 检查并修复时间同步
- 安装 sing-box
- 生成本机 Reality 密钥与 UUID
- 生成 relay 配置
- 启动 sing-box 服务
- 输出本机线路机 / 落地机链接

#### 步骤 6：拿到落地机链接并先做部署后自检

部署完成后，脚本会输出一条新的 Reality 链接，并保存到：

```text
/etc/sing-box/relay-link.txt
```

这条链接就是给客户端使用的线路机 / 落地机入口。

同时脚本现在还会自动做一页 **部署后自检**，重点确认：

- 配置文件是否已生成
- `sing-box check` 是否通过
- sing-box 服务是否 active
- 本机监听端口是否已监听
- `relay-link.txt` 是否已生成
- 本机到上游 `server:443` 的 TCP 连通性是否正常

如果自检全部通过，说明已经达到“可以先本机确认后再交付使用”的状态；如果还有未通过项，建议先执行 `sbm status` / `sbm logs` 继续检查。

**推荐最省事的做法：**

- 如果你有单条 Argo 节点链接：直接粘贴
- 如果你只有订阅内容：直接整段粘贴
- 如果你只有若干手工参数：再选手动输入

---

#### 步骤 7：如果部署失败，按提示排障

如果线路机 / 落地机部署失败，脚本现在会自动输出一段排障提示，重点帮助你检查：

- 主节点接入地址是否填错
- Argo Host / SNI 是否填错
- UUID 是否和上游一致
- WS Path 是否正确
- 本机监听端口是否已放行
- 本机 sing-box 服务是否真的启动成功
- 本机到上游 `server:443` 的 TCP 连通性是否正常

并且还会进一步给出一组 **自动诊断结论**，例如：

- 更像是 UUID 不匹配
- 更像是 WS Path / WebSocket 参数不匹配
- 更像是 Host / SNI / TLS 参数不匹配
- 更像是服务未启动或端口未监听成功
- 更像是本机到上游网络不通

如果需要进一步排查，可以继续执行：

```bash
sbm status
sbm logs
```

---

### 教程三：从主节点导出独立线路机脚本

适合：你已经在主节点上跑好了全套服务，现在想导出一个脚本给其它机器执行。

#### 步骤 1：在主节点上执行

```bash
sbm relay
```

或者从菜单进入：

- `1) 部署目标选择`
- `3) 生成线路机部署脚本`

#### 步骤 2：按提示设置线路机参数

脚本会提示：

- 线路机监听端口
- 线路机 Reality 伪装域名

并自动读取当前主节点的：

- Argo 接入地址
- Argo Host
- UUID
- WS Path

#### 步骤 3：复制脚本到线路机执行

脚本生成后会显示临时文件路径，例如：

```text
/tmp/sbm-relay-install.xxxxxx.sh
```

把这个脚本复制到目标机器后执行：

```bash
sh /tmp/sbm-relay-install.xxxxxx.sh
```

执行完成后，目标机器就会成为新的线路机 / 落地机。

---

## 🛡️ 安全建议

为了尽量简单且安全，建议按下面方式使用：

1. **优先使用 HTTPS 订阅地址，不要公开订阅调试地址。**
2. **不要把订阅 token、Argo token、UUID、Reality 私钥贴到公开聊天或工单里。**
3. **线路机 / 落地机场景下，尽量只开放实际使用的监听端口。**
4. **如果怀疑参数泄露，及时重新生成 UUID / token / Reality key。**
5. **自动识别只是为了省事，最终仍要确认 host、UUID、path 是否正确。**
6. **如果你粘贴的是整段订阅内容，脚本会列出其中所有可识别的 Argo 节点；请确认你选择的是想要使用的那一条。**
7. **订阅服务默认只监听 `127.0.0.1`，不要手动改成公网监听。**
8. **如果线路机 / 落地机场景显示“自检未全部通过”，建议先不要交付给最终用户，先用 `sbm status` / `sbm logs` 排查。**

## 🔄 旧用户升级兼容说明

对于已经在使用旧版本脚本的用户，本次更新保持 **向后兼容**：

- 旧的主节点完整部署流程不变，`sbm install` 仍按原方式工作。
- 旧的 `sbm relay` 仍然保留，继续用于 **从主节点导出线路机脚本**。
- 新增的 `sbm relay-install` 是 **增量能力**，不会替代旧命令。
- 现有 `/etc/sing-box/.params` 参数文件继续兼容，升级后无需手动迁移。
- 原有订阅、Argo、Reality、Hysteria2 相关流程不需要重装即可继续使用。

如果你是旧用户，通常只需要更新到新脚本版本，然后按需使用新增的 `relay-install` 功能即可。

## 📁 生成文件清单

脚本运行后可能创建或更新以下文件：

- `/etc/sing-box/config.json` — sing-box 主配置。
- `/etc/sing-box/.params` — 安装参数、端口、UUID、Reality key、订阅 token 等本地状态。
- `/etc/sing-box/share-links.txt` — 最近一次生成的节点分享链接。
- `/etc/sing-box/subscription.txt` — 订阅服务读取的订阅内容。
- `/etc/sing-box/sbm-subscription.env` — 订阅服务环境变量，包含订阅 token。
- `/etc/sing-box/argo-tunnel.env` — Argo Tunnel 运行参数。
- `/etc/sing-box/relay-link.txt` — 当前机器直装为线路机 / 落地机后生成的分享链接。
- `/usr/local/bin/sbm`、`/usr/local/bin/sing-box-manager` — 管理面板快捷命令。
- `/usr/local/bin/sbm-subscription-server.py` — 本地订阅服务脚本。
- `/etc/systemd/system/sing-box.service`、`/etc/systemd/system/argo-tunnel.service`、`/etc/systemd/system/sbm-subscription.service` — systemd 服务文件。
- `/etc/init.d/sing-box`、`/etc/init.d/argo-tunnel`、`/etc/init.d/sbm-subscription` — OpenRC 服务文件。

## 🔐 安全与暴露面

- 订阅服务默认只监听 `127.0.0.1`，公网订阅地址通过 Argo HTTPS 入口访问。
- 订阅地址包含随机 token；如怀疑泄露，建议重新生成 UUID / token / Reality key。
- 脚本会在确认端口后按系统环境尝试放行 sing-box 入站端口；订阅服务端口不应直接对公网开放。
- Argo token、订阅 token 和节点密钥均存放在本机配置文件中，请限制文件读取权限并避免公开日志输出。
- 线路机 / 落地机直装模式会严格校验上游参数，错误或不完整的 `VLESS + WS + Argo` 链接会被拒绝并要求改为手动输入。
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
