const p = msg.payload;
const now = Date.now();
const key = `${p.device_id}:${p.sensor}`;
const previous = context.get(`${key}:previous`);
const frozen = context.get(`${key}:frozen`) || { value: null, count: 0 };
const lastSeen = context.get("last_seen") || {};
const anomalies = [];

lastSeen[key] = now;
context.set("last_seen", lastSeen);

const numericValue = Number(p.cleaned_value !== undefined ? p.cleaned_value : p.value);
if (Number.isFinite(numericValue) && previous !== undefined) {
  const delta = Math.abs(numericValue - Number(previous));
  if (p.sensor === "smoke_level" && delta >= 80) {
    anomalies.push({ type: "sudden_spike", sensor: p.sensor, severity: "HIGH", delta });
  }
  if (p.sensor === "wind_speed" && delta >= 35) {
    anomalies.push({ type: "extreme_jump", sensor: p.sensor, severity: "MEDIUM", delta });
  }
}

const frozenEligible = p.source !== "open_meteo" && p.sensor !== "sprinkler_status";
if (frozenEligible) {
  if (p.value === frozen.value) {
    frozen.count += 1;
  } else {
    frozen.value = p.value;
    frozen.count = 1;
  }
  context.set(`${key}:frozen`, frozen);

  if (frozen.count >= 5) {
    anomalies.push({ type: "frozen_value", sensor: p.sensor, severity: "MEDIUM", repeat_count: frozen.count });
  }
}

if (Number.isFinite(numericValue)) {
  context.set(`${key}:previous`, numericValue);
}

const expected = [
  "station_01:ambient_temperature",
  "station_01:relative_humidity",
  "station_01:wind_speed",
  "station_01:precipitation",
  "station_01:smoke_level",
  "station_01:soil_dryness",
  "station_01:water_tank_level"
];

for (const expectedKey of expected) {
  if (lastSeen[expectedKey] && now - lastSeen[expectedKey] > 90000) {
    anomalies.push({ type: "missing_stream", sensor: expectedKey.split(":")[1], severity: "HIGH", age_ms: now - lastSeen[expectedKey] });
  }
}

if (anomalies.length === 0) {
  return [msg, null];
}

const alert = {
  timestamp: new Date().toISOString(),
  device_id: p.device_id,
  event_type: "anomaly",
  severity: anomalies.some(a => a.severity === "HIGH") ? "HIGH" : "MEDIUM",
  anomalies,
  source_message: p
};

context.set("latest_anomaly", alert);
return [msg, { payload: alert }];
