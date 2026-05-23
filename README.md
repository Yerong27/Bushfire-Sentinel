# Bushfire Sentinel

Bushfire Sentinel is a cyber-physical monitoring system for bushfire risk around the Yarra Ranges region, Victoria.

Core roles:

- Python collects Open-Meteo weather data and simulates local station_01 sensors.
- Python also simulates sprinkler actuator feedback after Node-RED sends a control command.
- MQTT carries all CPS messages.
- Sensor messages include `project_id=bushfire_sentinel` so Node-RED can reject unrelated public MQTT traffic.
- Node-RED is the orchestration, validation, analysis, logging, cloud, alert, and control layer.
- Splunk is the primary dashboard and investigation interface.
- AWS IoT Core receives structured JSON from Node-RED.

Assignment reports and presentation materials are kept outside this runnable MVP folder. This repository contains the runnable MVP implementation.

## Install

Required local tools:

- Python 3
- Node-RED, available as `node-red`
- Splunk Enterprise or Splunk local development instance

```bash
cd Bushfire-Sentinel
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

## First-Time Setup Order

Use this order on a new machine or after cloning the project.

1. Install Python dependencies if this has not already been done.

```bash
cd Bushfire-Sentinel
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

2. Start Splunk manually.

```bash
/Applications/Splunk/bin/splunk start
```

3. Configure the one-time local demo setup.

```bash
./setup/setup_local_demo.sh
```

The script will ask for the Splunk username and password. It configures Splunk, starts Node-RED if needed, and deploys the Bushfire Sentinel Node-RED flow by merging it into the running Node-RED instance. Existing non-project Node-RED flows are preserved.

4. Start the local demo.

```bash
./run_local_demo.sh
```

5. Open Node-RED if you want to inspect the deployed flow.

```text
http://127.0.0.1:1880
```

6. Open Splunk dashboard.

```text
http://127.0.0.1:8000
```

`run_local_demo.sh` does not install dependencies, does not start Splunk, and does not deploy Node-RED flows by default. It starts Node-RED if it is not already reachable, then starts the Python demo runner. It uses `PYTHON_BIN` if provided, otherwise it tries `.venv/bin/python`, `../.venv/bin/python`, `python3`, then `python`.

For the normal dashboard demo, Node-RED is required. To run only the Python MQTT publishers without Node-RED:

```bash
REQUIRE_NODE_RED=0 ./run_local_demo.sh
```

After the first setup, you normally only need to start Splunk manually and run `./run_local_demo.sh`. You do not need to rerun `setup_local_demo.sh` unless the dashboard JSON, Node-RED flow, log monitor setup, or index setup has changed.

## Daily Demo Startup

Use this after the first-time setup has already been completed.

```bash
cd Bushfire-Sentinel
source .venv/bin/activate
./run_local_demo.sh
```

For a normal dashboard demo, start Splunk first, then run the local demo:

```bash
/Applications/Splunk/bin/splunk start
source .venv/bin/activate
./run_local_demo.sh
```

For a backend-only test, Splunk can stay closed. The demo will still start Node-RED and Python, and JSONL logs will still be written locally.

By default this starts probabilistic demo mode:

- local sensor simulator uses `auto_random`
- actuator simulator uses `auto_random`

In `auto_random`, abnormal events are probability-triggered instead of manually switched. Short smoke spikes are treated as anomaly-style events, while separate smoke incident windows can last for several cycles so the risk engine can observe sustained elevated, high, or critical smoke. Water tank drops, missing values, unrealistic values, frozen readings, sensor dropouts, sprinkler failures, and no-response feedback may also appear naturally during the run.

Arguments:

- first argument = local sensor scenario
- second argument = actuator scenario

Examples:

```bash
./run_local_demo.sh auto_random auto_random
./run_local_demo.sh smoke_spike normal
./run_local_demo.sh smoke_spike sprinkler_failure
./run_local_demo.sh water_tank_drop normal
```

Stop demo processes:

```bash
./stop_local_demo.sh
```

The launcher starts Node-RED if it is not already reachable, then starts the unified Python demo runner. Splunk is not managed by the launcher. Start and stop Splunk manually when you want to use the dashboard.

Node-RED flow deployment is treated as one-time setup. `setup/setup_local_demo.sh` deploys the flow with a merge-based update: it replaces only the `Bushfire Sentinel CPS` tab and this project's Node-RED config nodes, then preserves any other Node-RED flows already in the workspace.

Manual startup:

Terminal 1:

```bash
python src/weather_collector.py --interval 30
```

Terminal 2:

```bash
python src/site_sensor_simulator.py --scenario normal --interval 10
```

Terminal 3:

```bash
python src/actuator_simulator.py --scenario normal
```

Useful demo scenarios:

```bash
python src/site_sensor_simulator.py --scenario smoke_spike
python src/site_sensor_simulator.py --scenario high_fire_demo
python src/site_sensor_simulator.py --scenario critical_fire_demo
python src/site_sensor_simulator.py --scenario water_tank_drop
python src/site_sensor_simulator.py --scenario unrealistic_value
python src/site_sensor_simulator.py --scenario frozen_sensor
python src/site_sensor_simulator.py --scenario sensor_dropout
python src/actuator_simulator.py --scenario sprinkler_failure
python src/actuator_simulator.py --scenario no_response
```

## Node-RED

The normal setup helper deploys the flow automatically:

```bash
./setup/setup_local_demo.sh
```

Manual merge deployment:

```bash
python scripts/deploy_node_red_flow.py
```

After deployment, refresh the Node-RED editor page if it was already open in the browser. The script verifies the Admin API state and prints the current Node-RED tab names.

Quick Admin API check:

```bash
curl -fsS http://127.0.0.1:1880/flows | python3 -m json.tool | grep "Bushfire Sentinel CPS"
```

The source flow is:

```text
node_red/bushfire_sentinel_flow.json
```

Active local MQTT topics:

- `cps/sensor/data`
- `cps/control`

Node-RED writes risk analysis and alert events to JSONL logs for Splunk instead of republishing them to unused local MQTT topics.

The Node-RED flow writes JSONL files under `BUSHFIRE_SENTINEL_LOG_DIR`. `run_local_demo.sh` sets this automatically to the repository `logs` directory. If you start Node-RED manually instead of using the launcher, start it from the project root like this:

```bash
BUSHFIRE_SENTINEL_LOG_DIR="$PWD/logs" node-red
```

The AWS IoT Core MQTT config node is a placeholder. Add the real AWS endpoint, certificates, private key, and root CA inside Node-RED, then enable the AWS IoT MQTT out nodes before cloud demonstration. The AWS topics are `cps/sensor/data` and `cps/analysis/risk`.

## Setup Details

Splunk is not started or stopped by the local demo scripts. Start Splunk manually first:

```bash
/Applications/Splunk/bin/splunk start
```

Then run the setup helper. This script does not install Splunk and does not manage the Splunk process. It configures an already-running local Splunk instance through the Splunk REST API, starts Node-RED if needed, and deploys the project Node-RED flow:

```bash
cd Bushfire-Sentinel
./setup/setup_local_demo.sh
```

The setup helper uses the local Splunk REST API to:

- create or verify the `bushfire_sentinel` index
- create or update the `bushfire_sentinel_json` sourcetype
- configure file monitors for the project JSONL logs
- use index time for dashboard freshness instead of the JSON payload timestamp
- import or update the Dashboard Studio dashboard from `splunk/bushfire_sentinel_dashboard_studio.json`
- merge-deploy `node_red/bushfire_sentinel_flow.json` into Node-RED without touching other flows

By default, the setup helper asks for the Splunk username and password:

```bash
./setup/setup_local_demo.sh
```

You can still pass credentials non-interactively if needed:

```bash
SPLUNK_USER=admin SPLUNK_PASSWORD='your-password' ./setup/setup_local_demo.sh
```

Optional setup variables:

- `SPLUNK_SCHEME`, default `https`
- `SPLUNK_HOST`, default `127.0.0.1`
- `SPLUNK_MGMT_PORT`, default `8089`
- `SPLUNK_APP`, default `search`
- `SPLUNK_OWNER`, default `nobody`
- `SPLUNK_INDEX`, default `bushfire_sentinel`
- `SPLUNK_SOURCETYPE`, default `bushfire_sentinel_json`
- `SPLUNK_DASHBOARD_ID`, default `bushfire_sentinel`
- `SPLUNK_LOG_DIR`, default `logs`
- `NODE_RED_URL`, default `http://127.0.0.1:1880`
- `NODE_RED_FLOW_FILE`, default `node_red/bushfire_sentinel_flow.json`
- `DEPLOY_NODE_RED_FLOW`, default `1`; set to `0` to skip Node-RED deployment
- `NODE_RED_BEARER_TOKEN`, optional bearer token for a secured Node-RED Admin API

Safe check without changing Splunk or Node-RED configuration:

```bash
./setup/setup_local_demo.sh --check
```

Reset and recreate the normal Bushfire Sentinel Splunk setup:

```bash
./setup/setup_local_demo.sh --reset
```

The reset command asks you to type `RESET` before it deletes anything. It deletes and recreates only the target dashboard, target file monitors, and target index configured by the script. By default these are:

- dashboard id: `bushfire_sentinel`
- index: `bushfire_sentinel`
- log directory: `logs`

End-to-end setup test without touching the main `bushfire_sentinel` index or dashboard:

```bash
mkdir -p logs/setup_test
touch logs/setup_test/sensor_data.jsonl \
      logs/setup_test/risk_analysis.jsonl \
      logs/setup_test/alerts.jsonl \
      logs/setup_test/control_commands.jsonl \
      logs/setup_test/actuator_feedback.jsonl

SPLUNK_USER=admin \
SPLUNK_PASSWORD='your-password' \
SPLUNK_INDEX=bushfire_sentinel_setup_test \
SPLUNK_DASHBOARD_ID=bushfire_sentinel_setup_test \
SPLUNK_DASHBOARD_TITLE='Bushfire Sentinel Setup Test' \
SPLUNK_LOG_DIR="$PWD/logs/setup_test" \
DEPLOY_NODE_RED_FLOW=0 \
./setup/setup_local_demo.sh
```

If the dashboard import fails because of a local Splunk version difference, create a new Dashboard Studio dashboard manually, switch to Source mode, and paste:

```text
splunk/bushfire_sentinel_dashboard_studio.json
```

The JSON-lines files monitored by Splunk are:

- `logs/sensor_data.jsonl`
- `logs/risk_analysis.jsonl`
- `logs/alerts.jsonl`
- `logs/control_commands.jsonl`
- `logs/actuator_feedback.jsonl`

Use this test search after setup:

```text
index=bushfire_sentinel sourcetype=bushfire_sentinel_json | head 20
```

## Important Semantics

`sprinkler_status` is actuator feedback, not a normal environmental sensor. Node-RED publishes `sprinkler_command` on `cps/control`; `src/actuator_simulator.py` receives the command and publishes `sprinkler_status` back on `cps/sensor/data`.

`fire_risk` and `response_capacity` are separate:

- `fire_risk`: temperature, humidity, wind, precipitation, smoke, soil dryness.
- `response_capacity`: water tank level and sprinkler actuator feedback.
- `overall_system_status`: combines fire risk and response capacity.
