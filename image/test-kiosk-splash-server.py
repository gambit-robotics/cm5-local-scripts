#!/usr/bin/env python3
"""Tests the setup hotspot the kiosk splash tells a cook to join."""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gambit-kiosk-splash-server")
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


if __name__ == "__main__":
    unittest.main()
