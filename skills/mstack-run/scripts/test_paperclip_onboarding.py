"""Scripted onboarding choices against isolated authentication/API fixtures."""
from pathlib import Path
import subprocess
import os
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parent))
import paperclip
import paperclip_config as config
import paperclip_onboarding as onboarding
import test_paperclip_transport as transport_fixture


class OnboardingTests(transport_fixture.TransportTests):
    def setUp(self):
        super().setUp()
        self.binding = config.binding_path(self.repo)
        self.binding.unlink()
    def available(self, method, path, data=None):
        if path == '/companies': return [{'id': 'c', 'name': 'Fixture'}]
        if path.endswith('/projects'): return [{'id': 'p', 'companyId': 'c', 'name': 'Project'}]
        raise AssertionError('unexpected API call')
    def test_explicit_valid_login_connect_and_status(self):
        with patch.object(paperclip.API, 'request', side_effect=self.available):
            self.assertEqual(onboarding.connect(self.repo, 'test', 'c', 'p')['state'], 'connected')
            before = self.binding.read_bytes()
            self.assertEqual(onboarding.status(self.repo)['state'], 'connected')
            self.assertEqual(self.binding.read_bytes(), before)
    def test_once_offer_and_decline(self):
        self.assertTrue(onboarding.eligibility(self.repo)['eligible'])
        self.assertFalse(onboarding.eligibility(self.repo)['offer'])
        self.assertTrue(onboarding.eligibility(self.repo, True, True)['offer'])
        self.assertFalse(onboarding.eligibility(self.repo, True)['offer'])
        onboarding.decline(self.repo)
        self.assertEqual(config.status(self.repo)['mode'], 'declined')
        self.assertFalse(onboarding.eligibility(self.repo, True)['offer'])
    def test_wrong_company_project_never_enables(self):
        with patch.object(paperclip.API, 'request', side_effect=self.available):
            with self.assertRaises(config.ConfigError): onboarding.connect(self.repo, 'test', 'wrong', 'p')
            with self.assertRaises(config.ConfigError): onboarding.connect(self.repo, 'test', 'c', 'wrong')
        self.assertFalse(self.binding.exists())
    def test_missing_expired_offline_preserve_binding(self):
        with patch.object(paperclip.API, 'request', side_effect=self.available): onboarding.connect(self.repo, 'test', 'c', 'p')
        before = self.binding.read_bytes()
        for diagnostic, expected in [('authentication expired; reconnect Paperclip', 'authentication-expired'), ('offline or invalid remote response; delivery pending', 'offline')]:
            with patch.object(paperclip.API, 'request', side_effect=paperclip.DeliveryError(diagnostic)):
                self.assertEqual(onboarding.reconnect(self.repo)['state'], expected)
            self.assertEqual(self.binding.read_bytes(), before)
        self.auth.unlink()
        self.assertEqual(onboarding.reconnect(self.repo)['state'], 'authentication-missing')
        self.assertEqual(self.binding.read_bytes(), before)
    def test_worktree_reuses_binding_and_settings(self):
        with patch.object(paperclip.API, 'request', side_effect=self.available): onboarding.connect(self.repo, 'test', 'c', 'p')
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-qm', 'fixture'], check=True)
        worktree = self.root / 'worktree'
        subprocess.run(['git', '-C', str(self.repo), 'worktree', 'add', '--detach', str(worktree)], check=True, capture_output=True)
        self.assertEqual(config.status(worktree), config.status(self.repo))
        self.assertFalse(onboarding.eligibility(worktree, True)['offer'])
    def test_profile_explicit_and_credentials_untouched(self):
        before = self.auth.read_bytes()
        onboarding.save_profile('other', self.base+'/', str(self.auth))
        self.assertEqual(self.auth.read_bytes(), before)
        self.assertEqual(onboarding.selected_profile('other')['api_base'], self.base)
    def test_shared_profile_cannot_be_retargeted(self):
        with patch.object(paperclip.API, 'request', side_effect=self.available): onboarding.connect(self.repo, 'test', 'c', 'p')
        before_profile, before_binding = self.profiles.read_bytes(), self.binding.read_bytes()
        with self.assertRaises(config.ConfigError): onboarding.save_profile('test', 'https://different.invalid', str(self.auth))
        self.assertEqual(self.profiles.read_bytes(), before_profile)
        self.assertEqual(self.binding.read_bytes(), before_binding)
    def test_bootstrap_headless_keeps_offer_eligible(self):
        environment = dict(os.environ, GIT_ALLOW_PROTOCOL='file', GIT_CONFIG_GLOBAL='/dev/null')
        result = subprocess.run(['bash', str(Path(__file__).parent/'init.sh'), 'bootstrap'], cwd=self.repo, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('setup eligible', result.stdout)
        self.assertTrue(onboarding.eligibility(self.repo, True)['offer'])
        self.assertEqual(self.calls, [])
    def test_creation_requires_explicit_choice(self):
        with self.assertRaises(config.ConfigError): onboarding.create_project('test', 'c', 'New')
        def available(method, path, data=None):
            if method == 'POST': return {'id': 'new', 'companyId': 'c'}
            return self.available(method, path, data)
        with patch.object(paperclip.API, 'request', side_effect=available):
            self.assertEqual(onboarding.create_project('test', 'c', 'New', True)['state'], 'created')
        self.assertFalse(self.binding.exists())

# Inherited transport cases need enabled binding and are already covered in their
# own suite; this subclass reuses only its HTTP fixture setup/teardown.
for name in list(transport_fixture.TransportTests.__dict__):
    if name.startswith('test_') and name not in OnboardingTests.__dict__:
        setattr(OnboardingTests, name, None)

if __name__ == '__main__': unittest.main()
