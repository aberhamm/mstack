"""Integration fixtures for the private Paperclip settings contract."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
from shutil import which
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('paperclip_config.py')
spec = importlib.util.spec_from_file_location('paperclip_config', SCRIPT)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '--allow-empty', '-qm', 'fixture'], check=True)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.patch = patch.dict(os.environ, {'HOME': str(self.home)})
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.profile = config.profile_path()
        self.profile.parent.mkdir(parents=True)
        self.profile.write_text(json.dumps({'version': 1, 'profiles': {'local': {'api_base': 'http://127.0.0.1:3100', 'auth_file': str(self.home / 'auth.json')}}}))
        self.binding = dict(version=1, mode='enabled', profile='local', company_id='company', project_id='project', repository_id='repository')

    def test_unconfigured_read_only(self):
        self.assertEqual(config.status(self.repo)['state'], 'unconfigured')
        self.assertFalse(config.binding_path(self.repo).exists())

    def test_detached_identity_and_local_settings(self):
        other = self.root / 'worktree'
        subprocess.run(['git', '-C', str(self.repo), 'worktree', 'add', '--detach', '-q', str(other)], check=True)
        local = self.repo / '.mstack'
        local.mkdir()
        settings = local / 'config.json'
        settings.write_text('{"health":{"custom":false}}')
        config.configure(self.repo, self.binding)
        self.assertEqual(config.status(other), config.status(self.repo))
        self.assertEqual(settings.read_text(), '{"health":{"custom":false}}')
        subprocess.run(['git', '-C', str(self.repo), 'remote', 'add', 'renamed', 'https://example.invalid/new.git'], check=True)
        self.assertEqual(config.status(other)['project_id'], 'project')

    def test_disabled_declined_without_profile(self):
        self.profile.unlink()
        for mode in ('disabled', 'declined'):
            value = dict(self.binding, mode=mode, profile=None)
            self.assertEqual(config.configure(self.repo, value)['state'], mode)
        self.assertEqual(config.disable(self.repo)['state'], 'disabled')

    def test_closed_schema_no_secrets(self):
        with self.assertRaises(config.ConfigError):
            config.configure(self.repo, dict(self.binding, token='do-not-print'))
        with self.assertRaises(config.ConfigError):
            config.validate_profiles({'version': 1, 'profiles': {'local': {'api_base': 'http://user:secret@example.invalid', 'auth_file': '/tmp/auth'}}})
        config.configure(self.repo, self.binding)
        with self.assertRaises(config.ConfigError):
            config.configure(self.repo, dict(self.binding, repository_id='replacement'))

    def test_malformed_missing_profile_and_permissions(self):
        config.configure(self.repo, self.binding)
        self.assertEqual(config.binding_path(self.repo).stat().st_mode & 0o777, 0o600)
        self.profile.write_text('{"version":1,"profiles":{}}')
        with self.assertRaises(config.ConfigError):
            config.status(self.repo)
        config.binding_path(self.repo).write_text('{"secret":"hidden"')
        with self.assertRaisesRegex(config.ConfigError, 'valid settings JSON'):
            config.status(self.repo)

    def test_lock_timeout_preserves_existing(self):
        config.configure(self.repo, self.binding)
        path = config.binding_path(self.repo)
        previous = path.read_bytes()
        path.with_suffix('.lock').mkdir()
        with self.assertRaises(config.ConfigError):
            with config.locked(path, timeout=0.01):
                pass
        self.assertEqual(path.read_bytes(), previous)

    def test_existing_shell_without_optional_runtimes(self):
        binaries = self.root / 'bin'
        binaries.mkdir()
        for name in ('bash', 'git', 'dirname', 'pwd', 'cat', 'sed', 'awk', 'mktemp', 'rm', 'mkdir', 'date', 'tr', 'head', 'cut', 'basename'):
            target = which(name)
            if target:
                (binaries / name).symlink_to(target)
        environment = dict(os.environ, PATH=str(binaries))
        script = SCRIPT.with_name('config.sh')
        for mode in ('unconfigured', 'disabled', 'declined'):
            if mode != 'unconfigured':
                config.configure(self.repo, dict(self.binding, mode=mode, profile=None))
            result = subprocess.run([str(binaries / 'bash'), str(script), 'show'], cwd=self.repo, env=environment, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"health"', result.stdout)

    def test_missing_test_module_fails(self):
        result = subprocess.run(['python3', '-m', 'unittest', 'missing_paperclip_tests_module'], cwd=self.root, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
