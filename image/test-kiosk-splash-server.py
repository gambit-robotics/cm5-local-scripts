#!/usr/bin/env python3
"""Tests the setup hotspot the kiosk splash tells a cook to join."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "gambit-kiosk-splash-server")
loader = importlib.machinery.SourceFileLoader("splash_server", SERVER)
server = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(server)

HOTSPOT_UP = "3: wlan0    inet 10.42.0.1/24 brd 10.42.0.255 scope global noprefixroute wlan0\n"


class SetupNetworkTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.defaults = os.path.join(tmp.name, "viam-defaults.json")
        self.cache = os.path.join(tmp.name, "config_cache.json")
        for name, path in (("VIAM_DEFAULTS", self.defaults), ("AGENT_CONFIG_CACHE", self.cache)):
            patcher = mock.patch.object(server, name, path)
            patcher.start()
            self.addCleanup(patcher.stop)

    def write(self, path: str, conf: dict) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"network_configuration": conf}, f)

    def test_a_new_device_names_the_images_hotspot(self) -> None:
        self.write(self.defaults, {"hotspot_prefix": "gambit-setup", "hotspot_password": "gambitsetup"})
        self.assertEqual(
            server.setup_network("User-Research-12"),
            {"ssid": "gambit-setup-user-research-12", "password": "gambitsetup", "address": "10.42.0.1"},
        )

    def test_the_config_the_agent_cached_wins(self) -> None:
        self.write(self.defaults, {"hotspot_prefix": "gambit-setup", "hotspot_password": "gambitsetup"})
        self.write(self.cache, {"hotspot_ssid": "kitchen-setup", "hotspot_password": "from-the-cloud"})
        network = server.setup_network("ur-12")
        self.assertEqual((network["ssid"], network["password"]), ("kitchen-setup", "from-the-cloud"))

    def test_without_config_it_names_the_agents_defaults(self) -> None:
        network = server.setup_network("ur-12")
        self.assertEqual((network["ssid"], network["password"]), ("viam-setup-ur-12", "viamsetup"))

    def test_the_name_fits_in_a_wifi_name(self) -> None:
        self.assertEqual(len(server.setup_network("a-very-long-kitchen-device-hostname")["ssid"]), 32)

    def test_the_splash_shows_the_steps_only_while_the_hotspot_is_up(self) -> None:
        self.write(self.defaults, {"hotspot_prefix": "gambit-setup", "hotspot_password": "gambitsetup"})
        unreachable = "http://127.0.0.1:9/"
        with mock.patch.object(server.os.path, "exists", return_value=False):
            with mock.patch.object(server, "command_output", return_value=HOTSPOT_UP):
                self.assertEqual(server.provisioning_state(unreachable)["setup"]["password"], "gambitsetup")
            with mock.patch.object(server, "command_output", return_value=""):
                self.assertNotIn("setup", server.provisioning_state(unreachable))


class SetupQRTest(unittest.TestCase):
    def serial(self, content: bytes) -> str:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "serial-number")
        with open(path, "wb") as f:
            f.write(content)
        patcher = mock.patch.object(server, "CPU_SERIAL", path)
        patcher.start()
        self.addCleanup(patcher.stop)
        return path

    def test_the_code_names_the_box_by_its_setup_id(self) -> None:
        # UR-12's serial; sha256 of it starts 6c22e875, as gambit-setup-name has it.
        self.serial(b"1F5762CBE17D0CA4\0")
        drawn = mock.Mock(stdout=b"<svg/>")
        with mock.patch.object(server.subprocess, "run", return_value=drawn) as run:
            self.assertEqual(server.setup_qr(), b"<svg/>")
        self.assertEqual(
            run.call_args.args[0][-1],
            "https://gambit-setup.chef-workspace.workers.dev/setup?device=6c22e875",
        )

    def test_without_a_serial_there_is_no_code(self) -> None:
        os.remove(self.serial(b""))
        with mock.patch.object(server.subprocess, "run") as run:
            self.assertEqual(server.setup_qr(), b"")
        run.assert_not_called()


class SetupQRFlagTest(unittest.TestCase):
    """The code shows only when the machine's config says so: core's
    attributes "setup": {"show_qr_code": true}, which gambit-setup-options
    copies out of viam-server's cached config at boot."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        os.makedirs(os.path.join(self.root, "root/.viam"))
        self.options = os.path.join(self.root, "run/gambit/setup.json")
        for name, value in (("SETUP_OPTIONS", self.options), ("hotspot_up", lambda: True), ("setup_qr", lambda: b"<svg/>")):
            patcher = mock.patch.object(server, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def cache(self, part: str, setup: object, age: int = 0) -> None:
        """viam-server's cached config for a part; core's setup block is left
        out when setup is None. Older by age seconds."""
        core = {"name": "core", "api": "rdk:component:sensor", "model": "gambit-robotics:chef:core",
                "attributes": {"mode": "boilover"}}
        if setup is not None:
            core["attributes"]["setup"] = setup
        config = {
            "cloud": {"id": part, "secret": "part-secret", "tls_private_key": "key"},
            "components": [{"name": "overhead-rgb", "attributes": {"setup": {"show_qr_code": True}}}, core],
        }
        path = os.path.join(self.root, f"root/.viam/cached_cloud_config_{part}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(config, f)
        os.utime(path, (1_800_000_000 - age, 1_800_000_000 - age))

    def boot(self) -> dict:
        """What gambit-setup-options leaves at boot."""
        subprocess.run(
            [os.path.join(HERE, "gambit-setup-options")],
            check=True,
            env={**os.environ, "GAMBIT_ROOT": self.root},
        )
        self.assertEqual(os.stat(self.options).st_mode & 0o777, 0o644)
        with open(self.options, encoding="utf-8") as f:
            return json.load(f)

    def served(self) -> int:
        httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{httpd.server_address[1]}/setup-qr.svg"
            with urllib.request.urlopen(url, timeout=2) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code
        finally:
            httpd.shutdown()
            httpd.server_close()

    def assert_qr(self, on: bool) -> None:
        self.assertEqual(server.with_setup({}).get("qr", False), on)
        self.assertEqual(self.served(), 200 if on else 404)

    def test_a_box_never_set_up_has_no_cache_and_no_code(self) -> None:
        self.assertEqual(self.boot(), {})
        self.assert_qr(False)

    def test_without_the_key_there_is_no_code(self) -> None:
        self.cache("a", None)
        self.assertEqual(self.boot(), {})
        self.assert_qr(False)
        self.cache("a", {})
        self.assertEqual(self.boot(), {})
        self.assert_qr(False)

    def test_the_config_turns_the_code_on(self) -> None:
        self.cache("a", {"show_qr_code": True})
        self.assertEqual(self.boot(), {"show_qr_code": True})
        self.assert_qr(True)

    def test_false_keeps_it_off(self) -> None:
        self.cache("a", {"show_qr_code": False})
        self.assertEqual(self.boot(), {"show_qr_code": False})
        self.assert_qr(False)

    def test_the_newest_cached_config_wins(self) -> None:
        self.cache("old", {"show_qr_code": True}, age=3600)
        self.cache("new", {"show_qr_code": False})
        self.assertEqual(self.boot(), {"show_qr_code": False})
        self.cache("old", {"show_qr_code": True})  # now the newest
        self.cache("new", {"show_qr_code": False}, age=3600)
        self.assertEqual(self.boot(), {"show_qr_code": True})

    def test_nothing_else_leaves_the_cache(self) -> None:
        self.cache("a", {"show_qr_code": True})
        self.boot()
        with open(self.options, encoding="utf-8") as f:
            copied = f.read()
        for secret in ("part-secret", "key", "boilover", "overhead-rgb"):
            self.assertNotIn(secret, copied)


if __name__ == "__main__":
    unittest.main()
