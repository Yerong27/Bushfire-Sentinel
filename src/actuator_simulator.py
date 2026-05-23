"""Simulate station_01 sprinkler actuator feedback after Node-RED commands."""

from __future__ import annotations

import argparse
import random
import time
from typing import Any

from config import DEFAULT_SCENARIO, load_sites
from mqtt_client import MqttJsonClient, MqttSettings
from schemas import ACTUATOR_FEEDBACK, CONTROL_COMMANDS, PRIMARY_SITE_ID, PROJECT_ID, TOPIC_CONTROL, TOPIC_SENSOR_DATA
from utils import utc_now

AUTO_RANDOM_SCENARIO = "auto_random"
AUTO_RESPONSE_PROBABILITIES = {
    "ON": 0.84,
    "FAILED": 0.11,
    "NO_RESPONSE": 0.05,
}


def primary_site() -> dict[str, Any]:
    for site in load_sites():
        if site["device_id"] == PRIMARY_SITE_ID:
            return site
    raise RuntimeError(f"Missing primary site {PRIMARY_SITE_ID}")


class SprinklerActuator:
    def __init__(self, scenario: str, response_delay: float = 0.8) -> None:
        self.scenario = scenario
        self.response_delay = response_delay
        self.site = primary_site()
        self.current_status = "OFF"
        self.client = MqttJsonClient(
            MqttSettings(client_prefix="actuator_simulator"),
            on_message=self.handle_command,
        )

    def start(self) -> None:
        self.client.connect()
        self.client.wait_until_connected()
        self.client.subscribe(TOPIC_CONTROL)
        print(f"Actuator simulator listening on {TOPIC_CONTROL} scenario={self.scenario}")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print("Stopping actuator simulator...")
        finally:
            self.client.close()

    def handle_command(self, topic: str, payload: dict[str, Any]) -> None:
        if payload.get("project_id") != PROJECT_ID:
            print(f"Ignoring control payload for different project: {payload}")
            return

        command = payload.get("sprinkler_command") or payload.get("command")
        if command not in CONTROL_COMMANDS:
            print(f"Ignoring unsupported control payload: {payload}")
            return

        command_id = payload.get("command_id") or f"cmd-{int(time.time())}"
        print(f"Received {command} command_id={command_id}")
        time.sleep(self.response_delay)

        status = self.decide_status(command)
        feedback = self.build_feedback(command_id, command, status)
        self.current_status = status if status in {"ON", "OFF"} else self.current_status
        self.client.publish_json(TOPIC_SENSOR_DATA, feedback, wait=False)
        print(f"Returned sprinkler_status={status} command_id={command_id}")

    def decide_status(self, command: str) -> str:
        if self.scenario == AUTO_RANDOM_SCENARIO:
            return self.random_status(command)
        if self.scenario == "sprinkler_failure":
            return "FAILED"
        if self.scenario == "no_response":
            return "NO_RESPONSE"
        if command in {"ACTIVATE_SPRINKLER", "EMERGENCY_ALERT"}:
            return "ON"
        if command == "SEND_WARNING":
            return self.current_status
        if command == "STANDBY":
            return "OFF"
        return "OFF"

    def random_status(self, command: str) -> str:
        if command == "SEND_WARNING":
            return self.current_status
        if command == "STANDBY":
            return "OFF"
        if command not in {"ACTIVATE_SPRINKLER", "EMERGENCY_ALERT"}:
            return "OFF"

        roll = random.random()
        cumulative = 0.0
        for status, probability in AUTO_RESPONSE_PROBABILITIES.items():
            cumulative += probability
            if roll <= cumulative:
                return status
        return "ON"

    def build_feedback(self, command_id: str, command: str, status: str) -> dict[str, Any]:
        return {
            "project_id": PROJECT_ID,
            "device_id": self.site["device_id"],
            "site_name": self.site["name"],
            "site_role": self.site["role"],
            "sensor": "sprinkler_status",
            "value": status,
            "unit": ACTUATOR_FEEDBACK["sprinkler_status"]["unit"],
            "timestamp": utc_now(),
            "source": "actuator_simulator",
            "command_id": command_id,
            "last_command": command,
            "response_time_ms": int(self.response_delay * 1000),
            "scenario": self.scenario,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Simulate sprinkler actuator feedback.")
    parser.add_argument("--scenario", default=DEFAULT_SCENARIO)
    parser.add_argument("--response-delay", type=float, default=0.8)
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    SprinklerActuator(args.scenario, args.response_delay).start()
