#!/usr/bin/env python3
"""
PCT2075 Temperature Safety Monitor

Monitors the PCT2075 I2C temperature sensor and triggers a graceful shutdown
when temperature exceeds the configured threshold. Runs independently of Viam.
"""

import logging
import subprocess
import sys
import time
from pathlib import Path

import yaml

CONFIG_PATH = Path("/etc/gambit/safety-config.yaml")
SENSOR_NAME = "pct2075"
MAX_CONSECUTIVE_FAILURES = 5

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
    """Parse I2C address from config (handles both string '0x37' and int)."""
    try:
        if isinstance(addr, str):
            return int(addr, 16)
        return int(addr)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Invalid i2c_address '{addr}'") from exc


def _coerce_float(name: str, value) -> float:
    """Coerce a config value to float with a clear error."""
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} ('{value}') must be a number") from exc


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
        i2c_address = parse_i2c_address(config.get("i2c_address", 0x37))
        warning_temp = _coerce_float("warning_temp_c", config.get("warning_temp_c", 70))
        shutdown_temp = _coerce_float("shutdown_temp_c", config.get("shutdown_temp_c", 80))
        poll_interval = _coerce_float("poll_interval_s", config.get("poll_interval_s", 5))
    except ValueError as exc:
        logger.error(exc)
        sys.exit(1)

    # Validate configuration
    if warning_temp >= shutdown_temp:
        logger.error(
            f"warning_temp_c ({warning_temp}) must be less than shutdown_temp_c ({shutdown_temp})"
        )
        sys.exit(1)

    logger.info(
        f"Starting PCT2075 safety monitor: "
        f"addr=0x{i2c_address:02X}, "
        f"warning={warning_temp}C, "
        f"shutdown={shutdown_temp}C, "
        f"poll={poll_interval}s"
    )

    # Initialize sensor
    try:
        import board
        import adafruit_pct2075

        i2c = board.I2C()
        sensor = adafruit_pct2075.PCT2075(i2c, address=i2c_address)
        logger.info(f"PCT2075 sensor initialized at 0x{i2c_address:02X}")
    except Exception as e:
        logger.error(f"Failed to initialize sensor: {e}")
        sys.exit(1)

    consecutive_failures = 0
    warning_logged = False

    while True:
        try:
            temperature = sensor.temperature
            consecutive_failures = 0

            logger.info(f"Temperature: {temperature:.1f}C")

            if temperature >= shutdown_temp:
                trigger_shutdown(f"PCT2075 temperature {temperature:.1f}C >= {shutdown_temp}C")
                time.sleep(70)  # Wait for shutdown to complete
                sys.exit(1)

            if temperature >= warning_temp:
                if not warning_logged:
                    logger.warning(
                        f"HIGH TEMPERATURE WARNING: {temperature:.1f}C >= {warning_temp}C"
                    )
                    warning_logged = True
            else:
                if warning_logged:
                    logger.info(f"Temperature returned to safe level: {temperature:.1f}C")
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
