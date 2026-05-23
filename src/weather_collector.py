"""Collect Open-Meteo weather data for all Yarra Ranges reference points."""

from __future__ import annotations

import argparse
import sys
import time
from typing import Any

import requests

from config import LOG_DIR, WEATHER_INTERVAL_SECONDS, load_sites
from mqtt_client import MqttJsonClient, MqttSettings
from schemas import PROJECT_ID, TOPIC_SENSOR_DATA, WEATHER_SENSORS
from utils import utc_now, write_jsonl

OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"
CURRENT_KEYS = ",".join(item["open_meteo_key"] for item in WEATHER_SENSORS.values())


def fetch_site_weather(site: dict[str, Any]) -> dict[str, Any]:
    response = requests.get(
        OPEN_METEO_URL,
        params={
            "latitude": site["latitude"],
            "longitude": site["longitude"],
            "current": CURRENT_KEYS,
        },
        timeout=10,
    )
    response.raise_for_status()
    return response.json()["current"]


def build_weather_messages(site: dict[str, Any], current: dict[str, Any]) -> list[dict[str, Any]]:
    timestamp = utc_now()
    messages = []
    for sensor, spec in WEATHER_SENSORS.items():
        value = current.get(spec["open_meteo_key"])
        messages.append(
            {
                "project_id": PROJECT_ID,
                "device_id": site["device_id"],
                "site_name": site["name"],
                "site_role": site["role"],
                "sensor": sensor,
                "value": value,
                "unit": spec["unit"],
                "timestamp": timestamp,
                "source": "open_meteo",
            }
        )
    return messages


def run(interval: int, once: bool = False) -> None:
    sites = load_sites()
    mqtt_client = MqttJsonClient(MqttSettings(client_prefix="weather_collector"))
    mqtt_client.connect()
    mqtt_client.wait_until_connected()

    try:
        while True:
            for site in sites:
                try:
                    current = fetch_site_weather(site)
                    messages = build_weather_messages(site, current)
                except requests.RequestException as exc:
                    error_event = {
                        "timestamp": utc_now(),
                        "device_id": site["device_id"],
                        "site_name": site["name"],
                        "event_type": "weather_fetch_error",
                        "error": str(exc),
                        "source": "weather_collector",
                    }
                    write_jsonl(LOG_DIR / "alerts.jsonl", error_event)
                    print(f"[ERROR] {site['device_id']} Open-Meteo fetch failed: {exc}", file=sys.stderr)
                    continue

                for message in messages:
                    mqtt_client.publish_json(TOPIC_SENSOR_DATA, message)
                    print(
                        f"{message['timestamp']} {message['device_id']} "
                        f"{message['sensor']}={message['value']}{message['unit']}"
                    )

            if once:
                return
            time.sleep(interval)
    except KeyboardInterrupt:
        print("Stopping weather collector...")
    finally:
        mqtt_client.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect Open-Meteo weather data for Bushfire Sentinel.")
    parser.add_argument("--interval", type=int, default=WEATHER_INTERVAL_SECONDS)
    parser.add_argument("--once", action="store_true", help="Fetch once and exit.")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    run(interval=args.interval, once=args.once)
