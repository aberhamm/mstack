"""HTTP integration fixtures: no requests reach the live board."""
import hashlib
import json
import os
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
                        if (body.get('status') == 'blocked') != bool(body.get('unblockDescriptor')):
                            self.send_response(422);self.send_header('Content-Type','application/json');self.end_headers()
                            self.wfile.write(b'{"error":"Entering blocked requires unblockDescriptor"}');return
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
    def test_blocked_outcome_names_a_human_unblock_owner(self):
        event = dict(self.event(1, 'blocked'), notes='Local outcome: authored\nLocal restrictions: needs-review=eng; blocked-by=[]')
        self.assertEqual(paperclip.operate(self.repo, event)['delivery'], 'delivered')
        self.assertEqual(self.issues['1']['status'], 'blocked')
        self.assertEqual(self.issues['1']['unblockDescriptor'], {'owner': {'userId': 'u'}, 'action': 'Clear the local plan block (needs-review=eng; blocked-by=[])'})
        self.assertEqual(self.emit(2, 'in_progress')['delivery'], 'delivered')
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
    def task(self, status='todo', note='Opened', title='Rotate the backup disk', key='item-1', **kwargs):
        return paperclip.task(self.repo, 'p', key, title, status, note, **kwargs)
    def writes(self):
        return [(m, p) for m, p in self.calls if m != 'GET']
    def task_ledgers(self):
        return sorted(config.binding_path(self.repo).parent.glob('tasks-*.json'))
    def test_task_first_call_creates_second_call_updates(self):
        created = self.task()
        self.assertEqual((created['delivery'], created['issue_id']), ('delivered', '1'))
        self.assertEqual(self.issues['1']['title'], 'Rotate the backup disk')
        self.assertEqual(self.issues['1']['status'], 'todo')
        self.assertIn('<!-- mstack-plan:', self.issues['1']['description'])
        self.assertNotIn('item-1', json.dumps(self.issues['1']))
        updated = self.task('done', 'Finished')
        self.assertEqual((updated['delivery'], updated['issue_id']), ('delivered', '1'))
        self.assertEqual(len(self.issues), 1)
        self.assertEqual(sum(m == 'POST' for m, p in self.calls), 1)
        self.assertEqual(self.issues['1']['status'], 'done')
        self.assertIn('Finished', self.comments['1'][-1]['body'])
        self.assertEqual(len(self.comments['1']), 2)
        calls = len(self.calls)
        self.assertEqual(self.task('done', 'Finished')['delivery'], 'delivered')
        self.assertEqual(len(self.calls), calls)
        self.assertFalse(paperclip.state_path(self.repo).exists())
    def test_task_keys_are_independent(self):
        self.task()
        self.assertEqual(self.task(key='item-2', title='Second item')['issue_id'], '2')
        self.assertEqual(len(self.issues), 2)
    def test_task_secret_like_title_or_note_refused_before_any_request(self):
        for arguments in ({'title': 'password: hunter2'}, {'note': 'Bearer abcdef'}, {'title': 'two\nlines'}, {'key': ''}, {'status': 'deleted'}):
            result = self.task(**arguments)
            self.assertEqual(result['delivery'], 'refused')
            self.assertNotIn('hunter2', json.dumps(result))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.task_ledgers(), [])
        self.assertEqual(sorted(path.name for path in config.binding_path(self.repo).parent.iterdir()), ['binding.json'])
        self.task()
        self.assertEqual(self.task(title='password: hunter2')['delivery'], 'refused')
    def test_task_interrupted_creation_retry_finds_task_by_key(self):
        self.fail_create = True
        self.assertEqual(self.task()['delivery'], 'pending')
        self.fail_create = False
        retried = self.task()
        self.assertEqual((retried['delivery'], retried['issue_id']), ('delivered', '1'))
        self.assertEqual(len(self.issues), 1)
        self.assertEqual(sum(m == 'POST' for m, p in self.calls), 1)
        self.assertEqual(self.issues['1']['status'], 'todo')
    def test_task_lost_creation_is_never_blindly_repeated(self):
        self.fail_create = True
        self.task()
        self.issues.clear()
        self.fail_create = False
        self.assertEqual(self.task()['delivery'], 'pending')
        self.assertEqual(sum(m == 'POST' for m, p in self.calls), 1)
    def test_task_dry_run_reads_only(self):
        preview = self.task(dry_run=True)
        self.assertEqual((preview['delivery'], preview['action']), ('dry-run', 'create'))
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.task_ledgers(), [])
        self.task()
        before = self.task_ledgers()[0].read_bytes()
        writes = self.writes()
        self.assertEqual(self.task(dry_run=True)['action'], 'none')
        closing = self.task('done', 'Finished', dry_run=True)
        self.assertEqual((closing['action'], closing['issue_id']), ('update', '1'))
        self.assertEqual(self.task(title='token=abc', dry_run=True)['delivery'], 'refused')
        self.assertEqual(self.writes(), writes)
        self.assertEqual(self.task_ledgers()[0].read_bytes(), before)
        self.assertEqual(self.issues['1']['status'], 'todo')
    def test_task_dry_run_finds_existing_task_without_local_ledger(self):
        self.task()
        self.task_ledgers()[0].unlink()
        preview = self.task(dry_run=True)
        self.assertEqual((preview['action'], preview['issue_id']), ('update', '1'))
        self.assertEqual(sum(m == 'POST' for m, p in self.calls), 1)
    def test_task_closed_task_is_not_reopened_and_never_deleted(self):
        self.task('cancelled', 'Withdrawn')
        self.assertEqual(self.task('todo', 'Again')['delivery'], 'conflict')
        self.assertEqual(self.issues['1']['status'], 'cancelled')
        later = self.task('done', 'Later')
        self.assertEqual(later['delivery'], 'pending')
        self.assertIn('earlier conflict', later['diagnostic'])
        self.assertFalse(any(m == 'DELETE' for m, p in self.calls))
    def test_task_blocked_names_an_unblock_owner(self):
        self.assertEqual(self.task('blocked', 'expired without a report')['delivery'], 'delivered')
        self.assertEqual(self.issues['1']['unblockDescriptor'], {'owner': {'userId': 'u'}, 'action': 'expired without a report'})
        self.assertEqual(self.task('done', 'Closed')['delivery'], 'delivered')
    def test_task_pending_work_on_other_keys_does_not_starve_this_key(self):
        self.fail_create = True
        self.task(key='a-stuck')
        self.issues.clear()
        self.fail_create = False
        self.assertEqual(self.task(key='z-later')['delivery'], 'delivered')
    def stamp(self, key, project='p'):
        inner = 'task-' + hashlib.sha256(key.encode()).hexdigest()[:40]
        return '<!-- mstack-plan:' + hashlib.sha256(('task:' + project + '\n' + inner).encode()).hexdigest() + ' -->'
    def test_task_marker_formula_is_stable(self):
        self.task(key='example-key')
        self.assertEqual(self.stamp('example-key'), '<!-- mstack-plan:06da58e614ae624c5da77ee549d6f57274551039351a8bd21366462f83d56797 -->')
        self.assertTrue(self.issues['1']['description'].startswith(self.stamp('example-key') + '\n'))
    def test_task_adopts_a_task_marked_elsewhere_under_the_plan_sync_rule(self):
        for number, state in (('5', 'backlog'), ('6', 'done')):
            self.issues[number] = {'id': number, 'companyId': 'c', 'projectId': 'p', 'title': 'Marked elsewhere', 'description': 'text', 'status': state, 'updatedAt': '1', 'assigneeUserId': None}
            self.comments[number] = []
        self.issues['5']['description'] = self.stamp('item-1') + '\ntext'
        adopted = self.task('in_progress', 'Started')
        self.assertEqual((adopted['delivery'], adopted['issue_id']), ('delivered', '5'))
        self.assertEqual((self.issues['5']['status'], len(self.issues)), ('in_progress', 2))
        self.assertFalse(any(m == 'POST' for m, p in self.calls))
        self.task_ledgers()[0].unlink()
        self.assertEqual(self.task('in_progress', 'Started')['delivery'], 'delivered')
        self.task_ledgers()[0].unlink()
        self.assertEqual(self.task('done', 'Finished')['delivery'], 'conflict')
        self.assertEqual(self.issues['5']['status'], 'in_progress')
    def test_task_pending_note_is_sent_later_not_dropped(self):
        self.task()
        def offline(*args):
            raise paperclip.DeliveryError('offline')
        self.assertEqual(self.task('in_progress', 'First note', api_factory=offline)['delivery'], 'pending')
        self.assertEqual(self.task('done', 'Second note')['delivery'], 'delivered')
        self.assertEqual([c['body'].split('\n', 1)[1] for c in self.comments['1']], ['Opened', 'First note', 'Second note'])
        self.assertEqual(self.issues['1']['status'], 'done')
    def test_task_retrying_an_older_queued_call_does_not_queue_it_twice(self):
        self.task()
        def offline(*args):
            raise paperclip.DeliveryError('offline')
        self.assertEqual(self.task('in_progress', 'A', api_factory=offline)['delivery'], 'pending')
        self.assertEqual(self.task('done', 'B', api_factory=offline)['delivery'], 'pending')
        self.assertEqual(self.task('in_progress', 'A', api_factory=offline)['delivery'], 'pending')
        self.assertEqual(len(json.loads(self.task_ledgers()[0].read_text())['events']), 3)
        self.assertEqual(self.task('in_progress', 'A')['delivery'], 'delivered')
        self.assertEqual(self.task('done', 'B')['delivery'], 'delivered')
        self.assertEqual([c['body'].split('\n', 1)[1] for c in self.comments['1']], ['Opened', 'A', 'B'])
        self.assertEqual(self.issues['1']['status'], 'done')
    def test_task_queued_blocked_call_keeps_its_own_unblock_action(self):
        self.task()
        def offline(*args):
            raise paperclip.DeliveryError('offline')
        self.task('blocked', 'waiting on vendor', api_factory=offline)
        self.assertEqual(self.task(key='item-2', note='Opened other')['delivery'], 'delivered')
        self.assertEqual(self.issues['1']['unblockDescriptor']['action'], 'waiting on vendor')
    def test_task_busy_lock_is_pending_not_refused(self):
        self.task()
        lock = self.task_ledgers()[0].with_suffix('.lock')
        lock.mkdir()
        try:
            busy = self.task('done', 'Finished')
        finally:
            lock.rmdir()
        self.assertEqual((busy['delivery'], busy['issue_id']), ('pending', None))
        self.assertEqual(self.task('done', 'Finished')['delivery'], 'delivered')
    def test_task_disabled_makes_no_request(self):
        config.disable(self.repo)
        self.assertEqual(self.task()['delivery'], 'disabled')
        self.assertEqual(self.calls, [])
    def test_task_command_line_answers_one_json_line(self):
        home = self.root/'home'
        (home/'.config/mstack').mkdir(parents=True)
        (home/'.config/mstack/paperclip.json').write_bytes(self.profiles.read_bytes())
        environment = dict(os.environ, HOME=str(home))
        base = ['bash', str(Path(__file__).with_name('paperclip.sh')), 'task', '--repo', str(self.repo), '--project', 'p', '--key', 'item-1', '--title', 'Rotate the backup disk', '--status', 'todo', '--note', 'Opened']
        def run(*extra):
            output = subprocess.run(base+list(extra), env=environment, capture_output=True, text=True, check=True).stdout
            self.assertEqual(output.count('\n'), 1)
            return json.loads(output)
        self.assertEqual(run('--dry-run')['action'], 'create')
        self.assertEqual(run('--status', 'deleted')['delivery'], 'refused')
        self.assertEqual(self.issues, {})
        self.assertEqual(run()['delivery'], 'delivered')
        self.assertEqual(run('--status', 'done', '--note', 'Finished')['issue_id'], '1')
        self.assertEqual(self.issues['1']['status'], 'done')
        self.assertEqual(len(self.issues), 1)
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
