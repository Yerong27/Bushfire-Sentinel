#!/usr/bin/env python3
"""Merge the Bushfire Sentinel flow into a running Node-RED instance."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


PROJECT_TAB_ID = "tab_bushfire_sentinel"
PROJECT_TAB_LABEL = "Bushfire Sentinel CPS"
LOG_DIR_TOKEN = "${BUSHFIRE_SENTINEL_LOG_DIR}"


def request_json(url: str, method: str = "GET", body: object | None = None) -> object:
    data = None
    headers = {
        "Accept": "application/json",
        "Node-RED-API-Version": "v2",
    }

    token = os.getenv("NODE_RED_BEARER_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
        headers["Node-RED-Deployment-Type"] = os.getenv("NODE_RED_DEPLOYMENT_TYPE", "full")

    req = Request(url, data=data, headers=headers, method=method)
    with urlopen(req, timeout=10) as response:
        raw = response.read().decode("utf-8")
    return json.loads(raw) if raw else {}


def split_flow_response(payload: object) -> tuple[list[dict], str | None, bool]:
    if isinstance(payload, dict) and isinstance(payload.get("flows"), list):
        return payload["flows"], payload.get("rev"), True
    if isinstance(payload, list):
        return payload, None, False
    raise ValueError("Unexpected Node-RED /flows response shape")


def project_config_ids(project_flow: list[dict]) -> set[str]:
    tab_ids = {node["id"] for node in project_flow if node.get("type") == "tab"}
    config_ids: set[str] = set()
    for node in project_flow:
        if node.get("type") == "tab":
            continue
        if node.get("z") in tab_ids:
            continue
        config_ids.add(node["id"])
    return config_ids


def merge_flows(existing: list[dict], project_flow: list[dict]) -> tuple[list[dict], int]:
    project_tab_ids = {node["id"] for node in project_flow if node.get("type") == "tab"}
    project_tab_labels = {
        node.get("label")
        for node in project_flow
        if node.get("type") == "tab" and node.get("label")
    }
    project_ids = {node["id"] for node in project_flow}
    config_ids = project_config_ids(project_flow)

    tabs_to_replace = set(project_tab_ids)
    for node in existing:
        if node.get("type") == "tab" and node.get("label") in project_tab_labels:
            tabs_to_replace.add(node["id"])

    kept: list[dict] = []
    removed = 0
    for node in existing:
        node_id = node.get("id")
        node_type = node.get("type")
        node_tab = node.get("z")

        replace_node = (
            node_id in project_ids
            or node_id in config_ids
            or node_tab in tabs_to_replace
            or (node_type == "tab" and node_id in tabs_to_replace)
        )

        if replace_node:
            removed += 1
        else:
            kept.append(node)

    return [*kept, *project_flow], removed


def deploy(url: str, body: object) -> None:
    try:
        request_json(url, "POST", body)
    except HTTPError as exc:
        if isinstance(body, dict) and exc.code in {400, 409}:
            request_json(url, "POST", body.get("flows", []))
            return
        raise


def flow_tabs(flows: list[dict]) -> list[tuple[str, str]]:
    return [
        (str(node.get("id", "")), str(node.get("label", "")))
        for node in flows
        if node.get("type") == "tab"
    ]


def resolve_log_dir(flow_path: Path) -> str:
    log_dir = os.getenv("BUSHFIRE_SENTINEL_LOG_DIR")
    if log_dir:
        return str(Path(log_dir).expanduser().resolve())
    return str((flow_path.resolve().parents[1] / "logs").resolve())


def materialize_file_paths(project_flow: list[dict], flow_path: Path) -> None:
    log_dir = resolve_log_dir(flow_path)
    for node in project_flow:
        if node.get("type") != "file":
            continue
        filename = node.get("filename")
        if isinstance(filename, str) and filename.startswith(LOG_DIR_TOKEN):
            node["filename"] = filename.replace(LOG_DIR_TOKEN, log_dir, 1)


def verify_deploy(url: str) -> list[tuple[str, str]]:
    payload = request_json(url)
    flows, _rev, _supports_v2 = split_flow_response(payload)
    tabs = flow_tabs(flows)
    has_project_tab = any(
        tab_id == PROJECT_TAB_ID or label == PROJECT_TAB_LABEL
        for tab_id, label in tabs
    )
    project_node_count = sum(1 for node in flows if node.get("z") == PROJECT_TAB_ID)

    if not has_project_tab or project_node_count == 0:
        tab_list = ", ".join(label or tab_id for tab_id, label in tabs) or "(none)"
        raise RuntimeError(
            "Node-RED accepted the deployment, but verification did not find "
            f"{PROJECT_TAB_LABEL!r}. Current tabs: {tab_list}"
        )

    unresolved_files = [
        node.get("filename", "")
        for node in flows
        if node.get("z") == PROJECT_TAB_ID
        and node.get("type") == "file"
        and LOG_DIR_TOKEN in str(node.get("filename", ""))
    ]
    if unresolved_files:
        files = ", ".join(str(item) for item in unresolved_files)
        raise RuntimeError(
            "Node-RED flow is present, but file nodes still contain unresolved "
            f"{LOG_DIR_TOKEN}: {files}. Rerun setup/setup_local_demo.sh to redeploy."
        )

    return tabs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--node-red-url",
        default=os.getenv("NODE_RED_URL", "http://127.0.0.1:1880"),
        help="Node-RED editor URL, default: %(default)s",
    )
    parser.add_argument(
        "--flow-file",
        default="node_red/bushfire_sentinel_flow.json",
        help="Flow JSON to merge, default: %(default)s",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Only verify that the Bushfire Sentinel flow is present in Node-RED.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print the merge result without deploying")
    args = parser.parse_args()

    flows_url = args.node_red_url.rstrip("/") + "/flows"
    try:
        current_payload = request_json(flows_url)
    except (HTTPError, URLError, TimeoutError) as exc:
        print(f"Could not reach Node-RED Admin API at {flows_url}: {exc}", file=sys.stderr)
        return 1

    existing, rev, supports_v2 = split_flow_response(current_payload)

    if args.verify_only:
        try:
            tabs = verify_deploy(flows_url)
        except (HTTPError, URLError, TimeoutError, RuntimeError) as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print("Node-RED Bushfire Sentinel flow verified.")
        print("Node-RED tabs now:")
        for _tab_id, label in tabs:
            print(f"  - {label}")
        return 0

    flow_path = Path(args.flow_file)
    project_flow = json.loads(flow_path.read_text(encoding="utf-8"))
    if not isinstance(project_flow, list):
        raise ValueError(f"Expected {flow_path} to contain a Node-RED flow array")
    materialize_file_paths(project_flow, flow_path)

    merged, removed = merge_flows(existing, project_flow)
    added = len(project_flow)

    if args.dry_run:
        print(f"Would remove {removed} existing Bushfire Sentinel nodes and add {added} project nodes.")
        print(f"Other existing nodes preserved: {len(existing) - removed}")
        return 0

    body: object = {"flows": merged}
    if supports_v2 and rev:
        body = {"rev": rev, "flows": merged}
    elif not supports_v2:
        body = merged

    try:
        deploy(flows_url, body)
        try:
            tabs = verify_deploy(flows_url)
        except RuntimeError:
            if isinstance(body, dict):
                deploy(flows_url, merged)
                tabs = verify_deploy(flows_url)
            else:
                raise
    except (HTTPError, URLError, TimeoutError) as exc:
        print(f"Could not deploy Node-RED flow at {flows_url}: {exc}", file=sys.stderr)
        return 1
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(
        "Node-RED flow deployed: "
        f"replaced {removed} existing Bushfire Sentinel nodes, "
        f"added {added} project nodes, preserved {len(existing) - removed} other nodes."
    )
    print("Node-RED tabs now:")
    for _tab_id, label in tabs:
        print(f"  - {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
