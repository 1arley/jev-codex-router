"""Which Jev answers, and with whose key.

The endpoint, the model and the credential are operator configuration, read
from the same env files the key always came from. That indirection exists so a
System One compatible gateway can answer instead of the hosted TypeSafe API --
without a code change, and without the key ever reaching a command line.

The compatibility contract these tests protect is the request and response
shape: POST {model, state, questions} with a bearer token, answered with an
`answers` object of typed decisions. A gateway that changes either half is not
a drop-in, whatever its URL says.
"""

import json
import os
import tempfile
import unittest
from unittest import mock

import jev_server as jev
from routing_policy import QUESTIONS


class ProviderConfig(unittest.TestCase):
    def env(self, tmp, **values):
        path = os.path.join(tmp, "jev.env")
        with open(path, "w", encoding="utf-8") as fh:
            for name, value in values.items():
                fh.write(f"{name}={value}\n")
        return mock.patch.multiple(
            jev, ENV_PATH=os.path.join(tmp, "missing.env"), HOME=tmp,
        ), mock.patch.dict(
            os.environ, {"JEV_ENV_FILE": path}, clear=True,
        )

    def test_env_file_selects_endpoint_model_and_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            (paths, environ) = self.env(
                tmp,
                JEV_API_URL="http://127.0.0.1:20128/v1/systemone",
                JEV_MODEL="oc/jev-1.13-free",
                JEV_API_KEY="local-key",
            )
            with paths, environ:
                self.assertEqual(jev.provider_setting("JEV_API_URL"),
                                 "http://127.0.0.1:20128/v1/systemone")
                self.assertEqual(jev.provider_setting("JEV_MODEL"), "oc/jev-1.13-free")
                self.assertEqual(jev.load_key(), "local-key")

    def test_typesafe_key_still_works_for_the_hosted_api(self):
        with tempfile.TemporaryDirectory() as tmp:
            (paths, environ) = self.env(tmp, TYPESAFE_API_KEY="hosted-key")
            with paths, environ:
                self.assertEqual(jev.load_key(), "hosted-key")
                self.assertEqual(jev.provider_setting("JEV_API_URL", jev.DEFAULT_API),
                                 jev.DEFAULT_API)
                self.assertEqual(jev.provider_setting("JEV_MODEL", jev.DEFAULT_MODEL),
                                 jev.DEFAULT_MODEL)

    def test_jev_api_key_wins_over_the_typesafe_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            (paths, environ) = self.env(
                tmp, JEV_API_KEY="local-key", TYPESAFE_API_KEY="hosted-key")
            with paths, environ:
                self.assertEqual(jev.load_key(), "local-key")

    def test_process_environment_is_the_last_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(jev, "ENV_PATH", os.path.join(tmp, "missing.env")), \
                 mock.patch.object(jev, "HOME", tmp), \
                 mock.patch.dict(
                     os.environ,
                     {"JEV_ENV_FILE": "", "JEV_API_URL": "http://127.0.0.1:9/v1/systemone"},
                     clear=True,
                 ):
                self.assertEqual(jev.provider_setting("JEV_API_URL"),
                                 "http://127.0.0.1:9/v1/systemone")

    def test_only_http_endpoints_are_accepted(self):
        # A typo'd scheme must not become a urllib request to an unknown handler.
        self.assertEqual(jev.resolve_api_url("file:///etc/passwd"), jev.DEFAULT_API)
        self.assertEqual(jev.resolve_api_url("127.0.0.1:20128"), jev.DEFAULT_API)
        self.assertEqual(jev.resolve_api_url("http://127.0.0.1:20128/v1/systemone/"),
                         "http://127.0.0.1:20128/v1/systemone")

    def test_call_jev_keeps_the_system_one_request_shape(self):
        """A drop-in gateway is only a drop-in if it accepts this exact body."""
        sent = {}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return json.dumps({"answers": {}}).encode()

        def fake_urlopen(request, timeout=None):
            sent["url"] = request.full_url
            sent["auth"] = request.headers["Authorization"]
            sent["body"] = json.loads(request.data)
            return FakeResponse()

        with mock.patch.object(jev, "API", "http://127.0.0.1:20128/v1/systemone"), \
             mock.patch.object(jev, "MODEL", "oc/jev-1.13-free"), \
             mock.patch.object(jev.urllib.request, "urlopen", fake_urlopen):
            jev.call_jev("local-key", "state text", QUESTIONS)

        self.assertEqual(sent["url"], "http://127.0.0.1:20128/v1/systemone")
        self.assertEqual(sent["auth"], "Bearer local-key")
        self.assertEqual(sent["body"]["model"], "oc/jev-1.13-free")
        self.assertEqual(sent["body"]["state"], "state text")
        self.assertEqual(sent["body"]["questions"], QUESTIONS)


if __name__ == "__main__":
    unittest.main()
