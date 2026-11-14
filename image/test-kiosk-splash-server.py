#!/usr/bin/env python3
"""Tests what the kiosk splash shows before Chef is up, and the setup name it
shows: the one gambit-setup-name gives viam-agent."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
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
# UR-12's serial, as /proc/device-tree/serial-number holds it.
UR12_SERIAL = b"1F5762CBE17D0CA4\0"


class SetupNameTest(unittest.TestCase):
    """A unit's fake root with the image's viam-defaults.json."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        os.makedirs(os.path.join(self.root, "etc"))
        defaults = os.path.join(self.root, "etc", "viam-defaults.json")
        shutil.copy(os.path.join(HERE, "viam-defaults.user-testing.json"), defaults)
        patcher = mock.patch.object(server, "VIAM_DEFAULTS", defaults)
        patcher.start()
        self.addCleanup(patcher.stop)

    def boot(self, serial: bytes) -> None:
        """What gambit-setup-name does at boot, before viam-agent starts."""
        os.makedirs(os.path.join(self.root, "proc", "device-tree"))
        with open(os.path.join(self.root, "proc", "device-tree", "serial-number"), "wb") as f:
            f.write(serial)
        subprocess.run(
            [os.path.join(HERE, "gambit-setup-name")],
            check=True,
            capture_output=True,
            env={**os.environ, "GAMBIT_ROOT": self.root},
        )

    def test_the_splash_shows_the_name_gambit_setup_name_gave_the_agent(self) -> None:
        self.boot(UR12_SERIAL)
        self.assertEqual(
            server.setup_network(),
            {"ssid": "gambit-setup-6c22e875", "password": "gambitsetup", "address": "10.42.0.1"},
        )

    def test_without_a_setup_name_it_shows_none_never_the_hostname(self) -> None:
        self.boot(b"")
        self.assertEqual(server.setup_network()["ssid"], "")
        self.assertNotIn("name", server.waiting_for_setup("setup", hotspot=True))

    def test_the_qr_code_carries_the_setup_id(self) -> None:
        self.boot(UR12_SERIAL)
        drawn = mock.Mock(stdout=b"<svg/>")
        with mock.patch.object(server.subprocess, "run", return_value=drawn) as run:
            self.assertEqual(server.setup_qr(), b"<svg/>")
        self.assertEqual(
            run.call_args.args[0][-1],
            "https://gambit-setup.chef-workspace.workers.dev/setup?device=6c22e875",
        )

    def test_without_a_setup_name_there_is_no_code(self) -> None:
        with mock.patch.object(server.subprocess, "run") as run:
            self.assertEqual(server.setup_qr(), b"")
        run.assert_not_called()

    def test_the_hotspot_is_up_while_the_box_holds_its_address(self) -> None:
        with mock.patch.object(server, "command_output", return_value=HOTSPOT_UP):
            self.assertTrue(server.hotspot_up())
        with mock.patch.object(server, "command_output", return_value=""):
            self.assertFalse(server.hotspot_up())


class StateTest(unittest.TestCase):
    """What the splash shows before it hands the screen to Chef."""

    def setUp(self) -> None:
        network = {"ssid": "gambit-setup-6c22e875", "password": "gambitsetup", "address": "10.42.0.1"}
        self.box(setup_network=lambda: network, setup_qr_on=lambda: False)
        self.box(viam_agent_logs=lambda: "", package_count=lambda: 0)
        self.agent, self.credentials, self.hotspot, self.online = True, False, False, False
        self.saved, self.chef = False, False
        self.box(
            target_ready=lambda _: self.chef,
            viam_agent_active=lambda: self.agent,
            hotspot_up=lambda: self.hotspot,
            network_online=lambda: self.online,
            wifi_saved=lambda: self.saved,
        )
        patcher = mock.patch.object(server.os.path, "exists", side_effect=lambda path: self.credentials)
        patcher.start()
        self.addCleanup(patcher.stop)

    def box(self, **attrs: object) -> None:
        for name, value in attrs.items():
            patcher = mock.patch.object(server, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def state(self) -> dict:
        return server.provisioning_state("http://127.0.0.1:9/")

    def test_a_box_without_credentials_asks_to_be_set_up_by_its_setup_name(self) -> None:
        self.assertEqual(self.state(), {"ready": False, "waiting": "setup", "name": "gambit-setup-6c22e875"})

    def test_the_hotspot_shows_only_while_it_is_up(self) -> None:
        self.hotspot = True
        self.assertEqual(
            self.state()["hotspot"],
            {"ssid": "gambit-setup-6c22e875", "password": "gambitsetup", "address": "10.42.0.1"},
        )

    def test_a_box_back_in_setup_mode_with_credentials_asks_for_wifi(self) -> None:
        self.credentials = self.hotspot = True
        self.assertEqual(self.state()["waiting"], "wifi")

    def test_before_the_agent_runs_it_is_starting(self) -> None:
        self.agent = False
        self.assertEqual(self.state(), {"ready": False, "message": "Starting up..."})

    def test_after_the_app_sends_wifi_it_is_connecting_not_waiting(self) -> None:
        self.credentials = self.saved = True
        self.assertEqual(self.state(), {"ready": False, "message": "Connecting to Wi-Fi..."})

    def test_once_online_it_is_configuring(self) -> None:
        self.credentials = self.saved = self.online = True
        self.assertEqual(self.state(), {"ready": False, "message": "Configuring. This can take a few minutes."})

    def test_once_online_with_chef_up_it_hands_over(self) -> None:
        self.credentials = self.saved = self.online = self.chef = True
        self.assertEqual(self.state(), {"ready": True, "message": "Opening Gambit..."})

    # GMBT-1624: a factory reset keeps /etc/viam.json and forgets the Wi-Fi.

    def test_after_a_reset_it_asks_for_wifi_even_with_chef_up(self) -> None:
        self.credentials = self.hotspot = self.chef = True
        self.assertEqual(self.state()["waiting"], "wifi")

    def test_after_a_reset_it_asks_for_wifi_before_the_hotspot_is_up(self) -> None:
        self.credentials = self.chef = True  # Bluetooth only, the first 15-45 s
        self.assertEqual(self.state(), {"ready": False, "waiting": "wifi", "name": "gambit-setup-6c22e875"})

    def test_once_the_app_saves_wifi_it_hands_over_to_chef(self) -> None:
        self.credentials = self.saved = self.chef = True
        self.assertTrue(self.state()["ready"])

    def test_a_box_online_without_wifi_hands_over(self) -> None:
        self.credentials = self.online = self.chef = True  # on Ethernet
        self.assertTrue(self.state()["ready"])


class WifiSavedTest(unittest.TestCase):
    """Saved Wi-Fi, from NetworkManager's profiles, as the kiosk user reads them."""

    def nmcli(self, profiles: dict[str, tuple[str, str]]) -> bool:
        def run(args: list[str], timeout: float = 1.0) -> str:
            if args[:3] == ["nmcli", "-t", "-f"]:
                return "".join(f"{uuid}:{kind}\n" for uuid, (kind, _) in profiles.items())
            if args[:3] == ["nmcli", "-g", "802-11-wireless.mode"]:
                return profiles[args[-1]][1] + "\n"
            raise AssertionError(args)

        with mock.patch.object(server, "command_output", side_effect=run):
            return server.wifi_saved()

    def test_none_after_a_reset(self) -> None:
        self.assertFalse(self.nmcli({}))

    def test_the_agents_hotspot_is_not_a_saved_network(self) -> None:
        self.assertFalse(self.nmcli({"a1": ("802-11-wireless", "ap"), "e1": ("802-3-ethernet", "")}))

    def test_a_home_network_is(self) -> None:
        self.assertTrue(self.nmcli({"a1": ("802-11-wireless", "ap"), "w1": ("802-11-wireless", "infrastructure")}))


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
        network = {"ssid": "gambit-setup-6c22e875", "password": "gambitsetup", "address": "10.42.0.1"}
        for name, value in (("SETUP_OPTIONS", self.options), ("setup_network", lambda: network), ("setup_qr", lambda: b"<svg/>")):
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
        self.assertEqual(server.waiting_for_setup("setup", hotspot=True).get("qr", False), on)
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
