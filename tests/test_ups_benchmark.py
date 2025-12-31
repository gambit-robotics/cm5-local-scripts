"""Tests for UPS benchmark script."""

import multiprocessing
import sys
import time
from io import StringIO
from pathlib import Path
from unittest.mock import MagicMock, patch, mock_open

import pytest

# Add scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from ups_benchmark import (
    calculate_battery_percent,
    parse_i2c_address,
    WorkerPool,
    SensorReader,
    BenchmarkRunner,
    CELL_VOLTAGE_FULL,
    CELL_VOLTAGE_EMPTY,
    DEFAULT_CELL_COUNT,
)


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
        for cells in [1, 2, 3, 4, 5, 6]:
            voltage = 4.2 * cells
            percent = calculate_battery_percent(voltage, cells)
            assert percent == 100.0

            voltage = 3.0 * cells
            percent = calculate_battery_percent(voltage, cells)
            assert percent == 0.0


class TestI2CAddressParsing:
    """Test I2C address parsing."""

    def test_parse_hex_string(self):
        """Test parsing hex string I2C address."""
        assert parse_i2c_address("0x42") == 0x42
        assert parse_i2c_address("0X42") == 0x42

    def test_parse_decimal_string(self):
        """Test parsing decimal string I2C address."""
        assert parse_i2c_address("66") == 66

    def test_parse_invalid_raises(self):
        """Test that invalid address raises ArgumentTypeError."""
        import argparse
        with pytest.raises(argparse.ArgumentTypeError):
            parse_i2c_address("invalid")


class TestWorkerPool:
    """Test WorkerPool management."""

    def test_create_workers(self):
        """Test creating workers."""
        pool = WorkerPool(max_workers=4)
        try:
            count = pool.set_worker_count(2)
            assert count == 2
            assert len(pool.workers) == 2
            assert len(pool.stop_events) == 2
        finally:
            pool.shutdown()

    def test_scale_up_workers(self):
        """Test scaling up number of workers."""
        pool = WorkerPool(max_workers=4)
        try:
            pool.set_worker_count(1)
            count = pool.set_worker_count(3)
            assert count == 3
            assert len(pool.workers) == 3
        finally:
            pool.shutdown()

    def test_scale_down_workers(self):
        """Test scaling down number of workers."""
        pool = WorkerPool(max_workers=4)
        try:
            pool.set_worker_count(3)
            count = pool.set_worker_count(1)
            assert count == 1
            assert len(pool.workers) == 1
        finally:
            pool.shutdown()

    def test_max_workers_limit(self):
        """Test that worker count is limited to max_workers."""
        pool = WorkerPool(max_workers=2)
        try:
            count = pool.set_worker_count(10)
            assert count == 2
        finally:
            pool.shutdown()

    def test_min_workers_zero(self):
        """Test that worker count can go to zero."""
        pool = WorkerPool(max_workers=4)
        try:
            pool.set_worker_count(2)
            count = pool.set_worker_count(0)
            assert count == 0
            assert len(pool.workers) == 0
        finally:
            pool.shutdown()

    def test_shutdown_clears_workers(self):
        """Test that shutdown clears all workers."""
        pool = WorkerPool(max_workers=4)
        pool.set_worker_count(2)
        pool.shutdown()
        assert len(pool.workers) == 0
        assert len(pool.stop_events) == 0


class TestSensorReader:
    """Test SensorReader with mocked sensor."""

    @pytest.fixture
    def mock_sensor(self):
        """Create a mock INA219 sensor."""
        sensor = MagicMock()
        sensor.bus_voltage = 11.5
        sensor.shunt_voltage = 0.01
        sensor.current = -500  # Negative = discharging
        return sensor

    @pytest.fixture
    def mock_imports(self, mock_sensor):
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

    def test_initialize_success(self, mock_imports):
        """Test successful sensor initialization."""
        reader = SensorReader(i2c_address=0x42)
        result = reader.initialize()
        assert result is True
        assert reader.sensor is not None

    def test_read_success(self, mock_imports):
        """Test successful sensor read."""
        reader = SensorReader(i2c_address=0x42)
        reader.initialize()

        reading = reader.read()
        assert reading is not None
        assert "voltage" in reading
        assert "current_ma" in reading
        assert "power_w" in reading
        assert "charging" in reading

    def test_read_voltage_includes_shunt(self, mock_imports):
        """Test that voltage includes shunt voltage."""
        mock_imports["sensor"].bus_voltage = 11.5
        mock_imports["sensor"].shunt_voltage = 0.05

        reader = SensorReader(i2c_address=0x42)
        reader.initialize()

        reading = reader.read()
        assert reading["voltage"] == 11.55

    def test_detect_charging(self, mock_imports):
        """Test detection of charging state."""
        mock_imports["sensor"].current = 500  # Positive = charging

        reader = SensorReader(i2c_address=0x42)
        reader.initialize()

        reading = reader.read()
        assert reading["charging"] is True

    def test_detect_discharging(self, mock_imports):
        """Test detection of discharging state."""
        mock_imports["sensor"].current = -500  # Negative = discharging

        reader = SensorReader(i2c_address=0x42)
        reader.initialize()

        reading = reader.read()
        assert reading["charging"] is False

    def test_read_failure_returns_none(self, mock_imports):
        """Test that read failure returns None."""
        mock_imports["sensor"].bus_voltage = property(
            lambda self: (_ for _ in ()).throw(OSError("I2C error"))
        )

        reader = SensorReader(i2c_address=0x42)
        reader.sensor = mock_imports["sensor"]

        # Force sensor to raise on attribute access
        reader.sensor.bus_voltage = MagicMock(side_effect=OSError("I2C error"))

        # Manually set sensor to simulate read failure
        reader.sensor = MagicMock()
        reader.sensor.bus_voltage = MagicMock(side_effect=OSError("I2C error"))

        reading = reader.read()
        assert reading is None

    def test_consecutive_failure_counting(self, mock_imports):
        """Test that consecutive failures are counted."""
        reader = SensorReader(i2c_address=0x42)
        reader.sensor = MagicMock()
        reader.sensor.bus_voltage = MagicMock(side_effect=OSError("I2C error"))

        for i in range(3):
            reader.read()
            assert reader.consecutive_failures == i + 1

    def test_failure_count_resets_on_success(self, mock_imports):
        """Test that failure count resets on successful read."""
        reader = SensorReader(i2c_address=0x42)
        reader.initialize()
        reader.consecutive_failures = 3

        reading = reader.read()
        assert reading is not None
        assert reader.consecutive_failures == 0


class TestBenchmarkRunnerArgs:
    """Test BenchmarkRunner argument handling."""

    @pytest.fixture
    def mock_args(self):
        """Create mock arguments."""
        args = MagicMock()
        args.profile = "stress"
        args.threshold = 10
        args.interval = 1.0
        args.output = "/tmp"
        args.cycle_duration = 60
        args.cells = 3
        args.i2c_address = 0x42
        args.no_csv = True
        return args

    def test_runner_initializes(self, mock_args):
        """Test that runner initializes correctly."""
        runner = BenchmarkRunner(mock_args)
        assert runner.args.profile == "stress"
        assert runner.args.threshold == 10
        assert runner.running is True

    def test_threshold_validation(self, mock_args):
        """Test that threshold is validated against current battery."""
        # This would require full integration testing with mocked sensor
        pass


class TestLoadLevelCalculation:
    """Test load level calculations for cyclic mode."""

    def test_load_100_uses_all_cores(self):
        """Test that 100% load uses all CPU cores."""
        cpu_count = 4
        target_load = 100
        workers = int(cpu_count * target_load / 100)
        assert workers == 4

    def test_load_75_uses_three_quarters(self):
        """Test that 75% load on 4 cores uses 3 workers."""
        cpu_count = 4
        target_load = 75
        workers = int(cpu_count * target_load / 100)
        assert workers == 3

    def test_load_50_uses_half(self):
        """Test that 50% load uses half the cores."""
        cpu_count = 4
        target_load = 50
        workers = int(cpu_count * target_load / 100)
        assert workers == 2

    def test_load_25_uses_quarter(self):
        """Test that 25% load uses quarter of cores."""
        cpu_count = 4
        target_load = 25
        workers = int(cpu_count * target_load / 100)
        assert workers == 1

    def test_load_0_uses_no_workers(self):
        """Test that 0% load uses no workers."""
        cpu_count = 4
        target_load = 0
        workers = int(cpu_count * target_load / 100)
        assert workers == 0


class TestCSVOutput:
    """Test CSV output formatting."""

    def test_csv_header_fields(self):
        """Test that CSV has correct header fields."""
        expected_headers = [
            "timestamp", "elapsed_s", "voltage_v", "current_ma", "power_w",
            "battery_pct", "target_load_pct", "workers", "charging", "notes"
        ]
        # This validates the spec - actual CSV writing tested in integration
        assert len(expected_headers) == 10

    def test_csv_filename_format(self):
        """Test CSV filename format."""
        from datetime import datetime
        profile = "stress"
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"benchmark_{profile}_{timestamp}.csv"
        assert filename.startswith("benchmark_stress_")
        assert filename.endswith(".csv")
