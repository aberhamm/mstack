"""Plan 100: board order changes (priority, backlog/todo) on the transport fake board.

No request reaches the live board. Issue objects are built from the Paperclip
2026.1005.0 key set in fixtures/paperclip/issue-update-2026.1005.0.json.
"""
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parent))
import paperclip
import test_paperclip_transport as transport

FIXTURE = Path(__file__).parent / 'fixtures/paperclip/issue-update-2026.1005.0.json'
MANUAL = 'issue manually changed; reconciliation required'
ADOPTED_DIFFERS = 'adopted issue state differs; inspect manually'


def fixture_keys():
    return json.loads(FIXTURE.read_text())['keys']


class BoardOrderHarness(unittest.TestCase):
    """The transport fake board, with every non-GET request body recorded."""

    def setUp(self):
        self.net = transport.TransportTests('test_delivery_and_deduplication')
        self.net.setUp()
        self.addCleanup(self.net.tearDown)
        self.sent = []
        real = paperclip.API.request
        def record(api, method, path, data=None):
            if method != 'GET':
                self.sent.append((method, path, data))
            return real(api, method, path, data)
        recorder = patch.object(paperclip.API, 'request', record)
        recorder.start()
        self.addCleanup(recorder.stop)

    def tearDown(self):
        # mstack never sends priority, in any request of any test in this file.
        self.assertFalse([body for _, _, body in self.sent if isinstance(body, dict) and 'priority' in body])

    def event(self, seq=1, outcome='backlog', plan='94', title='Fixture plan'):
        return {'schema_version': 1, 'repository_id': 'r', 'plan_id': plan, 'event_id': 'event-' + plan + '-' + str(seq),
                'sequence': seq, 'outcome': outcome, 'metadata': {'session': 'fixture', 'worktree': str(self.net.repo), 'title': title},
                'notes': 'Report ' + str(seq)}

    def emit(self, seq=1, outcome='backlog', **kwargs):
        return paperclip.operate(self.net.repo, self.event(seq, outcome, **kwargs))

    def make_task(self, number='1', status='backlog', plan='94', title='Fixture plan', **extra):
        """A board task with the real Paperclip key set, marked for this plan."""
        issue = {name: json.loads(json.dumps(spec['example'])) for name, spec in fixture_keys().items()}
        issue.update(id=number, companyId='c', projectId='p', title=title, status=status, priority='medium', updatedAt='1',
                     assigneeUserId=None, description=paperclip.plan_marker(self.event(plan=plan)) + '\nPlan text')
        issue.update(extra)
        self.net.issues[number] = issue
        self.net.comments[number] = []
        return issue

    def board(self, number='1', **changes):
        """A hand edit on the board: the fields change and updatedAt moves."""
        issue = self.net.issues[number]
        issue.update(changes)
        issue['updatedAt'] = str(int(issue['updatedAt']) + 1)

    def ledger(self):
        return json.loads(paperclip.state_path(self.net.repo).read_text())

    def mapping(self, plan='94'):
        return self.ledger()['mappings'][plan]

    def patches(self):
        return [body for method, _, body in self.sent if method == 'PATCH']


class CurrentBehaviourCharacterization(BoardOrderHarness):
    """Today's rule: any board change mstack did not make is a hand edit."""

    def test_priority_only_change_is_a_conflict(self):
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        self.board(priority='high')
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', MANUAL))
        self.assertEqual(len(self.net.comments['1']), 1)

    def test_backlog_to_todo_is_a_conflict(self):
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        self.board(status='todo')
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', MANUAL))
        self.assertEqual(self.net.issues['1']['status'], 'todo')

    def test_marker_found_todo_task_without_mapping_is_a_conflict(self):
        self.make_task(status='todo')
        result = self.emit(1)
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', ADOPTED_DIFFERS))
        self.assertEqual((self.net.issues['1']['status'], self.net.comments['1'], self.sent), ('todo', [], []))
        self.assertNotIn('94', self.ledger()['mappings'])


if __name__ == '__main__':
    unittest.main()
