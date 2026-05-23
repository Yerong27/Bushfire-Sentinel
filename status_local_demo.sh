#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT_DIR/logs/runtime/demo_pids.txt"
CHILD_PID_FILE="$ROOT_DIR/logs/runtime/python_child_pids.txt"
NODE_RED_URL="${NODE_RED_URL:-http://127.0.0.1:1880}"
SPLUNK_URL="${SPLUNK_URL:-http://127.0.0.1:8000}"

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

is_running() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

print_pid_file() {
  local file="$1"
  local label="$2"
  if [[ ! -f "$file" ]]; then
    echo "$label: no PID file"
    return
  fi

  echo "$label:"
  while read -r pid name; do
    [[ -z "${pid:-}" ]] && continue
    if is_running "$pid"; then
      echo "  running     $pid ${name:-process}"
    else
      echo "  not running $pid ${name:-process}"
    fi
  done < "$file"
}

print_matching_processes() {
  local matches
  matches="$(ps -axo pid,command 2>/dev/null | awk -v self="$$" '
    $1 == self { next }
    /run_local_demo\.sh/ { print $1, "launcher", "run_local_demo.sh"; next }
    /src\/main\.py/ { print $1, "python-main", "src/main.py"; next }
    /multiprocessing\.spawn/ { print $1, "python-child", "multiprocessing worker"; next }
    /node-red/ { print $1, "node-red", "Node-RED"; next }
  ' || true)"

  echo "Process details:"
  if [[ -z "$matches" ]]; then
    echo "  none"
  else
    echo "$matches" | awk '{ printf "  %-12s %-14s %s\n", $1, $2, substr($0, index($0,$3)) }'
  fi
}

matching_pids() {
  local pattern="$1"
  ps -axo pid,command 2>/dev/null | awk -v self="$$" -v pattern="$pattern" '
    $1 != self && $0 ~ pattern { print $1 }
  ' | sort -u || true
}

count_lines() {
  local text="$1"
  if [[ -z "$text" ]]; then
    echo 0
  else
    printf '%s\n' "$text" | wc -l | tr -d ' '
  fi
}

print_summary() {
  local run_pids main_pids child_pids node_red_pids
  local run_count main_count child_count node_red_count

  run_pids="$(matching_pids "run_local_demo\\.sh")"
  main_pids="$(matching_pids "src/main\\.py")"
  child_pids="$(matching_pids "multiprocessing\\.spawn")"
  node_red_pids="$(matching_pids "node-red")"

  run_count="$(count_lines "$run_pids")"
  main_count="$(count_lines "$main_pids")"
  child_count="$(count_lines "$child_pids")"
  node_red_count="$(count_lines "$node_red_pids")"

  echo "Summary:"
  if (( main_count == 0 )); then
    echo "  Python demo: stopped"
  elif (( main_count == 1 )); then
    echo "  Python demo: running (1 instance)"
  else
    echo "  Python demo: duplicate runs detected (${main_count} instances)"
    echo "  Action: run ./stop_local_demo.sh, then ./run_local_demo.sh"
  fi

  if (( node_red_count == 0 )); then
    echo "  Node-RED: stopped"
  elif (( node_red_count == 1 )); then
    echo "  Node-RED: running"
  else
    echo "  Node-RED: multiple node-red processes detected (${node_red_count})"
  fi

  echo "  Launcher shells: ${run_count}"
  echo "  Python child processes: ${child_count}"
}

check_url() {
  local label="$1"
  local url="$2"
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
    echo "  $label reachable: $url"
  else
    echo "  $label not reachable: $url"
  fi
}

jsonl_size() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -c < "$file" | tr -d ' '
  else
    echo 0
  fi
}

check_jsonl_growth() {
  local sensor="$ROOT_DIR/logs/sensor_data.jsonl"
  local risk="$ROOT_DIR/logs/risk_analysis.jsonl"
  local before_sensor before_risk after_sensor after_risk

  before_sensor="$(jsonl_size "$sensor")"
  before_risk="$(jsonl_size "$risk")"
  sleep 5
  after_sensor="$(jsonl_size "$sensor")"
  after_risk="$(jsonl_size "$risk")"

  echo "JSONL growth over 5s:"
  echo "  $(display_path "$sensor"): $before_sensor -> $after_sensor bytes"
  echo "  $(display_path "$risk"): $before_risk -> $after_risk bytes"
}

echo "Bushfire Sentinel status"
echo
print_summary
echo
print_pid_file "$PID_FILE" "Launcher PID file"
print_pid_file "$CHILD_PID_FILE" "Python child PID file"
echo
print_matching_processes
echo
echo "Services:"
check_url "Node-RED" "$NODE_RED_URL"
check_url "Splunk" "$SPLUNK_URL"
echo
check_jsonl_growth
