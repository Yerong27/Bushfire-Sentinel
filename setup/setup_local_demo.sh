#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SPLUNK_SCHEME="${SPLUNK_SCHEME:-https}"
SPLUNK_HOST="${SPLUNK_HOST:-127.0.0.1}"
SPLUNK_MGMT_PORT="${SPLUNK_MGMT_PORT:-8089}"
SPLUNK_APP="${SPLUNK_APP:-search}"
SPLUNK_OWNER="${SPLUNK_OWNER:-nobody}"
SPLUNK_INDEX="${SPLUNK_INDEX:-bushfire_sentinel}"
SPLUNK_SOURCETYPE="${SPLUNK_SOURCETYPE:-bushfire_sentinel_json}"
SPLUNK_DASHBOARD_ID="${SPLUNK_DASHBOARD_ID:-bushfire_sentinel}"
SPLUNK_DASHBOARD_TITLE="${SPLUNK_DASHBOARD_TITLE:-Bushfire Sentinel}"
SPLUNK_LOG_DIR="${SPLUNK_LOG_DIR:-${PROJECT_ROOT}/logs}"
NODE_RED_URL="${NODE_RED_URL:-http://127.0.0.1:1880}"
NODE_RED_FLOW_FILE="${NODE_RED_FLOW_FILE:-${PROJECT_ROOT}/node_red/bushfire_sentinel_flow.json}"
DEPLOY_NODE_RED_FLOW="${DEPLOY_NODE_RED_FLOW:-1}"
START_NODE_RED="${START_NODE_RED:-1}"
NODE_RED_CMD="${NODE_RED_CMD:-node-red}"
PYTHON_BIN="${PYTHON_BIN:-}"
CHECK_ONLY=0
RESET_FIRST=0
CONFIRM_RESET="${CONFIRM_RESET:-}"

SPLUNK_USER="${SPLUNK_USER:-}"
SPLUNK_PASSWORD="${SPLUNK_PASSWORD:-}"

BASE_URL="${SPLUNK_SCHEME}://${SPLUNK_HOST}:${SPLUNK_MGMT_PORT}"
DASHBOARD_JSON="${PROJECT_ROOT}/splunk/bushfire_sentinel_dashboard_studio.json"

LOG_FILES=(
  "${SPLUNK_LOG_DIR}/sensor_data.jsonl"
  "${SPLUNK_LOG_DIR}/risk_analysis.jsonl"
  "${SPLUNK_LOG_DIR}/alerts.jsonl"
  "${SPLUNK_LOG_DIR}/control_commands.jsonl"
  "${SPLUNK_LOG_DIR}/actuator_feedback.jsonl"
)

display_path() {
  local path="$1"
  case "$path" in
    "${PROJECT_ROOT}")
      printf '.\n'
      ;;
    "${PROJECT_ROOT}"/*)
      printf './%s\n' "${path#"${PROJECT_ROOT}/"}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

usage() {
  cat <<EOF
Usage: ./setup/setup_local_demo.sh [--check] [--reset]

Configures an already-running local Splunk instance, starts Node-RED if
needed, and deploys the Bushfire Sentinel Node-RED flow.

Options:
  --check    Validate Splunk access and local dashboard JSON only. No index,
             monitor, or dashboard changes are made.
  --reset    Delete the target dashboard, file monitors, and index before
             creating them again. The script asks for confirmation unless
             CONFIRM_RESET=YES is provided.

Environment variables:
  SPLUNK_USER
  SPLUNK_PASSWORD
  SPLUNK_SCHEME          default: https
  SPLUNK_HOST            default: 127.0.0.1
  SPLUNK_MGMT_PORT       default: 8089
  SPLUNK_APP             default: search
  SPLUNK_OWNER           default: nobody
  SPLUNK_INDEX           default: bushfire_sentinel
  SPLUNK_SOURCETYPE      default: bushfire_sentinel_json
  SPLUNK_DASHBOARD_ID    default: bushfire_sentinel
  SPLUNK_DASHBOARD_TITLE default: Bushfire Sentinel
  SPLUNK_LOG_DIR         default: PROJECT_ROOT/logs
  NODE_RED_URL           default: http://127.0.0.1:1880
  NODE_RED_FLOW_FILE     default: PROJECT_ROOT/node_red/bushfire_sentinel_flow.json
  DEPLOY_NODE_RED_FLOW   default: 1. Set to 0 to skip Node-RED flow deployment
  START_NODE_RED         default: 1. Set to 0 to require Node-RED to be running
  NODE_RED_CMD           default: node-red
  NODE_RED_BEARER_TOKEN  optional: bearer token for secured Node-RED Admin API
  PYTHON_BIN             optional: Python executable for helper scripts
  CONFIRM_RESET          optional: YES skips the interactive reset prompt
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        CHECK_ONLY=1
        shift
        ;;
      --reset)
        RESET_FIRST=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

urlencode() {
  "${PYTHON_BIN}" - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

prompt_credentials() {
  if [[ -z "${SPLUNK_USER}" ]]; then
    read -r -p "Splunk username [admin]: " SPLUNK_USER
    SPLUNK_USER="${SPLUNK_USER:-admin}"
  fi

  if [[ -z "${SPLUNK_PASSWORD}" ]]; then
    read -r -s -p "Splunk password: " SPLUNK_PASSWORD
    printf '\n'
  fi
}

splunk_get() {
  curl -ksS --fail -u "${SPLUNK_USER}:${SPLUNK_PASSWORD}" "$@"
}

splunk_post() {
  curl -ksS --fail -u "${SPLUNK_USER}:${SPLUNK_PASSWORD}" -X POST "$@"
}

splunk_delete() {
  curl -ksS --fail -u "${SPLUNK_USER}:${SPLUNK_PASSWORD}" -X DELETE "$@"
}

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "Missing required file: ${path}" >&2
    exit 1
  fi
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

  if [[ -x "${PROJECT_ROOT}/.venv/bin/python" ]]; then
    printf '%s\n' "${PROJECT_ROOT}/.venv/bin/python"
    return 0
  fi

  if [[ -x "${PROJECT_ROOT}/../.venv/bin/python" ]]; then
    printf '%s\n' "${PROJECT_ROOT}/../.venv/bin/python"
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

url_reachable() {
  local url="$1"
  command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "$url" >/dev/null 2>&1
}

start_node_red_if_needed() {
  if [[ "${DEPLOY_NODE_RED_FLOW}" != "1" ]]; then
    return
  fi

  if url_reachable "${NODE_RED_URL}"; then
    echo "Node-RED already reachable at ${NODE_RED_URL}"
    return
  fi

  if [[ "${START_NODE_RED}" != "1" ]]; then
    echo "Node-RED is not reachable at ${NODE_RED_URL} and START_NODE_RED=${START_NODE_RED}." >&2
    return 1
  fi

  if ! command -v "${NODE_RED_CMD}" >/dev/null 2>&1; then
    echo "Node-RED command not found: ${NODE_RED_CMD}" >&2
    echo "Install Node-RED or set NODE_RED_CMD=/path/to/node-red." >&2
    return 1
  fi

  mkdir -p "${PROJECT_ROOT}/logs/runtime" "${SPLUNK_LOG_DIR}"
  export BUSHFIRE_SENTINEL_LOG_DIR="${SPLUNK_LOG_DIR}"

  local log_file="${PROJECT_ROOT}/logs/runtime/node_red.log"
  echo "Starting Node-RED ..."
  (
    cd "${PROJECT_ROOT}"
    "${NODE_RED_CMD}"
  ) >"${log_file}" 2>&1 &
  local pid=$!
  echo "  pid=${pid} log=$(display_path "${log_file}")"

  local attempt
  for attempt in {1..20}; do
    if url_reachable "${NODE_RED_URL}"; then
      echo "  Node-RED is ready at ${NODE_RED_URL}"
      return
    fi
    sleep 1
  done

  echo "Node-RED did not become reachable. Check: ${log_file}" >&2
  return 1
}

check_splunk() {
  echo "Checking Splunk REST API at ${BASE_URL} ..."
  if ! splunk_get "${BASE_URL}/services/server/info?output_mode=json" >/dev/null; then
    echo
    echo "Cannot connect to Splunk REST API."
    echo "Start Splunk manually first, then rerun this script."
    echo "Expected local web UI: http://127.0.0.1:8000"
    echo "Expected REST API: ${BASE_URL}"
    exit 1
  fi
}

reset_dashboard() {
  local encoded_dashboard
  encoded_dashboard="$(urlencode "${SPLUNK_DASHBOARD_ID}")"

  if splunk_get "${BASE_URL}/servicesNS/${SPLUNK_OWNER}/${SPLUNK_APP}/data/ui/views/${encoded_dashboard}?output_mode=json" >/dev/null 2>&1; then
    echo "  deleting dashboard: ${SPLUNK_DASHBOARD_ID}"
    splunk_delete "${BASE_URL}/servicesNS/${SPLUNK_OWNER}/${SPLUNK_APP}/data/ui/views/${encoded_dashboard}" >/dev/null \
      || echo "  warning: dashboard delete returned an error; continuing"
  else
    echo "  dashboard not present: ${SPLUNK_DASHBOARD_ID}"
  fi
}

reset_monitor() {
  local file="$1"
  local encoded_file
  encoded_file="$(urlencode "${file}")"

  if splunk_get "${BASE_URL}/services/data/inputs/monitor/${encoded_file}?output_mode=json" >/dev/null 2>&1; then
    echo "  deleting monitor: $(display_path "${file}")"
    splunk_delete "${BASE_URL}/services/data/inputs/monitor/${encoded_file}" >/dev/null \
      || echo "  warning: monitor delete returned an error; continuing"
  else
    echo "  monitor not present: $(display_path "${file}")"
  fi
}

reset_monitors() {
  echo "Deleting target JSONL file monitors:"
  for file in "${LOG_FILES[@]}"; do
    reset_monitor "${file}"
  done
}

reset_index() {
  local encoded_index
  encoded_index="$(urlencode "${SPLUNK_INDEX}")"

  if splunk_get "${BASE_URL}/services/data/indexes/${encoded_index}?output_mode=json" >/dev/null 2>&1; then
    echo "  deleting index: ${SPLUNK_INDEX}"
    if splunk_delete "${BASE_URL}/services/data/indexes/${encoded_index}" >/dev/null 2>&1; then
      echo "  index deleted"
    else
      echo "  warning: index delete was not accepted by this Splunk version; clearing indexed events instead"
      splunk_post "${BASE_URL}/services/search/jobs" \
        -d "search=search index=${SPLUNK_INDEX} | delete" \
        -d "exec_mode=oneshot" \
        >/dev/null 2>&1 || echo "  warning: event delete was not available; continuing with existing index"
    fi
  else
    echo "  index not present: ${SPLUNK_INDEX}"
  fi
}

truncate_log_files() {
  echo "Clearing local JSONL log files:"
  mkdir -p "${SPLUNK_LOG_DIR}"
  for file in "${LOG_FILES[@]}"; do
    : > "${file}"
    echo "  cleared: $(display_path "${file}")"
  done
}

reset_existing_setup() {
  if [[ "${CONFIRM_RESET}" != "YES" ]]; then
    echo "Reset will delete and recreate the target Bushfire Sentinel Splunk setup:"
    echo "  dashboard id: ${SPLUNK_DASHBOARD_ID}"
    echo "  file monitors under: $(display_path "${SPLUNK_LOG_DIR}")"
    echo "  index or indexed events: ${SPLUNK_INDEX}"
    echo
    read -r -p "Type RESET to continue: " reset_answer
    if [[ "${reset_answer}" != "RESET" ]]; then
      echo "Reset cancelled."
      exit 0
    fi
  fi

  echo "Reset requested for:"
  echo "  index: ${SPLUNK_INDEX}"
  echo "  dashboard id: ${SPLUNK_DASHBOARD_ID}"
  echo "  log directory: $(display_path "${SPLUNK_LOG_DIR}")"
  echo

  reset_dashboard
  reset_monitors
  reset_index
  truncate_log_files
}

ensure_sourcetype() {
  echo "Ensuring sourcetype: ${SPLUNK_SOURCETYPE}"

  local encoded_sourcetype
  encoded_sourcetype="$(urlencode "${SPLUNK_SOURCETYPE}")"
  local endpoint="${BASE_URL}/servicesNS/${SPLUNK_OWNER}/${SPLUNK_APP}/configs/conf-props/${encoded_sourcetype}"

  local args=(
    -d "SHOULD_LINEMERGE=false"
    --data-urlencode "LINE_BREAKER=([\\r\\n]+)"
    -d "DATETIME_CONFIG=CURRENT"
    -d "KV_MODE=json"
    -d "TRUNCATE=0"
    -d "NO_BINARY_CHECK=1"
    -d "category=Structured"
    -d "description=Bushfire Sentinel JSONL, using index time for dashboard freshness"
  )

  if splunk_get "${endpoint}?output_mode=json" >/dev/null 2>&1; then
    splunk_post "${endpoint}" "${args[@]}" >/dev/null
    echo "  sourcetype updated"
    return
  fi

  splunk_post "${BASE_URL}/servicesNS/${SPLUNK_OWNER}/${SPLUNK_APP}/configs/conf-props" \
    -d "name=${SPLUNK_SOURCETYPE}" \
    "${args[@]}" \
    >/dev/null

  echo "  sourcetype created"
}

ensure_index() {
  echo "Ensuring index: ${SPLUNK_INDEX}"
  local encoded_index
  encoded_index="$(urlencode "${SPLUNK_INDEX}")"

  if splunk_get "${BASE_URL}/services/data/indexes/${encoded_index}?output_mode=json" >/dev/null 2>&1; then
    echo "  index already exists"
    return
  fi

  splunk_post "${BASE_URL}/services/data/indexes" \
    -d "name=${SPLUNK_INDEX}" \
    -d "datatype=event" \
    -d "maxTotalDataSizeMB=512" \
    >/dev/null

  echo "  index created"
}

ensure_log_files() {
  mkdir -p "${SPLUNK_LOG_DIR}"
  for file in "${LOG_FILES[@]}"; do
    touch "${file}"
  done
}

check_local_files() {
  require_file "${DASHBOARD_JSON}"
  "${PYTHON_BIN}" -m json.tool "${DASHBOARD_JSON}" >/dev/null
  echo "Dashboard JSON is valid: $(display_path "${DASHBOARD_JSON}")"

  require_file "${NODE_RED_FLOW_FILE}"
  "${PYTHON_BIN}" -m json.tool "${NODE_RED_FLOW_FILE}" >/dev/null
  echo "Node-RED flow JSON is valid: $(display_path "${NODE_RED_FLOW_FILE}")"
}

deploy_node_red_flow() {
  if [[ "${DEPLOY_NODE_RED_FLOW}" != "1" ]]; then
    echo "Skipping Node-RED flow deployment: DEPLOY_NODE_RED_FLOW=${DEPLOY_NODE_RED_FLOW}"
    return
  fi

  require_file "${NODE_RED_FLOW_FILE}"
  start_node_red_if_needed

  echo "Deploying Node-RED flow: $(display_path "${NODE_RED_FLOW_FILE}")"
  if "${PYTHON_BIN}" "${PROJECT_ROOT}/scripts/deploy_node_red_flow.py" \
    --node-red-url "${NODE_RED_URL}" \
    --flow-file "${NODE_RED_FLOW_FILE}"; then
    return
  fi

  echo
  echo "Node-RED flow deployment did not complete." >&2
  echo "Rerun setup after Node-RED is reachable, or deploy manually:" >&2
  echo "  NODE_RED_URL=${NODE_RED_URL} ${PYTHON_BIN} scripts/deploy_node_red_flow.py" >&2
  return 1
}

build_dashboard_xml() {
  local output_file="$1"

  "${PYTHON_BIN}" - "${DASHBOARD_JSON}" "${output_file}" "${SPLUNK_DASHBOARD_TITLE}" <<'PY'
import html
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
title = sys.argv[3]
dashboard_json = json_path.read_text(encoding="utf-8")

if "]]>" in dashboard_json:
    raise SystemExit("Dashboard JSON contains a CDATA terminator and cannot be wrapped safely.")

output_path.write_text(
    f'''<dashboard version="2" theme="light">
  <label>{html.escape(title)}</label>
  <definition><![CDATA[
{dashboard_json}
  ]]></definition>
</dashboard>
''',
    encoding="utf-8",
)
PY
}

ensure_monitor() {
  local file="$1"
  local encoded_file
  encoded_file="$(urlencode "${file}")"

  if splunk_get "${BASE_URL}/services/data/inputs/monitor/${encoded_file}?output_mode=json" >/dev/null 2>&1; then
    echo "  monitor already exists: $(display_path "${file}")"
    splunk_post "${BASE_URL}/services/data/inputs/monitor/${encoded_file}" \
      -d "index=${SPLUNK_INDEX}" \
      -d "sourcetype=${SPLUNK_SOURCETYPE}" \
      -d "disabled=0" \
      >/dev/null || true
    return
  fi

  splunk_post "${BASE_URL}/services/data/inputs/monitor" \
    -d "name=${file}" \
    -d "index=${SPLUNK_INDEX}" \
    -d "sourcetype=${SPLUNK_SOURCETYPE}" \
    -d "disabled=0" \
    >/dev/null

  echo "  monitor created: $(display_path "${file}")"
}

ensure_monitors() {
  echo "Ensuring JSONL file monitors:"
  for file in "${LOG_FILES[@]}"; do
    ensure_monitor "${file}"
  done
}

upsert_dashboard() {
  require_file "${DASHBOARD_JSON}"

  echo "Importing Dashboard Studio dashboard: ${SPLUNK_DASHBOARD_ID}"

  local encoded_dashboard
  encoded_dashboard="$(urlencode "${SPLUNK_DASHBOARD_ID}")"
  local dashboard_xml
  dashboard_xml="$(mktemp "${TMPDIR:-/tmp}/bushfire_sentinel_dashboard.XXXXXX.xml")"
  build_dashboard_xml "${dashboard_xml}"

  if splunk_get "${BASE_URL}/servicesNS/${SPLUNK_OWNER}/${SPLUNK_APP}/data/ui/views/${encoded_dashboard}?output_mode=json" >/dev/null 2>&1; then
    if splunk_post "${BASE_URL}/servicesNS/${SPLUNK_OWNER}/${SPLUNK_APP}/data/ui/views/${encoded_dashboard}" \
      --data-urlencode "eai:data@${dashboard_xml}" \
      >/dev/null; then
      rm -f "${dashboard_xml}"
      echo "  dashboard updated"
      return
    fi
  else
    if splunk_post "${BASE_URL}/servicesNS/${SPLUNK_OWNER}/${SPLUNK_APP}/data/ui/views" \
      -d "name=${SPLUNK_DASHBOARD_ID}" \
      --data-urlencode "eai:data@${dashboard_xml}" \
      >/dev/null; then
      rm -f "${dashboard_xml}"
      echo "  dashboard created"
      return
    fi
  fi

  rm -f "${dashboard_xml}"
  echo
  echo "Dashboard import did not succeed through this Splunk REST endpoint."
  echo "The index and file monitors may still be configured correctly."
  echo "Manual fallback:"
  echo "  1. Open Splunk: http://127.0.0.1:8000"
  echo "  2. Create a Dashboard Studio dashboard named Bushfire Sentinel"
  echo "  3. Open Source mode"
  echo "  4. Paste: $(display_path "${DASHBOARD_JSON}")"
}

print_summary() {
  echo
  echo "One-time setup complete."
  echo "  Splunk index: ${SPLUNK_INDEX}"
  echo "  Sourcetype: ${SPLUNK_SOURCETYPE}"
  echo "  Dashboard: ${SPLUNK_DASHBOARD_TITLE}"
  echo "  Logs: $(display_path "${SPLUNK_LOG_DIR}")"
  echo "  Node-RED flow: $(display_path "${NODE_RED_FLOW_FILE}")"
  echo
  echo "Open:"
  echo "  http://127.0.0.1:8000"
  echo
  echo "Test search:"
  echo "  index=${SPLUNK_INDEX} sourcetype=${SPLUNK_SOURCETYPE} | head 20"
  echo
  echo "Next step:"
  echo "  Start the demo with ./run_local_demo.sh"
}

main() {
  parse_args "$@"
  PYTHON_BIN="$(resolve_python)"

  echo "Bushfire Sentinel local setup"
  echo "Logs: $(display_path "${SPLUNK_LOG_DIR}")"
  echo "Splunk API: ${BASE_URL}"
  echo

  prompt_credentials
  check_splunk

  if [[ "${CHECK_ONLY}" == "1" ]]; then
    check_local_files
    echo
    echo "Check complete. No Splunk configuration was changed."
    exit 0
  fi

  if [[ "${RESET_FIRST}" == "1" ]]; then
    reset_existing_setup
  fi

  ensure_index
  ensure_sourcetype
  ensure_log_files
  ensure_monitors
  upsert_dashboard
  deploy_node_red_flow
  print_summary
}

main "$@"
