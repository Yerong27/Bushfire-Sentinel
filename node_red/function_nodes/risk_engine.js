const p = msg.payload;
const state = context.get("latest_state") || {};
const key = `${p.device_id}:${p.sensor}`;
state[key] = p;
context.set("latest_state", state);

if (p.device_id !== "station_01" && !["ambient_temperature", "relative_humidity", "wind_speed", "precipitation"].includes(p.sensor)) {
  return null;
}

function value(deviceId, sensor) {
  const item = state[`${deviceId}:${sensor}`];
  if (!item) return null;
  const raw = item.cleaned_value !== undefined ? item.cleaned_value : item.value;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

function rawValue(deviceId, sensor) {
  const item = state[`${deviceId}:${sensor}`];
  if (!item) return null;
  const n = Number(item.value);
  return Number.isFinite(n) ? n : null;
}

function regionalWeather(sensor, reducer) {
  const values = ["station_01", "station_ref_01", "station_ref_02"]
    .map(id => value(id, sensor))
    .filter(v => v !== null);
  if (values.length === 0) return null;
  return reducer(values);
}

const temp = regionalWeather("ambient_temperature", values => Math.max(...values));
const humidity = regionalWeather("relative_humidity", values => Math.min(...values));
const wind = regionalWeather("wind_speed", values => Math.max(...values));
const rain = regionalWeather("precipitation", values => Math.min(...values));
const nowMs = Date.now();
const smoke = value("station_01", "smoke_level");
const smokeRaw = rawValue("station_01", "smoke_level");
const soil = value("station_01", "soil_dryness");
const tank = value("station_01", "water_tank_level");
const sprinkler = state["station_01:sprinkler_status"] ? state["station_01:sprinkler_status"].value : null;

let smokeSignal = context.get("smoke_signal") || {
  elevated_count: 0,
  high_count: 0,
  critical_count: 0,
  latest_raw: null,
  latest_cleaned: null,
  timestamp_ms: 0
};

if (p.device_id === "station_01" && p.sensor === "smoke_level" && smokeRaw !== null) {
  smokeSignal = {
    elevated_count: smokeRaw >= 60 ? smokeSignal.elevated_count + 1 : 0,
    high_count: smokeRaw >= 150 ? smokeSignal.high_count + 1 : 0,
    critical_count: smokeRaw >= 250 ? smokeSignal.critical_count + 1 : 0,
    latest_raw: smokeRaw,
    latest_cleaned: smoke,
    timestamp_ms: nowMs
  };
  context.set("smoke_signal", smokeSignal);
}

const smokeSignalFresh = nowMs - (smokeSignal.timestamp_ms || 0) <= 90 * 1000;
const sustainedCriticalSmoke = smokeSignalFresh && smokeSignal.critical_count >= 2;
const sustainedHighSmoke = smokeSignalFresh && smokeSignal.high_count >= 2;
const sustainedElevatedSmoke = smokeSignalFresh && smokeSignal.elevated_count >= 3;

let score = 0;
const factors = [];

function add(condition, points, factor) {
  if (condition) {
    score += points;
    factors.push(factor);
  }
}

add(temp !== null && temp >= 35, 20, "high_temperature");
add(temp !== null && temp >= 30 && temp < 35, 10, "warm_temperature");
add(humidity !== null && humidity <= 20, 20, "very_low_humidity");
add(humidity !== null && humidity <= 35 && humidity > 20, 10, "low_humidity");
add(wind !== null && wind >= 45, 20, "high_wind");
add(wind !== null && wind >= 30 && wind < 45, 10, "elevated_wind");
add(rain !== null && rain <= 0.2, 10, "no_recent_precipitation");
add(rain !== null && rain > 0.2 && rain <= 1.0, 5, "low_precipitation");
add(sustainedCriticalSmoke, 40, "critical_smoke");
add(!sustainedCriticalSmoke && sustainedHighSmoke, 30, "high_smoke");
add(!sustainedCriticalSmoke && !sustainedHighSmoke && sustainedElevatedSmoke, 15, "elevated_smoke");
add(soil !== null && soil >= 85, 25, "very_dry_soil");
add(soil !== null && soil >= 65 && soil < 85, 15, "dry_soil");
add(soil !== null && soil >= 50 && soil < 65, 5, "drying_soil");

score = Math.min(score, 100);

let fireLevel = "LOW";
if (score >= 75) fireLevel = "CRITICAL";
else if (score >= 50) fireLevel = "HIGH";
else if (score >= 25) fireLevel = "MODERATE";

let responseCapacity = "NORMAL";
if ((sprinkler === "FAILED" || sprinkler === "NO_RESPONSE") && (fireLevel === "HIGH" || fireLevel === "CRITICAL")) {
  responseCapacity = "FAILED";
} else if (tank !== null && tank <= 5 && (fireLevel === "HIGH" || fireLevel === "CRITICAL")) {
  responseCapacity = "FAILED";
} else if (tank !== null && tank < 30) {
  responseCapacity = "WEAK";
} else if (tank !== null && tank < 60) {
  responseCapacity = "LIMITED";
}

let overall = "NORMAL";
if (responseCapacity === "FAILED" && (fireLevel === "HIGH" || fireLevel === "CRITICAL")) overall = "RESPONSE FAILURE ALERT";
else if (fireLevel === "CRITICAL") overall = "CRITICAL THREAT";
else if (fireLevel === "HIGH") overall = "HIGH RISK";
else if (fireLevel === "MODERATE") overall = "ELEVATED RISK";

let lowRiskStart = context.get("low_risk_start_time");
if (fireLevel === "LOW") {
  if (!lowRiskStart) {
    lowRiskStart = nowMs;
    context.set("low_risk_start_time", lowRiskStart);
  }
} else {
  context.set("low_risk_start_time", null);
  lowRiskStart = null;
}

let candidateCommand = null;
if (overall === "RESPONSE FAILURE ALERT" || fireLevel === "CRITICAL") candidateCommand = "EMERGENCY_ALERT";
else if (fireLevel === "HIGH" && responseCapacity !== "FAILED") candidateCommand = "ACTIVATE_SPRINKLER";
else if (
  fireLevel === "MODERATE"
  && (
    score >= 35
    || factors.includes("high_smoke")
    || factors.includes("critical_smoke")
    || factors.includes("dry_soil")
    || factors.includes("very_dry_soil")
  )
) candidateCommand = "SEND_WARNING";
else if (fireLevel === "LOW" && lowRiskStart && (nowMs - lowRiskStart >= 10 * 60 * 1000)) candidateCommand = "STANDBY";

const commandCooldownMs = {
  STANDBY: Infinity,
  SEND_WARNING: 10 * 60 * 1000,
  ACTIVATE_SPRINKLER: 2 * 60 * 1000,
  EMERGENCY_ALERT: 60 * 1000
};
const commandPriority = {
  STANDBY: 0,
  SEND_WARNING: 1,
  ACTIVATE_SPRINKLER: 2,
  EMERGENCY_ALERT: 3
};
const lastControl = context.get("last_control") || {};
const lastCommandTimes = context.get("last_command_times") || {};
const currentDecision = `${fireLevel}|${overall}|${candidateCommand || "NONE"}`;
const previousDecision = lastControl.decision || null;
const previousCommand = lastControl.command || null;
const cooldownMs = candidateCommand ? commandCooldownMs[candidateCommand] : Infinity;
const previousPriority = commandPriority[lastControl.command] || 0;
const currentPriority = candidateCommand ? commandPriority[candidateCommand] : 0;
const escalated = Boolean(previousCommand) && currentPriority > previousPriority;
const lastIssuedAt = candidateCommand ? lastCommandTimes[candidateCommand] || 0 : 0;
const commandNeverIssued = lastIssuedAt === 0;
const commandCooldownExpired = commandNeverIssued || nowMs - lastIssuedAt >= cooldownMs;
const standbyChanged = candidateCommand === "STANDBY" && previousCommand !== "STANDBY";
const commandAllowedByPolicy = candidateCommand === "STANDBY"
  ? standbyChanged
  : escalated || commandCooldownExpired;

let command = null;
if (candidateCommand && commandAllowedByPolicy) {
  command = candidateCommand;
  lastCommandTimes[command] = nowMs;
  context.set("last_command_times", lastCommandTimes);
  context.set("last_control", {
    command,
    decision: currentDecision,
    timestamp_ms: nowMs
  });
} else if (!candidateCommand && (previousCommand !== null || previousDecision !== currentDecision)) {
  context.set("last_control", {
    command: null,
    decision: currentDecision,
    timestamp_ms: nowMs
  });
}

const commandId = command ? `cmd-${nowMs}` : null;
const risk = {
  project_id: "bushfire_sentinel",
  timestamp: new Date().toISOString(),
  device_id: "station_01",
  fire_risk_score: score,
  fire_risk_level: fireLevel,
  response_capacity_status: responseCapacity,
  overall_system_status: overall,
  risk_factors: factors,
  weather_context: {
    max_temperature: temp,
    min_humidity: humidity,
    max_wind_speed: wind,
    min_precipitation: rain
  },
  local_context: {
    smoke_level: smoke,
    smoke_raw: smokeRaw,
    smoke_sustained_count: smokeSignal.elevated_count,
    soil_dryness: soil,
    water_tank_level: tank,
    sprinkler_status: sprinkler
  },
  candidate_command: candidateCommand,
  recommended_command: command,
  command_id: commandId
};

const alert = (fireLevel === "HIGH" || fireLevel === "CRITICAL" || responseCapacity === "FAILED")
  ? {
    project_id: "bushfire_sentinel",
    timestamp: risk.timestamp,
    device_id: "station_01",
    alert_type: responseCapacity === "FAILED" ? "RESPONSE_CAPACITY" : "FIRE_RISK",
    severity: fireLevel === "CRITICAL" || responseCapacity === "FAILED" ? "CRITICAL" : "HIGH",
    message: `${overall}: fire risk ${fireLevel}, response capacity ${responseCapacity}`,
    command
  }
  : null;

const control = command
  ? {
    project_id: "bushfire_sentinel",
    timestamp: risk.timestamp,
    device_id: "station_01",
    command_id: commandId,
    sprinkler_command: command,
    reason: `${fireLevel} fire risk with response capacity ${responseCapacity}`
  }
  : null;

return [
  { payload: risk },
  alert ? { payload: alert } : null,
  control ? { payload: control } : null
];
