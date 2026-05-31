# 发布流程

## 1. 构建单文件安装脚本

开发态源码位于 `src/`，发布态脚本为仓库根目录的 `install.sh`。

```bash
make build
```

## 2. 本地检查

```bash
make check
```

检查内容包括：

- 重新生成 `install.sh`
- Bash 语法检查
- 回归测试
- ShellCheck（本机未安装时会跳过）
- 生成 `dist/install.sh.sha256`

## 3. 创建版本标签

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

## 4. 安装方式

### main 分支一键安装

```bash
wget -qO- https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh | sh
```

### 固定版本安装

```bash
wget -O install.sh https://raw.githubusercontent.com/iceeyes27/sing-box/vX.Y.Z/install.sh
bash -n install.sh
sudo bash install.sh
```

### 校验后安装

发布时同步提供 `dist/install.sh.sha256` 的内容，用户可下载后校验：

```bash
wget -O install.sh https://raw.githubusercontent.com/iceeyes27/sing-box/vX.Y.Z/install.sh
shasum -a 256 install.sh
# 对比发布说明中的 SHA256 后再执行
sudo bash install.sh
```

Linux 环境也可以使用：

```bash
sha256sum install.sh
```
