"""Embedded sbm engine manager. Standard library only; never evaluates shell data."""
import contextlib
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

IO_DEADLINE = None


def io_budget():
    if IO_DEADLINE is not None and time.monotonic() >= IO_DEADLINE:
        raise EngineError("检查未完成：已达到总时限", 2)


class EngineError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def require(condition, message):
    if not condition:
        raise EngineError(message)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            io_budget()
            h.update(block)
    return h.hexdigest()


def trusted(path):
    """Existing file and ancestors must be root-owned and not replaceable by others."""
    path = pathlib.Path(path)
    require(path.resolve() == path, "可信文件或目录不能通过未知符号链接替换")
    for item in (path, *path.parents):
        value = item.stat()
        require(value.st_uid == 0, "文件来源或目录权限不可信")
        writable = value.st_mode & 0o022
        sticky_parent = item != path and str(item) in ("/tmp", "/var/tmp") and value.st_mode & stat.S_ISVTX
        require(not writable or sticky_parent, "文件来源或目录权限不可信")
    return path


def trusted_system_file(path):
    """Accept the standard merged-/usr alias only after checking its owner and target."""
    path = pathlib.Path(path)
    if path.resolve() == path:
        return trusted(path)
    legacy = pathlib.Path("/lib")
    require(legacy.is_symlink() and os.lstat(legacy).st_uid == 0, "系统服务路径链接不可信")
    try:
        relative = path.relative_to(legacy)
    except ValueError:
        raise EngineError("系统服务路径链接不受支持") from None
    target = pathlib.Path("/usr/lib") / relative
    require(legacy.resolve() == pathlib.Path("/usr/lib") and path.resolve() == target,
            "系统服务路径链接不受支持")
    trusted(legacy.parent)
    return trusted(target)


def atomic_bytes(path, data, mode=0o600):
    path = pathlib.Path(path)
    require(not path.is_symlink(), "拒绝替换未知符号链接")
    fd, temporary = tempfile.mkstemp(prefix=".sbm-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def atomic_json(path, data):
    atomic_bytes(path, (json.dumps(data, sort_keys=True) + "\n").encode())


def load_json(path):
    path = pathlib.Path(path)
    require(path.is_file() and not path.is_symlink(), "状态或配置不是普通文件")
    require(path.stat().st_size <= 4 * 1024 * 1024, "状态或配置文件过大")
    with open(path, encoding="utf-8") as handle:
        content = handle.read(4 * 1024 * 1024 + 1)
    io_budget()
    require(len(content.encode("utf-8")) <= 4 * 1024 * 1024, "状态或配置文件过大")
    return json.loads(content)


def safe_path(value):
    require(isinstance(value, str) and re.fullmatch(r"/[A-Za-z0-9_./+-]*", value), "不支持的路径或启动参数")
    require(".." not in pathlib.PurePosixPath(value).parts, "路径包含越界部分")
    return pathlib.Path(value)


def params_read(path):
    values = {}
    if not path.is_file():
        return values
    require(not path.is_symlink(), "参数文件不是普通文件")
    require(path.stat().st_size <= 1024 * 1024, "参数文件过大")
    with path.open(encoding="utf-8") as handle:
        content = handle.read(1024 * 1024 + 1)
    require(len(content.encode("utf-8")) <= 1024 * 1024, "参数文件过大")
    for line in content.splitlines():
        io_budget()
        match = re.fullmatch(r'([A-Z][A-Z0-9_]*)="((?:[^"\\]|\\[\\"])*)"', line)
        if match:
            values[match[1]] = re.sub(r'\\([\\"])', r'\1', match[2])
    return values


@dataclass
class Paths:
    engines: pathlib.Path
    state: pathlib.Path
    config: pathlib.Path
    params: pathlib.Path
    openrc: pathlib.Path
    dropin: pathlib.Path
    lock: pathlib.Path = pathlib.Path("/run/sbm/maintenance.lock")

    @property
    def manifest(self):
        return self.state / "engine.json"

    @property
    def pending(self):
        return self.state / "pending.json"

    @property
    def current(self):
        return self.engines / "current"


class Host:
    def __init__(self, deadline=None):
        self.deadline = deadline

    def run(self, argv, seconds=5, cwd=None, check=True):
        if self.deadline is not None:
            seconds = min(seconds, self.deadline - time.monotonic())
        if seconds <= 0:
            raise EngineError("检查未完成：已达到总时限", 2)
        try:
            result = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=seconds, text=True,
                                    encoding="utf-8", errors="replace")
        except (OSError, subprocess.TimeoutExpired):
            raise EngineError("命令不可用或超时", 2) from None
        if check and result.returncode:
            program = pathlib.Path(str(argv[0])).name
            if program not in ("systemctl", "rc-service", "rc-update", "runuser", "ss", "openssl"):
                program = "核心"
            raise EngineError(program + " 查询或操作失败（退出码 " + str(result.returncode) + "）")
        return result

    def manager(self):
        if shutil.which("systemctl"):
            if self.run(["systemctl", "show", "--property=Version", "--value"], check=False).returncode == 0:
                return "systemd"
        if shutil.which("rc-service"):
            return "openrc"
        return "none"

    def pid(self, manager):
        if manager == "systemd":
            text = self.run(["systemctl", "show", "sing-box", "--property=MainPID", "--value"]).stdout.strip()
        else:
            child = pathlib.Path("/run/openrc/options/sing-box/child_pid")
            pidfile = pathlib.Path("/run/sing-box.pid")
            text = (child if child.exists() else pidfile).read_text().strip()
        require(re.fullmatch(r"[1-9][0-9]*", text), "无法确认实际核心进程")
        return int(text)

    def active(self, manager):
        if manager == "systemd":
            return self.run(["systemctl", "is-active", "--quiet", "sing-box"], check=False).returncode == 0
        if manager == "openrc":
            return self.run(["rc-service", "sing-box", "status"], check=False).returncode == 0
        return False

    def enabled(self, manager):
        if manager == "systemd":
            value = self.run(["systemctl", "is-enabled", "sing-box"], check=False).stdout.strip()
            require(value in ("enabled", "disabled"), "不支持的服务自启状态")
            return value == "enabled"
        output = self.run(["rc-update", "show", "default"]).stdout
        return bool(re.search(r"^\s*sing-box\s*\|", output, re.M))

    def restart(self, manager):
        if manager == "systemd":
            self.run(["systemctl", "restart", "sing-box"], seconds=30)
        else:
            result = self.run(["rc-service", "sing-box", "status"], check=False)
            if result.returncode in (32, 64):
                # A live old PID must never be hidden by zap.
                try:
                    os.kill(self.pid(manager), 0)
                except (ProcessLookupError, FileNotFoundError, EngineError):
                    self.run(["rc-service", "sing-box", "zap"], seconds=10)
                else:
                    raise EngineError("OpenRC 状态异常且仍有存活进程")
            self.run(["rc-service", "sing-box", "restart"], seconds=30)

    def stop(self, manager):
        self.run(["systemctl", "stop", "sing-box"] if manager == "systemd" else
                 ["rc-service", "sing-box", "stop"], seconds=30)

    def reload(self, manager):
        if manager == "systemd":
            self.run(["systemctl", "daemon-reload"], seconds=10)


@dataclass
class Contract:
    manager: str
    binary: pathlib.Path
    argv: list
    workdir: pathlib.Path
    files: list
    service_files: list
    user: str = "root"
    group: str = ""
    running: bool = False
    enabled: bool = False
    signature: str = ""
    config_hash: str = ""
    inbounds: list = field(default_factory=list)

    def fingerprint(self, paths):
        values = []
        require(len(set(paths)) <= 128, "配置材料过多")
        total = 0
        for path in sorted(set(paths)):
            io_budget()
            require(path.is_file() and not path.is_symlink(), "配置材料缺失或是未知链接")
            meta = path.stat()
            require(meta.st_size <= 64 * 1024 * 1024, "配置材料过大")
            total += meta.st_size
            require(total <= 128 * 1024 * 1024, "配置材料总量过大")
            values.append((str(path), meta.st_mode, meta.st_uid, meta.st_gid, digest(path)))
        return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()

    def config_snapshot(self):
        material = list(self.files)
        inbounds = []
        for filename in self.files:
            config = load_json(filename)
            require(isinstance(config, dict), "配置结构无效")
            require(set(config) <= {"log", "inbounds", "outbounds", "route", "dns"}, "配置包含尚未支持的扩展")
            require(isinstance(config.get("log", {}), dict) and isinstance(config.get("route", {}), dict), "配置结构无效")
            require(isinstance(config.get("inbounds", []), list) and isinstance(config.get("outbounds", []), list), "配置结构无效")
            require(set(config.get("log", {})) <= {"level", "timestamp", "disabled"}, "配置包含文件日志或未知日志设置")
            require(not config.get("route", {}).get("rule_set"), "暂不接管带规则集的配置")
            for outbound in config.get("outbounds", []):
                require(isinstance(outbound, dict), "配置结构无效")
                require(outbound.get("type") in ("direct", "block", "dns"), "暂不接管含额外代理出站的配置")
            for inbound in config.get("inbounds", []):
                require(isinstance(inbound, dict), "配置结构无效")
                require(inbound.get("type") in ("vless", "hysteria2", "socks"), "配置包含尚未支持的入站")
                require(isinstance(inbound.get("listen_port"), int) and 0 < inbound["listen_port"] <= 65535,
                        "入站端口无效")
                tls = inbound.get("tls", {})
                require(isinstance(tls, dict), "TLS 配置结构无效")
                require(not tls.get("acme"), "暂不接管自动签发证书的配置")
                for key in ("key_path", "certificate_path"):
                    if key in tls:
                        value = safe_path(tls[key])
                        material.append(value)
                inbounds.append(inbound)
        self.inbounds = inbounds
        self.config_hash = self.fingerprint(material)
        # Directory membership is part of the contract, not only current file bytes.
        self.signature = self.fingerprint(self.service_files)
        return self.config_hash

    def check_args(self):
        return ["check" if value == "run" else value for value in self.argv]


def startup_args(tokens):
    require(tokens.count("run") == 1, "不支持的服务启动方式")
    result = []
    files = []
    directories = []
    workdir = pathlib.Path("/")
    index = 0
    while index < len(tokens):
        flag = tokens[index]
        if flag == "run":
            result.append(flag)
            index += 1
            continue
        require(flag in ("-c", "--config", "-C", "--config-directory", "-D", "--directory"),
                "启动参数超出受支持范围")
        require(index + 1 < len(tokens), "服务启动参数缺失")
        value = safe_path(tokens[index + 1])
        if flag in ("-D", "--directory"):
            require(value.is_dir() and not value.is_symlink(), "工作目录不存在或不受支持")
            workdir = value
        elif flag in ("-C", "--config-directory"):
            require(value.is_dir() and not value.is_symlink(), "配置目录不存在或不受支持")
            directories.append(value)
            members = config_files(value)
            files.extend(members)
        else:
            files.append(value)
        result.extend((flag, str(value)))
        index += 2
    require(files, "服务没有明确的配置文件")
    return result, list(dict.fromkeys(files)), directories, workdir


def config_files(directory):
    members = []
    with os.scandir(directory) as entries:
        for item in entries:
            io_budget()
            if item.name.endswith(".json"):
                members.append(pathlib.Path(item.path))
                require(len(members) <= 128, "配置目录文件过多")
    return sorted(members)


def read_contract(paths, host):
    manager = host.manager()
    service_files = []
    user = "root"
    if manager == "systemd":
        properties = ("ExecStart", "ExecStartPre", "ExecStartPost", "ExecStop", "FragmentPath", "DropInPaths",
                      "User", "Group", "WorkingDirectory", "RootDirectory", "RootImage", "NoExecPaths",
                      "InaccessiblePaths", "BindPaths", "BindReadOnlyPaths", "Environment", "EnvironmentFiles",
                      "DynamicUser", "PrivateUsers", "ProtectHome", "ExecPaths", "RestrictFileSystems",
                      "AppArmorProfile", "SELinuxContext", "SupplementaryGroups", "ReadOnlyPaths", "ReadWritePaths")
        result = host.run(["systemctl", "show", "sing-box", "--no-pager"] +
                          ["--property=" + name for name in properties])
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        for name in ("ExecStartPre", "ExecStartPost", "ExecStop", "RootDirectory", "RootImage", "NoExecPaths",
                     "InaccessiblePaths", "BindPaths", "BindReadOnlyPaths", "Environment", "EnvironmentFiles",
                     "ExecPaths", "RestrictFileSystems", "AppArmorProfile", "SELinuxContext", "SupplementaryGroups",
                     "ReadOnlyPaths", "ReadWritePaths"):
            require(not values.get(name), "服务含未知启动钩子、环境或沙箱路径")
        for name in ("DynamicUser", "PrivateUsers", "ProtectHome"):
            require(values.get(name, "no") in ("", "no"), "服务执行安全策略超出支持范围")
        text = values.get("ExecStart", "")
        match = re.fullmatch(r"\{ path=(/[A-Za-z0-9_./+-]+) ; argv\[\]=([A-Za-z0-9_./+ =-]+) ; ignore_errors=no ;[^{}]*\}", text)
        require(match, "无法安全解析唯一的服务执行命令")
        binary = safe_path(match[1])
        words = match[2].split()
        require(words and words[0] == str(binary), "服务核心路径不一致")
        argv, files, directories, workdir = startup_args(words[1:])
        configured_workdir = values.get("WorkingDirectory")
        if configured_workdir:
            workdir = safe_path(configured_workdir)
            require(workdir.is_dir(), "服务工作目录不存在")
        user = values.get("User") or "root"
        group = values.get("Group") or ""
        require(re.fullmatch(r"[A-Za-z0-9_-]+", user), "服务用户无效")
        require(not group or re.fullmatch(r"[A-Za-z0-9_-]+", group), "服务组无效")
        fragment = safe_path(values.get("FragmentPath", ""))
        require(fragment.name == "sing-box.service", "未知服务单元")
        service_files.append(trusted_system_file(fragment))
        for name in values.get("DropInPaths", "").split():
            path = safe_path(name)
            path = trusted_system_file(path)
            text = path.read_text()
            require(path == paths.dropin or not re.search(r"^\s*ExecStart\s*=", text, re.M),
                    "管理员已覆盖服务执行命令，未接管")
            service_files.append(path)
    elif manager == "openrc":
        group = ""
        text = paths.openrc.read_text()
        # Shell source is never executed. Only two exact, documented templates are accepted.
        lines = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
        definitions = {}
        for line in lines:
            if re.fullmatch(r'(name|description|command|command_args|pidfile|output_log|error_log|supervisor)="[A-Za-z0-9_./ +:-]+"', line):
                key, value = line.split("=", 1)
                require(key not in definitions, "OpenRC 字段重复")
                definitions[key] = value[1:-1]
            elif line in ("command_background=true", "respawn_delay=5", "respawn_max=5", "respawn_period=60",
                          "depend() {", "need net", "}", "depend() { need net; }"):
                continue
            else:
                raise EngineError("OpenRC 服务含未知自定义内容")
        require(definitions.get("name") == "sing-box" and definitions.get("pidfile") == "/run/sing-box.pid",
                "OpenRC 服务不是受支持模板")
        require(definitions.get("supervisor") == "supervise-daemon" or "command_background=true" in lines,
                "不支持的 OpenRC 进程方式")
        normalized = re.sub(r'^command="[A-Za-z0-9_./+-]+"$', 'command="CORE"', "\n".join(lines), flags=re.M)
        normalized = re.sub(r'^command_args="[A-Za-z0-9_./ +:-]+"$', 'command_args="ARGS"', normalized, flags=re.M)
        prefix = 'name="sing-box"\n'
        description = 'description="sing-box service"\n'
        base = 'command="CORE"\ncommand_args="ARGS"\n'
        logs = 'pidfile="/run/sing-box.pid"\noutput_log="/var/log/sing-box.log"\nerror_log="/var/log/sing-box.log"\n'
        supervised = prefix + description + base + 'supervisor="supervise-daemon"\nrespawn_delay=5\nrespawn_max=5\nrespawn_period=60\n' + logs + 'depend() {\nneed net\n}'
        legacy = prefix + base + 'command_background=true\n' + logs + 'depend() { need net; }'
        require(normalized in (supervised, legacy, prefix + description + base + 'command_background=true\n' + logs + 'depend() {\nneed net\n}'),
                "OpenRC 服务未匹配完整受支持模板")
        confd = pathlib.Path("/etc/conf.d/sing-box")
        require(not confd.exists() or not re.sub(r"(?m)^\s*#.*$", "", confd.read_text()).strip(),
                "OpenRC 存在额外覆盖配置")
        binary = safe_path(definitions.get("command", ""))
        argv, files, directories, workdir = startup_args(definitions.get("command_args", "").split())
        service_files.append(paths.openrc)
        if confd.exists():
            service_files.append(confd)
    else:
        raise EngineError("服务管理器不受支持", 2)
    require(binary.is_file() and os.access(binary, os.X_OK), "实际服务核心不存在或不可执行")
    # Package symlinks are accepted only after validating the resolved chain.
    trusted(binary.resolve())
    for filename in service_files:
        trusted(filename)
    contract = Contract(manager, binary, argv, workdir, files, service_files, user, group,
                        host.active(manager), host.enabled(manager))
    contract.directories = directories
    contract.config_snapshot()
    return contract


class EngineStore:
    def __init__(self, paths):
        self.paths = paths

    def read(self):
        require(self.paths.manifest.is_file(), "受管版本状态缺失")
        trusted(self.paths.manifest)
        data = load_json(self.paths.manifest)
        require(data.get("schema") == 1 and set(data) <= {"schema", "current", "previous", "contract", "updated"},
                "版本状态格式不受支持")
        for key in ("current", "previous"):
            record = data.get(key)
            if record:
                self.record_path(record)
        return data

    def record_path(self, record):
        require(isinstance(record, dict) and set(record) == {"version", "sha256", "path", "source", "evidence", "config_hash"},
                "版本记录无效")
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", record["version"]), "版本记录无效")
        require(re.fullmatch(r"[0-9a-f]{64}", record["sha256"]), "版本摘要无效")
        require(record["evidence"] in ("static", "runtime"), "版本证据无效")
        path = self.paths.engines / (record["version"] + "-" + record["sha256"]) / "sing-box"
        require(str(path) == record["path"] and path.resolve() == path, "受管内核路径无效")
        trusted(path)
        require(path.is_file() and not path.is_symlink() and stat.S_IMODE(path.stat().st_mode) == 0o755,
                "受管内核类型或执行权限异常")
        require(digest(path) == record["sha256"], "受管内核摘要不一致")
        return path

    def resolve(self):
        require(not self.paths.pending.exists(), "存在未完成事务，请先恢复")
        data = self.read()
        current = self.record_path(data["current"])
        require(self.paths.current.is_symlink() and self.paths.current.resolve() == current,
                "受管核心入口与记录不一致")
        return current

    def save_binary(self, binary, version, source, evidence, config_hash):
        sha = digest(binary)
        directory = self.paths.engines / (version + "-" + sha)
        directory.mkdir(mode=0o755, exist_ok=True)
        trusted(directory)
        destination = directory / "sing-box"
        if not destination.exists():
            atomic_bytes(destination, pathlib.Path(binary).read_bytes(), 0o755)
        require(digest(destination) == sha, "恢复核心保存失败")
        require(destination.is_file() and not destination.is_symlink() and
                stat.S_IMODE(destination.stat().st_mode) == 0o755, "恢复核心执行权限异常")
        return dict(version=version, sha256=sha, path=str(destination), source=source,
                    evidence=evidence, config_hash=config_hash)

    def switch(self, record):
        self.record_path(record)
        temporary = self.paths.engines / (".current-" + str(os.getpid()))
        require(not os.path.lexists(temporary), "临时核心入口已存在")
        os.symlink(record["path"], temporary)
        try:
            os.replace(temporary, self.paths.current)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()

    def cleanup(self, keep, dry_run=False):
        require(not self.paths.pending.exists(), "有未完成事务，未清理版本")
        protected = {record["path"] for record in keep if record}
        candidates = []
        for directory in self.paths.engines.iterdir():
            match = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)-([0-9a-f]{64})", directory.name)
            if not match or directory.is_symlink() or not directory.is_dir():
                continue
            binary = directory / "sing-box"
            if str(binary) in protected:
                continue
            require(list(directory.iterdir()) == [binary], "历史版本目录含未知文件，未删除")
            record = dict(version=match[1], sha256=match[2], path=str(binary), source="sbm", evidence="static", config_hash="")
            self.record_path(record)
            candidates.append((binary, directory))
        if dry_run:
            return
        for binary, directory in candidates:
            binary.unlink()
            directory.rmdir()


def binary_version(host, binary):
    binary = pathlib.Path(binary).resolve()
    trusted(binary)
    require(binary.is_file() and os.access(binary, os.X_OK), "核心不是普通可执行文件")
    with binary.open("rb") as handle:
        require(handle.read(4) == b"\x7fELF", "未执行未知的核心脚本")
    output = host.run([str(binary), "version"], seconds=8).stdout
    match = re.search(r"^sing-box version ([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)\s*$", output, re.M)
    require(match, "核心自报版本无效")
    return match[1]


def installation_source(host, binary):
    real = binary.resolve()
    if str(real).startswith("/usr/local/libexec/sbm/sing-box/"):
        return "sbm"
    for command, args, label in (("dpkg-query", ["-S", str(real)], "deb"),
                                 ("apk", ["info", "--who-owns", str(real)], "apk"),
                                 ("rpm", ["-qf", str(real)], "rpm")):
        if shutil.which(command) and host.run([command] + args, check=False).returncode == 0:
            return label
    require(str(real) in ("/usr/local/bin/sing-box", "/usr/bin/sing-box"), "核心来源不明，未接管")
    # A package-free release installation is allowed only in its documented location.
    require(str(real) == "/usr/local/bin/sing-box", "核心来源不明，未接管")
    return "release"

class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(urllib.parse.urlsplit(newurl).scheme == "https", "下载重定向不是 HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, target=None, maximum=4 * 1024 * 1024):
    require(url.startswith("https://"), "下载地址不是 HTTPS")
    opener = urllib.request.build_opener(HTTPSOnly())
    request = urllib.request.Request(url, headers={"User-Agent": "sbm-version-manager", "Accept": "application/vnd.github+json"})
    started = time.monotonic()
    try:
        with opener.open(request, timeout=15) as response:
            data = bytearray()
            with contextlib.ExitStack() as stack:
                output = stack.enter_context(open(target, "wb")) if target else None
                count = 0
                while True:
                    require(time.monotonic() - started < 90, "下载已达到总时限")
                    block = response.read(128 * 1024)
                    if not block:
                        break
                    count += len(block)
                    require(count <= maximum, "下载内容超过大小上限")
                    if output:
                        output.write(block)
                    else:
                        data.extend(block)
                return count if output else bytes(data)
    except (OSError, ValueError):
        raise EngineError("官方发布下载失败，未切换安装来源") from None


def release_asset(version, arch):
    require(not version or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "仅支持明确的稳定版本号")
    suffix = "tags/v" + version if version else "latest"
    release = json.loads(fetch("https://api.github.com/repos/SagerNet/sing-box/releases/" + suffix))
    tag = release.get("tag_name", "")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) and
            release.get("draft") is False and release.get("prerelease") is False,
            "官方发布不是稳定版本")
    require(not version or tag == "v" + version, "官方版本与请求不一致")
    version = tag[1:]
    name = "sing-box-" + version + "-linux-" + arch + "-musl.tar.gz"
    assets = [item for item in release.get("assets", []) if item.get("name") == name]
    require(len(assets) == 1, "官方架构资产缺失或不唯一")
    asset = assets[0]
    expected_url = "https://github.com/SagerNet/sing-box/releases/download/" + tag + "/" + name
    require(asset.get("browser_download_url") == expected_url and asset.get("state") == "uploaded" and
            isinstance(asset.get("size"), int) and 0 < asset["size"] <= 128 * 1024 * 1024,
            "官方资产元信息无效")
    checksum = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", checksum):
        sums = [item for item in release.get("assets", [])
                if item.get("name") in ("sing-box-" + version + "-checksums.txt", "checksums.txt", "SHA256SUMS")]
        require(len(sums) == 1, "官方 SHA256 缺失，更新已停止")
        url = sums[0].get("browser_download_url", "")
        require(url == "https://github.com/SagerNet/sing-box/releases/download/" + tag + "/" + sums[0]["name"],
                "官方校验地址无效")
        matches = []
        for line in fetch(url).decode("utf-8").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})\s+\*?" + re.escape(name), line)
            if match:
                matches.append(match[1])
        require(len(matches) == 1, "官方校验文件中缺少唯一资产摘要")
        checksum = "sha256:" + matches[0]
    return dict(version=version, name=name, url=expected_url, size=asset["size"], sha256=checksum[7:])


def unpack_candidate(archive, destination, asset, arch):
    require(digest(archive) == asset["sha256"], "安装包 SHA256 不一致")
    expected = asset["name"][:-7] + "/sing-box"
    with tarfile.open(archive, "r:gz") as handle:
        members = handle.getmembers()
        require(len(members) <= 100, "归档成员过多")
        for item in members:
            path = pathlib.PurePosixPath(item.name)
            require(not path.is_absolute() and ".." not in path.parts and (item.isfile() or item.isdir()),
                    "归档含越界路径、链接或特殊文件")
        binary = [item for item in members if item.name == expected and item.isfile()]
        require(len(binary) == 1 and 0 < binary[0].size <= 256 * 1024 * 1024, "归档核心成员无效")
        with handle.extractfile(binary[0]) as source:
            atomic_bytes(destination, source.read(), 0o755)
    header = destination.read_bytes()[:20]
    require(len(header) == 20 and header[:4] == b"\x7fELF" and header[5] in (1, 2), "候选不是有效 ELF 核心")
    machine = int.from_bytes(header[18:20], "little" if header[5] == 1 else "big")
    require(machine == {"amd64": 62, "arm64": 183, "armv7": 40, "386": 3}[arch], "候选架构不符")


def read_process(pid):
    directory = pathlib.Path("/proc") / str(pid)
    first = (directory / "stat").read_text().rsplit(") ", 1)[1].split()
    require(first[0] not in ("Z", "X"), "核心进程已经退出")
    binary_hash = digest(directory / "exe")
    argv = [value.decode("utf-8") for value in (directory / "cmdline").read_bytes().split(b"\0") if value]
    second = (directory / "stat").read_text().rsplit(") ", 1)[1].split()
    require(first[19] == second[19], "进程在检查期间变化")
    return binary_hash, argv


def port_owned(host, pid, port, udp=False):
    output = host.run(["ss", "-H", "-l", "-u" if udp else "-t", "-n", "-p"]).stdout
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 5 and fields[3].rsplit(":", 1)[-1] == str(port) and ("pid=" + str(pid) + ",") in line:
            return True
    return False


def local_challenge(host, binary, inbound, directory):
    """Run an isolated local origin and authenticated client after readiness checks."""
    import http.server
    import secrets
    import threading
    nonce = secrets.token_hex(24).encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(nonce)

        def log_message(self, *args):
            pass

    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=origin.serve_forever, daemon=True)
    thread.start()
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    client_port = probe.getsockname()[1]
    probe.close()
    protocol = inbound["type"]
    user = inbound.get("users", [{}])[0]
    listen = inbound.get("listen", "::")
    require(listen in ("::", "0.0.0.0", "127.0.0.1"), "本机认证暂不支持此监听地址")
    outbound = dict(type=protocol, server="127.0.0.1", server_port=inbound["listen_port"], tag="test-out")
    if protocol == "socks":
        require(user.get("username") and user.get("password"), "SOCKS 认证资料缺失")
        outbound.update(version="5", username=user["username"], password=user["password"])
    else:
        require(user.get("password"), "Hysteria2 认证资料缺失")
        outbound.update(password=user["password"], up_mbps=100, down_mbps=100,
                        tls=dict(enabled=True, insecure=True, server_name=inbound.get("tls", {}).get("server_name", "localhost")))
    client = dict(log=dict(level="error"), inbounds=[dict(type="socks", listen="127.0.0.1", listen_port=client_port)],
                  outbounds=[outbound])
    filename = directory / "client.json"
    atomic_json(filename, client)
    process = None
    try:
        host.run([str(binary), "check", "-c", str(filename)], seconds=8)
        process = subprocess.Popen([str(binary), "run", "-c", str(filename)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = min(time.monotonic() + 15, host.deadline or float("inf"))
        ready = False
        while time.monotonic() < deadline:
            require(process.poll() is None, "临时认证客户端提前退出")
            try:
                with socket.create_connection(("127.0.0.1", client_port), timeout=0.2):
                    ready = True
                    break
            except OSError:
                time.sleep(0.1)
        require(ready, "临时认证客户端未就绪")
        require(shutil.which("curl"), "缺少本机认证依赖 curl")
        while time.monotonic() < deadline:
            result = host.run(["curl", "--noproxy", "", "--proxy", "socks5h://127.0.0.1:" + str(client_port),
                               "-fsS", "--connect-timeout", "1", "--max-time", "3",
                               "http://127.0.0.1:" + str(origin.server_port) + "/"], seconds=4, check=False)
            if result.returncode == 0 and result.stdout.encode() == nonce:
                return
            time.sleep(0.2)
        raise EngineError("本机认证或数据转发未通过（已等待客户端就绪）")
    finally:
        if process:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        origin.shutdown()
        origin.server_close()
        filename.unlink(missing_ok=True)


def runtime_health(host, contract, binary, directory):
    previous_deadline = host.deadline
    host.deadline = min(previous_deadline or float("inf"), time.monotonic() + 60)
    try:
        require(shutil.which("ss"), "缺少 ss，无法核对监听归属")
        expected = digest(binary)
        ready = False
        while time.monotonic() < host.deadline:
            try:
                require(host.active(contract.manager), "服务未正常运行")
                pid = host.pid(contract.manager)
                actual, arguments = read_process(pid)
                ready = actual == expected and arguments[1:] == contract.argv and all(
                    port_owned(host, pid, inbound["listen_port"], inbound["type"] == "hysteria2")
                    for inbound in contract.inbounds)
                if ready:
                    break
            except (EngineError, OSError):
                pass
            time.sleep(0.1)
        require(ready, "服务核心或监听未在时限内就绪")
        for _ in range(2):
            require(host.active(contract.manager), "服务未正常运行")
            pid = host.pid(contract.manager)
            actual, arguments = read_process(pid)
            require(actual == expected and arguments[1:] == contract.argv, "实际运行核心或参数与目标不一致")
            for inbound in contract.inbounds:
                require(port_owned(host, pid, inbound["listen_port"], inbound["type"] == "hysteria2"),
                        "预期监听未归属于实际核心进程")
            time.sleep(0.2)
        for inbound in contract.inbounds:
            if inbound["type"] in ("socks", "hysteria2"):
                local_challenge(host, binary, inbound, directory)
    finally:
        host.deadline = previous_deadline


def contract_guard(contract, ignore=None):
    # Include config directory membership so added files cannot evade drift detection.
    members = [(str(directory), [str(item) for item in config_files(directory)])
               for directory in contract.directories]
    services = [item for item in contract.service_files if item != ignore]
    dropins = systemd_dropin_inventory(ignore) if contract.manager == "systemd" else []
    value = dict(config=contract.config_snapshot(), members=members, services=contract.fingerprint(services), dropins=dropins,
                 argv=contract.argv, user=contract.user, group=contract.group, workdir=str(contract.workdir))
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


SYSTEMD_UNIT_PATHS = tuple(pathlib.Path(path) for path in (
    "/etc/systemd/system.control", "/run/systemd/system.control", "/run/systemd/transient",
    "/run/systemd/generator.early", "/etc/systemd/system", "/etc/systemd/system.attached",
    "/run/systemd/system", "/run/systemd/system.attached", "/run/systemd/generator",
    "/usr/local/lib/systemd/system", "/usr/lib/systemd/system", "/lib/systemd/system",
    "/run/systemd/generator.late"))


def systemd_dropin_inventory(ignore):
    """Track on-disk drop-ins too, including changes not yet loaded by systemd."""
    entries = []
    for root in SYSTEMD_UNIT_PATHS:
        for suffix in ("service.d", "sing-.service.d", "sing-box.service.d"):
            directory = root / suffix
            if not directory.is_dir():
                continue
            for item in directory.iterdir():
                io_budget()
                if item.suffix != ".conf" or item == ignore:
                    continue
                require(len(entries) < 128, "systemd 覆盖配置过多")
                path = trusted_system_file(item)
                require(path.is_file() and not path.is_symlink(), "systemd 覆盖配置不是普通文件")
                meta = path.stat()
                require(meta.st_size <= 4 * 1024 * 1024, "systemd 覆盖配置过大")
                entries.append((str(item), str(path), meta.st_mode, meta.st_uid, meta.st_gid, digest(path)))
    return sorted(entries)


class Upgrade:
    def __init__(self, paths, host):
        self.paths = paths
        self.host = host
        self.store = EngineStore(paths)

    def prepare_storage(self):
        require(os.geteuid() == 0, "版本操作需要 root 权限")
        self.paths.engines.mkdir(parents=True, mode=0o755, exist_ok=True)
        self.paths.state.mkdir(parents=True, mode=0o700, exist_ok=True)
        trusted(self.paths.engines)
        trusted(self.paths.state)
        require(self.paths.state.stat().st_mode & 0o077 == 0, "版本状态目录应仅 root 可访问")
        require(shutil.disk_usage(self.paths.engines).free > 512 * 1024 * 1024,
                "磁盘空间不足，未开始版本切换")
        require(not os.statvfs(self.paths.engines).f_flag & getattr(os, "ST_NOEXEC", 8),
                "版本目录所在文件系统禁止执行")

    def check(self, binary, contract):
        command = [str(binary)] + contract.check_args()
        if contract.user != "root" or contract.group:
            require(shutil.which("runuser"), "无法按实际服务用户检查候选")
            command = ["runuser", "-u", contract.user] + (["-g", contract.group] if contract.group else []) + ["--"] + command
        self.host.run(command, seconds=15, cwd=str(contract.workdir))

    def entry_path(self, contract):
        return self.paths.dropin if contract.manager == "systemd" else self.paths.openrc

    def entry_data(self, contract):
        if contract.manager == "systemd":
            arguments = " ".join(contract.argv)
            return ("# Managed by sbm: engine schema 1\n[Service]\nExecStart=\nExecStart=" +
                    str(self.paths.current) + " " + arguments + "\n").encode()
        original = self.paths.openrc.read_text()
        updated, count = re.subn(r'^command="[A-Za-z0-9_./+-]+"$', 'command="' + str(self.paths.current) + '"', original, flags=re.M)
        require(count == 1, "OpenRC 核心入口不唯一")
        return updated.encode()

    def snapshot(self, contract, old_record, old_state):
        import base64
        entry = self.entry_path(contract)
        require(not entry.is_symlink(), "服务入口是未知链接")
        prior = None
        if entry.exists():
            prior = dict(data=base64.b64encode(entry.read_bytes()).decode(), mode=stat.S_IMODE(entry.stat().st_mode),
                         uid=entry.stat().st_uid, gid=entry.stat().st_gid)
        current = os.readlink(self.paths.current) if self.paths.current.is_symlink() else None
        require(current is not None or not os.path.lexists(self.paths.current), "活动入口不是符号链接")
        require(digest(contract.binary) == old_record["sha256"], "原核心在检查期间发生变化")
        return dict(schema=1, manager=contract.manager, old=old_record, target=None, manifest=old_state, entry=prior,
                    original_binary=str(contract.binary.resolve()), original_sha256=old_record["sha256"],
                    current=current, running=contract.running, enabled=contract.enabled,
                    argv=contract.argv, workdir=str(contract.workdir), user=contract.user, group=contract.group,
                    files=[str(item) for item in contract.files], directories=[str(item) for item in contract.directories],
                    service_files=[str(item) for item in contract.service_files],
                    guard=contract_guard(contract, entry), new_entry=base64.b64encode(self.entry_data(contract)).decode(),
                    phase="prepared")

    def restore(self):
        import base64
        trusted(self.paths.pending)
        saved = load_json(self.paths.pending)
        require(saved.get("schema") == 1 and saved.get("manager") in ("systemd", "openrc"), "恢复事务格式无效")
        required = {"schema", "manager", "old", "target", "manifest", "entry", "original_binary", "original_sha256", "current",
                    "running", "enabled", "argv", "workdir", "user", "group", "files", "directories", "service_files",
                    "guard", "new_entry", "phase"}
        require(set(saved) == required and type(saved["running"]) is bool and type(saved["enabled"]) is bool and
                saved["phase"] in ("prepared", "switched"), "恢复事务字段无效")
        require(isinstance(saved["argv"], list) and all(isinstance(item, str) for item in saved["argv"]), "恢复参数无效")
        startup_args(saved["argv"])
        require(re.fullmatch(r"[A-Za-z0-9_-]+", saved["user"]) and
                (not saved["group"] or re.fullmatch(r"[A-Za-z0-9_-]+", saved["group"])), "恢复服务用户无效")
        for key in ("original_sha256", "guard"):
            require(isinstance(saved[key], str) and re.fullmatch(r"[0-9a-f]{64}", saved[key]), "恢复摘要无效")
        for key in ("files", "directories", "service_files"):
            require(isinstance(saved[key], list) and len(saved[key]) <= 128 and all(isinstance(item, str) for item in saved[key]),
                    "恢复材料清单无效")
            for item in saved[key]:
                safe_path(item)
        require(isinstance(saved["new_entry"], str) and len(saved["new_entry"]) <= 65536, "恢复入口过大")
        if saved["entry"]:
            require(set(saved["entry"]) == {"data", "mode", "uid", "gid"} and
                    isinstance(saved["entry"]["data"], str) and len(saved["entry"]["data"]) <= 65536 and
                    type(saved["entry"]["mode"]) is int and 0 <= saved["entry"]["mode"] <= 0o777 and
                    saved["entry"]["uid"] == 0 and type(saved["entry"]["gid"]) is int and saved["entry"]["gid"] >= 0,
                    "恢复入口权限或内容无效")
        require(saved["current"] is None or saved["manifest"] is not None and
                saved["current"] == saved["manifest"]["current"]["path"], "恢复活动入口无效")
        if saved["target"]:
            self.store.record_path(saved["target"])
        current_value = os.readlink(self.paths.current) if self.paths.current.is_symlink() else None
        require(not os.path.lexists(self.paths.current) or self.paths.current.is_symlink(), "活动入口被外部替换")
        allowed = {saved["current"], saved["target"]["path"] if saved["target"] else None}
        require(current_value in allowed, "活动入口被外部修改，保留恢复材料")
        binary = self.store.record_path(saved["old"])
        if saved["manifest"] is None:
            original_binary = safe_path(saved["original_binary"])
            trusted(original_binary)
            require(digest(original_binary) == saved["original_sha256"], "原软件包核心被外部修改，保留恢复材料，未重启")
        contract = Contract(saved["manager"], binary, saved["argv"], safe_path(saved["workdir"]),
                            [safe_path(item) for item in saved["files"]],
                            [safe_path(item) for item in saved["service_files"]], saved["user"], saved["group"],
                            saved["running"], saved["enabled"])
        contract.directories = [safe_path(item) for item in saved["directories"]]
        entry = self.entry_path(contract)
        require(contract_guard(contract, entry) == saved["guard"], "配置或其他服务文件已变化，保留恢复材料，请手动检查")
        live = read_contract(self.paths, self.host)
        require(contract_guard(live, entry) == saved["guard"], "实际服务契约已变化，保留恢复材料")
        allowed_binaries = {saved["original_binary"], saved["old"]["path"]}
        if saved["target"]:
            allowed_binaries.add(saved["target"]["path"])
        require(str(live.binary.resolve()) in allowed_binaries, "实际服务核心已变化，保留恢复材料")
        expected = base64.b64decode(saved["new_entry"], validate=True)
        original = saved["entry"]
        previous = base64.b64decode(original["data"], validate=True) if original else None
        require(not entry.is_symlink(), "服务入口出现未知链接，未覆盖")
        if entry.exists():
            require(entry.read_bytes() in (expected, previous), "服务入口被外部修改，未覆盖")
        self.host.deadline = time.monotonic() + 60
        try:
            self.check(binary, contract)
            if original:
                atomic_bytes(entry, previous, original["mode"])
                os.chown(entry, original["uid"], original["gid"])
            elif entry.exists():
                entry.unlink()
            if saved["current"] is None:
                if self.paths.current.is_symlink():
                    self.paths.current.unlink()
            else:
                self.store.switch(saved["manifest"]["current"])
            if saved["manifest"] is None:
                if self.paths.manifest.exists():
                    self.paths.manifest.unlink()
            else:
                atomic_json(self.paths.manifest, saved["manifest"])
            self.host.reload(contract.manager)
            require(self.host.enabled(contract.manager) == contract.enabled, "服务自启状态被外部修改")
            if contract.running:
                self.host.restart(contract.manager)
                with tempfile.TemporaryDirectory(prefix="restore-", dir=self.paths.state) as temporary:
                    runtime_health(self.host, contract, binary, pathlib.Path(temporary))
            elif self.host.active(contract.manager):
                self.host.stop(contract.manager)
            self.paths.pending.unlink()
            print("已恢复操作前的核心、服务入口与运行状态；当前配置保持不变。")
        finally:
            self.host.deadline = None

    def execute(self, version="", rollback=False):
        require(not self.paths.pending.exists(), "存在未完成事务，请先执行回退恢复")
        contract = read_contract(self.paths, self.host)
        old_state = self.store.read() if self.paths.manifest.exists() else None
        if old_state:
            require(self.store.resolve().resolve() == contract.binary.resolve(), "服务与受管入口不一致")
            require(rollback or old_state["current"]["evidence"] == "runtime", "当前版本运行未验证，请先启动验证或回退")
            require(contract_guard(contract, self.entry_path(contract)) == old_state["contract"], "服务或配置契约已变化，请先检查")
        require(not self.paths.current.exists() or old_state is not None, "活动入口缺少对应受管状态")
        source = "sbm" if old_state else installation_source(self.host, contract.binary)
        old_version = binary_version(self.host, contract.binary)
        original_sha256 = digest(contract.binary)
        before = contract_guard(contract, self.entry_path(contract))
        if not rollback:
            self.check(contract.binary, contract)
        require(contract_guard(contract, self.entry_path(contract)) == before, "配置在原版本检查期间变化")
        self.prepare_storage()
        with tempfile.TemporaryDirectory(prefix="upgrade-", dir=self.paths.state) as temporary:
            work = pathlib.Path(temporary)
            if contract.running and not rollback:
                runtime_health(self.host, contract, contract.binary, work)
            old_record = self.store.save_binary(contract.binary, old_version, source,
                                               "static" if rollback else "runtime" if contract.running else "static", contract.config_hash)
            if rollback:
                require(old_state and old_state.get("previous"), "没有可回退的上一版本")
                target = old_state["previous"].copy()
                candidate = self.store.record_path(target)
            else:
                arch = {"x86_64": "amd64", "aarch64": "arm64", "armv7l": "armv7", "i386": "386", "i686": "386"}.get(os.uname().machine)
                require(arch, "架构不受支持")
                asset = release_asset(version, arch)
                require(tuple(map(int, asset["version"].split("."))) > tuple(map(int, old_version.split("-")[0].split("."))),
                        "目标版本不高于当前版本；降级请使用上一版本回退")
                archive = work / "core.tar.gz"
                count = fetch(asset["url"], archive, maximum=asset["size"])
                require(count == asset["size"], "下载大小与官方资产不一致")
                candidate = work / "sing-box"
                unpack_candidate(archive, candidate, asset, arch)
                require(binary_version(self.host, candidate) == asset["version"], "候选自报版本与官方发布不一致")
                target = self.store.save_binary(candidate, asset["version"], "official", "static", contract.config_hash)
                candidate = pathlib.Path(target["path"])
            require(contract_guard(contract, self.entry_path(contract)) == before, "配置在下载期间变化，未切换")
            require(digest(contract.binary) == original_sha256, "原核心在下载期间被外部修改，未切换")
            self.check(candidate, contract)
            require(contract_guard(contract, self.entry_path(contract)) == before, "配置在候选检查期间变化")
            # Snapshot after all non-mutating validation; records absence as well as bytes.
            saved = self.snapshot(contract, old_record, old_state)
            saved["target"] = target
            atomic_json(self.paths.pending, saved)
            try:
                require(contract_guard(contract, self.entry_path(contract)) == before, "配置在切换前发生变化")
                require(digest(contract.binary) == original_sha256, "原核心在切换前被外部修改")
                self.host.deadline = time.monotonic() + 60
                self.store.switch(target)
                saved["phase"] = "switched"
                atomic_json(self.paths.pending, saved)
                entry = self.entry_path(contract)
                entry.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                import base64
                atomic_bytes(entry, base64.b64decode(saved["new_entry"]), 0o644 if contract.manager == "systemd" else 0o755)
                self.host.reload(contract.manager)
                changed = read_contract(self.paths, self.host)
                require(changed.binary == self.paths.current and changed.argv == contract.argv, "生效服务入口与预期不一致")
                require(self.host.enabled(contract.manager) == contract.enabled, "服务自启状态发生变化")
                if contract.running:
                    self.host.restart(contract.manager)
                    runtime_health(self.host, changed, candidate, work)
                    target["evidence"] = "runtime"
                else:
                    require(not self.host.active(contract.manager), "原停止服务被意外启动")
                    target["evidence"] = "static"
                target["config_hash"] = changed.config_hash
                require(contract_guard(changed, entry) == before, "配置或服务在验证期间发生变化")
                # A failing version being rolled back is not promoted into a healthy recovery point.
                prior = None if rollback else old_record
                data = dict(schema=1, current=target, previous=prior, contract=before, updated=int(time.time()))
                atomic_json(self.paths.manifest, data)
                self.paths.pending.unlink()
                self.host.deadline = None
            except BaseException:
                try:
                    self.restore()
                except EngineError as recovery_error:
                    print("恢复未完成（" + str(recovery_error) + "），已保留恢复材料；请执行 sbm doctor 检查，再执行回退。", file=sys.stderr)
                except (OSError, ValueError):
                    print("恢复未完成，已保留恢复材料；请执行 sbm doctor 检查，再执行回退。", file=sys.stderr)
                raise
            try:
                self.store.cleanup((target, prior))
            except (EngineError, OSError):
                print("[WARN] 历史版本清理未完成，当前版本已保留。", file=sys.stderr)
            print("核心版本已切换到 " + target["version"] + ("，运行验证通过，公网未验证。" if contract.running else "，配置已验证，服务保持停止，运行未验证。"))

    def validate_start(self, allow_stopped=False):
        if not self.paths.manifest.exists():
            return
        require(not self.paths.pending.exists(), "存在未完成版本事务")
        data = self.store.read()
        contract = read_contract(self.paths, self.host)
        binary = self.store.resolve()
        require(contract.binary == self.paths.current and contract.binary.resolve() == binary,
                "服务入口与受管核心不一致")
        self.check(binary, contract)
        if contract.running:
            with tempfile.TemporaryDirectory(prefix="validate-", dir=self.paths.state) as temporary:
                runtime_health(self.host, contract, binary, pathlib.Path(temporary))
            data["current"]["evidence"] = "runtime"
        else:
            require(allow_stopped, "核心当前未运行")
            data["current"]["evidence"] = "static"
        data["current"]["config_hash"] = contract.config_hash
        data["contract"] = contract_guard(contract, self.entry_path(contract))
        atomic_json(self.paths.manifest, data)

    def writable_config(self):
        contract = read_contract(self.paths, self.host)
        require(self.store.resolve() == contract.binary.resolve(), "服务与受管核心不一致")
        require(contract.files == [self.paths.config] and len(contract.inbounds) <= 4,
                "当前服务使用额外配置，不能使用模板配置修改")
        return 0

    def remove_managed(self):
        require(not self.paths.pending.exists(), "未完成事务必须先恢复")
        if not self.paths.manifest.exists():
            return
        data = self.store.read()
        contract = read_contract(self.paths, self.host)
        require(not self.host.active(contract.manager), "请先停止服务再卸载受管版本")
        require(contract.binary == self.paths.current, "服务入口已被外部修改，未删除")
        # Validate every historical removal before touching active links or service entry.
        self.store.cleanup((), dry_run=True)
        if contract.manager == "systemd":
            require(self.paths.dropin.read_bytes() == self.entry_data(contract), "受管覆盖文件已变化")
            self.paths.dropin.unlink()
        else:
            # The full uninstall removes this known project template separately.
            require(self.paths.openrc in contract.service_files, "未知 OpenRC 服务")
        trusted(self.paths.engines)
        self.paths.current.unlink()
        self.store.cleanup(())
        self.paths.manifest.unlink()
        self.host.reload(contract.manager)

class Doctor:
    def __init__(self, paths, host):
        self.paths = paths
        self.host = host
        self.failed = False
        self.incomplete = False

    def item(self, label, check):
        try:
            value = check()
            print("[正常] " + label + ("：" + value if value else ""))
        except EngineError as error:
            if error.code == 2:
                self.incomplete = True
                print("[未完成] " + label)
            else:
                self.failed = True
                print("[异常] " + label)
        except (PermissionError, FileNotFoundError, OSError, ValueError):
            self.incomplete = True
            print("[未完成] " + label)

    def run(self):
        print("sbm / 统一诊断（本机只读）")
        print("系统：" + os.uname().sysname + " / " + os.uname().machine)
        if not self.paths.params.exists() and not self.paths.config.exists() and not self.paths.manifest.exists():
            print("[信息] 尚未安装节点；主菜单 → 安装节点")
            return 0
        self.item("保存参数", lambda: self.parameters())
        self.item("配置结构", lambda: self.configuration())
        self.item("版本状态", lambda: self.versions())
        contract = None
        try:
            contract = read_contract(self.paths, self.host)
        except EngineError as error:
            self.incomplete = self.incomplete or error.code == 2
            self.failed = self.failed or error.code != 2
            print("[未完成] 服务契约" if error.code == 2 else "[异常] 服务契约")
        except (OSError, ValueError):
            self.incomplete = True
            print("[未完成] 服务契约")
        if contract:
            self.item("服务版本来源", lambda: binary_version(self.host, contract.binary) + " / " +
                      ("sbm" if self.paths.manifest.exists() else installation_source(self.host, contract.binary)))
            cli = shutil.which("sing-box")
            if cli:
                self.item("系统 CLI 版本", lambda: binary_version(self.host, pathlib.Path(cli)))
            print("[信息] 服务：" + ("运行中" if contract.running else "已停止") +
                  "；开机自启：" + ("开启" if contract.enabled else "关闭"))
            if contract.running:
                def process_check():
                    pid = self.host.pid(contract.manager)
                    actual, arguments = read_process(pid)
                    require(actual == digest(contract.binary) and arguments[1:] == contract.argv,
                            "运行核心与服务不一致")
                    return "核心摘要与启动参数一致"
                self.item("实际核心", process_check)
                def listeners():
                    pid = self.host.pid(contract.manager)
                    for inbound in contract.inbounds:
                        require(port_owned(self.host, pid, inbound["listen_port"], inbound["type"] == "hysteria2"),
                                "监听未归属于核心")
                    return "预期端口归属于实际核心进程"
                self.item("监听归属", listeners)
            for inbound in contract.inbounds:
                certificate = inbound.get("tls", {}).get("certificate_path")
                if certificate:
                    def cert_check(filename=certificate):
                        self.host.run(["openssl", "x509", "-checkend", "0", "-noout", "-in", filename])
                        return "未过期"
                    self.item("本机证书", cert_check)
        print("[信息] 完整配置语义、协议认证、公网 IPv4/IPv6/NAT/CF 可达性：未检查")
        print("操作入口：服务管理 → 协议自检 / 公网连通性排查；系统维护 → sing-box 版本管理")
        return 1 if self.failed else 2 if self.incomplete else 0

    def parameters(self):
        values = params_read(self.paths.params)
        require(all(key in values for key in ("REALITY_PORT", "REALITY_SNI", "UUID")), "保存参数不完整")
        enabled = [name for key, name in (("HY2_ENABLED", "Hysteria2"), ("SOCKS_ENABLED", "SOCKS5"),
                                          ("ARGO_ENABLED", "Argo")) if values.get(key) == "true"]
        # Display only controlled labels; values such as node names may contain terminal escapes.
        label = "Reality" + (" / " + " / ".join(enabled) if enabled else "")
        if values.get("NAT_MODE") == "true":
            public = values.get("REALITY_PUBLIC_PORT", "")
            local = values.get("REALITY_PORT", "")
            if public.isdigit() and local.isdigit():
                label += "；保存的 NAT TCP " + public + " → " + local + "（公网未验证）"
        if shutil.which("ip"):
            output = self.host.run(["ip", "-6", "-o", "addr", "show", "scope", "global"], check=False).stdout
            count = 0
            for line in output.splitlines():
                fields = line.split()
                if len(fields) >= 4:
                    try:
                        address = ipaddress.ip_interface(fields[3]).ip
                        if address.is_global:
                            count += 1
                    except ValueError:
                        pass
            label += "；网卡公网 IPv6：" + str(count) + " 个（入站未验证）"
        return label

    def configuration(self):
        value = load_json(self.paths.config)
        require(isinstance(value, dict) and isinstance(value.get("inbounds"), list), "配置结构无效")
        return "JSON 可读；未执行内核检查"

    def versions(self):
        require(not self.paths.pending.exists(), "有未完成版本操作")
        if not self.paths.manifest.exists():
            return "未启用 sbm 版本管理"
        data = EngineStore(self.paths).read()
        EngineStore(self.paths).resolve()
        record = data["current"]
        return record["version"] + ("；运行验证通过" if record["evidence"] == "runtime" else "；运行未验证")


def show_versions(paths, host):
    if paths.pending.exists():
        print("状态：有未完成事务，请执行 sbm rollback sing-box --yes 恢复。")
        return 1
    if paths.manifest.exists():
        data = EngineStore(paths).read()
        EngineStore(paths).resolve()
        for key, label in (("current", "当前版本"), ("previous", "上一版本")):
            record = data.get(key)
            if record:
                print(label + "：" + record["version"] + "（" +
                      ("运行已验证" if record["evidence"] == "runtime" else "配置已验证，运行未验证") + "）")
        print("管理来源：sbm 独立版本目录；系统软件包保留")
    else:
        contract = read_contract(paths, host)
        print("当前版本：" + binary_version(host, contract.binary))
        print("管理来源：" + installation_source(host, contract.binary) + "；尚未启用 sbm 版本管理")
    return 0


def engine_main(argv):
    global IO_DEADLINE
    require(len(argv) >= 8, "内核管理参数缺失")
    paths = Paths(*(pathlib.Path(item) for item in argv[:7]))
    action = argv[7]
    host = Host(time.monotonic() + 15 if action in ("doctor", "versions") else None)
    IO_DEADLINE = host.deadline
    if action == "doctor":
        return Doctor(paths, host).run()
    if action == "resolve":
        print(EngineStore(paths).resolve())
    elif action == "versions":
        return show_versions(paths, host)
    elif action == "compatible":
        if paths.manifest.exists():
            EngineStore(paths).resolve()
        return 0
    elif action == "manager-download":
        require(len(argv) == 9, "管理脚本下载目标缺失")
        metadata = json.loads(fetch("https://api.github.com/repos/iceeyes27/sing-box/commits/main"))
        revision = metadata.get("sha", "")
        require(re.fullmatch(r"[0-9a-f]{40}", revision), "管理脚本提交无效")
        base = "https://raw.githubusercontent.com/iceeyes27/sing-box/" + revision + "/"
        content = fetch(base + "install.sh", maximum=4 * 1024 * 1024)
        checksum = fetch(base + "dist/install.sh.sha256").decode("ascii").strip()
        require(re.fullmatch(r"[0-9a-f]{64}  install.sh", checksum) and
                hashlib.sha256(content).hexdigest() == checksum[:64], "管理脚本校验失败")
        target = pathlib.Path(argv[8])
        require(target.is_file() and not target.is_symlink() and target.stat().st_uid == os.geteuid(), "管理脚本临时文件不可信")
        atomic_bytes(target, content)
    elif action in ("upgrade", "rollback", "validate-start", "refresh", "remove-managed", "writable-config"):
        require(os.geteuid() == 0, "版本操作需要 root 权限")
        import fcntl
        inherited_fd = os.environ.get("SBM_INHERITED_LOCK_FD", "")
        require(re.fullmatch(r"[0-9]+", inherited_fd), "版本操作缺少维护锁")
        lock_fd = int(inherited_fd)
        actual_lock = os.fstat(lock_fd)
        expected_lock = paths.lock.stat()
        require(actual_lock.st_ino == expected_lock.st_ino and actual_lock.st_dev == expected_lock.st_dev and
                expected_lock.st_uid == 0 and stat.S_ISREG(expected_lock.st_mode), "维护锁来源无效")
        # Keep the inherited open-file description alive if the parent shell exits.
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        updater = Upgrade(paths, host)
        def interrupted(signum, frame):
            raise EngineError("版本操作被中断，恢复材料已保留")
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        if action == "rollback" and paths.pending.exists():
            updater.restore()
        elif action == "writable-config":
            return updater.writable_config()
        elif action == "remove-managed":
            updater.remove_managed()
        elif action == "refresh":
            updater.validate_start(allow_stopped=True)
        elif action == "validate-start":
            updater.validate_start()
        else:
            updater.execute(argv[8] if len(argv) > 8 else "", rollback=action == "rollback")
    else:
        raise EngineError("未知内核管理动作", 2)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(engine_main(sys.argv[1:]))
    except EngineError as error:
        print("[ERROR] " + str(error), file=sys.stderr)
        raise SystemExit(error.code)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, tarfile.TarError):
        # Never expose malformed config, ExecStart, URLs, credentials, or raw command errors.
        print("[ERROR] 检查或版本操作未完成；未输出可能包含凭据的原始错误。", file=sys.stderr)
        raise SystemExit(2)
