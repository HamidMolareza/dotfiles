from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib import error as urllib_error


SCRIPT = Path(__file__).resolve().parents[1] / "codex-auth"


def load_codex_auth_module():
    module_name = "codex_auth_test_target"
    loader = importlib.machinery.SourceFileLoader(module_name, str(SCRIPT))
    spec = importlib.util.spec_from_loader(module_name, loader)
    if spec is None:
        raise RuntimeError(f"Could not load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    loader.exec_module(module)
    return module


codex_auth = load_codex_auth_module()


class NonClosingStringIO(io.StringIO):
    def close(self) -> None:
        pass


class FakeResponse:
    def __init__(self, body: bytes = b'{"ok": true}', *, read_error: OSError | None = None) -> None:
        self.body = body
        self.read_error = read_error
        self.status = 200

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        return None

    def read(self) -> bytes:
        if self.read_error is not None:
            raise self.read_error
        return self.body


class SequencedOpener:
    def __init__(self, outcomes: list[FakeResponse | BaseException]) -> None:
        self.outcomes = list(outcomes)
        self.call_count = 0

    def open(self, request, *, timeout: float):
        del request, timeout
        self.call_count += 1
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


class CodexAuthDependencyTests(unittest.TestCase):
    def test_custom_managed_venv_path_takes_precedence(self) -> None:
        with mock.patch.dict(
            codex_auth.os.environ,
            {
                codex_auth.VENV_ENV_VAR: "~/custom-codex-auth-venv",
                "XDG_DATA_HOME": "/ignored",
            },
        ):
            self.assertEqual(
                Path.home() / "custom-codex-auth-venv",
                codex_auth.managed_venv_path(),
            )

    def test_managed_venv_path_uses_xdg_data_home(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            with mock.patch.dict(codex_auth.os.environ, {"XDG_DATA_HOME": temporary_directory}):
                codex_auth.os.environ.pop(codex_auth.VENV_ENV_VAR, None)

                self.assertEqual(
                    Path(temporary_directory) / "codex-auth" / "venv",
                    codex_auth.managed_venv_path(),
                )

    def test_help_does_not_reexec_with_managed_python(self) -> None:
        with mock.patch.object(codex_auth, "managed_venv_path") as managed_venv_path:
            codex_auth.maybe_reexec_with_managed_python(["--help"])

        managed_venv_path.assert_not_called()

    def test_reexecs_with_managed_python_when_available(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            venv_path = Path(temporary_directory) / "venv"
            python_path = venv_path / "bin" / "python"
            python_path.parent.mkdir(parents=True)
            python_path.touch(mode=0o755)

            with (
                mock.patch.dict(codex_auth.os.environ, {codex_auth.VENV_ENV_VAR: str(venv_path)}),
                mock.patch.object(codex_auth.sys, "prefix", "/usr"),
                mock.patch.object(codex_auth.os, "execv") as execv,
            ):
                codex_auth.maybe_reexec_with_managed_python(["--dir", "/tmp/auth"])

            execv.assert_called_once_with(
                str(python_path),
                [str(python_path), str(SCRIPT.resolve()), "--dir", "/tmp/auth"],
            )

    def test_does_not_reexec_when_already_in_managed_venv(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            venv_path = Path(temporary_directory) / "venv"
            python_path = venv_path / "bin" / "python"
            python_path.parent.mkdir(parents=True)
            python_path.touch(mode=0o755)

            with (
                mock.patch.dict(codex_auth.os.environ, {codex_auth.VENV_ENV_VAR: str(venv_path)}),
                mock.patch.object(codex_auth.sys, "prefix", str(venv_path)),
                mock.patch.object(codex_auth.os, "execv") as execv,
            ):
                codex_auth.maybe_reexec_with_managed_python([])

            execv.assert_not_called()

    def test_broken_managed_python_does_not_stop_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            venv_path = Path(temporary_directory) / "venv"
            python_path = venv_path / "bin" / "python"
            python_path.parent.mkdir(parents=True)
            python_path.touch(mode=0o755)

            with (
                mock.patch.dict(codex_auth.os.environ, {codex_auth.VENV_ENV_VAR: str(venv_path)}),
                mock.patch.object(codex_auth.sys, "prefix", "/usr"),
                mock.patch.object(codex_auth.os, "execv", side_effect=OSError("broken interpreter")),
            ):
                codex_auth.maybe_reexec_with_managed_python([])

    def test_missing_prompt_toolkit_is_reported_as_optional_dependency(self) -> None:
        real_import = __import__

        def import_without_prompt_toolkit(name, *args, **kwargs):
            if name.startswith("prompt_toolkit"):
                raise ModuleNotFoundError("No module named 'prompt_toolkit'")
            return real_import(name, *args, **kwargs)

        with (
            mock.patch("builtins.__import__", side_effect=import_without_prompt_toolkit),
            mock.patch.object(
                codex_auth.importlib_metadata,
                "version",
                side_effect=codex_auth.importlib_metadata.PackageNotFoundError,
            ),
            self.assertRaises(codex_auth.PromptToolkitUnavailable) as raised,
        ):
            codex_auth.prompt_toolkit_choice([], None, None)

        self.assertEqual("prompt-toolkit is not installed", str(raised.exception))

    def test_incompatible_prompt_toolkit_version_is_reported(self) -> None:
        real_import = __import__

        def import_without_choice(name, *args, **kwargs):
            if name.startswith("prompt_toolkit"):
                raise ImportError("cannot import name 'choice'")
            return real_import(name, *args, **kwargs)

        with (
            mock.patch("builtins.__import__", side_effect=import_without_choice),
            mock.patch.object(codex_auth.importlib_metadata, "version", return_value="3.0.43"),
            self.assertRaises(codex_auth.PromptToolkitUnavailable) as raised,
        ):
            codex_auth.prompt_toolkit_choice([], None, None)

        self.assertIn("prompt-toolkit 3.0.43", str(raised.exception))

    def test_dependency_failure_prints_hint_and_uses_numbered_fallback(self) -> None:
        tty_input = NonClosingStringIO("1\n")
        tty_output = NonClosingStringIO()
        selected = mock.sentinel.selected

        with (
            mock.patch("builtins.open", side_effect=[tty_input, tty_output]),
            mock.patch.object(
                codex_auth,
                "prompt_toolkit_choice",
                side_effect=codex_auth.PromptToolkitUnavailable("prompt-toolkit is not installed"),
            ),
            mock.patch.object(codex_auth, "fallback_choice", return_value=selected) as fallback_choice,
        ):
            result = codex_auth.choose_auth_file([])

        self.assertIs(selected, result)
        fallback_choice.assert_called_once()
        self.assertIn(codex_auth.PROMPT_TOOLKIT_REQUIREMENT, tty_output.getvalue())
        self.assertIn(str(codex_auth.PROMPT_TOOLKIT_SETUP_GUIDE), tty_output.getvalue())

    def test_runtime_import_error_is_not_hidden_by_numbered_fallback(self) -> None:
        tty_input = NonClosingStringIO()
        tty_output = NonClosingStringIO()

        with (
            mock.patch("builtins.open", side_effect=[tty_input, tty_output]),
            mock.patch.object(codex_auth, "prompt_toolkit_choice", side_effect=ImportError("runtime failure")),
            mock.patch.object(codex_auth, "fallback_choice") as fallback_choice,
            self.assertRaisesRegex(ImportError, "runtime failure"),
        ):
            codex_auth.choose_auth_file([])

        fallback_choice.assert_not_called()

    def test_requirement_manifest_matches_runtime_hint(self) -> None:
        self.assertEqual(
            codex_auth.PROMPT_TOOLKIT_REQUIREMENT,
            codex_auth.PROMPT_TOOLKIT_REQUIREMENTS_FILE.read_text(encoding="utf-8").strip(),
        )


class CodexAuthRetryTests(unittest.TestCase):
    def fetch_with(self, opener: SequencedOpener):
        proxy_config = codex_auth.UsageProxyConfig(display="test")
        with (
            mock.patch.object(codex_auth, "build_usage_opener", return_value=opener),
            mock.patch.object(codex_auth.time, "sleep") as sleep,
        ):
            payload = codex_auth.fetch_usage_payload("https://example.test/usage", {}, proxy_config)
        return payload, sleep

    def test_retries_five_network_failures_before_success(self) -> None:
        failures = [
            urllib_error.URLError(ConnectionResetError("offline"))
            for _ in range(codex_auth.HTTP_MAX_RETRIES)
        ]
        opener = SequencedOpener([*failures, FakeResponse()])

        payload, sleep = self.fetch_with(opener)

        self.assertEqual({"ok": True}, payload)
        self.assertEqual(6, opener.call_count)
        self.assertEqual(
            [mock.call(1.0), mock.call(2.0), mock.call(4.0), mock.call(8.0), mock.call(16.0)],
            sleep.call_args_list,
        )

    def test_reports_network_error_after_all_retries_fail(self) -> None:
        failures = [
            urllib_error.URLError(ConnectionResetError("offline"))
            for _ in range(codex_auth.HTTP_MAX_RETRIES + 1)
        ]
        opener = SequencedOpener(failures)
        proxy_config = codex_auth.UsageProxyConfig(display="test")

        with (
            mock.patch.object(codex_auth, "build_usage_opener", return_value=opener),
            mock.patch.object(codex_auth.time, "sleep") as sleep,
            self.assertRaises(codex_auth.QuotaProbeError) as raised,
        ):
            codex_auth.fetch_usage_payload("https://example.test/usage", {}, proxy_config)

        self.assertEqual(codex_auth.NETWORK_ERROR, raised.exception.status)
        self.assertTrue(raised.exception.transient)
        self.assertEqual(6, opener.call_count)
        self.assertEqual(5, sleep.call_count)

    def test_retries_direct_response_read_network_error(self) -> None:
        opener = SequencedOpener(
            [
                FakeResponse(read_error=ConnectionResetError("connection reset while reading")),
                FakeResponse(),
            ]
        )

        payload, sleep = self.fetch_with(opener)

        self.assertEqual({"ok": True}, payload)
        self.assertEqual(2, opener.call_count)
        sleep.assert_called_once_with(1.0)

    def test_retries_timeout_before_success(self) -> None:
        opener = SequencedOpener([socket.timeout("timed out"), FakeResponse()])

        payload, sleep = self.fetch_with(opener)

        self.assertEqual({"ok": True}, payload)
        self.assertEqual(2, opener.call_count)
        sleep.assert_called_once_with(1.0)

    def test_does_not_retry_unauthorized_response(self) -> None:
        unauthorized = urllib_error.HTTPError(
            "https://example.test/usage",
            401,
            "Unauthorized",
            {},
            io.BytesIO(b'{"error": "unauthorized"}'),
        )
        opener = SequencedOpener([unauthorized])
        proxy_config = codex_auth.UsageProxyConfig(display="test")

        with (
            mock.patch.object(codex_auth, "build_usage_opener", return_value=opener),
            mock.patch.object(codex_auth.time, "sleep") as sleep,
            self.assertRaises(codex_auth.QuotaProbeError) as raised,
        ):
            codex_auth.fetch_usage_payload("https://example.test/usage", {}, proxy_config)

        self.assertEqual(codex_auth.UNAUTHORIZED, raised.exception.status)
        self.assertFalse(raised.exception.transient)
        self.assertEqual(1, opener.call_count)
        sleep.assert_not_called()

    def test_retries_retryable_http_response(self) -> None:
        unavailable = urllib_error.HTTPError(
            "https://example.test/usage",
            503,
            "Service Unavailable",
            {},
            io.BytesIO(b""),
        )
        opener = SequencedOpener([unavailable, FakeResponse()])

        payload, sleep = self.fetch_with(opener)

        self.assertEqual({"ok": True}, payload)
        self.assertEqual(2, opener.call_count)
        sleep.assert_called_once_with(1.0)


if __name__ == "__main__":
    unittest.main()
