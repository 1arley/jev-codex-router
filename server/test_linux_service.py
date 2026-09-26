"""The Linux service contract: one systemd --user unit, no launchd, no surprise.

`install-service.sh` dispatches to install-service-linux.sh, and `render` is the
only mode a test may use: it prints the unit and touches neither systemd nor
$XDG_CONFIG_HOME. That separation is the point -- a test that enabled the
developer's own unit would be a test that acts on the machine it runs on.
"""

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "server" / "install-service-linux.sh"


def render(env_overrides):
    env = {**os.environ, **env_overrides}
    result = subprocess.run(
        ["sh", str(INSTALLER), "render"],
        check=True,
        env=env,
        capture_output=True,
        text=True,
    )
    return result.stdout


class LinuxServiceUnit(unittest.TestCase):
    def test_render_writes_the_expected_unit(self):
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            unit = render({
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / "config"),
                "XDG_STATE_HOME": str(home / "state"),
                "CODEX_ROUTER_STATE_DIR": str(home / ".codex" / "codex-router"),
            })
        self.assertIn("ExecStart=", unit)
        self.assertIn("server/jev_server.py", unit)
        self.assertIn("Restart=always", unit)
        self.assertIn("WantedBy=default.target", unit)
        self.assertIn(f'Environment=CODEX_HOME="{home}/.codex"', unit)
        self.assertIn(
            f'Environment=CODEX_ROUTER_STATE_DIR="{home}/.codex/codex-router"', unit
        )
        self.assertIn(f"StandardOutput=append:{home}/state/jev-codex-router", unit)
        self.assertNotIn("JEV_ENV_FILE", unit)

    def test_render_honours_an_explicit_env_file(self):
        unit = render({"JEV_ENV_FILE": "/etc/jev.env"})
        self.assertIn('Environment=JEV_ENV_FILE="/etc/jev.env"', unit)

    def test_render_escapes_percent_for_systemd(self):
        # A literal % is a systemd specifier; an unescaped one silently changes
        # the value systemd starts the server with.
        unit = render({"CODEX_ROUTER_STATE_DIR": "/srv/100%state"})
        self.assertIn('Environment=CODEX_ROUTER_STATE_DIR="/srv/100%%state"', unit)
        self.assertNotIn('"/srv/100%state"', unit)

    def test_render_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            render({
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / "config"),
                "XDG_STATE_HOME": str(home / "state"),
            })
            self.assertEqual(list(home.iterdir()), [])

    def test_installer_rejects_an_unknown_verb(self):
        result = subprocess.run(
            ["sh", str(INSTALLER), "definitely-not-a-verb"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
