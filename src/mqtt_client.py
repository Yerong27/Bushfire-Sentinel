"""MQTT helper adapted from the classroom activity publisher."""

from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass
from typing import Any, Callable

try:
    import paho.mqtt.client as mqtt
except ImportError:  # Allows non-MQTT logic tests before dependencies are installed.
    mqtt = None

from config import MQTT_BROKER, MQTT_KEEPALIVE, MQTT_PORT


@dataclass
class MqttSettings:
    broker: str = MQTT_BROKER
    port: int = MQTT_PORT
    keepalive: int = MQTT_KEEPALIVE
    client_prefix: str = "bushfire_sentinel"


class MqttJsonClient:
    def __init__(
        self,
        settings: MqttSettings | None = None,
        on_message: Callable[[str, dict[str, Any]], None] | None = None,
    ) -> None:
        self.settings = settings or MqttSettings()
        self.connected = False
        self.on_message_handler = on_message
        self.client = self._build_client()

    def _build_client(self) -> mqtt.Client:
        if mqtt is None:
            raise RuntimeError("Missing dependency paho-mqtt. Install with: pip install -r requirements.txt")
        client_id = f"{self.settings.client_prefix}_{random.randint(1000, 9999)}"
        try:
            client = mqtt.Client(
                mqtt.CallbackAPIVersion.VERSION2,
                client_id=client_id,
                protocol=mqtt.MQTTv311,
            )
        except AttributeError:
            client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv311)

        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        client.on_message = self._on_message
        client.reconnect_delay_set(min_delay=1, max_delay=30)
        return client

    def _on_connect(self, client: mqtt.Client, userdata: Any, flags: Any, reason_code: Any, properties: Any = None) -> None:
        code_value = getattr(reason_code, "value", reason_code)
        self.connected = code_value == 0 or str(reason_code).lower() == "success"
        print(f"Connected to {self.settings.broker}:{self.settings.port} rc={reason_code}")

    def _on_disconnect(self, client: mqtt.Client, userdata: Any, *args: Any) -> None:
        self.connected = False
        reason = args[1] if len(args) >= 2 else (args[0] if args else None)
        print(f"Disconnected from broker rc={reason}")

    def _on_message(self, client: mqtt.Client, userdata: Any, message: mqtt.MQTTMessage) -> None:
        if not self.on_message_handler:
            return
        raw = message.payload.decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"raw": raw, "decode_error": True}
        self.on_message_handler(message.topic, payload)

    def connect(self) -> None:
        self.client.connect_async(
            self.settings.broker,
            self.settings.port,
            self.settings.keepalive,
        )
        self.client.loop_start()

    def wait_until_connected(self, timeout_seconds: int = 15) -> bool:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if self.connected:
                return True
            print("Waiting for MQTT connection...")
            time.sleep(1)
        return self.connected

    def subscribe(self, topic: str) -> None:
        self.client.subscribe(topic, qos=0)

    def publish_json(self, topic: str, payload: dict[str, Any], wait: bool = True) -> bool:
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
        info = self.client.publish(topic, encoded, qos=0, retain=False)
        if wait:
            info.wait_for_publish()
        ok = info.rc == mqtt.MQTT_ERR_SUCCESS
        if not ok:
            print(f"Publish failed for {topic}: rc={info.rc}")
        return ok

    def close(self) -> None:
        self.client.loop_stop()
        self.client.disconnect()
