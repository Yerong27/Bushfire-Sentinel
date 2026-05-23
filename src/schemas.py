"""Shared schema constants for Bushfire Sentinel."""

from __future__ import annotations

TOPIC_SENSOR_DATA = "cps/sensor/data"
TOPIC_RISK = "cps/analysis/risk"
TOPIC_ALERTS = "cps/alerts"
TOPIC_CONTROL = "cps/control"

PROJECT_ID = "bushfire_sentinel"
PRIMARY_SITE_ID = "station_01"

WEATHER_SENSORS = {
    "ambient_temperature": {
        "unit": "C",
        "min": -10,
        "max": 55,
        "open_meteo_key": "temperature_2m",
    },
    "relative_humidity": {
        "unit": "%",
        "min": 0,
        "max": 100,
        "open_meteo_key": "relative_humidity_2m",
    },
    "wind_speed": {
        "unit": "km/h",
        "min": 0,
        "max": 150,
        "open_meteo_key": "wind_speed_10m",
    },
    "precipitation": {
        "unit": "mm",
        "min": 0,
        "max": 300,
        "open_meteo_key": "precipitation",
    },
}

LOCAL_SENSORS = {
    "smoke_level": {"unit": "ppm", "min": 0, "max": 1000},
    "soil_dryness": {"unit": "%", "min": 0, "max": 100},
    "water_tank_level": {"unit": "%", "min": 0, "max": 100},
}

ACTUATOR_FEEDBACK = {
    "sprinkler_status": {
        "unit": "state",
        "allowed": ["ON", "OFF", "FAILED", "NO_RESPONSE"],
    }
}

CONTROL_COMMANDS = ["STANDBY", "SEND_WARNING", "ACTIVATE_SPRINKLER", "EMERGENCY_ALERT"]

FIRE_RISK_LEVELS = ["LOW", "MODERATE", "HIGH", "CRITICAL"]
RESPONSE_CAPACITY_LEVELS = ["NORMAL", "LIMITED", "WEAK", "FAILED"]
SYSTEM_STATUS_LEVELS = [
    "NORMAL",
    "ELEVATED RISK",
    "HIGH RISK",
    "CRITICAL THREAT",
    "RESPONSE FAILURE ALERT",
]
