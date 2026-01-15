#!/usr/bin/env python3
"""
UPS Battery Benchmarking Script

Benchmark UPS/battery runtime under CPU load to determine:
- Worst-case battery runtime (100% CPU)
- Variable load behavior (cyclic pattern)
- Power consumption at different utilization levels
"""

import argparse
import csv
import logging
import multiprocessing
import os
import signal
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

# Li-ion cell voltage constants (from ina219_safety.py)
CELL_VOLTAGE_FULL = 4.2  # V per cell at 100%
CELL_VOLTAGE_EMPTY = 3.0  # V per cell at 0%
DEFAULT_CELL_COUNT = 3
DEFAULT_I2C_ADDRESS = 0x41

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s: %(message)s",
    stream=sys.stdout
)
logger = logging.getLogger("ups_benchmark")


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


def cpu_stress_worker(stop_event: multiprocessing.Event) -> None:
    """
    Worker function that burns CPU with a tight arithmetic loop.
    Uses LCG pattern for predictable CPU burn.
    """
    x = 1
    while not stop_event.is_set():
        for _ in range(100000):
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF


class WorkerPool:
    """Manages a pool of CPU stress workers."""

    def __init__(self, max_workers: int):
        self.max_workers = max_workers
        self.workers: list[multiprocessing.Process] = []
        self.stop_events: list[multiprocessing.Event] = []

    def set_worker_count(self, count: int) -> int:
        """
        Adjust the number of active workers.
        Returns the actual number of workers running.
        """
        count = max(0, min(count, self.max_workers))
        current = len(self.workers)

        if count > current:
            # Start more workers
            for _ in range(count - current):
                stop_event = multiprocessing.Event()
                worker = multiprocessing.Process(
                    target=cpu_stress_worker,
                    args=(stop_event,),
                    daemon=True
                )
                worker.start()
                self.workers.append(worker)
                self.stop_events.append(stop_event)

        elif count < current:
            # Stop excess workers
            for _ in range(current - count):
                stop_event = self.stop_events.pop()
                worker = self.workers.pop()
                stop_event.set()
                worker.join(timeout=2.0)
                if worker.is_alive():
                    worker.terminate()

        return len(self.workers)

    def shutdown(self) -> None:
        """Stop all workers gracefully."""
        for event in self.stop_events:
            event.set()

        for worker in self.workers:
            worker.join(timeout=2.0)
            if worker.is_alive():
                worker.terminate()

        self.workers.clear()
        self.stop_events.clear()


class SensorReader:
    """Handles INA219 sensor reading with error handling."""

    def __init__(self, i2c_address: int = DEFAULT_I2C_ADDRESS):
        self.i2c_address = i2c_address
        self.sensor = None
        self.consecutive_failures = 0
        self.max_failures = 5

    def initialize(self) -> bool:
        """Initialize the INA219 sensor. Returns True on success."""
        try:
            import board
            from adafruit_ina219 import INA219

            i2c = board.I2C()
            self.sensor = INA219(i2c, addr=self.i2c_address)
            logger.info(f"INA219 sensor initialized at 0x{self.i2c_address:02X}")
            return True
        except Exception as e:
            logger.error(f"Failed to initialize sensor: {e}")
            return False

    def read(self) -> Optional[dict]:
        """
        Read sensor values. Returns dict with voltage, current, power, or None on failure.
        """
        if self.sensor is None:
            return None

        try:
            bus_voltage = self.sensor.bus_voltage
            shunt_voltage = self.sensor.shunt_voltage
            voltage = bus_voltage + shunt_voltage
            current_ma = self.sensor.current
            power_w = abs(voltage * current_ma / 1000)

            self.consecutive_failures = 0
            return {
                "voltage": voltage,
                "current_ma": current_ma,
                "power_w": power_w,
                "charging": current_ma > 0
            }
        except Exception as e:
            self.consecutive_failures += 1
            logger.error(
                f"Sensor read failed ({self.consecutive_failures}/{self.max_failures}): {e}"
            )
            if self.consecutive_failures >= self.max_failures:
                logger.critical(
                    f"Sensor read failed {self.max_failures} consecutive times. "
                    "Hardware may be disconnected."
                )
                self.consecutive_failures = 0
            return None


class BenchmarkRunner:
    """Main benchmark orchestrator."""

    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.cpu_count = multiprocessing.cpu_count()
        self.worker_pool = WorkerPool(self.cpu_count)
        self.sensor = SensorReader(args.i2c_address)
        self.running = True
        self.start_time: Optional[float] = None
        self.csv_writer = None
        self.csv_file = None
        self.start_battery_pct: Optional[float] = None

    def setup_signal_handlers(self) -> None:
        """Setup SIGINT and SIGTERM handlers for graceful shutdown."""
        def handler(signum, frame):
            logger.info(f"Received signal {signum}, initiating shutdown...")
            self.running = False

        signal.signal(signal.SIGINT, handler)
        signal.signal(signal.SIGTERM, handler)

    def setup_csv(self) -> None:
        """Setup CSV output file."""
        if self.args.no_csv:
            return

        output_dir = Path(self.args.output)
        output_dir.mkdir(parents=True, exist_ok=True)

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"benchmark_{self.args.profile}_{timestamp}.csv"
        filepath = output_dir / filename

        self.csv_file = open(filepath, "w", newline="")
        self.csv_writer = csv.writer(self.csv_file)
        self.csv_writer.writerow([
            "timestamp", "elapsed_s", "voltage_v", "current_ma", "power_w",
            "battery_pct", "target_load_pct", "workers", "charging", "notes"
        ])
        logger.info(f"CSV output: {filepath}")

    def write_sample(
        self,
        reading: dict,
        battery_pct: float,
        target_load: int,
        workers: int,
        notes: str = ""
    ) -> None:
        """Write a sample to console and CSV."""
        elapsed = time.monotonic() - self.start_time

        # Console output
        status = "charging" if reading["charging"] else "discharging"
        logger.info(
            f"[{elapsed:7.1f}s] {battery_pct:5.1f}%  {reading['voltage']:.2f}V  "
            f"{reading['current_ma']:+.0f}mA  {reading['power_w']:.1f}W  "
            f"load={target_load}%"
        )

        # CSV output
        if self.csv_writer:
            self.csv_writer.writerow([
                datetime.now().isoformat(),
                f"{elapsed:.1f}",
                f"{reading['voltage']:.2f}",
                f"{reading['current_ma']:.0f}",
                f"{reading['power_w']:.2f}",
                f"{battery_pct:.1f}",
                target_load,
                workers,
                str(reading["charging"]).lower(),
                notes
            ])
            self.csv_file.flush()

    def run_stress(self) -> None:
        """Run stress profile - 100% CPU until threshold or signal."""
        logger.info("Starting stress profile (100% CPU on all cores)")

        workers = self.worker_pool.set_worker_count(self.cpu_count)
        target_load = 100

        while self.running:
            reading = self.sensor.read()
            if reading is None:
                time.sleep(self.args.interval)
                continue

            battery_pct = calculate_battery_percent(reading["voltage"], self.args.cells)

            if self.start_battery_pct is None:
                self.start_battery_pct = battery_pct
                self.write_sample(reading, battery_pct, target_load, workers, "test_start")
            else:
                self.write_sample(reading, battery_pct, target_load, workers)

            # Check threshold (only when discharging)
            if not reading["charging"] and battery_pct <= self.args.threshold:
                logger.info(
                    f"Battery threshold reached ({battery_pct:.1f}% <= {self.args.threshold}%)"
                )
                break

            time.sleep(self.args.interval)

    def run_cyclic(self) -> None:
        """Run cyclic profile - rotate through load levels."""
        load_levels = [100, 75, 50, 25, 0]
        logger.info(f"Starting cyclic profile (cycle duration: {self.args.cycle_duration}s per level)")

        cycle_start = time.monotonic()
        level_idx = 0
        first_sample = True

        while self.running:
            # Check if it's time to move to next load level
            elapsed_in_cycle = time.monotonic() - cycle_start
            if elapsed_in_cycle >= self.args.cycle_duration:
                level_idx = (level_idx + 1) % len(load_levels)
                cycle_start = time.monotonic()
                logger.info(f"Switching to {load_levels[level_idx]}% load")

            target_load = load_levels[level_idx]
            target_workers = int(self.cpu_count * target_load / 100)
            workers = self.worker_pool.set_worker_count(target_workers)

            reading = self.sensor.read()
            if reading is None:
                time.sleep(self.args.interval)
                continue

            battery_pct = calculate_battery_percent(reading["voltage"], self.args.cells)

            if first_sample:
                self.start_battery_pct = battery_pct
                self.write_sample(reading, battery_pct, target_load, workers, "test_start")
                first_sample = False
            else:
                self.write_sample(reading, battery_pct, target_load, workers)

            # Check threshold (only when discharging)
            if not reading["charging"] and battery_pct <= self.args.threshold:
                logger.info(
                    f"Battery threshold reached ({battery_pct:.1f}% <= {self.args.threshold}%)"
                )
                break

            time.sleep(self.args.interval)

    def print_summary(self) -> None:
        """Print test summary statistics."""
        if self.start_time is None:
            return

        elapsed = time.monotonic() - self.start_time
        reading = self.sensor.read()

        logger.info("-" * 50)
        logger.info(f"Test complete: {elapsed:.1f}s elapsed")

        if reading:
            end_pct = calculate_battery_percent(reading["voltage"], self.args.cells)
            if self.start_battery_pct is not None:
                logger.info(f"Battery: {self.start_battery_pct:.1f}% → {end_pct:.1f}%")

    def run(self) -> int:
        """Main entry point. Returns exit code."""
        self.setup_signal_handlers()

        # Initialize sensor
        if not self.sensor.initialize():
            return 1

        # Get initial reading
        initial = self.sensor.read()
        if initial is None:
            logger.error("Failed to get initial sensor reading")
            return 1

        initial_pct = calculate_battery_percent(initial["voltage"], self.args.cells)

        # Validate threshold
        if self.args.threshold >= initial_pct:
            logger.error(
                f"Threshold ({self.args.threshold}%) >= current battery ({initial_pct:.1f}%)"
            )
            return 1

        logger.info(
            f"Starting UPS benchmark: profile={self.args.profile}, "
            f"threshold={self.args.threshold}%, interval={self.args.interval}s"
        )
        logger.info(
            f"System: {self.cpu_count} cores, battery at {initial_pct:.1f}% ({initial['voltage']:.2f}V)"
        )

        self.setup_csv()
        self.start_time = time.monotonic()

        try:
            if self.args.profile == "stress":
                self.run_stress()
            elif self.args.profile == "cyclic":
                self.run_cyclic()
        finally:
            self.worker_pool.shutdown()
            self.print_summary()

            if self.csv_file:
                self.csv_file.close()

        return 0


def parse_i2c_address(addr: str) -> int:
    """Parse I2C address from string (handles '0x42' or '66')."""
    try:
        if addr.startswith("0x") or addr.startswith("0X"):
            return int(addr, 16)
        return int(addr)
    except ValueError as e:
        raise argparse.ArgumentTypeError(f"Invalid I2C address: {addr}") from e


def main() -> int:
    """Parse arguments and run benchmark."""
    parser = argparse.ArgumentParser(
        description="Benchmark UPS/battery runtime under CPU load",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Stress mode - 100% CPU until threshold or Ctrl+C
  %(prog)s stress --threshold 10 --output ./results/

  # Cyclic mode - rotate through load levels
  %(prog)s cyclic --cycle-duration 60 --threshold 10
        """
    )

    parser.add_argument(
        "profile",
        choices=["stress", "cyclic"],
        help="Test profile: 'stress' (100%% CPU) or 'cyclic' (rotating loads)"
    )

    parser.add_argument(
        "--threshold",
        type=float,
        default=10,
        metavar="PCT",
        help="Stop at this battery %% (default: 10)"
    )

    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        metavar="SEC",
        help="Log interval in seconds (default: 1.0)"
    )

    parser.add_argument(
        "--output",
        type=str,
        default=".",
        metavar="DIR",
        help="CSV output directory (default: current directory)"
    )

    parser.add_argument(
        "--cycle-duration",
        type=float,
        default=60,
        metavar="SEC",
        help="Seconds per load level in cyclic mode (default: 60)"
    )

    parser.add_argument(
        "--cells",
        type=int,
        default=DEFAULT_CELL_COUNT,
        metavar="N",
        help=f"Battery cell count (default: {DEFAULT_CELL_COUNT})"
    )

    parser.add_argument(
        "--i2c-address",
        type=parse_i2c_address,
        default=DEFAULT_I2C_ADDRESS,
        metavar="ADDR",
        help=f"INA219 I2C address (default: 0x{DEFAULT_I2C_ADDRESS:02X})"
    )

    parser.add_argument(
        "--no-csv",
        action="store_true",
        help="Console only, no CSV output"
    )

    args = parser.parse_args()

    runner = BenchmarkRunner(args)
    return runner.run()


if __name__ == "__main__":
    sys.exit(main())
