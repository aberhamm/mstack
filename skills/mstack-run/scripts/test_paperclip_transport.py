"""HTTP integration fixtures: no requests reach the live board."""
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid
import sys
sys.path.insert(0, str(Path(__file__).parent))
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest
from unittest.mock import patch
import paperclip
import paperclip_config as config


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.issues, self.comments, self.calls = {}, {}, []
        self.client_request_ids = []
        self.fail_create = self.fail_patch = self.redirect = False
        fixture = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.handle_request('GET')
            def do_POST(self):
                self.handle_request('POST')
            def do_PATCH(self):
                self.handle_request('PATCH')
            def handle_request(self, method):
                fixture.calls.append((method, self.path))
                if fixture.redirect:
                    self.send_response(302)
                    self.send_header('Location', '/stolen')
                    self.end_headers()
                    return
                body = json.loads(self.rfile.read(int(self.headers['Content-Length']))) if self.headers.get('Content-Length') else None
                if self.path.startswith('/api/companies/c/issues'):
                    if method == 'GET':
                        result = [{'id': k, 'description': 'truncated'} for k in fixture.issues]
                    else:
                        issue = dict(body, id=str(len(fixture.issues)+1), companyId='c', updatedAt='1')
                        fixture.issues[issue['id']] = issue
                        fixture.comments[issue['id']] = []
                        if fixture.fail_create:
                            self.connection.close()
                            return
                        result = issue
                elif self.path.endswith('/comments'):
                    result = fixture.comments[self.path.split('/')[-2]]
                else:
                    issue = fixture.issues[self.path.split('/')[-1]]
                    if method == 'PATCH':
                        try:
                            request_id=body['commentClientRequestId']
                            if str(uuid.UUID(request_id)) != request_id: raise ValueError()
                        except (KeyError, ValueError, TypeError):
                            self.send_response(400);self.send_header('Content-Type','application/json');self.end_headers()
                            self.wfile.write(b'{"error":"commentClientRequestId requires UUID"}');return
                        fixture.client_request_ids.append(request_id)
                        fixture.comments[issue['id']].append({'body': body.pop('comment')})
                        body.pop('commentClientRequestId')
                        issue.update(body, updatedAt=str(int(issue['updatedAt'])+1))
                        if fixture.fail_patch:
                            self.connection.close()
                            return
                    result = issue
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = 'http://127.0.0.1:' + str(self.server.server_port)
        self.auth = self.root / 'auth.json'
        self.auth.write_text(json.dumps({'credentials': {self.base: {'token': 'fixture', 'userId': 'u'}}}))
        self.profiles = self.root / 'profiles.json'
        self.profiles.write_text(json.dumps({'version': 1, 'profiles': {'test': {'api_base': self.base, 'auth_file': str(self.auth)}}}))
        self.profile_patch = patch.object(config, 'profile_path', return_value=self.profiles)
        self.profile_patch.start()
        config.configure(self.repo, {'version': 1, 'mode': 'enabled', 'repository_id': 'r', 'profile': 'test', 'company_id': 'c', 'project_id': 'p'})
    def tearDown(self):
        self.profile_patch.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()
    def event(self, seq=1, outcome='in_progress'):
        return {'schema_version': 1, 'repository_id': 'r', 'plan_id': '94', 'event_id': 'event-'+str(seq), 'sequence': seq, 'outcome': outcome, 'metadata': {'session': 'fixture', 'worktree': str(self.repo)}, 'notes': 'Working'}
    def emit(self, seq=1, outcome='in_progress'):
        return paperclip.operate(self.repo, self.event(seq, outcome))
    def test_delivery_and_deduplication(self):
        self.assertEqual(self.emit()['delivery'], 'delivered')
        calls = len(self.calls)
        self.assertEqual(self.emit()['delivery'], 'delivered')
        self.assertEqual(len(self.calls), calls)
        self.assertEqual(len(self.issues), 1)
        self.assertEqual(self.issues['1']['assigneeUserId'], 'u')
        self.assertEqual(self.issues['1']['status'], 'in_progress')
        self.assertEqual(self.emit(2, 'done')['delivery'], 'delivered')
        self.assertEqual(len(self.comments['1']), 2)
    def test_comment_client_request_id_uses_stable_uuid_contract(self):
        self.assertEqual(self.emit()['delivery'],'delivered')
        expected=str(uuid.uuid5(uuid.NAMESPACE_URL,'mstack-paperclip:event-1'))
        self.assertEqual(self.client_request_ids,[expected])
        self.assertEqual(uuid.UUID(expected).version,5)
        api=paperclip.API(self.base,str(self.auth))
        with self.assertRaises(paperclip.DeliveryError):
            api.request('PATCH','/issues/1',{'comment':'invalid request','commentClientRequestId':'event-1'})
        self.assertEqual(len(self.comments['1']),1)
        self.assertEqual(self.emit()['delivery'],'delivered')
        self.assertEqual(self.client_request_ids,[expected])
    def test_uncertain_create_reconciles_exact_full_marker(self):
        self.fail_create = True
        self.assertEqual(self.emit()['delivery'], 'pending')
        self.fail_create = False
        self.assertEqual(self.emit()['delivery'], 'delivered')
        self.assertEqual(len(self.issues), 1)
        self.assertEqual(self.issues['1']['status'], 'in_progress')
    def test_uncertain_create_manual_change_conflict(self):
        self.fail_create = True
        self.emit()
        self.fail_create = False
        self.issues['1']['status'] = 'done'
        self.assertEqual(self.emit()['delivery'], 'conflict')
        self.assertEqual(self.issues['1']['status'], 'done')
        self.assertEqual(len(self.comments['1']), 0)
    def test_uncertain_patch_reconciles_without_resend(self):
        self.fail_patch = True
        self.assertEqual(self.emit()['delivery'], 'pending')
        self.fail_patch = False
        self.assertEqual(self.emit()['delivery'], 'delivered')
        self.assertEqual(len(self.comments['1']), 1)
    def test_unresolved_uncertainty_never_resends(self):
        self.fail_create = True
        self.emit()
        self.issues.clear()
        self.fail_create = False
        self.assertEqual(self.emit()['delivery'], 'pending')
        self.assertEqual(sum(m == 'POST' for m,p in self.calls), 1)
    def test_manual_state_conflict_preserves_state(self):
        self.emit()
        self.issues['1'].update(status='blocked', updatedAt='manual')
        self.assertEqual(self.emit(2, 'done')['delivery'], 'conflict')
        self.assertEqual(self.issues['1']['status'], 'blocked')
        self.assertEqual(self.emit(3, 'done')['delivery'], 'pending')
        self.assertEqual(len(self.comments['1']), 1)
    def test_agent_ownership_refused(self):
        self.emit()
        self.issues['1']['assigneeAgentId'] = 'agent'
        self.assertEqual(self.emit(2, 'done')['delivery'], 'conflict')
        self.assertFalse(any('wakeup' in p for m,p in self.calls))
    def test_redirect_not_followed(self):
        self.redirect = True
        self.assertEqual(self.emit()['delivery'], 'conflict')
        self.assertFalse(any(p == '/stolen' for m,p in self.calls))
    def test_offline_durable_and_superseded(self):
        def offline(*args):
            raise paperclip.DeliveryError('offline')
        self.assertEqual(paperclip.operate(self.repo, self.event(), api_factory=offline)['delivery'], 'pending')
        self.assertEqual(self.emit(2, 'done')['delivery'], 'delivered')
        self.assertEqual(len(self.comments['1']), 1)
        self.assertEqual(self.issues['1']['status'], 'done')
    def test_disabled_no_credentials_or_network(self):
        config.disable(self.repo)
        self.auth.unlink()
        self.assertEqual(self.emit()['delivery'], 'disabled')
        self.assertEqual(self.calls, [])
    def test_sequence_and_sensitive_notes_rejected(self):
        self.emit()
        event = self.event(2)
        event['notes'] = 'token=secret'
        with self.assertRaises(config.ConfigError):
            paperclip.operate(self.repo, event)
        event = self.event()
        event['event_id'] = 'other'
        with self.assertRaises(config.ConfigError):
            paperclip.operate(self.repo, event)
    def test_total_request_deadline(self):
        api = paperclip.API(self.base, self.auth, time.monotonic()+0.1)
        with patch.object(api.opener, "open", side_effect=lambda *a, **k: time.sleep(1)):
            started = time.monotonic()
            with self.assertRaises(paperclip.DeliveryError):
                api.request("GET", "/issues")
            self.assertLess(time.monotonic()-started, 0.5)
    def test_pagination(self):
        api = paperclip.API(self.base, self.auth)
        with patch.object(api, 'request', side_effect=[{'items': [{'id': '1'}], 'nextCursor': 'next'}, {'items': [{'id': '2'}], 'nextCursor': None}]) as request:
            self.assertEqual(len(api.pages('/issues')), 2)
            self.assertIn('cursor=next', request.call_args.args[1])
    def test_api_base_rejects_credential_urls_without_echo(self):
        for value in ['https://secret@example.org', 'https://example.org?token=secret', 'https://example.org#secret']:
            with self.assertRaises(config.ConfigError) as exc:
                paperclip.normalize_base(value)
            self.assertNotIn('secret', str(exc.exception))


if __name__ == '__main__':
    unittest.main()
