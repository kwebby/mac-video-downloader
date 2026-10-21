#!/usr/bin/env python3
"""Offline installer failure-path tests. No real install, mount, or network call.

Only the test copy redirects macOS/network commands to fixtures. The actual
system shasum checks fixture bytes, so checksum failures are not mocked away.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "Scripts/install.sh"
PAYLOAD = b"MVD signed disk image fixture\n"
TOOLS = {
    "/usr/bin/uname": "uname",
    "/usr/bin/sw_vers": "sw_vers",
    "/usr/bin/pgrep": "pgrep",
    "/usr/bin/curl": "curl",
    "/usr/bin/plutil": "plutil",
    "/usr/bin/codesign": "codesign",
    "/usr/sbin/spctl": "spctl",
    "/usr/bin/hdiutil": "hdiutil",
    "/usr/bin/ditto": "ditto",
    "/usr/bin/xcode-select": "xcode-select",
    "/usr/bin/stat": "stat",
    "/bin/mv": "mv",
}

MOCK = r'''
import hashlib, json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["MVD_TEST_ROOT"])
log = root / "commands.jsonl"
with log.open("a") as stream:
    stream.write(json.dumps({"tool": name, "args": args}) + "\n")
def setting(name, default=""):
    return os.environ.get("MVD_TEST_" + name, default)
def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)
if name == "uname":
    print(setting("OS", "Darwin") if args == ["-s"] else setting("ARCH", "arm64"))
elif name == "sw_vers":
    print(setting("MACOS", "14.7"))
elif name == "pgrep":
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    count = sum(call["tool"] == "pgrep" and call["args"][-1] == "MVD" for call in calls)
    active = setting("RUNNING") == args[-1] or (setting("RUNNING_LATE") and args[-1] == "MVD" and count >= 2)
    raise SystemExit(0 if active else 1)
elif name == "curl":
    assert "--proto" in args and args[args.index("--proto") + 1] == "=https"
    assert "--proto-redir" in args and args[args.index("--proto-redir") + 1] == "=https"
    url = args[-1]
    assert url.startswith("https://github.com/kwebby/mac-video-downloader/releases/download/") or url == "https://api.github.com/repos/kwebby/mac-video-downloader/releases/latest"
    output = pathlib.Path(args[args.index("--output") + 1])
    if setting("NETWORK_FAIL"):
        fail("mock network failure")
    if url.endswith("/releases/latest"):
        output.write_text(json.dumps({"tag_name": setting("LATEST", "v0.4.4")}))
    elif url.endswith("SHA256SUMS.txt"):
        version = url.split("/download/v", 1)[1].split("/", 1)[0]
        asset = "MVD-" + version + "-arm64.dmg"
        checksum = hashlib.sha256(b"MVD signed disk image fixture\n").hexdigest()
        if setting("BAD_CHECKSUM"):
            checksum = "0" * 64
        lines = checksum + "  " + asset + "\n"
        if setting("MANIFEST") == "duplicate":
            lines += lines
        if setting("MANIFEST") == "missing":
            lines = checksum + "  some-other-file.dmg\n"
        if setting("MANIFEST") == "unsafe-extra":
            lines += "0" * 64 + "  ../../outside-secret\n"
        output.write_text(lines)
    else:
        output.write_bytes(b"MVD signed disk image fixture\n")
elif name == "plutil":
    key = args[args.index("-extract") + 1]
    data = pathlib.Path(args[-1]).read_bytes()
    value = json.loads(data) if args[-1].endswith(".json") else plistlib.loads(data)
    if key not in value:
        raise SystemExit(1)
    print(value[key])
elif name == "codesign":
    path = pathlib.Path(args[-1])
    if "--verify" in args:
        requirement = next(arg for arg in args if arg.startswith("--test-requirement="))
        assert "anchor apple generic" in requirement and "SG77J9KKYK" in requirement
        assert "--strict" in args and "--deep" in args
        if path.suffix == ".app":
            assert 'identifier "io.harbor.downloads.dev"' in requirement
        bad = setting("BAD_SIGNATURE")
        if bad == "all" or (bad == "app" and path.suffix == ".app") or (bad == "staged" and "/.mvd-install." in str(path)):
            fail("mock signature rejection")
    else:
        team = "WRONGTEAM" if setting("BAD_TEAM") else "SG77J9KKYK"
        print("Authority=Developer ID Application: Raman Singh (" + team + ")\nTeamIdentifier=" + team, file=sys.stderr)
elif name == "spctl":
    assert "--assess" in args
    if setting("GATEKEEPER_FAIL"):
        fail("mock Gatekeeper rejection")
    source = "Developer ID" if setting("NOT_NOTARIZED") else "Notarized Developer ID"
    print("accepted\nsource=" + source, file=sys.stderr)
elif name == "hdiutil":
    if args[0] == "attach":
        assert "-readonly" in args and "-nobrowse" in args and "-noautoopen" in args
        if setting("MOUNT_FAIL"):
            fail("mock mount failure")
        mount = pathlib.Path(args[args.index("-mountpoint") + 1])
        app = mount / "MVD.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/MVD").write_text("new app")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.harbor.downloads.dev", "CFBundleShortVersionString": setting("APP_VERSION", "0.4.4")}))
        (app / "version-marker").write_text("new app")
    else:
        assert args[0] == "detach"
        if setting("DETACH_FAIL"):
            fail("mock detach failure")
        if setting("DEST_RACE"):
            target = pathlib.Path(os.environ["MVD_TEST_DEST"]) / "MVD.app"
            target.mkdir(exist_ok=True)
            (target / "version-marker").write_text("another app appeared")
elif name == "ditto":
    source, target = map(pathlib.Path, args)
    if setting("COPY_FAIL"):
        target.mkdir()
        (target / "partial").write_text("incomplete copy")
        fail("mock copy failure")
    shutil.copytree(source, target, symlinks=True)
elif name == "xcode-select":
    if not setting("CLT"):
        raise SystemExit(1)
    print(root / "DeveloperTools")
elif name == "stapler":
    assert args[0] == "validate"
    if setting("BAD_STAPLE"):
        fail("mock invalid staple")
elif name == "stat":
    assert args[:2] == ["-f", "%d:%i"]
    value = pathlib.Path(args[-1]).stat()
    print(str(value.st_dev) + ":" + str(value.st_ino))
elif name == "mv":
    source, target = map(pathlib.Path, args)
    if setting("COMMIT_FAIL") and source.name == "MVD.app" and source.parent.name.startswith(".mvd-install."):
        fail("mock final move failure")
    shutil.move(str(source), str(target))
else:
    fail("unexpected mock command: " + name)
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mvd-installer-test-")
        self.root = Path(self.temporary.name)
        self.destination = self.root / "Applications with spaces"
        self.destination.mkdir()
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        mock = self.bin / "mock-command"
        mock.write_text(f"#!{sys.executable}\n" + textwrap.dedent(MOCK))
        mock.chmod(0o755)
        script = INSTALLER.read_text()
        for original, name in TOOLS.items():
            (self.bin / name).symlink_to(mock)
            script = script.replace(original, str(self.bin / name))
        self.script = self.root / "install.sh"
        self.script.write_text(script)
        developer_tools = self.root / "DeveloperTools/usr/bin"
        developer_tools.mkdir(parents=True)
        (developer_tools / "stapler").symlink_to(mock)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("MVD_")}
        temp_root = self.root / "temporary files"
        temp_root.mkdir()
        self.environment.update(MVD_TEST_ROOT=str(self.root), MVD_TEST_DEST=str(self.destination), TMPDIR=str(temp_root))

    def tearDown(self):
        self.temporary.cleanup()

    def run_installer(self, *options, success=True, **settings):
        environment = self.environment | {"MVD_TEST_" + key: str(value) for key, value in settings.items()}
        result = subprocess.run(["/bin/bash", str(self.script), "--destination", str(self.destination), *options], env=environment, cwd=self.root, text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commands(self, tool):
        path = self.root / "commands.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call["args"] for call in calls if call["tool"] == tool]

    def old_app(self):
        app = self.destination / "MVD.app"
        app.mkdir()
        (app / "version-marker").write_text("old app")
        return app

    def assert_old_app_kept(self):
        self.assertEqual((self.destination / "MVD.app/version-marker").read_text(), "old app")
        self.assertFalse(list(self.destination.glob(".mvd-install.*")))

    def test_latest_installs_verified_app_with_stock_tools_and_no_developer_tools(self):
        self.run_installer(MANIFEST="unsafe-extra")
        self.assertEqual((self.destination / "MVD.app/version-marker").read_text(), "new app")
        self.assertEqual(len(self.commands("curl")), 3)
        self.assertEqual(len(self.commands("spctl")), 3)
        self.assertEqual(self.commands("stapler"), [])
        self.assertTrue(any(call[0] == "detach" for call in self.commands("hdiutil")))
        self.assertFalse(list(self.destination.glob(".mvd-install.*")))

    def test_version_pin_skips_latest_api(self):
        self.run_installer("--version", "0.4.4")
        self.assertEqual(len(self.commands("curl")), 2)
        self.assertTrue(all("/download/v0.4.4/" in args[-1] for args in self.commands("curl")))

    def test_relative_destination_with_spaces_stays_inside_the_selected_folder(self):
        self.run_installer("--destination", "relative target", "--version", "v0.4.4")
        self.assertEqual((self.root / "relative target/MVD.app/version-marker").read_text(), "new app")

    def test_environment_version_pin(self):
        self.environment["MVD_VERSION"] = "v0.4.4"
        self.run_installer()
        self.assertEqual(len(self.commands("curl")), 2)

    def test_checksum_mismatch_preserves_old_app_and_never_mounts(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, BAD_CHECKSUM=1)
        self.assert_old_app_kept()
        self.assertEqual(self.commands("hdiutil"), [])

    def test_missing_or_duplicate_manifest_entry_is_rejected(self):
        for manifest in ["missing", "duplicate"]:
            with self.subTest(manifest=manifest):
                self.run_installer("--version", "v0.4.4", success=False, MANIFEST=manifest)
                self.assertFalse((self.destination / "MVD.app").exists())
                self.assertEqual(self.commands("hdiutil"), [])

    def test_wrong_apple_signer_is_rejected_before_mount(self):
        self.run_installer("--version", "v0.4.4", success=False, BAD_TEAM=1)
        self.assertEqual(self.commands("hdiutil"), [])
        self.assertFalse((self.destination / "MVD.app").exists())

    def test_gatekeeper_must_confirm_notarization_even_when_exit_status_is_zero(self):
        self.run_installer("--version", "v0.4.4", success=False, NOT_NOTARIZED=1)
        self.assertEqual(self.commands("hdiutil"), [])

    def test_app_signature_failure_ejects_and_preserves_existing_app(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, BAD_SIGNATURE="app")
        self.assert_old_app_kept()
        self.assertTrue(any(call[0] == "detach" for call in self.commands("hdiutil")))

    def test_staged_copy_is_verified_before_existing_app_moves(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, BAD_SIGNATURE="staged")
        self.assert_old_app_kept()
        self.assertEqual(self.commands("mv"), [])

    def test_mismatched_release_version_is_rejected(self):
        self.run_installer("--version", "v0.4.4", success=False, APP_VERSION="0.4.3")
        self.assertEqual(self.commands("ditto"), [])
        self.assertFalse((self.destination / "MVD.app").exists())

    def test_existing_app_requires_explicit_replace_before_network(self):
        self.old_app()
        self.run_installer("--version", "v0.4.4", success=False)
        self.assert_old_app_kept()
        self.assertEqual(self.commands("curl"), [])

    def test_explicit_replacement_commits_new_app_and_removes_temporary_backup(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4")
        self.assertEqual((self.destination / "MVD.app/version-marker").read_text(), "new app")
        self.assertFalse(list(self.destination.glob(".mvd-install.*")))

    def test_running_app_or_background_service_is_never_stopped(self):
        self.old_app()
        for process in ["MVD", "HarborBroker"]:
            with self.subTest(process=process):
                self.run_installer("--replace", "--version", "v0.4.4", success=False, RUNNING=process)
                self.assert_old_app_kept()
                self.assertEqual(self.commands("curl"), [])

    def test_app_opened_while_downloading_prevents_replacement(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, RUNNING_LATE=1)
        self.assert_old_app_kept()
        self.assertEqual(self.commands("mv"), [])

    def test_copy_failure_preserves_previous_version(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, COPY_FAIL=1)
        self.assert_old_app_kept()

    def test_final_move_failure_restores_previous_version(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, COMMIT_FAIL=1)
        self.assert_old_app_kept()
        self.assertEqual(len(self.commands("mv")), 3)

    def test_destination_change_during_download_is_not_overwritten(self):
        self.run_installer("--replace", "--version", "v0.4.4", success=False, DEST_RACE=1)
        self.assertEqual((self.destination / "MVD.app/version-marker").read_text(), "another app appeared")
        self.assertEqual(self.commands("mv"), [])

    def test_download_only_saves_dmg_even_if_mvd_is_running(self):
        self.run_installer("--download-only", "--version", "v0.4.4", RUNNING="MVD")
        self.assertEqual((self.destination / "MVD-0.4.4-arm64.dmg").read_bytes(), PAYLOAD)
        self.assertFalse((self.destination / "MVD.app").exists())
        self.assertEqual(self.commands("ditto"), [])
        self.assertEqual(self.commands("pgrep"), [])

    def test_download_only_requires_explicit_replace_for_existing_dmg(self):
        target = self.destination / "MVD-0.4.4-arm64.dmg"
        target.write_bytes(b"previous download")
        self.run_installer("--download-only", "--version", "v0.4.4", success=False)
        self.assertEqual(target.read_bytes(), b"previous download")
        self.assertEqual(self.commands("curl"), [])

    def test_failed_mount_never_stages_or_replaces_the_existing_app(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, MOUNT_FAIL=1)
        self.assert_old_app_kept()
        self.assertEqual(self.commands("ditto"), [])

    def test_optional_existing_stapler_must_validate(self):
        self.run_installer("--version", "v0.4.4", success=False, CLT=1, BAD_STAPLE=1)
        self.assertEqual(len(self.commands("stapler")), 1)
        self.assertEqual(self.commands("hdiutil"), [])

    def test_detach_failure_prevents_install_and_keeps_mount_folder(self):
        self.old_app()
        self.run_installer("--replace", "--version", "v0.4.4", success=False, DETACH_FAIL=1)
        self.assert_old_app_kept()
        self.assertEqual(self.commands("mv"), [])
        self.assertTrue(list((self.root / "temporary files").glob("mvd-install.*")))

    def test_unsupported_platform_fails_before_network(self):
        for settings in [dict(OS="Linux"), dict(ARCH="x86_64"), dict(MACOS="13.6")]:
            with self.subTest(settings=settings):
                self.run_installer("--version", "v0.4.4", success=False, **settings)
                self.assertEqual(self.commands("curl"), [])

    def test_unexpected_release_tag_is_rejected_without_evaluation(self):
        self.run_installer(success=False, LATEST="v0.4.4; touch injected")
        self.assertEqual(len(self.commands("curl")), 1)
        self.assertFalse((self.root / "injected").exists())

    def test_symbolic_link_destination_is_not_replaced(self):
        original = self.root / "untouched folder"
        original.mkdir()
        (self.destination / "MVD.app").symlink_to(original)
        self.run_installer("--replace", "--version", "v0.4.4", success=False)
        self.assertTrue((self.destination / "MVD.app").is_symlink())
        self.assertTrue(original.is_dir())
        self.assertEqual(self.commands("curl"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
