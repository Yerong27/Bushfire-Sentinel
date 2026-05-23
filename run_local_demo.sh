#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-}"
SCENARIO="${1:-auto_random}"
ACTUATOR_SCENARIO="${2:-auto_random}"
WEATHER_INTERVAL="${WEATHER_INTERVAL:-30}"
SENSOR_INTERVAL="${SENSOR_INTERVAL:-10}"
RUN_LOG_DIR="$ROOT_DIR/logs/runtime"
PID_FILE="$ROOT_DIR/logs/runtime/demo_pids.txt"
BUSHFIRE_SENTINEL_LOG_DIR="${BUSHFIRE_SENTINEL_LOG_DIR:-$ROOT_DIR/logs}"
NODE_RED_URL="${NODE_RED_URL:-http://127.0.0.1:1880}"
SPLUNK_URL="${SPLUNK_URL:-http://127.0.0.1:8000}"
MQTT_BROKER="${MQTT_BROKER:-broker.hivemq.com}"
MQTT_PORT="${MQTT_PORT:-1883}"
START_NODE_RED="${START_NODE_RED:-1}"
REQUIRE_NODE_RED="${REQUIRE_NODE_RED:-1}"
NODE_RED_CMD="${NODE_RED_CMD:-node-red}"
DEPLOY_NODE_RED_FLOW="${DEPLOY_NODE_RED_FLOW:-0}"
VERIFY_NODE_RED_FLOW="${VERIFY_NODE_RED_FLOW:-1}"
NODE_RED_FLOW_FILE="${NODE_RED_FLOW_FILE:-$ROOT_DIR/node_red/bushfire_sentinel_flow.json}"

mkdir -p "$RUN_LOG_DIR"
mkdir -p "$BUSHFIRE_SENTINEL_LOG_DIR"
export BUSHFIRE_SENTINEL_LOG_DIR

display_path() {
  local path="$1"
  case "$path" in
    "$ROOT_DIR")
      printf '.\n'
      ;;
    "$ROOT_DIR"/*)
      printf './%s\n' "${path#"$ROOT_DIR"/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

resolve_python() {
  if [[ -n "${PYTHON_BIN}" ]]; then
    if [[ "${PYTHON_BIN}" == */* ]]; then
      [[ -x "${PYTHON_BIN}" ]] && printf '%s\n' "${PYTHON_BIN}" && return 0
    elif command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
      command -v "${PYTHON_BIN}"
      return 0
    fi
    echo "Python runtime not found or not executable: ${PYTHON_BIN}" >&2
    return 1
  fi

  if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    printf '%s\n' "$ROOT_DIR/.venv/bin/python"
    return 0
  fi

  if [[ -x "$ROOT_DIR/../.venv/bin/python" ]]; then
    printf '%s\n' "$ROOT_DIR/../.venv/bin/python"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi

  echo "Python runtime not found. Install Python 3 or set PYTHON_BIN=/path/to/python." >&2
  return 1
}

check_python_requirements() {
  if "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import paho.mqtt.client
import requests
PY
  then
    return 0
  fi

  echo "Python dependencies are missing for: $PYTHON_BIN" >&2
  echo "Install them with:" >&2
  echo "  python3 -m venv .venv" >&2
  echo "  source .venv/bin/activate" >&2
  echo "  pip install -r requirements.txt" >&2
  echo "Or rerun with PYTHON_BIN=/path/to/python that already has the dependencies." >&2
  exit 1
}

PYTHON_BIN="$(resolve_python)"
check_python_requirements

find_existing_demo_pids() {
  ps -axo pid,command 2>/dev/null | awk -v self="$$" '
    $1 != self && index($0, "src/main.py") { print $1 }
  ' | sort -u || true
}

guard_against_duplicate_demo() {
  local existing_pids
  existing_pids="$(find_existing_demo_pids)"
  if [[ -z "$existing_pids" ]]; then
    : > "$PID_FILE"
    return
  fi

  echo "A Bushfire Sentinel Python demo is already running:" >&2
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    echo "  pid=$pid" >&2
  done <<< "$existing_pids"
  echo >&2
  echo "Stop it first, then start a fresh run:" >&2
  echo "  ./stop_local_demo.sh" >&2
  echo "  ./run_local_demo.sh" >&2
  exit 1
}

guard_against_duplicate_demo

start_process() {
  local name="$1"
  shift
  local log_file="$RUN_LOG_DIR/${name}.log"
  echo "Starting $name ..."
  (
    cd "$ROOT_DIR"
    "$@"
  ) > "$log_file" 2>&1 &
  local pid=$!
  echo "$pid $name" >> "$PID_FILE"
  echo "  pid=$pid log=$(display_path "$log_file")"
}

check_url() {
  local label="$1"
  local url="$2"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      echo "  $label: $url  [reachable]"
    else
      echo "  $label: $url  [not reachable from this shell]"
    fi
  else
    echo "  $label: $url"
  fi
}

url_reachable() {
  local url="$1"
  command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "$url" >/dev/null 2>&1
}

start_node_red_if_needed() {
  if [[ "$START_NODE_RED" != "1" ]]; then
    echo "Node-RED auto-start disabled by START_NODE_RED=$START_NODE_RED"
    return
  fi

  if url_reachable "$NODE_RED_URL"; then
    echo "Node-RED already reachable at $NODE_RED_URL"
    return
  fi

  if ! command -v "$NODE_RED_CMD" >/dev/null 2>&1; then
    echo "Node-RED command not found: $NODE_RED_CMD" >&2
    echo "Install Node-RED or set NODE_RED_CMD=/path/to/node-red." >&2
    exit 1
  fi

  local log_file="$RUN_LOG_DIR/node_red.log"
  echo "Starting Node-RED ..."
  (
    cd "$ROOT_DIR"
    "$NODE_RED_CMD"
  ) > "$log_file" 2>&1 &
  local pid=$!
  echo "$pid node_red" >> "$PID_FILE"
  echo "  pid=$pid log=$(display_path "$log_file")"

  local attempt
  for attempt in {1..10}; do
    if url_reachable "$NODE_RED_URL"; then
      echo "  Node-RED is ready at $NODE_RED_URL"
      return
    fi
    sleep 1
  done

  echo "  Node-RED did not become reachable yet. Check: $log_file"
  if [[ "$REQUIRE_NODE_RED" == "1" ]]; then
    echo "Node-RED is required for the dashboard demo. Set REQUIRE_NODE_RED=0 to run Python publishers only." >&2
    exit 1
  fi
}

deploy_node_red_flow_if_needed() {
  if [[ "$DEPLOY_NODE_RED_FLOW" != "1" ]]; then
    echo "Node-RED flow auto-deploy disabled by DEPLOY_NODE_RED_FLOW=$DEPLOY_NODE_RED_FLOW"
    return
  fi

  if ! url_reachable "$NODE_RED_URL"; then
    echo "Node-RED is not reachable, skipping flow auto-deploy."
    return
  fi

  echo "Deploying Bushfire Sentinel Node-RED flow ..."
  "$PYTHON_BIN" "$ROOT_DIR/scripts/deploy_node_red_flow.py" \
    --node-red-url "$NODE_RED_URL" \
    --flow-file "$NODE_RED_FLOW_FILE"
}

verify_node_red_flow_if_needed() {
  if [[ "$VERIFY_NODE_RED_FLOW" != "1" ]]; then
    return
  fi

  if ! url_reachable "$NODE_RED_URL"; then
    echo "Node-RED is not reachable, cannot verify the project flow." >&2
    exit 1
  fi

  if "$PYTHON_BIN" "$ROOT_DIR/scripts/deploy_node_red_flow.py" \
    --node-red-url "$NODE_RED_URL" \
    --verify-only >/dev/null; then
    echo "Node-RED Bushfire Sentinel flow verified."
    return
  fi

  echo "Node-RED is running, but the Bushfire Sentinel flow is not active." >&2
  echo "Run one-time setup first:" >&2
  echo "  ./setup/setup_local_demo.sh" >&2
  echo "Or deploy during this launch with:" >&2
  echo "  DEPLOY_NODE_RED_FLOW=1 ./run_local_demo.sh" >&2
  exit 1
}

jsonl_size() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -c < "$file" | tr -d ' '
  else
    echo 0
  fi
}

check_jsonl_progress() {
  local sensor_log="$BUSHFIRE_SENTINEL_LOG_DIR/sensor_data.jsonl"
  local risk_log="$BUSHFIRE_SENTINEL_LOG_DIR/risk_analysis.jsonl"
  local before_sensor="$1"
  local before_risk="$2"
  local wait_seconds="${3:-25}"

  echo "Checking JSONL output for ${wait_seconds}s ..."
  sleep "$wait_seconds"

  local after_sensor after_risk
  after_sensor="$(jsonl_size "$sensor_log")"
  after_risk="$(jsonl_size "$risk_log")"

  if (( after_sensor > before_sensor && after_risk > before_risk )); then
    echo "  JSONL output is active."
    return
  fi

  echo "  warning: JSONL output did not grow as expected." >&2
  echo "  sensor_data.jsonl: $before_sensor -> $after_sensor bytes" >&2
  echo "  risk_analysis.jsonl: $before_risk -> $after_risk bytes" >&2
  echo "  Python publishers may be running, but Node-RED may not be receiving/writing data." >&2
  echo "  Check Node-RED at $NODE_RED_URL and rerun: ./setup/setup_local_demo.sh" >&2
}

echo "Bushfire Sentinel demo"
echo "Scenario: sensors=$SCENARIO actuator=$ACTUATOR_SCENARIO"
echo
echo "Checking services:"
check_url "Node-RED editor" "$NODE_RED_URL"
check_url "Splunk web UI" "$SPLUNK_URL"
echo

start_node_red_if_needed
deploy_node_red_flow_if_needed
verify_node_red_flow_if_needed
echo
sensor_size_before="$(jsonl_size "$BUSHFIRE_SENTINEL_LOG_DIR/sensor_data.jsonl")"
risk_size_before="$(jsonl_size "$BUSHFIRE_SENTINEL_LOG_DIR/risk_analysis.jsonl")"
start_process "python_main" "$PYTHON_BIN" -u src/main.py \
  --sensor-scenario "$SCENARIO" \
  --actuator-scenario "$ACTUATOR_SCENARIO" \
  --weather-interval "$WEATHER_INTERVAL" \
  --sensor-interval "$SENSOR_INTERVAL"
check_jsonl_progress "$sensor_size_before" "$risk_size_before"

echo
echo "All demo processes started."
echo "PID file: $(display_path "$PID_FILE")"
echo
echo "Open:"
echo "  Node-RED: $NODE_RED_URL"
echo "  Splunk:   $SPLUNK_URL"
echo
echo "Useful commands:"
echo "  tail -f $(display_path "$RUN_LOG_DIR/python_main.log")"
echo "  ./stop_local_demo.sh"
