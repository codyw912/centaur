from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


ENTRYPOINT_SH = Path(__file__).resolve().parents[2] / "sandbox" / "entrypoint.sh"


def _write_codex_harness_config(home: Path) -> Path:
    harness_dir = home / "harness"
    codex_dir = harness_dir / "codex"
    codex_dir.mkdir(parents=True)
    (codex_dir / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-5.5"',
                'model_reasoning_effort = "low"',
                'plan_mode_reasoning_effort = "high"',
                'approval_policy = "on-request"',
                'approvals_reviewer = "user"',
                'web_search = "live"',
                'personality = "pragmatic"',
                'sandbox_mode = "workspace-write"',
                "check_for_update_on_startup = true",
                "suppress_unstable_features_warning = true",
                'service_tier = "fast"',
                "",
                "[tools]",
                "view_image = true",
                "",
                "[features]",
                "goals = true",
                "memories = true",
                "code_mode = true",
                "hooks = true",
                "browser_use = true",
                "computer_use = true",
                "enable_fanout = true",
                "runtime_metrics = true",
                "",
                "[features.multi_agent_v2]",
                "enabled = true",
                "max_concurrent_threads_per_session = 6",
                "",
                "[agents]",
                "max_depth = 2",
                "job_max_runtime_seconds = 1800",
                "",
            ]
        )
    )
    return harness_dir


def _write_fake_codex(bin_dir: Path) -> Path:
    bin_dir.mkdir(parents=True)
    codex = bin_dir / "codex"
    codex.write_text(
        "\n".join(
            [
                "#!/bin/sh",
                "set -eu",
                'printf "%s\\n" "$*" >> "$CODEX_FAKE_LOG"',
                'if [ "$1" = "login" ] && [ "${2:-}" = "status" ]; then',
                '  test -f "$CODEX_FAKE_HOME/logged-in"',
                "  exit $?",
                "fi",
                'if [ "$1" = "login" ] && [ "${2:-}" = "--with-access-token" ]; then',
                "  token=$(cat)",
                '  if [ "$token" = "secret-token" ]; then',
                '    touch "$CODEX_FAKE_HOME/logged-in"',
                "    exit 0",
                "  fi",
                "  exit 2",
                "fi",
                'if [ "$1" = "login" ] && [ "${2:-}" = "--with-api-key" ]; then',
                "  cat >/dev/null",
                "  exit 0",
                "fi",
                "exit 64",
                "",
            ]
        )
    )
    codex.chmod(0o755)
    return codex


def test_sandbox_entrypoint_bootstraps_mock_google_adc(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / ".config" / "amp").mkdir(parents=True)
    harness_dir = _write_codex_harness_config(home)

    result = subprocess.run(
        [
            "bash",
            str(ENTRYPOINT_SH),
            "sh",
            "-lc",
            'printf \'%s\n\' "$GOOGLE_APPLICATION_CREDENTIALS" && cat "$GOOGLE_APPLICATION_CREDENTIALS"',
        ],
        check=False,
        capture_output=True,
        text=True,
        env={
            "HOME": str(home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "CENTAUR_HARNESS_CONFIG_DIR": str(harness_dir),
        },
    )

    assert result.returncode == 0, result.stderr or result.stdout
    adc_path, adc_json = result.stdout.split("\n", 1)
    assert adc_path == str(
        home / ".config" / "gcloud" / "application_default_credentials.json"
    )
    assert Path(adc_path).is_file()
    adc = json.loads(adc_json)
    assert adc == {
        "type": "service_account",
        "project_id": "centaur-sandbox",
        "private_key_id": "0000000000000000000000000000000000000000",
        "private_key": adc["private_key"],
        "client_email": "mock@creds.com",
        "client_id": "100000000000000000000",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
        "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/mock%40creds.com",
        "universe_domain": "googleapis.com",
    }
    assert adc["private_key"].startswith("-----BEGIN PRIVATE KEY-----\n")
    assert adc["private_key"].endswith("-----END PRIVATE KEY-----\n")

    codex_config = (home / ".codex" / "config.toml").read_text()
    assert 'model = "gpt-5.5"' in codex_config
    assert 'model_reasoning_effort = "low"' in codex_config
    assert 'plan_mode_reasoning_effort = "high"' in codex_config
    assert 'approval_policy = "on-request"' in codex_config
    assert 'sandbox_mode = "workspace-write"' in codex_config
    assert 'service_tier = "fast"' in codex_config
    assert "max_concurrent_threads_per_session = 6" in codex_config


def test_sandbox_entrypoint_installs_codex_harness_config(tmp_path: Path) -> None:
    home = tmp_path / "home"
    harness_dir = _write_codex_harness_config(home)

    result = subprocess.run(
        [
            "bash",
            str(ENTRYPOINT_SH),
            "sh",
            "-lc",
            'cat "$HOME/.codex/config.toml"',
        ],
        check=False,
        capture_output=True,
        text=True,
        env={
            "HOME": str(home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "CENTAUR_HARNESS_CONFIG_DIR": str(harness_dir),
        },
    )

    assert result.returncode == 0, result.stderr or result.stdout
    assert result.stdout == (harness_dir / "codex" / "config.toml").read_text()


def test_sandbox_entrypoint_bootstraps_codex_access_token_and_unsets_it(
    tmp_path: Path,
) -> None:
    home = tmp_path / "home"
    harness_dir = _write_codex_harness_config(home)
    fake_home = tmp_path / "fake-codex"
    fake_home.mkdir()
    fake_log = tmp_path / "codex.log"
    bin_dir = tmp_path / "bin"
    _write_fake_codex(bin_dir)

    result = subprocess.run(
        [
            "bash",
            str(ENTRYPOINT_SH),
            "sh",
            "-lc",
            'if printenv CODEX_ACCESS_TOKEN >/dev/null; then exit 9; fi; printf "done"',
        ],
        check=False,
        capture_output=True,
        text=True,
        env={
            "HOME": str(home),
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "CENTAUR_HARNESS_CONFIG_DIR": str(harness_dir),
            "CODEX_AUTH_MODE": "access_token",
            "CODEX_ACCESS_TOKEN": "secret-token",
            "CODEX_FAKE_HOME": str(fake_home),
            "CODEX_FAKE_LOG": str(fake_log),
        },
    )

    assert result.returncode == 0, result.stderr or result.stdout
    assert result.stdout == "done"
    assert result.stderr == ""
    assert fake_log.read_text().splitlines() == [
        "login status",
        "login --with-access-token",
        "login status",
    ]
    assert "secret-token" not in result.stdout
    assert "secret-token" not in result.stderr
    assert "secret-token" not in fake_log.read_text()


def test_sandbox_entrypoint_accepts_existing_codex_login_without_direct_token(
    tmp_path: Path,
) -> None:
    home = tmp_path / "home"
    harness_dir = _write_codex_harness_config(home)
    fake_home = tmp_path / "fake-codex"
    fake_home.mkdir()
    (fake_home / "logged-in").touch()
    fake_log = tmp_path / "codex.log"
    bin_dir = tmp_path / "bin"
    _write_fake_codex(bin_dir)

    result = subprocess.run(
        ["bash", str(ENTRYPOINT_SH), "sh", "-lc", "printf done"],
        check=False,
        capture_output=True,
        text=True,
        env={
            "HOME": str(home),
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "CENTAUR_HARNESS_CONFIG_DIR": str(harness_dir),
            "CODEX_AUTH_MODE": "access_token",
            "CODEX_FAKE_HOME": str(fake_home),
            "CODEX_FAKE_LOG": str(fake_log),
        },
    )

    assert result.returncode == 0, result.stderr or result.stdout
    assert result.stdout == "done"
    assert result.stderr == ""
    assert fake_log.read_text().splitlines() == ["login status", "login status"]


def test_sandbox_entrypoint_fails_codex_access_token_mode_without_valid_login(
    tmp_path: Path,
) -> None:
    home = tmp_path / "home"
    harness_dir = _write_codex_harness_config(home)
    fake_home = tmp_path / "fake-codex"
    fake_home.mkdir()
    fake_log = tmp_path / "codex.log"
    bin_dir = tmp_path / "bin"
    _write_fake_codex(bin_dir)

    result = subprocess.run(
        ["bash", str(ENTRYPOINT_SH), "sh", "-lc", "printf unreachable"],
        check=False,
        capture_output=True,
        text=True,
        env={
            "HOME": str(home),
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "CENTAUR_HARNESS_CONFIG_DIR": str(harness_dir),
            "CODEX_AUTH_MODE": "access_token",
            "CODEX_FAKE_HOME": str(fake_home),
            "CODEX_FAKE_LOG": str(fake_log),
        },
    )

    assert result.returncode == 1
    assert (
        "codex login status failed in access_token mode; configure brokered Codex auth"
        in result.stderr
    )
    assert result.stdout == ""
    assert fake_log.read_text().splitlines() == ["login status", "login status"]
