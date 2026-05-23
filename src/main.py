"""Unified local runner for Bushfire Sentinel Python components."""

from __future__ import annotations

import argparse
import multiprocessing as mp
from pathlib import Path
import signal
import sys
import time
from collections.abc import Callable

from config import DEFAULT_SCENARIO, PUBLISH_INTERVAL_SECONDS, WEATHER_INTERVAL_SECONDS
from actuator_simulator import SprinklerActuator
from site_sensor_simulator import run as run_site_sensors
from weather_collector import run as run_weather

ROOT_DIR = Path(__file__).resolve().parents[1]
RUNTIME_DIR = ROOT_DIR / "logs" / "runtime"
CHILD_PID_FILE = RUNTIME_DIR / "python_child_pids.txt"


def run_actuator(scenario: str, response_delay: float) -> None:
    SprinklerActuator(scenario=scenario, response_delay=response_delay).start()


def start_process(name: str, target: Callable[..., None], args: tuple[object, ...]) -> mp.Process:
    process = mp.Process(target=target, args=args, name=name)
    process.start()
    print(f"Started {name} pid={process.pid}", flush=True)
    return process


def stop_processes(processes: list[mp.Process]) -> None:
    for process in processes:
        if process.is_alive():
            print(f"Stopping {process.name} pid={process.pid}", flush=True)
            process.terminate()

    deadline = time.time() + 5
    for process in processes:
        remaining = max(0.1, deadline - time.time())
        process.join(timeout=remaining)

    for process in processes:
        if process.is_alive():
            print(f"Force stopping {process.name} pid={process.pid}", flush=True)
            process.kill()
            process.join(timeout=1)


def write_child_pid_file(processes: list[mp.Process]) -> None:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    with CHILD_PID_FILE.open("w", encoding="utf-8") as pid_file:
        for process in processes:
            if process.pid is not None:
                pid_file.write(f"{process.pid} {process.name}\n")


def run_all(
    sensor_scenario: str,
    actuator_scenario: str,
    weather_interval: int,
    sensor_interval: int,
    response_delay: float,
) -> None:
    processes = [
        start_process("weather_collector", run_weather, (weather_interval, False)),
        start_process("site_sensor_simulator", run_site_sensors, (sensor_scenario, sensor_interval, False)),
        start_process("actuator_simulator", run_actuator, (actuator_scenario, response_delay)),
    ]
    write_child_pid_file(processes)

    stopping = False

    def handle_stop(signum: int, _frame: object) -> None:
        nonlocal stopping
        if stopping:
            return
        stopping = True
        print(f"Received signal {signum}; stopping Bushfire Sentinel Python runner...", flush=True)
        stop_processes(processes)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    try:
        while True:
            for process in processes:
                if not process.is_alive():
                    raise RuntimeError(f"{process.name} exited unexpectedly with code {process.exitcode}")
            time.sleep(2)
    finally:
        stop_processes(processes)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run all Bushfire Sentinel Python components.")
    parser.add_argument("--sensor-scenario", default=DEFAULT_SCENARIO)
    parser.add_argument("--actuator-scenario", default=DEFAULT_SCENARIO)
    parser.add_argument("--weather-interval", type=int, default=WEATHER_INTERVAL_SECONDS)
    parser.add_argument("--sensor-interval", type=int, default=PUBLISH_INTERVAL_SECONDS)
    parser.add_argument("--response-delay", type=float, default=0.8)
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    run_all(
        sensor_scenario=args.sensor_scenario,
        actuator_scenario=args.actuator_scenario,
        weather_interval=args.weather_interval,
        sensor_interval=args.sensor_interval,
        response_delay=args.response_delay,
    )
