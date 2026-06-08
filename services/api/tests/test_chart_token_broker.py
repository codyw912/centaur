from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[3]
CHART = ROOT / "contrib" / "chart"


def _render_chart(*sets: str) -> list[dict[str, Any]]:
    if shutil.which("helm") is None:
        pytest.skip("helm is not installed")
    args = [
        "helm",
        "template",
        "centaur",
        str(CHART),
        "-n",
        "centaur",
    ]
    for value in sets:
        args.extend(["--set", value])
    result = subprocess.run(
        args,
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        doc
        for doc in yaml.safe_load_all(result.stdout)
        if isinstance(doc, dict) and doc
    ]


def _deployment(docs: list[dict[str, Any]], name_suffix: str) -> dict[str, Any]:
    for doc in docs:
        if doc.get("kind") == "Deployment" and doc["metadata"]["name"].endswith(
            name_suffix
        ):
            return doc
    raise AssertionError(f"Deployment ending with {name_suffix!r} not rendered")


def _network_policy(docs: list[dict[str, Any]], name_suffix: str) -> dict[str, Any]:
    for doc in docs:
        if doc.get("kind") == "NetworkPolicy" and doc["metadata"]["name"].endswith(
            name_suffix
        ):
            return doc
    raise AssertionError(f"NetworkPolicy ending with {name_suffix!r} not rendered")


def _container_env(
    deployment: dict[str, Any], container_name: str
) -> list[dict[str, Any]]:
    containers = deployment["spec"]["template"]["spec"]["containers"]
    for container in containers:
        if container["name"] == container_name:
            return container.get("env", [])
    raise AssertionError(f"container {container_name!r} not found")


def _env_by_name(env: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {entry["name"]: entry for entry in env}


def test_token_broker_inherits_onepassword_connect_token_key() -> None:
    docs = _render_chart(
        "tokenBroker.enabled=true",
        "ironProxy.secretSource=onepassword-connect",
    )

    broker_env = _env_by_name(
        _container_env(_deployment(docs, "-token-broker"), "iron-token-broker")
    )
    assert broker_env["OP_CONNECT_HOST"] == {
        "name": "OP_CONNECT_HOST",
        "value": "http://onepassword-connect:8080",
    }
    assert broker_env["OP_CONNECT_TOKEN"]["valueFrom"]["secretKeyRef"] == {
        "name": "centaur-infra-env",
        "key": "OP_CONNECT_TOKEN",
    }

    api_env = _env_by_name(_container_env(_deployment(docs, "-api"), "api"))
    assert api_env["TOKEN_BROKER_SECRET_SOURCE"] == {
        "name": "TOKEN_BROKER_SECRET_SOURCE",
        "value": "onepassword-connect",
    }


def test_token_broker_can_use_broker_specific_onepassword_connect_token_key() -> None:
    docs = _render_chart(
        "tokenBroker.enabled=true",
        "ironProxy.secretSource=onepassword-connect",
        "tokenBroker.opVault=Broker Tokens",
        "tokenBroker.onepasswordConnect.host=http://broker-connect:8080",
        "tokenBroker.onepasswordConnect.tokenKey=TOKEN_BROKER_OP_CONNECT_TOKEN",
        "tokenBroker.onepasswordConnect.egress.podSelector.app=broker-connect",
    )

    broker_env = _env_by_name(
        _container_env(_deployment(docs, "-token-broker"), "iron-token-broker")
    )
    assert broker_env["OP_CONNECT_HOST"] == {
        "name": "OP_CONNECT_HOST",
        "value": "http://broker-connect:8080",
    }
    assert broker_env["OP_CONNECT_TOKEN"]["valueFrom"]["secretKeyRef"] == {
        "name": "centaur-token-broker-env",
        "key": "TOKEN_BROKER_OP_CONNECT_TOKEN",
    }

    broker_policy = _network_policy(docs, "-token-broker")
    assert "broker-connect" in yaml.safe_dump(broker_policy["spec"]["egress"])

    non_broker_manifests = [
        doc
        for doc in docs
        if doc.get("kind") != "Deployment"
        or not doc["metadata"]["name"].endswith("-token-broker")
    ]
    assert "TOKEN_BROKER_OP_CONNECT_TOKEN" not in yaml.safe_dump(non_broker_manifests)


def test_token_broker_service_account_mode_remains_unchanged() -> None:
    docs = _render_chart(
        "tokenBroker.enabled=true",
        "ironProxy.secretSource=onepassword",
        "tokenBroker.onepasswordServiceAccountTokenKey=TOKEN_BROKER_OP_SERVICE_ACCOUNT_TOKEN",
    )

    broker_env = _env_by_name(
        _container_env(_deployment(docs, "-token-broker"), "iron-token-broker")
    )
    assert "OP_CONNECT_HOST" not in broker_env
    assert "OP_CONNECT_TOKEN" not in broker_env
    assert broker_env["OP_SERVICE_ACCOUNT_TOKEN"]["valueFrom"]["secretKeyRef"] == {
        "name": "centaur-infra-env",
        "key": "TOKEN_BROKER_OP_SERVICE_ACCOUNT_TOKEN",
    }
