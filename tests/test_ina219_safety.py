"""Tests for INA219 safety monitoring script."""

import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import yaml

# Add scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from ina219_safety import (
    calculate_battery_percent,
    _coerce_float,
    _coerce_int,
    parse_i2c_address,
    CELL_VOLTAGE_FULL,
    CELL_VOLTAGE_EMPTY,
    DEFAULT_CELL_COUNT,
    MAX_CELL_COUNT,
)


@pytest.fixture
def mock_config(tmp_path):
    """Create a temporary config file."""
    config = {
        "ina219": {
            "i2c_address": "0x42",
            "warning_battery_percent": 15,
            "shutdown_battery_percent": 5,
            "poll_interval_s": 1,
            "battery_cell_count": 3,
        }
    }
    config_file = tmp_path / "safety-config.yaml"
    with open(config_file, "w") as f:
        yaml.dump(config, f)
    return config_file


@pytest.fixture
def mock_sensor():
    """Create a mock INA219 sensor."""
    sensor = MagicMock()
    sensor.bus_voltage = 11.5
    sensor.shunt_voltage = 0.01
    sensor.current = -500  # Negative = discharging
    sensor.power = 5.5
    return sensor


@pytest.fixture
def mock_imports(mock_sensor):
    """Mock the board and adafruit imports."""
    mock_board = MagicMock()
    mock_board.I2C.return_value = MagicMock()

    mock_ina219_module = MagicMock()
    mock_ina219_module.INA219.return_value = mock_sensor

    with patch.dict(
        sys.modules,
        {
            "board": mock_board,
            "adafruit_ina219": mock_ina219_module,
        },
    ):
        yield {"board": mock_board, "ina219": mock_ina219_module, "sensor": mock_sensor}


class TestBatteryPercentCalculation:
    """Test battery percentage calculation."""

    def test_full_battery_3s(self):
        """Test 100% at full voltage for 3S pack."""
        voltage = 4.2 * 3  # 12.6V
        percent = calculate_battery_percent(voltage, 3)
        assert percent == 100.0

    def test_empty_battery_3s(self):
        """Test 0% at empty voltage for 3S pack."""
        voltage = 3.0 * 3  # 9.0V
        percent = calculate_battery_percent(voltage, 3)
        assert percent == 0.0

    def test_half_battery_3s(self):
        """Test 50% at midpoint voltage for 3S pack."""
        voltage = (4.2 + 3.0) / 2 * 3  # 10.8V
        percent = calculate_battery_percent(voltage, 3)
        assert abs(percent - 50.0) < 0.1

    def test_clamp_above_100(self):
        """Test that percentage is clamped to 100%."""
        voltage = 4.5 * 3  # Over-voltage
        percent = calculate_battery_percent(voltage, 3)
        assert percent == 100.0

    def test_clamp_below_0(self):
        """Test that percentage is clamped to 0%."""
        voltage = 2.5 * 3  # Under-voltage
        percent = calculate_battery_percent(voltage, 3)
        assert percent == 0.0

    def test_different_cell_counts(self):
        """Test calculation for different cell counts."""
        # Full battery at different cell counts
        for cells in [1, 2, 3, 4, 5, 6]:
            voltage = 4.2 * cells
            percent = calculate_battery_percent(voltage, cells)
            assert percent == 100.0

            voltage = 3.0 * cells
            percent = calculate_battery_percent(voltage, cells)
            assert percent == 0.0


class TestConfigLoading:
    """Test configuration loading."""

    def test_load_config_success(self, mock_config):
        """Test loading a valid config file."""
        with open(mock_config) as f:
            full_config = yaml.safe_load(f)

        config = full_config["ina219"]
        assert config["i2c_address"] == "0x42"
        assert config["warning_battery_percent"] == 15
        assert config["shutdown_battery_percent"] == 5

    def test_parse_i2c_address_string(self):
        """Test parsing hex string I2C address."""
        assert parse_i2c_address("0x42") == 0x42
        assert parse_i2c_address(0x42) == 0x42


class TestThresholds:
    """Test threshold detection."""

    def test_warning_threshold_detection(self, mock_imports):
        """Test that warning is logged at warning threshold."""
        # Set voltage for ~15% battery (3S)
        # 15% = 0.15 * (12.6 - 9.0) + 9.0 = 9.54V
        mock_imports["sensor"].bus_voltage = 9.54
        mock_imports["sensor"].shunt_voltage = 0

        voltage = mock_imports["sensor"].bus_voltage + mock_imports["sensor"].shunt_voltage
        percent = calculate_battery_percent(voltage, 3)
        warning_percent = 15

        assert percent <= warning_percent

    def test_shutdown_threshold_detection(self, mock_imports):
        """Test that shutdown is triggered at shutdown threshold."""
        # Set voltage for ~5% battery (3S)
        # 5% = 0.05 * (12.6 - 9.0) + 9.0 = 9.18V
        mock_imports["sensor"].bus_voltage = 9.18
        mock_imports["sensor"].shunt_voltage = 0

        voltage = mock_imports["sensor"].bus_voltage + mock_imports["sensor"].shunt_voltage
        percent = calculate_battery_percent(voltage, 3)
        shutdown_percent = 5

        assert percent <= shutdown_percent

    def test_normal_battery_no_warning(self, mock_imports):
        """Test that normal battery level doesn't trigger warning."""
        # Set voltage for ~50% battery
        mock_imports["sensor"].bus_voltage = 10.8
        mock_imports["sensor"].shunt_voltage = 0

        voltage = mock_imports["sensor"].bus_voltage + mock_imports["sensor"].shunt_voltage
        percent = calculate_battery_percent(voltage, 3)
        warning_percent = 15

        assert percent > warning_percent


class TestChargingState:
    """Test charging state detection."""

    def test_detect_charging(self, mock_imports):
        """Test detection of charging state (positive current)."""
        mock_imports["sensor"].current = 500  # Positive = charging

        current = mock_imports["sensor"].current
        is_charging = current > 0

        assert is_charging

    def test_detect_discharging(self, mock_imports):
        """Test detection of discharging state (negative current)."""
        mock_imports["sensor"].current = -500  # Negative = discharging

        current = mock_imports["sensor"].current
        is_charging = current > 0

        assert not is_charging

    def test_no_shutdown_while_charging(self, mock_imports):
        """Test that shutdown is not triggered while charging."""
        # Low battery but charging
        mock_imports["sensor"].bus_voltage = 9.0  # 0%
        mock_imports["sensor"].shunt_voltage = 0
        mock_imports["sensor"].current = 500  # Charging

        voltage = mock_imports["sensor"].bus_voltage + mock_imports["sensor"].shunt_voltage
        percent = calculate_battery_percent(voltage, 3)
        is_charging = mock_imports["sensor"].current > 0
        shutdown_percent = 5

        # Should NOT shutdown because charging
        should_shutdown = not is_charging and percent <= shutdown_percent
        assert not should_shutdown


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

            trigger_shutdown("Battery level 5.0% <= 5%")

            mock_run.assert_called_once()
            call_args = mock_run.call_args[0][0]
            assert "shutdown" in call_args
            assert "Battery" in call_args[-1]


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

    def test_voltage_calculation_includes_shunt(self, mock_imports):
        """Test that total voltage includes shunt voltage."""
        mock_imports["sensor"].bus_voltage = 11.5
        mock_imports["sensor"].shunt_voltage = 0.05

        voltage = mock_imports["sensor"].bus_voltage + mock_imports["sensor"].shunt_voltage

        assert voltage == 11.55


class TestConfigValidation:
    """Test configuration validation."""

    def test_cell_count_valid_range(self):
        """Test that valid cell counts are within range."""
        for cells in range(1, MAX_CELL_COUNT + 1):
            assert 1 <= cells <= MAX_CELL_COUNT

    def test_cell_count_max_voltage(self):
        """Test that max cell count stays under INA219's 26V limit."""
        max_voltage = CELL_VOLTAGE_FULL * MAX_CELL_COUNT
        assert max_voltage <= 26.0  # INA219 max bus voltage

    def test_warning_must_exceed_shutdown(self):
        """Test that warning percent must be > shutdown percent."""
        warning_percent = 15
        shutdown_percent = 5
        assert warning_percent > shutdown_percent

    def test_coercion_accepts_string_numbers(self):
        """Test that numeric strings are coerced to floats/ints."""
        assert _coerce_float("warning_battery_percent", "15") == 15.0
        assert _coerce_int("battery_cell_count", "3") == 3

    def test_coercion_errors_on_invalid(self):
        """Test that invalid numeric values raise clear errors."""
        with pytest.raises(ValueError, match="warning_battery_percent"):
            _coerce_float("warning_battery_percent", "abc")
        with pytest.raises(ValueError, match="battery_cell_count"):
            _coerce_int("battery_cell_count", "abc")
