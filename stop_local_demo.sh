#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT_DIR/logs/runtime/demo_pids.txt"
CHILD_PID_FILE="$ROOT_DIR/logs/runtime/python_child_pids.txt"

is_running() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

stop_pid() {
  local pid="$1"
  local name="$2"
  [[ -z "${pid:-}" ]] && return

  if is_running "$pid"; then
    echo "Stopping $name pid=$pid"
    if ! kill "$pid" 2>/dev/null; then
      echo "  warning: could not stop $name pid=$pid"
    fi
  else
    echo "$name pid=$pid is not running"
  fi
}

force_pid() {
  local pid="$1"
  local name="$2"
  [[ -z "${pid:-}" ]] && return

  if is_running "$pid"; then
    echo "Force stopping $name pid=$pid"
    kill -9 "$pid" 2>/dev/null || true
  fi
}

wait_for_pids() {
  local pids="$1"
  local seconds="${2:-6}"
  [[ -z "$pids" ]] && return

  local i
  for ((i = 0; i < seconds; i++)); do
    local still_running=""
    while read -r pid; do
      [[ -z "$pid" ]] && continue
      if is_running "$pid"; then
        still_running=1
      fi
    done <<< "$pids"

    [[ -z "$still_running" ]] && return
    sleep 1
  done
}

collect_pid_file_pids() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '{ print $1 }' "$file" | sort -u
}

tracked_pids=""
if [[ ! -f "$PID_FILE" ]]; then
  echo "No PID file found: $PID_FILE"
else
  tracked_pids="$(collect_pid_file_pids "$PID_FILE")"
  while read -r pid name; do
    stop_pid "$pid" "$name"
  done < "$PID_FILE"

  rm -f "$PID_FILE"
fi

if [[ -n "$tracked_pids" ]]; then
  wait_for_pids "$tracked_pids" 8
fi

child_pids="$(collect_pid_file_pids "$CHILD_PID_FILE")"
if [[ -n "$child_pids" ]]; then
  echo "Checking Python child processes recorded by main.py:"
  while read -r pid name; do
    [[ -z "${pid:-}" ]] && continue
    stop_pid "$pid" "${name:-python_child}"
  done < "$CHILD_PID_FILE"
  wait_for_pids "$child_pids" 4
fi

fallback_pids="$(ps -axo pid,command 2>/dev/null | awk -v self="$$" '
  $1 != self && /bash \.\/run_local_demo\.sh/ { print $1 }
  $1 != self && /bash .*run_local_demo\.sh/ { print $1 }
  $1 != self && /src\/main\.py|src\/weather_collector\.py|src\/site_sensor_simulator\.py|src\/actuator_simulator\.py/ { print $1 }
  $1 != self && /multiprocessing\.spawn/ { print $1 }
  $1 != self && /multiprocessing\.resource_tracker/ { print $1 }
' | sort -u || true)"
if [[ -n "$fallback_pids" ]]; then
  echo "Stopping leftover demo processes:"
  while read -r pid; do
    stop_pid "$pid" "demo_python"
  done <<< "$fallback_pids"
  wait_for_pids "$fallback_pids" 4
fi

node_red_pids="$(ps -axo pid,command 2>/dev/null | awk -v self="$$" '
  $1 != self && /node-red/ { print $1 }
' | sort -u || true)"
if [[ -n "$node_red_pids" ]]; then
  echo "Stopping Node-RED processes:"
  while read -r pid; do
    stop_pid "$pid" "node_red"
  done <<< "$node_red_pids"
  wait_for_pids "$node_red_pids" 4
fi

if command -v lsof >/dev/null 2>&1; then
  port_pids="$(lsof -tiTCP:1880 -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$port_pids" ]]; then
    echo "Stopping processes still listening on port 1880:"
    while read -r pid; do
      stop_pid "$pid" "port_1880_listener"
    done <<< "$port_pids"
    wait_for_pids "$port_pids" 4
  fi
fi

leftover_pids="$(ps -axo pid,command 2>/dev/null | awk -v self="$$" '
  $1 != self && /bash \.\/run_local_demo\.sh/ { print $1 }
  $1 != self && /bash .*run_local_demo\.sh/ { print $1 }
  $1 != self && /src\/main\.py|src\/weather_collector\.py|src\/site_sensor_simulator\.py|src\/actuator_simulator\.py/ { print $1 }
  $1 != self && /multiprocessing\.spawn/ { print $1 }
  $1 != self && /multiprocessing\.resource_tracker/ { print $1 }
  $1 != self && /node-red/ { print $1 }
' | sort -u || true)"
if [[ -n "$leftover_pids" ]]; then
  echo "Force stopping remaining known demo processes:"
  while read -r pid; do
    force_pid "$pid" "leftover"
  done <<< "$leftover_pids"
fi

if command -v lsof >/dev/null 2>&1; then
  final_port_pids="$(lsof -tiTCP:1880 -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$final_port_pids" ]]; then
    echo "Force stopping remaining port 1880 listeners:"
    while read -r pid; do
      force_pid "$pid" "port_1880_listener"
    done <<< "$final_port_pids"
  fi
fi

rm -f "$CHILD_PID_FILE"

echo "Demo processes stopped."
