"""Engine state/transaction tests. All files are temporary and all host actions mocked."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sbm_engine", ROOT / "src" / "engine.py")
engine = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = engine
spec.loader.exec_module(engine)


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sbm-unit-")
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name).resolve()
        self.paths = engine.Paths(self.root / "engines", self.root / "state", self.root / "config.json",
                                  self.root / "params", self.root / "sing-box", self.root / "50-sbm.conf")
        self.paths.engines.mkdir()
        self.paths.state.mkdir(mode=0o700)
        self.paths.config.write_text('{"inbounds":[],"outbounds":[{"type":"direct"}]}')
        self.paths.params.write_text('REALITY_PORT="24443"\nREALITY_SNI="example.com"\nUUID="SECRET_UUID"\n')
        self.paths.dropin.write_text("original service data\n")
        self.binary = self.root / "original"
        self.binary.write_bytes(b"old-binary")
        self.target = self.root / "target"
        self.target.write_bytes(b"new-binary")
        self.contract = engine.Contract("systemd", self.binary, ["run", "-c", str(self.paths.config)],
                                        self.root, [self.paths.config], [self.paths.dropin],
                                        running=False, enabled=False)
        self.contract.directories = []
        self.contract.config_snapshot()
        self.trust = mock.patch.object(engine, "trusted", side_effect=lambda p: pathlib.Path(p))
        self.trust.start()
        self.addCleanup(self.trust.stop)

    def record(self, version="1.0.0", binary=None, evidence="runtime"):
        return engine.EngineStore(self.paths).save_binary(binary or self.binary, version, "release", evidence,
                                                          self.contract.config_hash)

    def test_manifest_never_evaluates_shell_and_bad_state_never_falls_back(self):
        self.paths.manifest.write_text('{"schema":2}')
        with self.assertRaises(engine.EngineError):
            engine.EngineStore(self.paths).resolve()
        self.assertTrue(self.paths.manifest.exists())

    def test_resolver_verifies_hash_link_and_record(self):
        store = engine.EngineStore(self.paths)
        old = self.record()
        engine.atomic_json(self.paths.manifest, dict(schema=1, current=old, previous=None, contract="", updated=0))
        store.switch(old)
        self.assertEqual(store.resolve(), pathlib.Path(old["path"]))
        pathlib.Path(old["path"]).write_bytes(b"tampered")
        with self.assertRaises(engine.EngineError):
            store.resolve()

    def test_pending_prevents_resolve(self):
        self.paths.pending.write_text("{}")
        with self.assertRaises(engine.EngineError):
            engine.EngineStore(self.paths).resolve()

    def test_config_directory_membership_is_hashed(self):
        directory = self.root / "conf.d"
        directory.mkdir()
        self.contract.directories = [directory]
        before = engine.contract_guard(self.contract)
        (directory / "new.json").write_text("{}")
        self.assertNotEqual(before, engine.contract_guard(self.contract))

    def test_configuration_rejects_side_effectful_and_malformed_inputs(self):
        for config in ({"inbounds": [None]}, {"inbounds": [{"type": "socks", "listen_port": 1, "tls": []}]},
                       {"experimental": {"cache_file": {"enabled": True}}}, {"log": {"output": "/tmp/log"}},
                       {"route": {"rule_set": [{}]}}, {"outbounds": [{"type": "http"}]}):
            self.paths.config.write_text(json.dumps(config))
            with self.subTest(config=config), self.assertRaises(engine.EngineError):
                self.contract.config_snapshot()

    def test_args_accept_official_flag_order_and_reject_shell(self):
        argv, files, _, _ = engine.startup_args(["-D", str(self.root), "-c", str(self.paths.config), "run"])
        self.assertEqual(argv[-1], "run")
        self.assertEqual(files, [self.paths.config])
        for args in (["run", "--unknown", "true"], ["run", "-c", "$(touch /tmp/pwned)"], ["run", "-c", "relative"]):
            with self.subTest(args=args), self.assertRaises(engine.EngineError):
                engine.startup_args(args)
        self.assertEqual(engine.safe_path("/"), pathlib.Path("/"))

    def test_parameter_reader_never_expands_code(self):
        marker = self.root / "injection"
        self.paths.params.write_text('UUID="$(touch ' + str(marker) + ')"\nARGO_TOKEN="SECRET_TOKEN"\n')
        values = engine.params_read(self.paths.params)
        self.assertIn("$(touch", values["UUID"])
        self.assertFalse(marker.exists())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "POSIX special files")
    def test_config_readers_reject_fifo_and_symlink_without_opening(self):
        fifo = self.root / "blocking-file"
        os.mkfifo(fifo)
        with self.assertRaises(engine.EngineError):
            engine.load_json(fifo)
        link = self.root / "config-link"
        link.symlink_to(self.paths.config)
        with self.assertRaises(engine.EngineError):
            engine.load_json(link)

    def test_candidate_archive_checks_digest_and_rejects_symlinks(self):
        archive = self.root / "package.tar.gz"
        with tarfile.open(archive, "w:gz") as handle:
            item = tarfile.TarInfo("sing-box-1.1.0-linux-amd64-musl/sing-box")
            item.type = tarfile.SYMTYPE
            item.linkname = "/tmp/outside"
            handle.addfile(item)
        asset = dict(name="sing-box-1.1.0-linux-amd64-musl.tar.gz", sha256=engine.digest(archive))
        with self.assertRaises(engine.EngineError):
            engine.unpack_candidate(archive, self.root / "candidate", asset, "amd64")
        asset["sha256"] = "0" * 64
        with self.assertRaises(engine.EngineError):
            engine.unpack_candidate(archive, self.root / "candidate", asset, "amd64")
        self.assertFalse((self.root / "candidate").exists())

    def test_release_missing_digest_and_checksum_refuses(self):
        release = dict(tag_name="v1.2.3", draft=False, prerelease=False, assets=[dict(
            name="sing-box-1.2.3-linux-amd64-musl.tar.gz", state="uploaded", size=100,
            browser_download_url="https://github.com/SagerNet/sing-box/releases/download/v1.2.3/sing-box-1.2.3-linux-amd64-musl.tar.gz")])
        with mock.patch.object(engine, "fetch", return_value=json.dumps(release).encode()):
            with self.assertRaises(engine.EngineError):
                engine.release_asset("1.2.3", "amd64")

    def test_restore_first_adoption_restores_absence_and_entry_bytes(self):
        host = mock.Mock()
        host.enabled.return_value = False
        host.active.return_value = False
        updater = engine.Upgrade(self.paths, host)
        old = self.record(evidence="static")
        saved = updater.snapshot(self.contract, old, None)
        saved["entry"]["uid"] = 0
        saved["target"] = self.record("1.1.0", self.target)
        engine.atomic_json(self.paths.pending, saved)
        engine.EngineStore(self.paths).switch(saved["target"])
        self.paths.dropin.write_bytes(updater.entry_data(self.contract))
        with mock.patch.object(updater, "check"), mock.patch.object(engine.os, "chown"), \
             mock.patch.object(engine, "read_contract", return_value=self.contract):
            updater.restore()
        self.assertEqual(self.paths.dropin.read_text(), "original service data\n")
        self.assertFalse(self.paths.manifest.exists())
        self.assertFalse(self.paths.pending.exists())
        self.assertFalse(os.path.lexists(self.paths.current))
        host.restart.assert_not_called()

    def test_restore_accepts_root_working_directory(self):
        host = mock.Mock()
        host.enabled.return_value = False
        host.active.return_value = False
        updater = engine.Upgrade(self.paths, host)
        self.contract.workdir = pathlib.Path("/")
        saved = updater.snapshot(self.contract, self.record(evidence="static"), None)
        saved["entry"]["uid"] = 0
        engine.atomic_json(self.paths.pending, saved)
        with mock.patch.object(updater, "check"), mock.patch.object(engine.os, "chown"), \
             mock.patch.object(engine, "read_contract", return_value=self.contract):
            updater.restore()
        self.assertFalse(self.paths.pending.exists())
        host.restart.assert_not_called()

    def test_restore_refuses_external_config_change_preserving_materials(self):
        host = mock.Mock()
        updater = engine.Upgrade(self.paths, host)
        saved = updater.snapshot(self.contract, self.record(), None)
        engine.atomic_json(self.paths.pending, saved)
        self.paths.config.write_text('{"inbounds":[],"log":{"level":"debug"}}')
        with self.assertRaises(engine.EngineError):
            updater.restore()
        self.assertTrue(self.paths.pending.exists())
        host.restart.assert_not_called()

    def test_stopped_unverified_core_cannot_upgrade_twice(self):
        record = self.record(evidence="static")
        store = engine.EngineStore(self.paths)
        store.switch(record)
        self.contract.binary = self.paths.current
        engine.atomic_json(self.paths.manifest, dict(schema=1, current=record, previous=None, contract="", updated=0))
        host = mock.Mock()
        with mock.patch.object(engine, "read_contract", return_value=self.contract):
            with self.assertRaisesRegex(engine.EngineError, "运行未验证"):
                engine.Upgrade(self.paths, host).execute("1.1.0")
        host.restart.assert_not_called()

    def test_doctor_hides_credentials_and_never_mutates(self):
        before = {path: path.read_bytes() for path in (self.paths.params, self.paths.config, self.paths.dropin)}
        host = mock.Mock()
        report = io.StringIO()
        with mock.patch.object(engine, "read_contract", side_effect=engine.EngineError("SECRET_TOKEN", 2)), mock.patch.object(engine.shutil, "which", return_value=None), contextlib.redirect_stdout(report):
            code = engine.Doctor(self.paths, host).run()
        self.assertEqual(code, 2)
        self.assertNotIn("SECRET_UUID", report.getvalue())
        self.assertNotIn("SECRET_TOKEN", report.getvalue())
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        host.restart.assert_not_called()
        host.run.assert_not_called()

    def test_io_budget_applies_to_hashes(self):
        with mock.patch.object(engine, "IO_DEADLINE", 0):
            with self.assertRaises(engine.EngineError):
                engine.digest(self.binary)

    def test_version_query_never_executes_unknown_script(self):
        self.binary.write_text('#!/bin/sh\nexit 0\n')
        self.binary.chmod(0o755)
        host = mock.Mock()
        with self.assertRaisesRegex(engine.EngineError, "未知的核心脚本"):
            engine.binary_version(host, self.binary)
        host.run.assert_not_called()

    def test_successful_stopped_update_and_rollback_preserve_configuration(self):
        host = mock.Mock()
        host.enabled.return_value = False
        host.active.return_value = False
        current = self.contract
        def read_contract(paths, unused_host):
            current.binary = paths.current if paths.current.is_symlink() else self.binary
            current.config_snapshot()
            return current
        updater = engine.Upgrade(self.paths, host)
        before_config = self.paths.config.read_bytes()
        before_params = self.paths.params.read_bytes()
        asset = dict(version="1.1.0", url="local-test-asset", size=10)
        def unpack(archive, destination, asset, arch):
            destination.write_bytes(self.target.read_bytes())
        def version(unused_host, binary):
            return "1.1.0" if pathlib.Path(binary).read_bytes() == self.target.read_bytes() else "1.0.0"
        with mock.patch.object(engine, "read_contract", side_effect=read_contract), \
             mock.patch.object(engine, "installation_source", return_value="deb"), \
             mock.patch.object(engine, "binary_version", side_effect=version), \
             mock.patch.object(engine, "release_asset", return_value=asset), \
             mock.patch.object(engine, "fetch", return_value=10), \
             mock.patch.object(engine, "unpack_candidate", side_effect=unpack), \
             mock.patch.object(updater, "prepare_storage"), mock.patch.object(updater, "check"), \
             mock.patch.object(engine.os, "uname", return_value=mock.Mock(machine="x86_64")):
            updater.execute("1.1.0")
            state = engine.EngineStore(self.paths).read()
            self.assertEqual(state["current"]["version"], "1.1.0")
            self.assertEqual(state["current"]["evidence"], "static")
            with self.assertRaisesRegex(engine.EngineError, "运行未验证"):
                updater.execute("1.2.0")
            updater.execute(rollback=True)
            self.assertEqual(engine.EngineStore(self.paths).read()["current"]["version"], "1.0.0")
        self.assertEqual(before_config, self.paths.config.read_bytes())
        self.assertEqual(before_params, self.paths.params.read_bytes())
        self.assertFalse(self.paths.pending.exists())
        host.restart.assert_not_called()

    def test_wrong_mode_saved_binary_is_rejected(self):
        record = self.record()
        path = pathlib.Path(record["path"])
        path.chmod(0o600)
        with self.assertRaisesRegex(engine.EngineError, "执行权限异常"):
            engine.EngineStore(self.paths).record_path(record)

    def test_uninstall_preflight_keeps_entries_when_history_is_unknown(self):
        store = engine.EngineStore(self.paths)
        record = self.record()
        store.switch(record)
        engine.atomic_json(self.paths.manifest, dict(schema=1,current=record,previous=None,contract="",updated=0))
        self.contract.binary = self.paths.current
        extra = pathlib.Path(record["path"]).parent / "administrator-file"
        extra.write_text("must be preserved")
        original_entry = self.paths.dropin.read_bytes()
        host = mock.Mock()
        host.active.return_value = False
        with mock.patch.object(engine,"read_contract",return_value=self.contract):
            with self.assertRaisesRegex(engine.EngineError,"未知文件"):
                engine.Upgrade(self.paths,host).remove_managed()
        self.assertTrue(self.paths.current.is_symlink())
        self.assertTrue(self.paths.manifest.exists())
        self.assertEqual(original_entry,self.paths.dropin.read_bytes())

    def test_pending_rejects_unknown_fields_before_execution(self):
        updater = engine.Upgrade(self.paths, mock.Mock())
        saved = updater.snapshot(self.contract, self.record(), None)
        saved["injected"] = "shell command"
        engine.atomic_json(self.paths.pending, saved)
        with mock.patch.object(updater, "check") as check:
            with self.assertRaises(engine.EngineError):
                updater.restore()
            check.assert_not_called()
        self.assertTrue(self.paths.pending.exists())

    def test_original_package_change_blocks_first_restore(self):
        updater = engine.Upgrade(self.paths, mock.Mock())
        saved = updater.snapshot(self.contract, self.record(), None)
        saved["entry"]["uid"] = 0
        engine.atomic_json(self.paths.pending, saved)
        self.binary.write_bytes(b"externally changed package")
        with self.assertRaisesRegex(engine.EngineError, "原软件包核心被外部修改"):
            updater.restore()
        self.assertTrue(self.paths.pending.exists())

    def test_execute_failure_after_entry_switch_restores_first_adoption(self):
        host = mock.Mock()
        host.enabled.return_value = False
        host.active.return_value = False
        updater = engine.Upgrade(self.paths, host)
        original_entry = self.paths.dropin.read_bytes()
        original_snapshot = updater.snapshot
        def snapshot(*args):
            saved = original_snapshot(*args)
            saved["entry"]["uid"] = 0
            return saved
        with mock.patch.object(engine, "read_contract", side_effect=[self.contract, engine.EngineError("injected failure"), self.contract]), \
             mock.patch.object(engine, "installation_source", return_value="deb"), \
             mock.patch.object(engine, "binary_version", side_effect=["1.0.0", "1.1.0"]), \
             mock.patch.object(engine, "release_asset", return_value=dict(version="1.1.0",url="test",size=1)), \
             mock.patch.object(engine, "fetch", return_value=1), \
             mock.patch.object(engine, "unpack_candidate", side_effect=lambda a,p,m,r:p.write_bytes(b"candidate")), \
             mock.patch.object(updater, "prepare_storage"), mock.patch.object(updater, "check"), \
             mock.patch.object(updater, "snapshot", side_effect=snapshot), mock.patch.object(engine.os, "chown"), \
             mock.patch.object(engine.os, "uname", return_value=mock.Mock(machine="x86_64")):
            with self.assertRaisesRegex(engine.EngineError,"injected failure"):
                updater.execute("1.1.0")
        self.assertEqual(self.paths.dropin.read_bytes(), original_entry)
        self.assertFalse(self.paths.manifest.exists())
        self.assertFalse(self.paths.pending.exists())
        self.assertFalse(os.path.lexists(self.paths.current))
        host.restart.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "Linux merged-/usr service paths")
    def test_merged_usr_service_path_is_normalized(self):
        legacy = pathlib.Path("/lib/systemd/system")
        if not pathlib.Path("/lib").is_symlink() or not legacy.is_dir():
            self.skipTest("system does not use the standard merged-/usr alias")
        service = next((p for p in legacy.glob("*.service") if not p.is_symlink()), None)
        if service is None:
            self.skipTest("no systemd unit is present")
        self.assertEqual(engine.trusted_system_file(service), service.resolve())

    def test_pending_restore_refuses_new_unloaded_systemd_dropin(self):
        systemd = self.root / "units"
        directory = systemd / "sing-box.service.d"
        directory.mkdir(parents=True)
        host = mock.Mock()
        updater = engine.Upgrade(self.paths, host)
        with mock.patch.object(engine, "SYSTEMD_UNIT_PATHS", (systemd,)):
            saved = updater.snapshot(self.contract, self.record(), None)
            saved["entry"]["uid"] = 0
            engine.atomic_json(self.paths.pending, saved)
            (directory / "80-admin.conf").write_text("[Service]\nExecStart=/other/core\n")
            with self.assertRaisesRegex(engine.EngineError, "服务文件已变化"):
                updater.restore()
        self.assertTrue(self.paths.pending.exists())
        host.restart.assert_not_called()

    def test_publish_script_contains_embedded_engine_exactly(self):
        installer = ROOT / "install.sh"
        if not installer.exists():
            self.skipTest("build installer first")
        content = installer.read_text(encoding="utf-8")
        if (ROOT / "src" / "engine.py").read_text(encoding="utf-8") not in content:
            self.fail("generated installer does not contain the current engine source")

    @unittest.skipUnless(os.name == "posix", "Bash CLI runs on Linux")
    def test_real_doctor_entry_is_readonly_with_hostile_path(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        replacements = {"CONFIG_DIR": str(self.root), "SBM_STATE_DIR": str(self.paths.state),
                        "SBM_ENGINE_ROOT": str(self.paths.engines), "SBM_ENGINE_DROPIN": str(self.paths.dropin),
                        "PARAMS_FILE": str(self.paths.params), "CONFIG_FILE": str(self.paths.config),
                        "SINGBOX_OPENRC_SERVICE": str(self.paths.openrc)}
        import re
        for key, value in replacements.items():
            source, count = re.subn(r'^' + key + r'="[^"\n]*"$', key + '="' + value + '"', source, count=1, flags=re.M)
            self.assertEqual(count, 1)
        script = self.root / "installer.sh"
        script.write_text(source)
        bindir = self.root / "bin"
        bindir.mkdir()
        marker = self.root / "unexpected-write"
        malicious = bindir / "sing-box"
        malicious.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n')
        malicious.chmod(0o755)
        # No service mutation command is needed or permitted in this fixture.
        for name in ("systemctl", "rc-service", "curl", "wget"):
            tool = bindir / name
            tool.write_text('#!/bin/sh\nexit 1\n')
            tool.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"])
        env.pop("SBM_TEST_MODE", None)
        before = {p: (p.read_bytes(), p.stat().st_mode) for p in (self.paths.params, self.paths.config)}
        for shell in ("bash", "sh"):
            result = subprocess.run([shell, str(script), "doctor"], env=env, capture_output=True, text=True, timeout=20)
            self.assertIn(result.returncode, (1, 2))
            self.assertNotIn("SECRET_UUID", result.stdout + result.stderr)
            self.assertNotIn("Traceback", result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual(before, {p: (p.read_bytes(), p.stat().st_mode) for p in before})

    def test_transaction_keeps_all_four_service_states(self):
        for running, enabled in ((False, False), (False, True), (True, False), (True, True)):
            with self.subTest(running=running, enabled=enabled):
                self.paths.manifest.unlink(missing_ok=True)
                self.paths.pending.unlink(missing_ok=True)
                if self.paths.current.is_symlink():
                    self.paths.current.unlink()
                self.paths.dropin.write_text("original service data\n")
                host = mock.Mock()
                host.enabled.return_value = enabled
                host.active.return_value = running
                self.contract.running = running
                self.contract.enabled = enabled
                def contract(paths, unused):
                    self.contract.binary = paths.current if paths.current.is_symlink() else self.binary
                    return self.contract
                updater = engine.Upgrade(self.paths, host)
                with mock.patch.object(engine, "read_contract", side_effect=contract), \
                     mock.patch.object(engine, "installation_source", return_value="deb"), \
                     mock.patch.object(engine, "binary_version", side_effect=["1.0.0", "1.1.0"]), \
                     mock.patch.object(engine, "release_asset", return_value=dict(version="1.1.0",url="test",size=1)), \
                     mock.patch.object(engine, "fetch", return_value=1), \
                     mock.patch.object(engine, "unpack_candidate", side_effect=lambda a,p,m,r:p.write_bytes(b"four-state-candidate")), \
                     mock.patch.object(updater, "prepare_storage"), mock.patch.object(updater, "check"), \
                     mock.patch.object(engine, "runtime_health"), \
                     mock.patch.object(engine.os, "uname", return_value=mock.Mock(machine="x86_64")):
                    updater.execute("1.1.0")
                self.assertEqual(host.restart.call_count, int(running))
                self.assertEqual(engine.EngineStore(self.paths).read()["current"]["evidence"], "runtime" if running else "static")
                host.stop.assert_not_called()


if __name__ == "__main__":
    unittest.main()
