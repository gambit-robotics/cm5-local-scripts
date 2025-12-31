# UPS Battery Benchmark Script

Benchmark UPS/battery runtime under CPU load to determine worst-case battery runtime and power consumption at different utilization levels.

## Requirements

- Python 3.9+
- Adafruit INA219 sensor connected via I2C
- Dependencies: `adafruit-circuitpython-ina219`, `PyYAML`

```bash
pip install adafruit-circuitpython-ina219
```

## Usage

### Stress Mode

Run 100% CPU load on all cores until battery threshold or Ctrl+C:

```bash
python3 ups_benchmark.py stress --threshold 10 --output ./results/
```

### Cyclic Mode

Rotate through load levels (100% → 75% → 50% → 25% → 0%):

```bash
python3 ups_benchmark.py cyclic --cycle-duration 60 --threshold 10
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--threshold PCT` | 10 | Stop at this battery % |
| `--interval SEC` | 1.0 | Logging interval in seconds |
| `--output DIR` | `.` | CSV output directory |
| `--cycle-duration SEC` | 60 | Seconds per load level (cyclic mode) |
| `--cells N` | 3 | Battery cell count (1-6) |
| `--i2c-address ADDR` | 0x42 | INA219 I2C address |
| `--no-csv` | false | Console output only |

## Output

### Console

```
INFO: Starting UPS benchmark: profile=stress, threshold=10%, interval=1.0s
INFO: System: 4 cores, battery at 78.3% (11.82V)
INFO: [    0.0s] 78.3%  11.82V  -1523mA  18.0W  load=100%
INFO: [    1.0s] 77.5%  11.79V  -1548mA  18.3W  load=100%
...
INFO: Battery threshold reached (10.1% <= 10%)
INFO: Test complete: 423.0s elapsed
INFO: Battery: 78.3% → 10.1%
```

### CSV

Output file: `benchmark_<profile>_<timestamp>.csv`

```csv
timestamp,elapsed_s,voltage_v,current_ma,power_w,battery_pct,target_load_pct,workers,charging,notes
2024-01-15T10:30:00,0.0,11.82,-1523,18.01,78.3,100,4,false,test_start
2024-01-15T10:30:01,1.0,11.79,-1548,18.25,77.5,100,4,false,
```

## How It Works

1. **CPU Load Generation**: Uses Python multiprocessing to spawn worker processes that run tight arithmetic loops (LCG pattern)
2. **Load Modulation**: Adjusts worker count to achieve target CPU percentage (e.g., 75% on 4 cores = 3 workers)
3. **Battery Monitoring**: Reads INA219 sensor for voltage/current, calculates battery % using linear interpolation between 3.0V (empty) and 4.2V (full) per cell
4. **Graceful Shutdown**: Handles SIGINT/SIGTERM to cleanly stop workers and write final summary

## Testing

```bash
pytest tests/test_ups_benchmark.py -v
```

## See Also

- `ina219_safety.py` - Battery safety monitor that triggers system shutdown at low battery
