# Bushfire Sentinel

Bushfire Sentinel is a runnable cyber-physical monitoring demo for bushfire risk around the Yarra Ranges region, Victoria.

The local pipeline is:

```text
Python simulators + Open-Meteo -> MQTT -> Node-RED -> JSONL logs -> Splunk Dashboard Studio
```

Python publishes weather, local sensor, and actuator feedback messages. Node-RED validates, analyzes, logs, alerts, and sends sprinkler commands. Splunk monitors the JSONL logs and displays the operational dashboard.

## Demo Video

https://github.com/user-attachments/assets/ad719a85-8081-4ebb-814a-29db45ac608f

Recorded Splunk dashboard demonstration: [Watch on YouTube](https://youtu.be/lBQ9JEF5AVk)

## Prerequisites

- Python 3
- Node-RED available as `node-red`
- Splunk Enterprise or a local Splunk development instance

The demo assumes Splunk Web is available at `http://127.0.0.1:8000` and the Splunk management API at `https://127.0.0.1:8089`.

## Quick Start

```bash
git clone https://github.com/Yerong27/Bushfire-Sentinel.git
cd Bushfire-Sentinel

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Start Splunk manually:

```bash
/Applications/Splunk/bin/splunk start
```

Run the one-time local setup:

```bash
./setup/setup_local_demo.sh
```

This configures the Splunk index, sourcetype, file monitors, dashboard, and Node-RED flow. It asks for your local Splunk username and password. Existing non-project Node-RED flows are preserved.

Start the demo:

```bash
./run_local_demo.sh
```

Open:

- Node-RED: `http://127.0.0.1:1880`
- Splunk: `http://127.0.0.1:8000`

## Daily Run

After the first setup, normally run:

```bash
cd Bushfire-Sentinel
source .venv/bin/activate
/Applications/Splunk/bin/splunk start
./run_local_demo.sh
```

Stop local demo processes:

```bash
./stop_local_demo.sh
```

Check process and log status:

```bash
./status_local_demo.sh
```

Reset and recreate the local Splunk setup:

```bash
./setup/setup_local_demo.sh --reset
```

Use reset after changing monitor setup, clearing old indexed data, or rebuilding the dashboard from scratch.

## Demo Scenarios

Default mode is probabilistic:

```bash
./run_local_demo.sh auto_random auto_random
```

The first argument controls local sensor behavior. The second controls actuator feedback.

Useful examples:

```bash
./run_local_demo.sh smoke_spike normal
./run_local_demo.sh critical_fire_demo normal
./run_local_demo.sh water_tank_drop normal
./run_local_demo.sh smoke_spike sprinkler_failure
./run_local_demo.sh smoke_spike no_response
```

In `auto_random`, smoke spikes, sustained smoke incidents, water tank drops, missing readings, frozen sensors, sprinkler failures, and no-response feedback may appear naturally during the run.

## What Setup Does

`./setup/setup_local_demo.sh`:

- creates or verifies the `bushfire_sentinel` Splunk index
- creates or updates the `bushfire_sentinel_json` sourcetype
- configures Splunk file monitors for `logs/*.jsonl`
- imports `splunk/bushfire_sentinel_dashboard_studio.json`
- starts Node-RED if needed
- merge-deploys `node_red/bushfire_sentinel_flow.json`

The setup script uses index time for dashboard freshness, so a reset also clears local JSONL files and avoids stale historical payload timestamps.

The runtime launcher does not configure Splunk and does not deploy the Node-RED flow by default. It starts Node-RED if needed, verifies the project flow, then starts the Python demo runner.

## Useful Commands

Run setup checks without changing Splunk or Node-RED:

```bash
./setup/setup_local_demo.sh --check
```

Deploy the Node-RED flow manually:

```bash
python scripts/deploy_node_red_flow.py
```

Run Python publishers without requiring Node-RED:

```bash
REQUIRE_NODE_RED=0 ./run_local_demo.sh
```

Use a different Python runtime:

```bash
PYTHON_BIN=/path/to/python ./run_local_demo.sh
```

Test Splunk data after setup:

```text
index=bushfire_sentinel sourcetype=bushfire_sentinel_json | head 20
```

## Repository Layout

```text
config/       Example MQTT/AWS config and demo site/scenario data
node_red/     Node-RED flow and function-node source
scripts/      Helper scripts, including Node-RED merge deployment
setup/        One-time local setup for Splunk and Node-RED
splunk/       Dashboard Studio JSON
src/          Python collectors, simulators, schemas, and MQTT client
logs/         Runtime JSONL output, ignored except .gitkeep
```

## Notes

`sprinkler_status` is actuator feedback, not an environmental sensor. Node-RED publishes `sprinkler_command`; `src/actuator_simulator.py` returns `sprinkler_status`.

`fire_risk` and `response_capacity` are separate:

- `fire_risk`: temperature, humidity, wind, precipitation, smoke, and soil dryness
- `response_capacity`: water tank level and actuator feedback
- `overall_system_status`: combined operational state

AWS IoT nodes in the Node-RED flow are placeholders. Add real AWS endpoint and certificate details in Node-RED before using the cloud path.
