"""Configuration loading helpers."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover - optional local convenience
    load_dotenv = None

BASE_DIR = Path(__file__).resolve().parents[1]
CONFIG_DIR = BASE_DIR / "config"

_log_dir = Path(os.getenv("BUSHFIRE_SENTINEL_LOG_DIR") or os.getenv("LOG_DIR", "logs"))
LOG_DIR = _log_dir if _log_dir.is_absolute() else BASE_DIR / _log_dir

if load_dotenv:
    load_dotenv(BASE_DIR / ".env")


def env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_sites() -> list[dict[str, Any]]:
    return load_json(CONFIG_DIR / "sites.json")


def load_scenarios() -> dict[str, dict[str, Any]]:
    return load_json(CONFIG_DIR / "scenarios.json")


MQTT_BROKER = os.getenv("MQTT_BROKER", "broker.hivemq.com")
MQTT_PORT = env_int("MQTT_PORT", 1883)
MQTT_KEEPALIVE = env_int("MQTT_KEEPALIVE", 60)
PUBLISH_INTERVAL_SECONDS = env_int("PUBLISH_INTERVAL_SECONDS", 10)
WEATHER_INTERVAL_SECONDS = env_int("WEATHER_INTERVAL_SECONDS", 30)
DEFAULT_SCENARIO = os.getenv("SCENARIO", "normal")
