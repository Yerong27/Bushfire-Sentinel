const ranges = {
  ambient_temperature: { min: -10, max: 55 },
  relative_humidity: { min: 0, max: 100 },
  wind_speed: { min: 0, max: 150 },
  precipitation: { min: 0, max: 300 },
  smoke_level: { min: 0, max: 1000 },
  soil_dryness: { min: 0, max: 100 },
  water_tank_level: { min: 0, max: 100 }
};

const allowedSprinkler = ["ON", "OFF", "FAILED", "NO_RESPONSE"];
const expectedProjectId = "bushfire_sentinel";
const p = msg.payload || {};
const errors = [];

for (const field of ["project_id", "device_id", "sensor", "timestamp", "source"]) {
  if (p[field] === undefined || p[field] === null || p[field] === "") {
    errors.push(`missing_${field}`);
  }
}

if (p.project_id !== undefined && p.project_id !== expectedProjectId) {
  errors.push("invalid_project_id");
}

if (p.value === undefined || p.value === null || p.value === "") {
  errors.push("missing_value");
}

if (p.sensor === "sprinkler_status") {
  if (!allowedSprinkler.includes(String(p.value))) {
    errors.push("invalid_sprinkler_feedback");
  }
  if (p.source !== "actuator_simulator") {
    errors.push("sprinkler_status_must_be_actuator_feedback");
  }
} else if (ranges[p.sensor]) {
  const value = Number(p.value);
  if (!Number.isFinite(value)) {
    errors.push("non_numeric_value");
  } else if (value < ranges[p.sensor].min || value > ranges[p.sensor].max) {
    errors.push("unrealistic_value");
  } else {
    p.value = value;
  }
} else if (p.sensor !== undefined) {
  errors.push("unknown_sensor");
}

if (errors.length > 0) {
  msg.payload = {
    timestamp: new Date().toISOString(),
    event_type: "validation_reject",
    severity: "WARN",
    errors,
    original: p
  };
  return [null, msg];
}

p.validation_status = "valid";
msg.payload = p;
return [msg, null];
