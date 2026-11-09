"""Plan 100: board order changes (priority, backlog/todo) on the transport fake board.

No request reaches the live board. Issue objects are built from the Paperclip
2026.1005.0 key set in fixtures/paperclip/issue-update-2026.1005.0.json.
"""
import json
import os
from pathlib import Path
import subprocess
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
        """A hand edit on the board: the fields change, updatedAt moves, and statusVersion
        moves as the real board's trigger moves it."""
        issue = self.net.issues[number]
        transport.bump_status_version(issue, changes)
        issue.update(changes)
        issue['updatedAt'] = str(int(issue['updatedAt']) + 1)

    def ledger(self):
        return json.loads(paperclip.state_path(self.net.repo).read_text())

    def mapping(self, plan='94'):
        return self.ledger()['mappings'][plan]

    def patches(self):
        return [body for method, _, body in self.sent if method == 'PATCH']


class CharacterizationFlipped(BoardOrderHarness):
    """The pre-plan-100 pins, flipped in the diff that changed the rule; (3) keeps its pin."""

    def test_priority_only_change_is_adopted(self):
        # Before plan 100: conflict, 'issue manually changed; reconciliation required'.
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        self.board(priority='high')
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        self.assertEqual((len(self.net.comments['1']), self.net.issues['1']['priority']), (2, 'high'))

    def test_backlog_to_todo_is_adopted(self):
        # Before plan 100: conflict, 'issue manually changed; reconciliation required'.
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        self.board(status='todo')
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        self.assertEqual(self.net.issues['1']['status'], 'todo')

    def test_marker_found_todo_task_without_mapping_is_a_conflict(self):
        self.make_task(status='todo')
        result = self.emit(1)
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', ADOPTED_DIFFERS))
        self.assertEqual((self.net.issues['1']['status'], self.net.comments['1'], self.sent), ('todo', [], []))
        self.assertNotIn('94', self.ledger()['mappings'])


# Shared contract table (plan 100, Design; homelab plan 236 holds the same table).
# | # | baseline status | board status | other change | expected |
CONTRACT = [
    (1, 'backlog', 'backlog', 'priority', 'adopt'),
    (2, 'backlog', 'todo', 'none', 'adopt'),
    (3, 'todo', 'backlog', 'none', 'adopt'),
    (4, 'backlog', 'todo', 'priority', 'adopt'),
    (5, 'backlog', 'in_progress', 'none', 'conflict'),
    (6, 'todo', 'blocked', 'none', 'conflict'),
    (7, 'todo', 'done', 'none', 'conflict'),
    (8, 'backlog', 'backlog', 'title', 'conflict'),
    (9, 'backlog', 'todo', 'description', 'conflict'),
    (10, 'in_progress', 'todo', 'none', 'conflict'),
    (11, 'backlog (no snapshot)', 'backlog', 'priority', 'conflict'),
    (12, 'blocked', 'blocked', 'priority', 'adopt'),
]


def fixture_issue(**changes):
    issue = {name: json.loads(json.dumps(spec['example'])) for name, spec in fixture_keys().items()}
    issue.update(changes)
    return issue


class ContractTable(unittest.TestCase):
    """board_change() is pure: the shared table, on the real Paperclip key set."""

    def test_contract_table(self):
        for row, baseline, board, other, expected in CONTRACT:
            with self.subTest(row=row):
                status = baseline.split(' ')[0]
                base = fixture_issue(status=status, updatedAt='1')
                mapping = {'issue_id': base['id'], 'status': status, 'updated_at': '1', 'sequence': 1}
                if 'no snapshot' not in baseline:
                    mapping['snapshot'] = paperclip.snapshot_of(base)
                issue = dict(base, status=board, updatedAt='2')
                if other == 'priority':
                    issue['priority'] = 'high'
                elif other != 'none':
                    issue[other] = 'Changed by hand'
                self.assertEqual(paperclip.board_change(mapping, issue)[0], expected)

    def test_unchanged_board_is_same(self):
        base = fixture_issue(status='todo', updatedAt='1')
        self.assertEqual(paperclip.board_change({'status': 'todo', 'updated_at': '1'}, base), ('same', set()))

    def test_fixture_classes_match_the_rule(self):
        spec = json.loads(FIXTURE.read_text())
        classes = {}
        for name, entry in spec['keys'].items():
            classes.setdefault(entry['class'], set()).add(name)
        self.assertEqual(paperclip.PROJECTION_FIELDS, classes['PROJECTION'])
        self.assertEqual(paperclip.RELATION_FIELDS, classes['RELATION'])
        self.assertEqual(paperclip.DOCUMENT_FIELDS, classes['DOCUMENT'])
        self.assertEqual(paperclip.BOARD_SIDE_EFFECT_FIELDS, set(spec['board_side_effect_fields']))
        self.assertEqual(paperclip.BOARD_SIDE_EFFECT_FIELDS, classes['BOARD_SIDE_EFFECT'])
        self.assertIn('statusVersion', paperclip.BOARD_SIDE_EFFECT_FIELDS)  # migrations/0227 L146-158 trigger
        self.assertEqual(classes['BASELINE'], {'status', 'priority', 'updatedAt'})
        self.assertEqual(classes['GOAL'], {'goalId'})
        self.assertEqual(paperclip.ADOPTABLE_STATUSES, {'backlog', 'todo'})

    def test_label_order_is_not_a_change(self):
        # Code review L1: Paperclip orders labelIds by label name, so a rename elsewhere reorders them.
        ids = ['00000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-00000000000b']
        base = fixture_issue(status='backlog', updatedAt='1', priority='medium', labelIds=ids)
        mapping = {'status': 'backlog', 'updated_at': '1', 'snapshot': paperclip.snapshot_of(base)}
        board = dict(base, labelIds=list(reversed(ids)), priority='high', updatedAt='2')
        self.assertEqual(paperclip.board_change(mapping, board), ('adopt', {'priority'}))
        swapped = dict(board, labelIds=[ids[0], '00000000-0000-4000-8000-00000000000c'])
        self.assertEqual(paperclip.board_change(mapping, swapped), ('conflict', {'priority', 'rest'}))

    def test_expected_status(self):
        self.assertEqual(paperclip.expected_status('backlog', 'todo'), 'todo')
        for outcome, current in (('backlog', 'backlog'), ('backlog', 'blocked'), ('in_progress', 'todo'), ('done', 'todo'), ('blocked', 'todo')):
            self.assertEqual(paperclip.expected_status(outcome, current), outcome)


class AdoptionDelivery(BoardOrderHarness):
    """Delivery after Matthew orders work: adopted, then mstack's own report goes through."""

    def delivered_after(self, start='backlog', steps=None, **change):
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        sequence = 2
        if start != 'backlog':
            self.board(status=start)
            self.assertEqual(self.emit(2)['delivery'], 'delivered')
            sequence = 3
        for step in steps or [change]:
            self.board(**step)
        result = self.emit(sequence, 'in_progress')
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        self.assertEqual(self.patches()[-1]['status'], 'in_progress')
        self.assertEqual(self.net.issues['1']['status'], 'in_progress')
        mapping = self.mapping()
        self.assertEqual(mapping['updated_at'], self.net.issues['1']['updatedAt'])
        self.assertEqual(mapping['snapshot'], paperclip.snapshot_of(self.net.issues['1']))
        return mapping

    def test_priority_only_change_is_adopted(self):
        self.delivered_after(priority='high')
        self.assertEqual(self.net.issues['1']['priority'], 'high')

    def test_backlog_to_todo_is_adopted(self):
        self.delivered_after(status='todo')

    def test_todo_to_backlog_is_adopted(self):
        self.delivered_after(start='todo', status='backlog')

    def test_priority_and_todo_together_are_adopted(self):
        self.delivered_after(status='todo', priority='urgent')
        self.assertEqual(self.net.issues['1']['priority'], 'urgent')

    def test_priority_changed_and_back_is_adopted(self):
        self.delivered_after(steps=[{'priority': 'high'}, {'priority': 'medium'}])

    def test_adoption_is_recorded_before_the_write(self):
        self.make_task()
        self.emit(1)
        self.board(status='todo', priority='high')
        self.net.fail_patch = True
        self.assertEqual(self.emit(2, 'in_progress')['delivery'], 'pending')
        mapping = self.mapping()
        self.assertEqual(mapping['adopted'], {'fields': ['priority', 'status'], 'updated_at': '3'})
        self.assertEqual((mapping['status'], mapping['updated_at']), ('todo', '3'))


class StillConflicts(BoardOrderHarness):
    """Every change other than priority and backlog/todo is still a hand edit."""

    def assert_conflict(self, start='backlog', diagnostic=MANUAL, **change):
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        if start != 'backlog':
            self.board(status=start)
            self.assertEqual(self.emit(2)['delivery'], 'delivered')
        self.board(**change)
        before, comments, writes = json.loads(json.dumps(self.net.issues['1'])), len(self.net.comments['1']), len(self.sent)
        result = self.emit(9, 'in_progress')
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', diagnostic))
        self.assertEqual((self.net.issues['1'], len(self.net.comments['1']), len(self.sent)), (before, comments, writes))

    def test_hand_statuses_are_conflicts(self):
        for start in ('backlog', 'todo'):
            for status in ('in_progress', 'blocked', 'in_review', 'done', 'cancelled'):
                with self.subTest(start=start, status=status):
                    self.tearDown()
                    self.doCleanups()
                    self.setUp()
                    self.assert_conflict(start, status=status)

    def test_own_field_changes_are_conflicts(self):
        for change in ({'title': 'Renamed by hand'}, {'description': 'Rewritten by hand'}, {'parentId': 'other'},
                       {'labelIds': ['another-label']}, {'newPaperclipField': 'unknown to the fixture'},
                       {'title': 'Renamed by hand', 'priority': 'high'}, {'description': 'Edited', 'status': 'todo'}):
            with self.subTest(change=change):
                self.tearDown()
                self.doCleanups()
                self.setUp()
                self.assert_conflict(**change)

    def test_changed_blocker_ids_are_a_conflict(self):
        blocker = {'id': 'another-blocker', 'identifier': 'PLC-9', 'title': 'Other', 'status': 'todo', 'priority': 'low',
                   'assigneeAgentId': None, 'assigneeUserId': None, 'scheduledRetry': None}
        self.assert_conflict(blockedBy=[blocker], priority='high')

    def test_a_running_task_moved_to_todo_is_a_conflict(self):
        self.make_task()
        self.emit(1)
        self.assertEqual(self.emit(2, 'in_progress')['delivery'], 'delivered')
        self.board(status='todo')
        result = self.emit(3, 'in_review')
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', MANUAL))
        self.assertEqual(self.net.issues['1']['status'], 'todo')

    def test_assignee_and_agent_changes_keep_their_guard_diagnostics(self):
        for change, diagnostic in (({'assigneeUserId': 'someone-else'}, 'another human owns this issue'),
                                   ({'assigneeAgentId': 'agent'}, 'agent or active execution ownership conflict')):
            with self.subTest(change=change):
                self.tearDown()
                self.doCleanups()
                self.setUp()
                self.assert_conflict(diagnostic=diagnostic, priority='high', **change)


class FailClosedBaseline(BoardOrderHarness):
    """A missing or unreadable snapshot behaves exactly as before plan 100."""

    BROKEN = (None, 'missing', {'v': 3, 'priority': 'medium', 'rest': '0' * 64}, {'v': 0, 'priority': 'medium', 'rest': '0' * 64}, {'v': 1, 'priority': 'medium', 'rest': 'not-a-hash'},
              {'v': 1, 'priority': 'medium', 'rest': 'A' * 64}, {'v': True, 'priority': 'medium', 'rest': '0' * 64}, 'text')

    def break_snapshot(self, value):
        path = paperclip.state_path(self.net.repo)
        state = self.ledger()
        if value == 'missing':
            state['mappings']['94'].pop('snapshot')
        else:
            state['mappings']['94']['snapshot'] = value
        path.write_text(json.dumps(state))

    def test_broken_snapshot_makes_a_priority_change_a_conflict(self):
        for value in self.BROKEN:
            with self.subTest(snapshot=value):
                self.tearDown()
                self.doCleanups()
                self.setUp()
                self.make_task()
                self.emit(1)
                self.break_snapshot(value)
                self.board(priority='high')
                result = self.emit(2, 'in_progress')
                self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', MANUAL))

    def test_unchanged_board_still_delivers_and_gains_a_snapshot(self):
        self.make_task()
        self.emit(1)
        self.break_snapshot('missing')
        self.assertEqual(self.emit(2, 'in_progress')['delivery'], 'delivered')
        self.assertEqual(self.mapping()['snapshot'], paperclip.snapshot_of(self.net.issues['1']))
        self.board(priority='high')
        self.assertEqual(self.emit(3, 'in_review')['delivery'], 'delivered')


class ProjectionDrift(BoardOrderHarness):
    """Data that changes when other rows change is not a hand change to this task."""

    def drifted(self):
        issue = self.net.issues['1']
        issue['ancestors'] = [{'id': 'parent', 'title': 'Parent'}]
        issue['goal'] = {'id': issue['goalId'], 'title': 'Goal renamed elsewhere', 'updatedAt': 'later'}
        issue['relatedWork'] = {'inbound': [{'issue': {'id': 'mentioning'}}], 'outbound': []}
        issue['referencedIssueIdentifiers'] = ['PLC-7']
        issue['blocks'] = [{'id': 'blocked-elsewhere', 'title': 'Other task'}]
        issue['blockerAttention'] = {'state': 'attention'}
        issue['reviewAttention'] = {'state': 'review'}
        issue['labels'] = [dict(label, name='renamed label') for label in issue['labels']]
        for name in ('archivedAt', 'activeRecoveryAction', 'scheduledRetry', 'executionBlocker', 'successfulRunHandoff',
                     'currentExecutionWorkspace', 'externalChannelBinding', 'mentionedProjects'):
            issue[name] = {'drifted': name}
        issue['blockedBy'] = [dict(row, title='Retitled elsewhere', status='done', priority='urgent') for row in issue['blockedBy']]
        issue['documentSummaries'] = [{'id': 'doc', 'key': 'notes', 'latestRevisionId': 'rev-1', 'latestRevisionNumber': 1, 'title': 'Old'}]
        return issue

    def start(self):
        self.make_task(documentSummaries=[{'id': 'doc', 'key': 'notes', 'latestRevisionId': 'rev-1', 'latestRevisionNumber': 1, 'title': 'Notes'}])
        self.assertEqual(self.emit(1)['delivery'], 'delivered')

    def test_projection_drift_with_a_priority_change_is_adopted(self):
        self.start()
        issue = self.drifted()
        issue['documentSummaries'][0].update(title='Renamed summary', updatedAt='later')
        # An inherited goal that follows the project's goal.
        issue['project'] = dict(issue['project'], goalId='new-goal', goalIds=['new-goal'])
        issue['goalId'] = 'new-goal'
        self.board(priority='high')
        self.assertEqual(self.emit(2, 'in_progress')['delivery'], 'delivered')

    def test_own_documents_and_an_explicit_goal_still_conflict(self):
        for change in ({'documentSummaries': [{'id': 'doc', 'key': 'notes', 'latestRevisionId': 'rev-2', 'latestRevisionNumber': 2}]},
                       {'documentSummaries': [{'id': 'doc', 'key': 'notes', 'latestRevisionId': 'rev-1', 'latestRevisionNumber': 1},
                                              {'id': 'doc-2', 'key': 'plan', 'latestRevisionId': 'rev-9', 'latestRevisionNumber': 1}]},
                       {'planDocument': {'id': 'plan-doc', 'key': 'plan', 'latestRevisionId': 'rev-3', 'latestRevisionNumber': 3, 'body': 'Hand plan'}},
                       {'goalId': 'explicit-goal'}):
            with self.subTest(change=change):
                self.tearDown()
                self.doCleanups()
                self.setUp()
                self.start()
                self.drifted()
                self.board(priority='high', **change)
                result = self.emit(2, 'in_progress')
                self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', MANUAL))


class AuthoredAndMarkers(BoardOrderHarness):

    def test_authored_report_keeps_todo_and_a_later_claim_moves_it(self):
        self.make_task()
        self.emit(1)
        self.board(status='todo', priority='high')
        self.assertEqual(self.emit(2)['delivery'], 'delivered')
        self.assertNotIn('status', self.patches()[-1])
        self.assertEqual(self.patches()[-1]['assigneeUserId'], 'u')
        self.assertEqual((self.net.issues['1']['status'], len(self.net.comments['1'])), ('todo', 2))
        self.assertEqual(self.emit(3, 'in_progress')['delivery'], 'delivered')
        self.assertEqual(self.net.issues['1']['status'], 'in_progress')

    def test_authored_marker_rerun_on_todo_is_delivered(self):
        self.make_task()
        self.emit(1)
        self.board(status='todo')
        self.net.fail_patch = True
        self.assertEqual(self.emit(2)['delivery'], 'pending')
        self.net.fail_patch = False
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        self.assertEqual((self.net.issues['1']['status'], len(self.net.comments['1'])), ('todo', 2))

    def lost_response(self, seq):
        """An authored PATCH lands on the board but its response is lost."""
        self.net.fail_patch = True
        self.assertEqual(self.emit(seq)['delivery'], 'pending')
        self.net.fail_patch = False

    def test_lost_response_then_todo_is_delivered(self):
        # Matthew orders the task after the write landed: still mstack's own retry.
        self.make_task()
        self.emit(1)
        self.lost_response(2)
        self.board(status='todo')
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        self.assertEqual(self.mapping()['snapshot'], paperclip.snapshot_of(self.net.issues['1']))

    def test_lost_first_response_then_todo_is_delivered(self):
        # The first authored PATCH also sets the assignee; that alone is mstack's own edit.
        self.make_task()
        self.lost_response(1)
        self.board(status='todo')
        result = self.emit(1)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))

    def test_lost_response_then_retitle_and_todo_is_a_conflict(self):
        # Code review M1: a hand retitle with the todo move must not become the baseline.
        self.make_task()
        self.emit(1)
        before = self.mapping()
        self.lost_response(2)
        self.board(status='todo', title='Retitled by hand')
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', 'marker exists but issue outcome changed; inspect manually'))
        self.assertEqual(self.mapping()['snapshot'], before['snapshot'])
        self.assertNotEqual(self.emit(3, 'in_progress')['delivery'], 'delivered')  # held behind the conflict

    def test_lost_response_without_snapshot_then_todo_is_a_conflict(self):
        # No baseline to compare against: the strict rule from before plan 100.
        self.make_task()
        self.emit(1)
        self.lost_response(2)
        path = paperclip.state_path(self.net.repo)
        state = json.loads(path.read_text())
        del state['mappings']['94']['snapshot']
        path.write_text(json.dumps(state))
        self.board(status='todo')
        self.assertEqual(self.emit(2)['delivery'], 'conflict')

    def test_existing_board_blocked_task_moves_to_backlog_on_the_next_authored_report(self):
        self.make_task(status='blocked')
        self.assertEqual(self.emit(1, 'blocked')['delivery'], 'delivered')
        self.assertEqual(self.emit(2)['delivery'], 'delivered')
        self.assertEqual((self.net.issues['1']['status'], self.patches()[-1]['status']), ('backlog', 'backlog'))

    def test_no_mapping_todo_task_found_by_marker_stays_a_conflict(self):
        for title in ('Fixture plan', 'Renamed on the board'):
            with self.subTest(title=title):
                self.tearDown()
                self.doCleanups()
                self.setUp()
                self.make_task(status='todo', title=title)
                result = self.emit(1)
                self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', ADOPTED_DIFFERS))
                self.assertEqual((self.net.issues['1']['status'], self.net.comments['1'], self.sent), ('todo', [], []))
                self.assertNotIn('94', self.ledger()['mappings'])

    def test_marker_adoption_of_backlog_writes_a_snapshot(self):
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        self.assertTrue(paperclip.valid_snapshot(self.mapping()['snapshot']))

    def test_keyed_task_priority_change_is_adopted(self):
        def task(status, note):
            return paperclip.task(self.net.repo, 'p', 'order-key', 'Keyed task', status, note)
        self.assertEqual(task('backlog', 'Opened')['delivery'], 'delivered')
        issue_id = next(iter(self.net.issues))
        self.board(issue_id, priority='high')
        result = task('in_progress', 'Started')
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        self.assertEqual(self.net.issues[issue_id]['status'], 'in_progress')
        self.board(issue_id, title='Renamed by hand')
        self.assertEqual(task('done', 'Finished')['delivery'], 'conflict')


class SeedSnapshots(BoardOrderHarness):
    """seed-snapshots reads the board only and seeds only tasks unchanged since mstack's last write."""

    def setUp(self):
        super().setUp()
        handler = self.net.server.RequestHandlerClass
        original = handler.handle_request
        self.missing, self.offline = set(), set()
        harness = self
        def handle(request, method):
            issue_id = request.path.split('?')[0].split('/')[3] if request.path.startswith('/api/issues/') else None
            if issue_id in harness.missing:
                request.send_response(404)
                request.send_header('Content-Type', 'application/json')
                request.end_headers()
                request.wfile.write(b'{"error":"Issue not found"}')
                return
            if issue_id in harness.offline:
                request.connection.close()
                return
            return original(request, method)
        handler.handle_request = handle

    def legacy(self, plan, number, status='backlog', **extra):
        """A task and a mapping as written before plan 100: no snapshot."""
        self.make_task(number, status=status, plan=plan, **extra)
        path = paperclip.state_path(self.net.repo)
        state = paperclip.load_state(path)
        state['mappings'][plan] = {'issue_id': number, 'status': status, 'updated_at': '1', 'sequence': 1}
        path.write_text(json.dumps(state))

    def seed(self):
        return paperclip.seed_snapshots(self.net.repo)

    def test_seeds_only_unchanged_records(self):
        self.legacy('10', '1')
        self.legacy('11', '2')
        self.board('2', priority='high')
        self.legacy('12', '3', status='done')
        self.legacy('13', '4')
        self.board('4', agentNote='x', assigneeAgentId='agent')
        self.legacy('14', '5')
        self.missing.add('5')
        self.legacy('15', '6')
        self.offline.add('6')
        self.legacy('16', '7', status='blocked')
        result = self.seed()
        self.assertEqual({k: result[k] for k in ('seeded', 'changed', 'closed', 'already', 'errors')},
                         {'seeded': 2, 'changed': 1, 'closed': 1, 'already': 0, 'errors': 3})
        self.assertEqual([(row['plan'], row['issue_id'], row['result']) for row in result['tasks']],
                         [('10', '1', 'seeded'), ('11', '2', 'changed'), ('12', '3', 'closed'), ('13', '4', 'error'),
                          ('14', '5', 'error'), ('15', '6', 'error'), ('16', '7', 'seeded')])
        self.assertEqual([row['diagnostic'] for row in result['tasks'] if row['result'] == 'error'],
                         ['agent or active execution ownership conflict', 'remote request rejected; reconcile before retry',
                          'offline or invalid remote response; delivery pending'])
        mappings = self.ledger()['mappings']
        self.assertEqual(mappings['10']['snapshot'], paperclip.snapshot_of(self.net.issues['1']))
        self.assertEqual(mappings['16']['snapshot'], paperclip.snapshot_of(self.net.issues['7']))
        for plan in ('11', '12', '13', '14', '15'):
            self.assertNotIn('snapshot', mappings[plan])
        self.assertEqual(self.sent, [])
        self.assertFalse([m for m, _ in self.net.calls if m != 'GET'])
        # A second run: what was seeded is 'already', every other count is unchanged.
        again = self.seed()
        self.assertEqual({k: again[k] for k in ('seeded', 'changed', 'closed', 'already', 'errors')},
                         {'seeded': 0, 'changed': 1, 'closed': 1, 'already': 2, 'errors': 3})
        self.assertEqual(self.ledger()['mappings'], mappings)
        self.assertEqual(self.sent, [])

    def test_seeded_task_adopts_and_a_changed_one_still_conflicts(self):
        self.legacy('94', '1')
        self.legacy('95', '2')
        self.board('2', status='todo')
        self.seed()
        self.board('1', priority='high')
        self.assertEqual(self.emit(2, 'in_progress')['delivery'], 'delivered')
        self.board('2', priority='high')
        result = self.emit(2, 'in_progress', plan='95')
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', MANUAL))

    def test_existing_valid_snapshot_is_not_rewritten(self):
        self.make_task()
        self.emit(1)
        before = self.ledger()['mappings']['94']
        self.board(priority='high')
        result = self.seed()
        self.assertEqual((result['already'], self.ledger()['mappings']['94']), (1, before))

    def test_board_reads_run_without_the_lock_and_a_concurrent_change_is_skipped(self):
        # Code review L2: no ledger lock across board GETs; a mapping changed meanwhile is not seeded.
        self.legacy('10', '1')
        self.legacy('11', '2')
        path = paperclip.state_path(self.net.repo)
        real = paperclip.full_issue
        held = []
        def read(api, issue_id):
            try:
                with paperclip.config.locked(path, timeout=0):
                    if issue_id == '2':  # A concurrent emit rewrites plan 11's mapping mid-seed.
                        state = paperclip.load_state(path)
                        state['mappings']['11']['sequence'] = 2
                        paperclip.config.atomic_write(path, state)
            except paperclip.config.ConfigError:
                held.append(issue_id)
            return real(api, issue_id)
        with patch.object(paperclip, 'full_issue', read):
            result = self.seed()
        self.assertEqual(held, [])
        self.assertEqual([(row['plan'], row['result'], row['diagnostic']) for row in result['tasks']],
                         [('10', 'seeded', None), ('11', 'error', 'local mapping changed during the seed; not seeded, rerun')])
        self.assertEqual((result['seeded'], result['errors']), (1, 1))
        mappings = self.ledger()['mappings']
        self.assertEqual(mappings['10']['snapshot'], paperclip.snapshot_of(self.net.issues['1']))
        self.assertEqual(mappings['11'], {'issue_id': '2', 'status': 'backlog', 'updated_at': '1', 'sequence': 2})
        self.assertEqual(self.seed()['seeded'], 1)  # A rerun seeds it.

    def test_command_line_prints_one_json_line(self):
        self.legacy('10', '1')
        home = self.net.root / 'home'
        (home / '.config/mstack').mkdir(parents=True)
        (home / '.config/mstack/paperclip.json').write_bytes(self.net.profiles.read_bytes())
        result = subprocess.run([sys.executable, str(Path(paperclip.__file__)), 'seed-snapshots', '--repo', str(self.net.repo)],
                                capture_output=True, text=True, env=dict(os.environ, HOME=str(home)), timeout=60)
        self.assertEqual(result.stdout.count('\n'), 1)
        answer = json.loads(result.stdout)
        self.assertEqual((answer['seeded'], [(row['plan'], row['result']) for row in answer['tasks']]), (1, [('10', 'seeded')]))
        self.assertEqual(self.ledger()['mappings']['10']['snapshot'], paperclip.snapshot_of(self.net.issues['1']))
        self.assertFalse([method for method, _ in self.net.calls if method != 'GET'])

# What snapshot_of() returned before this fix (83a057f) for fixture_issue(status='backlog',
# updatedAt='1') at statusVersion 0 and 3: the shape of the v1 snapshots already in ledgers.
V1_AT_0 = {'v': 1, 'priority': 'medium', 'rest': 'b8c2f628435b65b34b2af418e70cf13348ab8f08b72ce865c885f4d7af9af670'}
V1_AT_3 = {'v': 1, 'priority': 'medium', 'rest': 'cba164c7701e1ef3e3c24d89a9d6742ccf26242243e548b599d15c2908d05958'}


def v1_snapshot(issue):
    """A v1 snapshot as the pre-fix code wrote it: statusVersion hashed in."""
    canonical = json.dumps(paperclip.rest_view(issue, frozenset()), sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return {'v': 1, 'priority': issue.get('priority'), 'rest': paperclip.hashlib.sha256(canonical.encode('utf-8')).hexdigest()}


class StatusVersionIsABoardSideEffect(unittest.TestCase):
    """The real board adds 1 to statusVersion on every status change (migrations/0227 L146-158)."""

    def mapping(self, snapshot, status='backlog'):
        return {'issue_id': 'x', 'status': status, 'updated_at': '1', 'sequence': 1, 'snapshot': snapshot}

    def test_v2_ignores_status_version(self):
        base = fixture_issue(status='backlog', updatedAt='1', statusVersion=0)
        snapshot = paperclip.snapshot_of(base)
        self.assertEqual(snapshot['v'], 2)
        self.assertEqual(snapshot, paperclip.snapshot_of(dict(base, statusVersion=7)))
        moved = dict(base, status='todo', priority='high', statusVersion=1, updatedAt='3')
        self.assertEqual(paperclip.board_change(self.mapping(snapshot), moved), ('adopt', {'priority', 'status'}))

    def test_v1_helper_reproduces_the_pre_fix_hash(self):
        base = fixture_issue(status='backlog', updatedAt='1')
        self.assertEqual(v1_snapshot(dict(base, statusVersion=0)), V1_AT_0)
        self.assertEqual(v1_snapshot(dict(base, statusVersion=3)), V1_AT_3)
        self.assertTrue(paperclip.valid_snapshot(V1_AT_0))

    def test_v1_that_still_matches_the_board(self):
        base = fixture_issue(status='backlog', updatedAt='1', statusVersion=0)
        self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), dict(base, updatedAt='2')), ('adopt', set()))
        self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), dict(base, priority='high', updatedAt='2')), ('adopt', {'priority'}))

    def test_v1_that_differs_only_in_status_version(self):
        base = fixture_issue(status='backlog', updatedAt='1')
        # Matthew marks the task ready: the trigger takes statusVersion 0 -> 1.
        todo = dict(base, status='todo', priority='high', statusVersion=1, updatedAt='3')
        self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), todo), ('adopt', {'priority', 'status'}))
        # The MAT-96 case: moved and moved back, statusVersion 0 -> 2, visible fields as before.
        back = dict(base, statusVersion=2, updatedAt='5')
        self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), back), ('adopt', set()))
        # A snapshot taken at 3 is still found from a board at 40.
        self.assertEqual(paperclip.board_change(self.mapping(V1_AT_3), dict(base, statusVersion=40, updatedAt='9')), ('adopt', set()))

    def test_v1_that_differs_elsewhere_is_a_conflict(self):
        base = fixture_issue(status='backlog', updatedAt='1')
        for change in ({'title': 'Renamed by hand'}, {'description': 'Rewritten'}, {'labelIds': ['another-label']},
                       {'newPaperclipField': 'unknown'}, {'assigneeUserId': None}):
            with self.subTest(change=change):
                for version in (0, 1, 5):
                    issue = dict(base, status='todo', statusVersion=version, updatedAt='3', **change)
                    self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), issue)[0], 'conflict')

    def test_v1_that_cannot_be_judged_is_a_conflict(self):
        base = fixture_issue(status='backlog', updatedAt='1')
        # statusVersion only increases: a board below the snapshot's value cannot be the same task state.
        self.assertEqual(paperclip.board_change(self.mapping(V1_AT_3), dict(base, statusVersion=2, updatedAt='2'))[0], 'conflict')
        for value in (None, '0', True, -1, 1.0):
            with self.subTest(statusVersion=value):
                self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), dict(base, statusVersion=value, updatedAt='2'))[0], 'conflict')
        missing = {k: v for k, v in base.items() if k != 'statusVersion'}
        self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), dict(missing, updatedAt='2'))[0], 'conflict')
        # Beyond the search window: fail closed, never adopt.
        with patch.object(paperclip, 'V1_STATUS_VERSION_SEARCH', 2):
            self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), dict(base, statusVersion=2, updatedAt='2'))[0], 'adopt')
            self.assertEqual(paperclip.board_change(self.mapping(V1_AT_0), dict(base, statusVersion=3, updatedAt='2'))[0], 'conflict')

    def test_own_retry_ignores_the_bump_of_the_lost_write(self):
        api = type('Api', (), {'user_id': 'u'})()
        base = fixture_issue(status='backlog', updatedAt='1', statusVersion=0, assigneeUserId=None)
        landed = dict(base, assigneeUserId='u', status='todo', statusVersion=2, updatedAt='4')
        for snapshot in (paperclip.snapshot_of(base), v1_snapshot(base)):
            with self.subTest(v=snapshot['v']):
                self.assertTrue(paperclip.own_retry(self.mapping(snapshot), landed, api))
                self.assertFalse(paperclip.own_retry(self.mapping(snapshot), dict(landed, title='Retitled'), api))


class StatusVersionDelivery(BoardOrderHarness):
    """Delivery on a fake board that bumps statusVersion as the real one does."""

    def to_v1(self):
        """Rewrite the mapping's snapshot as the pre-fix code would have stored it for the current board."""
        path = paperclip.state_path(self.net.repo)
        state = self.ledger()
        state['mappings']['94']['snapshot'] = v1_snapshot(self.net.issues['1'])
        path.write_text(json.dumps(state))

    def test_todo_and_priority_then_report_is_adopted(self):
        self.make_task()
        self.assertEqual(self.emit(1)['delivery'], 'delivered')
        version = self.net.issues['1']['statusVersion']
        self.board(status='todo', priority='high')
        self.assertEqual(self.net.issues['1']['statusVersion'], version + 1)
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        self.assertEqual((self.net.issues['1']['status'], self.net.issues['1']['priority']), ('todo', 'high'))
        mapping = self.mapping()
        self.assertEqual(mapping['adopted']['fields'], ['priority', 'status'])
        self.assertEqual(mapping['snapshot'], paperclip.snapshot_of(self.net.issues['1']))
        self.assertEqual(self.emit(3, 'in_progress')['delivery'], 'delivered')

    def test_v1_snapshot_is_adopted_and_upgraded_on_the_next_write(self):
        self.make_task()
        self.emit(1)
        self.to_v1()
        self.board(status='todo', priority='high')
        result = self.emit(2)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
        snapshot = self.mapping()['snapshot']
        self.assertEqual((snapshot['v'], snapshot), (2, paperclip.snapshot_of(self.net.issues['1'])))

    def test_v1_snapshot_with_a_hand_edit_is_a_conflict(self):
        self.make_task()
        self.emit(1)
        self.to_v1()
        before = self.mapping()
        self.board(status='todo', title='Renamed by hand')
        result = self.emit(2, 'in_progress')
        self.assertEqual((result['delivery'], result['diagnostic']), ('conflict', MANUAL))
        self.assertEqual(self.mapping(), before)
        self.assertEqual(self.net.issues['1']['status'], 'todo')

    def test_lost_response_then_todo_on_a_bumping_board(self):
        for v1 in (False, True):
            with self.subTest(v1=v1):
                self.tearDown()
                self.doCleanups()
                self.setUp()
                self.make_task()
                self.emit(1)
                if v1:
                    self.to_v1()
                self.net.fail_patch = True
                self.assertEqual(self.emit(2)['delivery'], 'pending')
                self.net.fail_patch = False
                version = self.net.issues['1']['statusVersion']
                self.board(status='todo')
                self.assertEqual(self.net.issues['1']['statusVersion'], version + 1)
                result = self.emit(2)
                self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))
                self.assertEqual(self.mapping()['snapshot'], paperclip.snapshot_of(self.net.issues['1']))

    def test_lost_first_response_bumps_and_is_still_own_retry(self):
        self.make_task()
        self.net.fail_patch = True
        self.assertEqual(self.emit(1)['delivery'], 'pending')
        self.net.fail_patch = False
        self.assertEqual(self.net.issues['1']['statusVersion'], 1)  # the lost write set the assignee
        self.board(status='todo')
        self.assertEqual(self.net.issues['1']['statusVersion'], 2)
        result = self.emit(1)
        self.assertEqual((result['delivery'], result['diagnostic']), ('delivered', None))


if __name__ == '__main__':
    unittest.main()
