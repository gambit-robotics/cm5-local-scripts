#!/usr/bin/env python3
"""
INA219 UPS Battery Safety Monitor

Monitors the INA219 power monitor for battery level and triggers a graceful
shutdown when battery drops below the configured threshold. Runs independently of Viam.
"""

import logging
import subprocess
import sys
import time
from pathlib import Path

import yaml

CONFIG_PATH = Path("/etc/gambit/safety-config.yaml")
SENSOR_NAME = "ina219"
MAX_CONSECUTIVE_FAILURES = 5

# Li-ion cell voltage constants for battery percentage calculation
CELL_VOLTAGE_FULL = 4.2  # V per cell at 100%
CELL_VOLTAGE_EMPTY = 3.0  # V per cell at 0%
DEFAULT_CELL_COUNT = 3  # 3S battery pack
MAX_CELL_COUNT = 6  # INA219 max bus voltage is 26V; 6S = 25.2V max

# Configure logging to journald via stdout
logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s: %(message)s",
    stream=sys.stdout
)
logger = logging.getLogger(SENSOR_NAME)


def load_config() -> dict:
    """Load configuration from the config file."""
    if not CONFIG_PATH.exists():
        logger.error(f"Config file not found: {CONFIG_PATH}")
        sys.exit(1)

    with open(CONFIG_PATH) as f:
        config = yaml.safe_load(f)

    if SENSOR_NAME not in config:
        logger.error(f"No '{SENSOR_NAME}' section in config file")
        sys.exit(1)

    return config[SENSOR_NAME]


def parse_i2c_address(addr: str | int) -> int:
    """Parse I2C address from config (handles both string '0x42' and int)."""
    try:
        if isinstance(addr, str):
            return int(addr, 16)
        return int(addr)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Invalid i2c_address '{addr}'") from exc


def calculate_battery_percent(voltage: float, cell_count: int = DEFAULT_CELL_COUNT) -> float:
    """
    Calculate battery percentage based on voltage and cell count.

    Uses linear interpolation between empty (3.0V/cell) and full (4.2V/cell).
    Result is clamped to 0-100%.
    """
    voltage_full = CELL_VOLTAGE_FULL * cell_count
    voltage_empty = CELL_VOLTAGE_EMPTY * cell_count
    voltage_range = voltage_full - voltage_empty

    percent = ((voltage - voltage_empty) / voltage_range) * 100
    return max(0.0, min(100.0, percent))


def _coerce_float(name: str, value) -> float:
    """Coerce a config value to float with a clear error."""
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} ('{value}') must be a number") from exc


def _coerce_int(name: str, value) -> int:
    """Coerce a config value to int with a clear error."""
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} ('{value}') must be an integer") from exc


def trigger_shutdown(reason: str) -> None:
    """Trigger a graceful system shutdown with 1 minute warning."""
    logger.critical(f"INITIATING SHUTDOWN: {reason}")
    try:
        # No sudo needed - systemd service runs as root
        subprocess.run(
            ["shutdown", "-h", "+1", f"Safety shutdown: {reason}"],
            check=True
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to initiate shutdown: {e}")


def main() -> None:
    """Main monitoring loop."""
    config = load_config()

    try:
        i2c_address = parse_i2c_address(config.get("i2c_address", 0x41))
        warning_percent = _coerce_float("warning_battery_percent", config.get("warning_battery_percent", 15))
        shutdown_percent = _coerce_float("shutdown_battery_percent", config.get("shutdown_battery_percent", 5))
        poll_interval = _coerce_float("poll_interval_s", config.get("poll_interval_s", 10))
        cell_count = _coerce_int("battery_cell_count", config.get("battery_cell_count", DEFAULT_CELL_COUNT))
    except ValueError as exc:
        logger.error(exc)
        sys.exit(1)

    # Validate configuration
    if warning_percent <= shutdown_percent:
        logger.error(
            f"warning_battery_percent ({warning_percent}) must be greater than shutdown_battery_percent ({shutdown_percent})"
        )
        sys.exit(1)

    if not (1 <= cell_count <= MAX_CELL_COUNT):
        logger.error(f"battery_cell_count ({cell_count}) must be between 1 and {MAX_CELL_COUNT}")
        sys.exit(1)

    logger.info(
        f"Starting INA219 safety monitor: "
        f"addr=0x{i2c_address:02X}, "
        f"warning={warning_percent}%, "
        f"shutdown={shutdown_percent}%, "
        f"poll={poll_interval}s, "
        f"cells={cell_count}S"
    )

    # Initialize sensor
    try:
        import board
        from adafruit_ina219 import INA219

        i2c = board.I2C()
        sensor = INA219(i2c, addr=i2c_address)
        logger.info(f"INA219 sensor initialized at 0x{i2c_address:02X}")
    except Exception as e:
        logger.error(f"Failed to initialize sensor: {e}")
        sys.exit(1)

    consecutive_failures = 0
    warning_logged = False

    while True:
        try:
            # Read battery voltage (bus + shunt for true battery voltage)
            bus_voltage = sensor.bus_voltage
            shunt_voltage = sensor.shunt_voltage
            voltage = bus_voltage + shunt_voltage
            current_ma = sensor.current

            battery_percent = calculate_battery_percent(voltage, cell_count)
            is_charging = current_ma > 0
            consecutive_failures = 0

            status = "charging" if is_charging else "discharging"
            logger.info(
                f"Battery: {battery_percent:.1f}% ({voltage:.2f}V), "
                f"{abs(current_ma):.0f}mA {status}"
            )

            # Only trigger shutdown if discharging
            if not is_charging and battery_percent <= shutdown_percent:
                trigger_shutdown(
                    f"Battery level {battery_percent:.1f}% <= {shutdown_percent}%"
                )
                time.sleep(70)  # Wait for shutdown to complete
                sys.exit(1)

            if not is_charging and battery_percent <= warning_percent:
                if not warning_logged:
                    logger.warning(
                        f"LOW BATTERY WARNING: {battery_percent:.1f}% <= {warning_percent}%"
                    )
                    warning_logged = True
            else:
                if warning_logged:
                    logger.info(f"Battery level recovered: {battery_percent:.1f}%")
                    warning_logged = False

        except Exception as e:
            consecutive_failures += 1
            logger.error(f"Failed to read sensor ({consecutive_failures}/{MAX_CONSECUTIVE_FAILURES}): {e}")

            if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                logger.critical(
                    f"Sensor read failed {MAX_CONSECUTIVE_FAILURES} consecutive times. "
                    "Hardware may be disconnected. NOT triggering shutdown."
                )
                # Reset counter to avoid spamming critical logs
                consecutive_failures = 0

        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
