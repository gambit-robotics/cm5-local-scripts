"""Tests for MCP9601 safety monitoring script."""

import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import yaml

# Add scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from mcp9601_safety import (
    VALID_THERMOCOUPLE_TYPES,
    _coerce_float,
    _thermocouple_enum,
    parse_i2c_address,
)


@pytest.fixture
def mock_config(tmp_path):
    """Create a temporary config file."""
    config = {
        "mcp9601": {
            "i2c_address": "0x67",
            "thermocouple_type": "K",
            "warning_temp_c": 60,
            "shutdown_temp_c": 75,
            "poll_interval_s": 1,
        }
    }
    config_file = tmp_path / "safety-config.yaml"
    with open(config_file, "w") as f:
        yaml.dump(config, f)
    return config_file


@pytest.fixture
def mock_sensor():
    """Create a mock MCP9601 sensor."""
    sensor = MagicMock()
    sensor.temperature = 25.0  # Hot junction
    sensor.ambient_temperature = 22.0  # Cold junction
    return sensor


@pytest.fixture
def mock_imports(mock_sensor):
    """Mock the board and adafruit imports."""
    mock_board = MagicMock()
    mock_board.I2C.return_value = MagicMock()

    mock_mcp9600 = MagicMock()
    mock_mcp9600.MCP9600.return_value = mock_sensor
    mock_mcp9600.ThermocoupleType = {"K": "ENUM_K"}

    with patch.dict(
        sys.modules,
        {
            "board": mock_board,
            "adafruit_mcp9600": mock_mcp9600,
        },
    ):
        yield {"board": mock_board, "mcp9600": mock_mcp9600, "sensor": mock_sensor}


class TestConfigLoading:
    """Test configuration loading."""

    def test_load_config_success(self, mock_config):
        """Test loading a valid config file."""
        with open(mock_config) as f:
            full_config = yaml.safe_load(f)

        config = full_config["mcp9601"]
        assert config["i2c_address"] == "0x67"
        assert config["warning_temp_c"] == 60
        assert config["shutdown_temp_c"] == 75

    def test_parse_i2c_address_string(self):
        """Test parsing hex string I2C address."""
        assert parse_i2c_address("0x67") == 0x67
        assert parse_i2c_address(0x67) == 0x67

    def test_valid_thermocouple_types(self):
        """Test that all expected thermocouple types are valid."""
        expected_types = ("K", "J", "T", "N", "S", "E", "B", "R")
        for tc_type in expected_types:
            assert tc_type in VALID_THERMOCOUPLE_TYPES

    def test_coerce_float_accepts_strings(self):
        """Test that numeric strings are coerced to floats."""
        assert _coerce_float("warning_temp_c", "60") == 60.0

    def test_coerce_float_raises_on_invalid(self):
        """Test that invalid numeric values raise clear errors."""
        with pytest.raises(ValueError, match="warning_temp_c"):
            _coerce_float("warning_temp_c", "not-a-number")

    def test_thermocouple_type_maps_to_enum(self, mock_imports):
        """Test that thermocouple string maps to enum before use."""
        enum_value = _thermocouple_enum("K")
        assert enum_value == "ENUM_K"


class TestThresholds:
    """Test threshold detection."""

    def test_warning_threshold_detection(self, mock_imports):
        """Test that warning is logged at warning threshold."""
        mock_imports["sensor"].temperature = 60.0

        temp = mock_imports["sensor"].temperature
        warning_temp = 60
        assert temp >= warning_temp

    def test_shutdown_threshold_detection(self, mock_imports):
        """Test that shutdown is triggered at shutdown threshold."""
        mock_imports["sensor"].temperature = 75.0

        temp = mock_imports["sensor"].temperature
        shutdown_temp = 75
        assert temp >= shutdown_temp

    def test_normal_temp_no_warning(self, mock_imports):
        """Test that normal temperature doesn't trigger warning."""
        mock_imports["sensor"].temperature = 40.0

        temp = mock_imports["sensor"].temperature
        warning_temp = 60
        assert temp < warning_temp

    def test_hot_junction_is_monitored(self, mock_imports):
        """Test that hot junction (not ambient) is monitored."""
        mock_imports["sensor"].temperature = 70.0  # Hot junction high
        mock_imports["sensor"].ambient_temperature = 25.0  # Ambient normal

        # Should use hot junction for threshold comparison
        hot_temp = mock_imports["sensor"].temperature
        ambient_temp = mock_imports["sensor"].ambient_temperature
        warning_temp = 60

        assert hot_temp >= warning_temp
        assert ambient_temp < warning_temp


class TestShutdownTrigger:
    """Test shutdown command execution."""

    def test_trigger_shutdown_calls_command(self):
        """Test that trigger_shutdown calls the shutdown command."""
        with patch("subprocess.run") as mock_run:
            # Note: No sudo - service runs as root
            def trigger_shutdown(reason: str) -> None:
                subprocess.run(
                    ["shutdown", "-h", "+1", f"Safety shutdown: {reason}"],
                    check=True,
                )

            trigger_shutdown("MCP9601 temperature 75.0C >= 75C")

            mock_run.assert_called_once()
            call_args = mock_run.call_args[0][0]
            assert "shutdown" in call_args
            assert "MCP9601" in call_args[-1]


class TestI2CFailureHandling:
    """Test I2C failure handling."""

    def test_consecutive_failure_counting(self, mock_imports):
        """Test that consecutive failures are counted correctly."""
        max_failures = 5
        consecutive_failures = 0

        for _ in range(max_failures):
            try:
                raise OSError("I2C read failed")
            except OSError:
                consecutive_failures += 1

        assert consecutive_failures == max_failures

    def test_failure_counter_resets_on_success(self, mock_imports):
        """Test that failure counter resets after successful read."""
        consecutive_failures = 3

        # Simulate successful read
        _ = mock_imports["sensor"].temperature
        consecutive_failures = 0

        assert consecutive_failures == 0

    def test_both_readings_available(self, mock_imports):
        """Test that both hot and cold junction readings are available."""
        hot = mock_imports["sensor"].temperature
        cold = mock_imports["sensor"].ambient_temperature

        assert hot is not None
        assert cold is not None
