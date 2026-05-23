"""Simulate station_01 local site sensors for controlled demonstrations."""

from __future__ import annotations

import argparse
import random
import time
from typing import Any

from config import DEFAULT_SCENARIO, PUBLISH_INTERVAL_SECONDS, load_scenarios, load_sites
from mqtt_client import MqttJsonClient, MqttSettings
from schemas import LOCAL_SENSORS, PRIMARY_SITE_ID, PROJECT_ID, TOPIC_SENSOR_DATA, WEATHER_SENSORS
from utils import utc_now

AUTO_RANDOM_SCENARIO = "auto_random"
AUTO_EVENT_PROBABILITIES = {
    "smoke_spike": 0.015,
    "smoke_incident": 0.025,
    "dry_soil_build_up": 0.04,
    "water_tank_drop": 0.03,
    "missing_value": 0.01,
    "unrealistic_value": 0.01,
    "frozen_sensor": 0.015,
    "sensor_dropout": 0.01,
}

RAIN_MEMORY_SECONDS = 15 * 60
SMOKE_INCIDENT_PROFILES = {
    "elevated_smoke_event": {
        "duration_seconds": (40, 90),
        "smoke_level": (60, 140),
        "soil_scenario": "rising_weather_risk",
        "weight": 0.60,
    },
    "high_smoke_event": {
        "duration_seconds": (30, 60),
        "smoke_level": (150, 240),
        "soil_scenario": "high_fire_demo",
        "weight": 0.30,
    },
    "critical_smoke_event": {
        "duration_seconds": (20, 45),
        "smoke_level": (250, 350),
        "soil_scenario": "critical_fire_demo",
        "weight": 0.10,
    },
}


def primary_site() -> dict[str, Any]:
    for site in load_sites():
        if site["device_id"] == PRIMARY_SITE_ID:
            return site
    raise RuntimeError(f"Missing primary site {PRIMARY_SITE_ID}")


def sensor_value(scenario: dict[str, Any], sensor: str) -> float:
    low, high = scenario[sensor]
    if low == high:
        return float(low)
    return round(random.uniform(float(low), float(high)), 2)


def ranged_value(bounds: tuple[float, float]) -> float:
    low, high = bounds
    if low == high:
        return float(low)
    return round(random.uniform(float(low), float(high)), 2)


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def update_latest_weather(latest_weather: dict[str, float], payload: dict[str, Any]) -> None:
    if payload.get("project_id") != PROJECT_ID:
        return
    if payload.get("source") != "open_meteo":
        return
    if payload.get("device_id") != PRIMARY_SITE_ID:
        return
    sensor = payload.get("sensor")
    if sensor not in WEATHER_SENSORS:
        return
    try:
        latest_weather[sensor] = float(payload["value"])
    except (TypeError, ValueError):
        return


def update_soil_dryness_state(
    soil_state: dict[str, Any],
    scenarios: dict[str, dict[str, Any]],
    source_scenario: str,
    latest_weather: dict[str, float],
    now_seconds: float,
) -> tuple[float, bool, bool]:
    """Update slow-changing local flammability state using scenario pressure and recent weather."""
    if soil_state.get("value") is None:
        low, high = scenarios["normal"]["soil_dryness"]
        soil_state["value"] = random.uniform(float(low), float(high))

    previous = float(soil_state["value"])
    rain = latest_weather.get("precipitation")
    humidity = latest_weather.get("relative_humidity")
    temperature = latest_weather.get("ambient_temperature")
    wind = latest_weather.get("wind_speed")
    last_rain = soil_state.get("last_effective_rain_timestamp")

    if rain is not None and rain > 0.2:
        soil_state["last_effective_rain_timestamp"] = now_seconds
        last_rain = now_seconds

    recent_rain_active = bool(last_rain and now_seconds - float(last_rain) <= RAIN_MEMORY_SECONDS)
    adjusted = previous + random.uniform(-1.0, 1.0)

    target_low, target_high = scenarios.get(source_scenario, scenarios["normal"])["soil_dryness"]
    if previous < float(target_low):
        adjusted += random.uniform(0.5, 1.5)
    elif previous > float(target_high):
        adjusted -= random.uniform(0.5, 1.5)

    if rain is not None:
        if rain > 0.2:
            adjusted -= random.uniform(2.0, 5.0)
        elif recent_rain_active:
            adjusted -= random.uniform(1.0, 2.5)

    if humidity is not None and humidity >= 85:
        adjusted -= random.uniform(1.0, 2.0)
    elif humidity is not None and humidity >= 70:
        adjusted -= random.uniform(0.5, 1.5)

    no_recent_rain = not recent_rain_active and (rain is None or rain <= 0.2)
    warm_or_windy = (
        (temperature is not None and temperature >= 25)
        or (wind is not None and wind >= 20)
    )
    if no_recent_rain and warm_or_windy:
        adjusted += random.uniform(1.0, 3.0)

    if source_scenario == "rising_weather_risk":
        adjusted += random.uniform(3.0, 6.0)
    elif source_scenario == "high_fire_demo":
        adjusted += random.uniform(5.0, 8.0)
    elif source_scenario == "critical_fire_demo":
        adjusted += random.uniform(10.0, 15.0)

    upper_limit = 100.0
    if source_scenario in {"rising_weather_risk", "high_fire_demo"}:
        upper_limit = 90.0

    adjusted = round(clamp(adjusted, 0, upper_limit), 2)
    soil_state["value"] = adjusted
    return adjusted, adjusted != round(previous, 2), recent_rain_active


def weather_adjusted_soil_dryness(value: float, latest_weather: dict[str, float]) -> float:
    """Legacy helper for one-off calculations; stateful updates are used during simulation."""
    adjusted = value
    rain = latest_weather.get("precipitation")
    humidity = latest_weather.get("relative_humidity")
    temperature = latest_weather.get("ambient_temperature")
    wind = latest_weather.get("wind_speed")

    if rain is not None:
        if rain >= 1.0:
            adjusted -= 20
        elif rain >= 0.2:
            adjusted -= 10

    if humidity is not None:
        if humidity >= 85:
            adjusted -= 12
        elif humidity >= 70:
            adjusted -= 6
        elif humidity <= 35:
            adjusted += 8

    if temperature is not None:
        if temperature >= 30:
            adjusted += 10
        elif temperature >= 25:
            adjusted += 5

    if wind is not None and wind >= 30:
        adjusted += 5

    return round(clamp(adjusted, 0, 100), 2)


def build_messages(
    site: dict[str, Any],
    scenario_name: str,
    scenario: dict[str, Any],
    cycle: int,
    scenarios: dict[str, dict[str, Any]],
    soil_state: dict[str, Any],
    latest_weather: dict[str, float],
) -> list[dict[str, Any]]:
    timestamp = utc_now()
    now_seconds = time.time()
    messages = []

    for sensor, spec in LOCAL_SENSORS.items():
        if scenario_name == "sensor_dropout" and sensor == "smoke_level" and cycle > 3:
            continue

        value = sensor_value(scenario, sensor)
        weather_adjusted = False
        recent_rain_active = False

        if sensor == "soil_dryness" and scenario_name not in {"unrealistic_value", "frozen_sensor"}:
            value, weather_adjusted, recent_rain_active = update_soil_dryness_state(
                soil_state,
                scenarios,
                scenario_name,
                latest_weather,
                now_seconds,
            )

        message: dict[str, Any] = {
            "project_id": PROJECT_ID,
            "device_id": site["device_id"],
            "site_name": site["name"],
            "site_role": site["role"],
            "sensor": sensor,
            "value": value,
            "unit": spec["unit"],
            "timestamp": timestamp,
            "source": "simulator",
            "scenario": scenario_name,
        }

        if sensor == "soil_dryness":
            message["weather_adjusted"] = weather_adjusted
            message["recent_rain_active"] = recent_rain_active

        if scenario_name == "missing_value" and sensor == "smoke_level" and cycle % 4 == 0:
            message.pop("value")

        messages.append(message)

    return messages


def random_event_flags() -> dict[str, bool]:
    return {
        event_name: random.random() < probability
        for event_name, probability in AUTO_EVENT_PROBABILITIES.items()
    }


def choose_smoke_incident_profile() -> str:
    roll = random.random()
    cumulative = 0.0
    for name, profile in SMOKE_INCIDENT_PROFILES.items():
        cumulative += float(profile["weight"])
        if roll <= cumulative:
            return name
    return "elevated_smoke_event"


def update_smoke_incident_state(incident_state: dict[str, Any], now_seconds: float, trigger: bool) -> dict[str, Any] | None:
    active = incident_state.get("active")
    if active and now_seconds < float(active["end_time"]):
        return active

    if active and now_seconds >= float(active["end_time"]):
        incident_state["active"] = None
        active = None

    if not trigger:
        return None

    profile_name = choose_smoke_incident_profile()
    profile = SMOKE_INCIDENT_PROFILES[profile_name]
    duration_low, duration_high = profile["duration_seconds"]
    active = {
        "profile": profile_name,
        "end_time": now_seconds + random.uniform(float(duration_low), float(duration_high)),
        "smoke_level": profile["smoke_level"],
        "soil_scenario": profile["soil_scenario"],
    }
    incident_state["active"] = active
    return active


def auto_random_messages(
    site: dict[str, Any],
    scenarios: dict[str, dict[str, Any]],
    cycle: int,
    frozen_values: dict[str, float],
    soil_state: dict[str, Any],
    incident_state: dict[str, Any],
    latest_weather: dict[str, float],
) -> list[dict[str, Any]]:
    flags = random_event_flags()
    timestamp = utc_now()
    now_seconds = time.time()
    smoke_incident = update_smoke_incident_state(incident_state, now_seconds, flags["smoke_incident"])
    messages = []

    for sensor, spec in LOCAL_SENSORS.items():
        if flags["sensor_dropout"] and sensor == "smoke_level":
            continue

        weather_adjusted = False
        recent_rain_active = False
        source_scenario = "normal"
        smoke_event_profile = smoke_incident["profile"] if smoke_incident else None

        if sensor == "smoke_level" and smoke_incident:
            source_scenario = smoke_incident["profile"]
        elif sensor == "smoke_level" and flags["smoke_spike"]:
            source_scenario = "smoke_spike"
        elif sensor == "water_tank_level" and flags["water_tank_drop"]:
            source_scenario = "water_tank_drop"
        elif sensor == "soil_dryness" and smoke_incident:
            source_scenario = smoke_incident["soil_scenario"]
        elif sensor == "soil_dryness" and flags["dry_soil_build_up"]:
            source_scenario = "rising_weather_risk"

        if flags["unrealistic_value"]:
            source_scenario = "unrealistic_value"

        if flags["frozen_sensor"]:
            frozen_values.setdefault(sensor, sensor_value(scenarios["frozen_sensor"], sensor))
            value = frozen_values[sensor]
            source_scenario = "frozen_sensor"
        else:
            frozen_values.pop(sensor, None)
            if sensor == "soil_dryness" and source_scenario != "unrealistic_value":
                value, weather_adjusted, recent_rain_active = update_soil_dryness_state(
                    soil_state,
                    scenarios,
                    source_scenario,
                    latest_weather,
                    now_seconds,
                )
            elif sensor == "smoke_level" and smoke_incident:
                value = ranged_value(smoke_incident["smoke_level"])
            else:
                value = sensor_value(scenarios[source_scenario], sensor)

        message: dict[str, Any] = {
            "project_id": PROJECT_ID,
            "device_id": site["device_id"],
            "site_name": site["name"],
            "site_role": site["role"],
            "sensor": sensor,
            "value": value,
            "unit": spec["unit"],
            "timestamp": timestamp,
            "source": "simulator",
            "scenario": AUTO_RANDOM_SCENARIO,
            "active_event": source_scenario,
            "smoke_event_profile": smoke_event_profile,
            "event_flags": flags,
        }

        if sensor == "soil_dryness":
            message["weather_adjusted"] = weather_adjusted
            message["recent_rain_active"] = recent_rain_active

        if flags["missing_value"] and sensor == "smoke_level":
            message.pop("value")

        messages.append(message)

    return messages


def run(scenario_name: str, interval: int, once: bool = False) -> None:
    scenarios = load_scenarios()
    if scenario_name not in scenarios and scenario_name != AUTO_RANDOM_SCENARIO:
        choices = sorted([*scenarios.keys(), AUTO_RANDOM_SCENARIO])
        raise ValueError(f"Unknown scenario {scenario_name}. Choose one of: {', '.join(choices)}")

    scenario = scenarios.get(scenario_name)
    site = primary_site()
    latest_weather: dict[str, float] = {}

    def handle_weather_message(_topic: str, payload: dict[str, Any]) -> None:
        update_latest_weather(latest_weather, payload)

    mqtt_client = MqttJsonClient(
        MqttSettings(client_prefix="site_sensor_simulator"),
        on_message=handle_weather_message,
    )
    mqtt_client.connect()
    mqtt_client.wait_until_connected()
    mqtt_client.subscribe(TOPIC_SENSOR_DATA)

    cycle = 0
    frozen_values: dict[str, float] = {}
    soil_state: dict[str, Any] = {}
    incident_state: dict[str, Any] = {}
    try:
        while True:
            cycle += 1
            if scenario_name == AUTO_RANDOM_SCENARIO:
                messages = auto_random_messages(
                    site,
                    scenarios,
                    cycle,
                    frozen_values,
                    soil_state,
                    incident_state,
                    latest_weather,
                )
            else:
                messages = build_messages(site, scenario_name, scenario, cycle, scenarios, soil_state, latest_weather)

            for message in messages:
                if message.get("sensor") == "soil_dryness" and "weather_adjusted" not in message:
                    message["weather_adjusted"] = False
                mqtt_client.publish_json(TOPIC_SENSOR_DATA, message)
                value = message.get("value", "<missing>")
                active_event = message.get("active_event", scenario_name)
                print(
                    f"{message['timestamp']} {message['sensor']}={value}{message['unit']} "
                    f"scenario={scenario_name} active_event={active_event}"
                )

            if once:
                return
            time.sleep(interval)
    except KeyboardInterrupt:
        print("Stopping site sensor simulator...")
    finally:
        mqtt_client.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Simulate station_01 local Bushfire Sentinel sensors.")
    parser.add_argument("--scenario", default=DEFAULT_SCENARIO)
    parser.add_argument("--interval", type=int, default=PUBLISH_INTERVAL_SECONDS)
    parser.add_argument("--once", action="store_true", help="Publish one cycle and exit.")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    run(scenario_name=args.scenario, interval=args.interval, once=args.once)
