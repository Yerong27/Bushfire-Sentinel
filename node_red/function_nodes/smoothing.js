const smoothingSensors = ["ambient_temperature", "relative_humidity", "wind_speed", "smoke_level"];
const p = msg.payload;

if (!smoothingSensors.includes(p.sensor)) {
  return msg;
}

const key = `${p.device_id}:${p.sensor}`;
const window = context.get(key) || [];
window.push(Number(p.value));
while (window.length > 5) {
  window.shift();
}

context.set(key, window);
p.cleaned_value = Number((window.reduce((sum, item) => sum + item, 0) / window.length).toFixed(2));
p.smoothing_method = "moving_average_5";
p.smoothing_window_size = window.length;
msg.payload = p;
return msg;
