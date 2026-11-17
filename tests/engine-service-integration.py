#!/usr/bin/env python3
"""Real OpenRC core transactions inside a rootless, offline namespace/chroot.

The external launcher creates and verifies the isolated root, installs the
baseline Alpine package, and supplies a verified official target archive.
This script never installs packages, downloads files, or runs host services.
"""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]
MARKER = pathlib.Path("/.sbm-isolated-test-root")
TARGET_VERSION = "1.14.4"
TARGET_NAME = "sing-box-1.14.4-linux-amd64-musl.tar.gz"
TARGET_SHA256 = "8f7c5f0651238850d96a0e488e5473cd77ec1a0098f63942e943f475a12057ca"
TARGET_ARCHIVE = pathlib.Path("/workspace/fixtures") / TARGET_NAME
ENGINE_ROOT = pathlib.Path("/usr/local/libexec/sbm/sing-box")
STATE_ROOT = pathlib.Path("/var/lib/sbm")
CONFIG_ROOT = pathlib.Path("/etc/sing-box")
DROPIN = pathlib.Path("/etc/systemd/system/sing-box.service.d/50-sbm-engine.conf")
OPENRC = pathlib.Path("/etc/init.d/sing-box")
REPORT = pathlib.Path("/tmp/sbm-engine-service-report.json")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(argv, timeout=90, allowed=(0,)):
    result = subprocess.run([str(item) for item in argv], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, text=True)
    if result.returncode not in allowed:
        raise RuntimeError("fixture command failed: " + str(argv[0]) + "; exit=" + str(result.returncode) +
                           "; stderr=" + result.stderr[-2000:])
    return result


def environment_guard():
    """Check the launcher's isolation evidence before any filesystem mutation."""
    require(sys.platform.startswith("linux") and os.geteuid() == 0, "isolated Linux root required")
    require(os.environ.get("SBM_ISOLATED_TEST") == "1", "explicit isolated-test opt-in required")
    mappings = [line.split() for line in pathlib.Path("/proc/self/uid_map").read_text().splitlines() if line.strip()]
    require(len(mappings) == 1 and len(mappings[0]) == 3 and all(value.isdecimal() for value in mappings[0]),
            "a single rootless user-namespace mapping is required")
    inside, outside, count = map(int, mappings[0])
    require(inside == 0 and outside > 0 and count == 1, "uid 0 must map only to an outer non-root uid")
    for name, variable in (("mnt", "SBM_PARENT_MNT_NS"), ("pid", "SBM_PARENT_PID_NS"), ("net", "SBM_PARENT_NET_NS")):
        parent = os.environ.get(variable, "")
        require(re.fullmatch(name + r":\[[0-9]+\]", parent), "launcher parent namespace evidence missing")
        require(os.readlink("/proc/self/ns/" + name) != parent, "the " + name + " namespace is shared with the launcher")
    require(os.readlink("/proc/1/ns/pid") == os.readlink("/proc/self/ns/pid"),
            "procfs must belong to the private PID namespace")
    roots = []
    for line in pathlib.Path("/proc/self/mountinfo").read_text().splitlines():
        before, separator, after = line.partition(" - ")
        if separator and before.split()[4] == "/":
            roots.append(after.split()[0])
    require(roots == ["tmpfs"], "the chroot root must be its own tmpfs mount")
    identity = os.environ.get("SBM_ISOLATED_ROOT_ID", "")
    require(re.fullmatch(r"[A-Za-z0-9._-]{16,128}", identity), "launcher root identity missing")
    require(MARKER.is_file() and not MARKER.is_symlink(), "dedicated isolated-root marker missing")
    metadata = MARKER.stat()
    require(metadata.st_uid == 0 and stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_size <= 256,
            "isolated-root marker ownership or mode is invalid")
    require(MARKER.read_text().strip() == identity, "isolated-root marker does not match the launcher")
    require(os.uname().machine == "x86_64", "this local fixture currently supports x86_64")
    require(shutil.which("ip"), "iproute2 is required to verify network isolation")
    links = json.loads(run(["ip", "-j", "link", "show"]).stdout)
    require(len(links) == 1 and links[0].get("ifname") == "lo" and "UP" in links[0].get("flags", []),
            "the network namespace must contain only an enabled loopback interface")
    for family in ("-4", "-6"):
        routes = json.loads(run(["ip", "-j", family, "route", "show", "table", "all"]).stdout)
        require(all(route.get("dev") == "lo" and not route.get("gateway") and
                    route.get("dst") not in ("default", "0.0.0.0/0", "::/0") for route in routes),
                "the test namespace must have no external or default route")


def openrc_preflight():
    require(re.search(r'^ID=alpine$', pathlib.Path("/etc/os-release").read_text(), re.M),
            "the OpenRC fixture requires an isolated Alpine root")
    for tool in ("python3", "bash", "curl", "ss", "gcc", "apk", "rc-service", "rc-update", "supervise-daemon"):
        require(shutil.which(tool), "launcher did not supply dependency: " + tool)
    require(run(["apk", "info", "--exists", "sing-box"], allowed=(0, 1)).returncode == 0,
            "the launcher must preinstall the real sing-box Alpine package")
    require(run(["apk", "info", "--who-owns", "/usr/bin/sing-box"]).stdout.strip(), "packaged core ownership is missing")
    require(pathlib.Path("/usr/bin/sing-box").is_file() and not pathlib.Path("/usr/bin/sing-box").is_symlink(),
            "the installed package must supply an ordinary core file")
    for path in (ENGINE_ROOT, STATE_ROOT, pathlib.Path("/usr/local/bin/sing-box"),
                 CONFIG_ROOT / ".params", pathlib.Path("/run/sing-box.pid"), pathlib.Path("/run/sbm"),
                 pathlib.Path("/run/openrc/options/sing-box")):
        require(not os.path.lexists(path), "existing managed configuration or service state must be preserved")
    require(not pathlib.Path("/etc/conf.d/sing-box").exists() or
            not re.sub(r"(?m)^\s*#.*$", "", pathlib.Path("/etc/conf.d/sing-box").read_text()).strip(),
            "the launcher must provide a fresh package without custom OpenRC overrides")
    for process in pathlib.Path("/proc").iterdir():
        if process.name.isdecimal():
            try:
                same_core = os.path.samefile(process / "exe", "/usr/bin/sing-box")
            except (OSError, PermissionError):
                continue
            require(not same_core, "the isolated package core must not already be running")


def load_engine():
    spec = importlib.util.spec_from_file_location("sbm_service_engine", ROOT / "src/engine.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def files_snapshot(paths):
    result = {}
    for path in paths:
        value = path.stat()
        result[str(path)] = (hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(value.st_mode),
                             value.st_uid, value.st_gid)
    return result


@contextlib.contextmanager
def local_release(engine, asset, archive):
    """Replace offline download input only; all actual transaction checks remain."""
    original_release, original_fetch = engine.release_asset, engine.fetch

    def release(version, arch):
        require(version == asset["version"] and arch == "amd64", "unexpected local candidate request")
        return asset.copy()

    def fetch(url, target=None, maximum=0):
        require(url == asset["url"] and target is not None and maximum == asset["size"],
                "unexpected download request in the offline fixture")
        require(engine.digest(archive) == asset["sha256"], "local fixture archive changed")
        shutil.copyfile(archive, target)
        return archive.stat().st_size

    engine.release_asset, engine.fetch = release, fetch
    try:
        yield
    finally:
        engine.release_asset, engine.fetch = original_release, original_fetch


class ServiceIntegration:
    def __init__(self):
        self.engine = load_engine()
        self.host = self.engine.Host()
        self.work = pathlib.Path(tempfile.mkdtemp(prefix="sbm-service-isolated-", dir="/tmp"))
        self.paths = self.engine.Paths(ENGINE_ROOT, STATE_ROOT, CONFIG_ROOT / "config.json",
                                       CONFIG_ROOT / ".params", OPENRC, DROPIN)
        self.results = []
        self.service_prepared = False

    def prepare_assets(self):
        self.old_binary = pathlib.Path("/usr/bin/sing-box")
        self.old_version = self.engine.binary_version(self.host, self.old_binary)
        require(tuple(map(int, self.old_version.split("-")[0].split("."))) < tuple(map(int, TARGET_VERSION.split("."))),
                "the preinstalled baseline must be older than the supplied target")
        require(self.engine.installation_source(self.host, self.old_binary) == "apk", "real package ownership was not detected")
        require(TARGET_ARCHIVE.is_file() and not TARGET_ARCHIVE.is_symlink(), "launcher target archive missing")
        require(self.engine.digest(TARGET_ARCHIVE) == TARGET_SHA256, "official 1.14.4 archive SHA256 mismatch")
        self.asset = {"version": TARGET_VERSION, "name": TARGET_NAME,
                      "url": "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/" + TARGET_NAME,
                      "size": TARGET_ARCHIVE.stat().st_size, "sha256": TARGET_SHA256}
        candidate = self.work / "candidate-core"
        self.engine.unpack_candidate(TARGET_ARCHIVE, candidate, self.asset, "amd64")
        require(self.engine.binary_version(self.host, candidate) == TARGET_VERSION, "official target version mismatch")
        self.old_hash = self.engine.digest(self.old_binary)
        self.new_hash = self.engine.digest(candidate)
        require(self.old_hash != self.new_hash, "different real baseline and target cores are required")
        self.package_paths = [self.old_binary, pathlib.Path("/lib/apk/db/installed")]
        self.package_state = run(["apk", "info", "--all", "sing-box"]).stdout
        self.package_files = files_snapshot(self.package_paths)

    def prepare_service(self):
        CONFIG_ROOT.mkdir(mode=0o700, exist_ok=True)
        if self.paths.config.exists():
            require(self.paths.config.is_file() and not self.paths.config.is_symlink(), "packaged config is not an ordinary file")
            shutil.copy2(self.paths.config, self.work / "packaged-config.original")
        if OPENRC.exists():
            require(OPENRC.is_file() and not OPENRC.is_symlink(), "packaged OpenRC script is not an ordinary file")
            shutil.copy2(OPENRC, self.work / "packaged-openrc.original")
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        config = {"log": {"level": "error"}, "inbounds": [{"type": "socks", "tag": "isolated-socks",
                  "listen": "127.0.0.1", "listen_port": port,
                  "users": [{"username": "isolated-fixture", "password": secrets.token_hex(16)}]}],
                  "outbounds": [{"type": "direct", "tag": "direct"}]}
        self.engine.atomic_json(self.paths.config, config)
        self.engine.atomic_bytes(self.paths.params, ('REALITY_PORT="' + str(port) + '"\nREALITY_SNI="example.invalid"\n'
                                'UUID="isolated-fixture-only"\nSOCKS_ENABLED="true"\nARGO_ENABLED="false"\n').encode())
        self.expected_files = files_snapshot([self.paths.config, self.paths.params])
        for name in ("daemons", "exclusive", "failed", "hotplugged", "inactive", "options", "scheduled",
                     "started", "starting", "stopping", "tmp", "wasinactive"):
            (pathlib.Path("/run/openrc") / name).mkdir(parents=True, exist_ok=True)
        pathlib.Path("/run/openrc/softlevel").write_text("default\n")
        with pathlib.Path("/etc/rc.conf").open("a") as handle:
            handle.write('\n# Isolated service transaction fixture\nrc_cgroup_mode="none"\n')
        wrapper = pathlib.Path("/usr/local/sbin/rc-service")
        wrapper_text = '#!/bin/sh\nexec /sbin/rc-service --nodeps "$@"\n'
        require(not wrapper.exists() or wrapper.read_text() == wrapper_text, "unexpected preexisting service wrapper")
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        wrapper.write_text(wrapper_text)
        wrapper.chmod(0o755)
        os.environ["PATH"] = "/usr/local/sbin:" + os.environ["PATH"]
        OPENRC.write_text('#!/sbin/openrc-run\nname="sing-box"\ndescription="sing-box service"\n'
                          'command="/usr/bin/sing-box"\ncommand_args="run -c /etc/sing-box/config.json"\n'
                          'supervisor="supervise-daemon"\nrespawn_delay=5\nrespawn_max=5\nrespawn_period=60\n'
                          'pidfile="/run/sing-box.pid"\noutput_log="/var/log/sing-box.log"\n'
                          'error_log="/var/log/sing-box.log"\ndepend() {\n    need net\n}\n')
        OPENRC.chmod(0o755)
        self.openrc_original = OPENRC.read_bytes()
        self.paths.lock.parent.mkdir(mode=0o700)
        self.service_prepared = True

    def assert_unchanged(self):
        require(files_snapshot([self.paths.config, self.paths.params]) == self.expected_files, "node configuration changed")
        require(files_snapshot(self.package_paths) == self.package_files, "installed core or package database changed")
        require(run(["apk", "info", "--all", "sing-box"]).stdout == self.package_state, "package metadata changed")
        normalized = OPENRC.read_text().replace(str(self.paths.current), "/usr/bin/sing-box").encode()
        require(normalized == self.openrc_original, "OpenRC fields other than the executable path changed")

    def set_enabled(self, enabled):
        run(["rc-update", "add" if enabled else "del", "sing-box", "default"], allowed=(0, 1))
        require(self.host.enabled("openrc") == enabled, "could not establish requested boot state")

    def reset(self, running, enabled):
        if self.host.active("openrc"):
            self.host.stop("openrc")
        for path in (self.paths.engines, self.paths.state):
            require(path in (ENGINE_ROOT, STATE_ROOT) and not path.is_symlink(), "unsafe isolated cleanup path")
            if path.exists():
                shutil.rmtree(path)
        OPENRC.write_bytes(self.openrc_original)
        OPENRC.chmod(0o755)
        self.set_enabled(enabled)
        if running:
            self.host.restart("openrc")
            contract = self.engine.read_contract(self.paths, self.host)
            self.engine.runtime_health(self.host, contract, self.old_binary, self.work)
        require(self.host.active("openrc") == running, "could not establish requested running state")
        self.assert_unchanged()

    @contextlib.contextmanager
    def locked(self):
        with self.paths.lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def assert_version(self, version, sha, running, enabled):
        state = self.engine.EngineStore(self.paths).read()
        binary = self.engine.EngineStore(self.paths).resolve()
        require(state["current"]["version"] == version and self.engine.digest(binary) == sha, "wrong committed core")
        require(state["current"]["evidence"] == ("runtime" if running else "static"), "incorrect evidence level")
        require(not self.paths.pending.exists(), "completed transaction left pending state")
        require(self.host.active("openrc") == running and self.host.enabled("openrc") == enabled,
                "running or boot state changed")
        if running:
            contract = self.engine.read_contract(self.paths, self.host)
            self.engine.runtime_health(self.host, contract, binary, self.work)
        self.assert_unchanged()
        return state

    def normal_transactions(self):
        for running, enabled in ((True, True), (True, False), (False, True), (False, False)):
            print("CASE: OpenRC running=" + str(running) + " enabled=" + str(enabled), flush=True)
            self.reset(running, enabled)
            updater = self.engine.Upgrade(self.paths, self.host)
            with self.locked(), local_release(self.engine, self.asset, TARGET_ARCHIVE):
                updater.execute(TARGET_VERSION)
            state = self.assert_version(TARGET_VERSION, self.new_hash, running, enabled)
            require(state["previous"]["version"] == self.old_version, "packaged baseline was not retained")
            run(["bash", ROOT / "install.sh", "rollback", "sing-box", "--yes"], timeout=150)
            self.assert_version(self.old_version, self.old_hash, running, enabled)
            self.results.append({"scenario": "adopt-upgrade-rollback", "running": running, "enabled": enabled, "passed": True})

    def automatic_recovery(self):
        print("CASE: OpenRC automatic startup-failure recovery", flush=True)
        self.reset(True, True)
        version = "101.0.0"
        marker = pathlib.Path("/tmp/sbm-failing-core-started")
        marker.unlink(missing_ok=True)
        source = self.work / "failing-core.c"
        source.write_text('#include <stdio.h>\n#include <string.h>\nint main(int argc,char **argv){\n'
                          'for(int i=1;i<argc;i++){if(!strcmp(argv[i],"version")){puts("sing-box version ' + version + '");return 0;}'
                          'if(!strcmp(argv[i],"check"))return 0;}'
                          'FILE *f=fopen("/tmp/sbm-failing-core-started","w");if(f){fputs("run",f);fclose(f);}return 71;}\n')
        binary = self.work / "failing-core"
        run(["gcc", "-O2", "-o", binary, source])
        archive = self.work / "failing-core.tar.gz"
        name = "sing-box-" + version + "-linux-amd64-musl"
        with tarfile.open(archive, "w:gz") as handle:
            handle.add(binary, arcname=name + "/sing-box")
        asset = {"version": version, "name": name + ".tar.gz", "url": "https://isolated.invalid/failing-core",
                 "size": archive.stat().st_size, "sha256": self.engine.digest(archive)}
        failure = None
        original_health = self.engine.runtime_health

        def bounded_health(host, contract, core, directory):
            previous_deadline = host.deadline
            host.deadline = min(previous_deadline or float("inf"), time.monotonic() + 10)
            try:
                return original_health(host, contract, core, directory)
            finally:
                host.deadline = previous_deadline

        try:
            self.engine.runtime_health = bounded_health
            with self.locked(), local_release(self.engine, asset, archive):
                self.engine.Upgrade(self.paths, self.host).execute(version)
        except self.engine.EngineError as error:
            failure = error
        finally:
            self.engine.runtime_health = original_health
        require(failure is not None, "a core that exits at startup was reported successful")
        require(marker.is_file() and marker.read_text() == "run", "the candidate core was never started")
        require(not self.paths.pending.exists() and not self.paths.manifest.exists() and
                not os.path.lexists(self.paths.current), "first adoption failure was not fully restored")
        require(self.host.active("openrc") and self.host.enabled("openrc"), "baseline service state was not restored")
        contract = self.engine.read_contract(self.paths, self.host)
        require(contract.binary == self.old_binary, "baseline service entry was not restored")
        self.engine.runtime_health(self.host, contract, self.old_binary, self.work)
        self.assert_unchanged()
        self.results.append({"scenario": "automatic-startup-failure-recovery", "passed": True})

    def execute(self, scenario):
        try:
            self.prepare_assets()
            self.prepare_service()
            if scenario == "all":
                self.normal_transactions()
            self.automatic_recovery()
        finally:
            if self.service_prepared:
                with contextlib.suppress(Exception):
                    self.host.stop("openrc")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manager", choices=("openrc", "systemd"), default="openrc")
    parser.add_argument("--scenario", choices=("all", "recovery"), default="all")
    args = parser.parse_args()
    environment_guard()
    if args.manager == "systemd":
        print("SKIP: systemd service transactions are not implemented in this rootless test root; no platform pass is claimed.")
        return 77
    openrc_preflight()
    suite = ServiceIntegration()
    report = {"manager": "openrc", "target": TARGET_VERSION, "passed": False, "scenarios": suite.results}
    started = time.monotonic()
    try:
        suite.execute(args.scenario)
        report["baseline_version"] = suite.old_version
        report["passed"] = True
        if args.scenario == "all":
            print("PASS: isolated real OpenRC adoption, upgrade, rollback, four service states and failure recovery")
        else:
            print("PASS: isolated real OpenRC automatic failure recovery")
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - started, 2)
        REPORT.write_text(json.dumps(report, indent=2) + "\n")
        print("REPORT: " + json.dumps(report, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("FAIL: isolated service transaction: " + type(error).__name__ + ": " + str(error), file=sys.stderr)
        raise SystemExit(1)
