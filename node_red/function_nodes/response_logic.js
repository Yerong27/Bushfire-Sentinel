const p = msg.payload;

if (p.sensor !== "sprinkler_status") {
  return null;
}

msg.payload = {
  timestamp: new Date().toISOString(),
  event_type: "actuator_feedback",
  device_id: p.device_id,
  command_id: p.command_id,
  last_command: p.last_command,
  sprinkler_status: p.value,
  response_time_ms: p.response_time_ms,
  scenario: p.scenario,
  source: p.source
};

return msg;
