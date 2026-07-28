from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import socket
import sys
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
