#!/usr/bin/env python3
"""Bounded, human-owned Paperclip reporting with durable reconciliation."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import signal
import threading
import contextlib
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit, urlunsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener

import paperclip_config as config


class DeliveryError(Exception):
    def __init__(self, diagnostic, delivery='pending'):
        super().__init__(diagnostic)
        self.delivery = delivery


def normalize_base(value):
    try:
        url = urlsplit(value)
        if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError()
        url.port
    except (ValueError, TypeError):
        raise config.ConfigError('invalid profile API address') from None
    return urlunsplit((url.scheme, url.netloc, url.path.rstrip('/'), '', ''))


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise DeliveryError('authenticated redirects refused', 'conflict')


@contextlib.contextmanager
def bounded_request(seconds):
    # Supported desktop/CLI platforms are Unix. Refuse other-thread use rather
    # than allowing a socket's inactivity timeout to become an unlimited read.
    if threading.current_thread() is not threading.main_thread():
        raise DeliveryError('reporting requires the main CLI thread')
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    def expired(signum, frame):
        raise DeliveryError('delivery deadline reached')
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, min(seconds, previous_timer[0]) if previous_timer[0] else seconds)
    started = time.monotonic()
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_timer[0]:
            signal.setitimer(signal.ITIMER_REAL, max(0.000001, previous_timer[0] - (time.monotonic()-started)), previous_timer[1])


class API:
    def __init__(self, base, auth_file, deadline=None):
        self.base = normalize_base(base)
        self.deadline = deadline if deadline is not None else time.monotonic() + 30
        try:
            credential = config.read_json(Path(auth_file).expanduser())['credentials'][self.base]
            self.token, self.user_id = credential['token'], credential['userId']
            if not all(isinstance(v, str) and v and '\n' not in v and '\r' not in v for v in (self.token, self.user_id)):
                raise ValueError()
        except (KeyError, TypeError, ValueError, config.ConfigError):
            raise DeliveryError('authentication missing; use official board login') from None
        self.opener = build_opener(NoRedirect())

    def request(self, method, path, data=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise DeliveryError('delivery deadline reached')
        request = Request(self.base + '/api' + path, method=method,
                          data=None if data is None else json.dumps(data).encode(),
                          headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'})
        try:
            with bounded_request(remaining), self.opener.open(request, timeout=min(5, remaining)) as response:
                # Bound response sizes as well as request time.
                payload = response.read(4 * 1024 * 1024 + 1)
                if len(payload) > 4 * 1024 * 1024:
                    raise DeliveryError('response exceeds safe size')
                return json.loads(payload)
        except HTTPError as error:
            if error.code == 401:
                raise DeliveryError('authentication expired; reconnect Paperclip') from None
            if error.code == 403:
                raise DeliveryError('authorization conflict', 'conflict') from None
            raise DeliveryError('remote request rejected; reconcile before retry') from None
        except (URLError, TimeoutError, OSError, ValueError):
            raise DeliveryError('offline or invalid remote response; delivery pending') from None

    def pages(self, path):
        rows, cursor, seen = [], None, set()
        for _ in range(100):
            suffix = ('&' if '?' in path else '?') + urlencode({'cursor': cursor}) if cursor else ''
            result = self.request('GET', path + suffix)
            if isinstance(result, list):
                return rows + result
            if not isinstance(result, dict) or not isinstance(result.get('items'), list):
                raise DeliveryError('unsupported pagination; reconciliation pending')
            rows.extend(result['items'])
            cursor = result.get('nextCursor')
            if not cursor:
                return rows
            if not isinstance(cursor, str) or cursor in seen:
                raise DeliveryError('invalid pagination; reconciliation pending')
            seen.add(cursor)
        raise DeliveryError('pagination bound reached; reconciliation pending')


def marker(event):
    digest = hashlib.sha256((event['repository_id'] + '\n' + event['plan_id'] + '\n' + event['event_id']).encode()).hexdigest()
    return '<!-- mstack-event:' + digest + ' -->'


def plan_marker(event):
    digest = hashlib.sha256((event['repository_id'] + '\n' + event['plan_id']).encode()).hexdigest()
    return '<!-- mstack-plan:' + digest + ' -->'


def unblock_action(event):
    restrictions = next((line for line in event['notes'].splitlines() if line.startswith('Local restrictions: ')), '')
    return ('Clear the local plan block' + (' (' + restrictions[len('Local restrictions: '):] + ')' if restrictions else ''))[:500]


def task_unblock_action(event):
    return (event['notes'].strip().splitlines() or ['Review this task'])[0][:500]


def validate_event(value, binding):
    keys = {'schema_version', 'repository_id', 'plan_id', 'event_id', 'sequence', 'outcome', 'metadata', 'notes'}
    if not isinstance(value, dict) or set(value) != keys or type(value['schema_version']) is not int or value['schema_version'] != 1:
        raise config.ConfigError('invalid event schema')
    if value['repository_id'] != binding['repository_id']:
        raise config.ConfigError('event repository identity mismatch')
    for key in ('plan_id', 'event_id'):
        if not isinstance(value[key], str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', value[key]):
            raise config.ConfigError('invalid event identifier')
    if type(value['sequence']) is not int or value['sequence'] < 1:
        raise config.ConfigError('invalid event sequence')
    if value['outcome'] not in {'backlog', 'todo', 'in_progress', 'blocked', 'in_review', 'done', 'cancelled', 'note'}:
        raise config.ConfigError('invalid event outcome')
    if not isinstance(value['metadata'], dict) or set(value['metadata']) - {'session', 'worktree', 'title', 'commit'}:
        raise config.ConfigError('invalid event metadata')
    strings = list(value['metadata'].values()) + [value['notes']]
    if any(not isinstance(s, str) or len(s) > 8000 or any(ord(c) < 32 and c not in '\n\t' for c in s) for s in strings):
        raise config.ConfigError('invalid event text')
    # Refuse common credential material, rather than persisting it as a note.
    if any(re.search(r'(?i)(bearer\s+\S+|(?:token|password|api[_-]?key)\s*[:=]|-----BEGIN .*PRIVATE KEY)', s) for s in strings):
        raise config.ConfigError('event text contains credential-like material')
    return value


def state_path(repo):
    return config.binding_path(repo).parent / 'events.json'


def load_state(path):
    return config.read_json(path) if path.exists() else {'version': 1, 'events': [], 'mappings': {}}


def guard(issue, api, binding):
    if issue.get('companyId') != binding['company_id'] or issue.get('projectId') != binding['project_id'] or issue.get('descriptionTruncated'):
        raise DeliveryError('full issue unavailable in configured project', 'conflict')
    if any(issue.get(k) for k in ('executionRunId', 'checkoutRunId', 'assigneeAgentId', 'reviewRequest')) or issue.get('workMode') == 'review' or issue.get('harnessKind') == 'review':
        raise DeliveryError('agent or active execution ownership conflict', 'conflict')
    if issue.get('assigneeUserId') not in (None, api.user_id):
        raise DeliveryError('another human owns this issue', 'conflict')


def full_issue(api, issue_id):
    return api.request('GET', '/issues/' + quote(issue_id, safe=''))


# Plan 100: which board changes are Matthew ordering work, not a hand edit.
# Fixed from the Paperclip 2026.1005.0 source, read-only; the evidence and every
# key's class are in fixtures/paperclip/issue-update-2026.1005.0.json. Re-derive
# on every Paperclip upgrade: a hand-editable field moved into a dropped key would
# loosen this rule silently.
ADOPTABLE_STATUSES = frozenset({'backlog', 'todo'})
# Columns Paperclip itself writes on a priority-only or backlog/todo update, besides
# updatedAt (services/issues.js L7050-7070, L7213-7247): none. goalId is recomputed
# there (resolveNextIssueGoalId) but keeps its value unless the project goal changed.
BOARD_SIDE_EFFECT_FIELDS = frozenset()
# Joined or derived data that changes when other rows change: dropped from the hash.
PROJECTION_FIELDS = frozenset({
    'labels',                      # services/issues.js L1896: label rows; membership is labelIds (hashed)
    'archivedAt', 'archivedByActorType', 'archivedByAgentId', 'archivedByRunId',  # routes/issues.js L6030, services L1828-1836: per-viewer inbox
    'ancestors',                   # routes/issues.js L6032: parent issue rows
    'blockerAttention',            # routes/issues.js L6033: conditional, other issues' runs and approvals
    'reviewAttention',             # routes/issues.js L6034: conditional, review requests
    'successfulRunHandoff',        # routes/issues.js L6035: run state
    'executionBlocker',            # routes/issues.js L6036
    'scheduledRetry',              # routes/issues.js L6037
    'activeRecoveryAction',        # routes/issues.js L6038: revalidated on every read
    'blocks',                      # routes/issues.js L6040: inverse of other issues' blockedBy (services L4742-4775)
    'relatedWork',                 # routes/issues.js L6041: references from other issues
    'referencedIssueIdentifiers',  # routes/issues.js L6042: identifiers of other issues
    'project',                     # routes/issues.js L6044: project row (read for the inherited goal test)
    'goal',                        # routes/issues.js L6045: goal row
    'mentionedProjects',           # routes/issues.js L6046
    'currentExecutionWorkspace',   # routes/issues.js L6047
    'externalChannelBinding',      # routes/issues.js L6050: chat conversation and publication state
})
# This task's own related rows whose membership is a decision: hashed as sorted ids only.
RELATION_FIELDS = frozenset({
    'blockedBy',     # routes/issues.js L6039: this task's own blockers
    'workProducts',  # routes/issues.js L6048: this task's work products
    'linkedCases',   # routes/issues.js L6049: this task's case links
})
# This task's own documents: hashed as (key, id, latestRevisionId, latestRevisionNumber), never dropped.
DOCUMENT_FIELDS = frozenset({'planDocument', 'documentSummaries'})  # routes/issues.js L6043, services/documents.js L85-112
_BASELINE_FIELDS = ('status', 'priority', 'updatedAt')


def _related_ids(value):
    if isinstance(value, list) and all(isinstance(row, dict) and 'id' in row for row in value):
        return sorted(str(row['id']) for row in value)
    return value  # An unknown shape is hashed in full: a false conflict, never a false adoption.


def _document_digest(value):
    rows = [] if value is None else value if isinstance(value, list) else [value]
    if not all(isinstance(row, dict) and 'id' in row for row in rows):
        return value
    return sorted(([row.get('key'), row['id'], row.get('latestRevisionId'), row.get('latestRevisionNumber')] for row in rows), key=json.dumps)


def _project_goal(issue):
    project = issue.get('project')
    if not isinstance(project, dict):
        return None
    goals = project.get('goalIds')
    return project.get('goalId') or (goals[0] if isinstance(goals, list) and goals else None)


def rest_view(issue):
    """The issue without the fields mstack compares directly, and without data that is not this task's own."""
    view = {}
    for key, value in issue.items():
        if key in _BASELINE_FIELDS or key in BOARD_SIDE_EFFECT_FIELDS or key in PROJECTION_FIELDS:
            continue
        if key in RELATION_FIELDS:
            value = _related_ids(value)
        elif key in DOCUMENT_FIELDS:
            value = _document_digest(value)
        elif key == 'goalId' and value is not None and value == _project_goal(issue):
            value = 'inherited'  # resolveNextIssueGoalId's own test for an inherited goal
        view[key] = value
    return view


def snapshot_of(issue):
    canonical = json.dumps(rest_view(issue), sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return {'v': 1, 'priority': issue.get('priority'), 'rest': hashlib.sha256(canonical.encode('utf-8')).hexdigest()}


def valid_snapshot(snapshot):
    return (isinstance(snapshot, dict) and type(snapshot.get('v')) is int and snapshot['v'] == 1 and 'priority' in snapshot
            and isinstance(snapshot.get('rest'), str) and re.fullmatch(r'[0-9a-f]{64}', snapshot['rest']) is not None)


def board_change(mapping, issue):
    """('same', set()), ('adopt', changed) or ('conflict', changed) for the board against mstack's last write."""
    if issue.get('status') == mapping.get('status') and issue.get('updatedAt') == mapping.get('updated_at'):
        return 'same', set()
    snapshot = mapping.get('snapshot')
    if not valid_snapshot(snapshot):
        return 'conflict', set()  # No baseline: exactly the rule before plan 100.
    changed = set()
    if issue.get('priority') != snapshot['priority']:
        changed.add('priority')
    if issue.get('status') != mapping.get('status'):
        changed.add('status')
    if snapshot_of(issue)['rest'] != snapshot['rest']:
        changed.add('rest')
    ordered = 'status' not in changed or (mapping.get('status') in ADOPTABLE_STATUSES and issue.get('status') in ADOPTABLE_STATUSES)
    return ('adopt' if 'rest' not in changed and ordered else 'conflict'), changed


def adopt(mapping, issue, changed):
    """Take the board's order fields as the new baseline; nothing reads 'adopted' for control flow."""
    mapping.update(status=issue['status'], updated_at=issue.get('updatedAt'), snapshot=snapshot_of(issue),
                   adopted={'fields': sorted(changed), 'updated_at': issue.get('updatedAt')})


def expected_status(outcome, current):
    """An authored report never moves Matthew's todo back to backlog."""
    return 'todo' if outcome == 'backlog' and current == 'todo' else outcome


def deliver(entry, state, api, binding, save):
    event = entry['event']
    plan = event['plan_id']
    mapping = state['mappings'].get(plan)
    stamp = marker(event)
    identity_stamp = plan_marker(event)
    if not mapping:
        candidates = []
        path = '/companies/' + quote(binding['company_id'], safe='') + '/issues?' + urlencode({'projectId': binding['project_id']})
        for row in api.pages(path):
            issue = full_issue(api, row['id'])
            if identity_stamp in (issue.get('description') or '') or stamp in (issue.get('description') or ''):
                candidates.append(issue)
        if len(candidates) > 1:
            raise DeliveryError('duplicate event markers require reconciliation', 'conflict')
        if candidates:
            issue = candidates[0]
            guard(issue, api, binding)
            if entry['uncertain'] and (issue['status'] != 'backlog' or issue.get('assigneeUserId') is not None):
                raise DeliveryError('uncertain creation was manually changed; inspect manually', 'conflict')
            if not entry['uncertain'] and issue['status'] != 'backlog' and event['outcome'] not in ('note', issue['status']):
                raise DeliveryError('adopted issue state differs; inspect manually', 'conflict')
            mapping = {'issue_id': issue['id'], 'status': issue['status'], 'updated_at': issue.get('updatedAt'), 'sequence': event['sequence'], 'snapshot': snapshot_of(issue)}
            state['mappings'][plan] = mapping
            entry['uncertain'] = False
            save()
        if not mapping and entry['uncertain']:
            raise DeliveryError('uncertain creation unresolved; no blind recreation')
        if not mapping:
            entry['uncertain'] = True
            save()  # Intent reaches disk BEFORE mutation; even a crash is uncertain.
            created = api.request('POST', '/companies/' + quote(binding['company_id'], safe='') + '/issues', {
                'projectId': binding['project_id'], 'title': event['metadata'].get('title', 'Plan ' + plan),
                'description': identity_stamp + '\n' + stamp + '\n' + event['notes'], 'status': 'backlog',
                'assigneeUserId': None, 'assigneeAgentId': None})
            issue = full_issue(api, created['id'])
            guard(issue, api, binding)
            if stamp not in (issue.get('description') or ''):
                raise DeliveryError('creation marker readback missing')
            mapping = {'issue_id': issue['id'], 'status': issue['status'], 'updated_at': issue.get('updatedAt'), 'sequence': 0, 'snapshot': snapshot_of(issue)}
            state['mappings'][plan] = mapping
            entry['uncertain'] = False
            save()
    issue = full_issue(api, mapping['issue_id'])
    guard(issue, api, binding)
    comments = api.pages('/issues/' + quote(issue['id'], safe='') + '/comments')
    if any(stamp in (comment.get('body') or '') for comment in comments):
        if issue.get('assigneeUserId') != api.user_id or (event['outcome'] != 'note' and issue['status'] != expected_status(event['outcome'], issue['status'])):
            raise DeliveryError('marker exists but issue outcome changed; inspect manually', 'conflict')
        mapping.update(status=issue['status'], updated_at=issue.get('updatedAt'), sequence=event['sequence'], snapshot=snapshot_of(issue))
        entry['delivery'] = 'delivered'
        save()
        return
    if entry['uncertain']:
        raise DeliveryError('uncertain update unresolved; no blind resend')
    change, changed = board_change(mapping, issue)
    if change == 'conflict':
        raise DeliveryError('issue manually changed; reconciliation required', 'conflict')
    if change == 'adopt':
        adopt(mapping, issue, changed)  # Saved before the write: the board still matches it if the write fails.
        save()
    if issue['status'] in ('done', 'cancelled') and event['outcome'] not in ('note', issue['status']):
        raise DeliveryError('terminal issue cannot be implicitly reopened', 'conflict')
    fresh = full_issue(api, issue['id'])
    guard(fresh, api, binding)
    if fresh != issue:
        raise DeliveryError('issue changed while preparing update', 'conflict')
    payload = {'comment': stamp + '\n' + event['notes'], 'commentClientRequestId': str(uuid.uuid5(uuid.NAMESPACE_URL, 'mstack-paperclip:'+event['event_id'])), 'assigneeUserId': api.user_id}
    target = expected_status(event['outcome'], issue['status'])
    if event['outcome'] != 'note' and target == event['outcome']:
        payload['status'] = event['outcome']  # Never 'priority', and never todo->backlog.
    if event['outcome'] == 'blocked':
        # The board refuses a bare blocked status (422); name the human who can unblock it.
        payload['unblockDescriptor'] = {'owner': {'userId': api.user_id}, 'action': task_unblock_action(event) if binding.get('task') else unblock_action(event)}
    entry['uncertain'] = True
    save()
    api.request('PATCH', '/issues/' + quote(issue['id'], safe=''), payload)
    confirmed = full_issue(api, issue['id'])
    comments = api.pages('/issues/' + quote(issue['id'], safe='') + '/comments')
    if not any(stamp in (comment.get('body') or '') for comment in comments):
        raise DeliveryError('update marker readback missing')
    guard(confirmed, api, binding)
    if confirmed.get('assigneeUserId') != api.user_id or (event['outcome'] != 'note' and confirmed['status'] != target):
        raise DeliveryError('mutation outcome not confirmed; inspect manually', 'conflict')
    mapping.update(status=confirmed['status'], updated_at=confirmed.get('updatedAt'), sequence=event['sequence'], snapshot=snapshot_of(confirmed))
    entry['delivery'] = 'delivered'
    entry['uncertain'] = False
    save()


def operate(repo, event=None, limit=10, api_factory=API):
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return {'delivery': 'disabled', 'event_id': None, 'diagnostic': None}
    return operate_state(binding, state_path(repo), lambda state: event, limit, api_factory)


def operate_state(binding, path, make_event, limit=10, api_factory=API, focus=None, supersede=True):
    # make_event runs under the ledger lock, so an event derived from the ledger cannot race.
    # focus names a plan identity whose events are attempted before any other pending work.
    # supersede=False delivers every pending event in order instead of only the latest per identity.
    deadline = time.monotonic() + 30
    with config.locked(path, timeout=min(3, max(0, deadline-time.monotonic()))):
        state = load_state(path)
        save = lambda: config.atomic_write(path, state)
        event = make_event(state)
        if event is not None:
            validate_event(event, binding)
            existing = [e for e in state['events'] if e['event']['event_id'] == event['event_id']]
            if existing and existing[0]['event'] != event:
                raise config.ConfigError('event identifier reused with different content')
            if not existing:
                peers = [e for e in state['events'] if e['event']['plan_id'] == event['plan_id']]
                if peers and event['sequence'] <= max(e['event']['sequence'] for e in peers):
                    raise config.ConfigError('event sequence must increase')
                state['events'].append({'event': event, 'delivery': 'pending', 'uncertain': False, 'diagnostic': None})
                save()
        try:
            profile = config.validate_profiles(config.read_json(config.profile_path()))['profiles'][binding['profile']]
            api = api_factory(profile['api_base'], profile['auth_file'], deadline)
        except DeliveryError as error:
            return {'delivery': error.delivery, 'event_id': event['event_id'] if event else None, 'diagnostic': str(error)}
        pending = [e for e in state['events'] if e['delivery'] == 'pending']
        blocked_plans = {e['event']['plan_id'] for e in state['events'] if e['delivery'] == 'conflict'}
        for entry in sorted(pending, key=lambda e: (e['event']['plan_id'] != focus, e['event']['plan_id'], e['event']['sequence']))[:min(max(limit, 0), 10)]:
            if entry['event']['plan_id'] in blocked_plans:
                continue
            peers = [e for e in state['events'] if e['event']['plan_id'] == entry['event']['plan_id']]
            latest = max(e['event']['sequence'] for e in peers)
            if supersede and entry['event']['sequence'] < latest and not entry['uncertain']:
                entry.update(delivery='delivered', diagnostic='superseded locally; not sent')
                save()
                continue
            try:
                deliver(entry, state, api, binding, save)
                entry['diagnostic'] = None
            except DeliveryError as error:
                entry.update(delivery=error.delivery, diagnostic=str(error))
                save()
                # An uncertain predecessor must never be overtaken by a later event.
                break
            save()
        if event:
            entry = next(e for e in state['events'] if e['event']['event_id'] == event['event_id'])
            return {'delivery': entry['delivery'], 'event_id': event['event_id'], 'diagnostic': entry['diagnostic']}
        return {'delivery': 'pending' if any(e['delivery'] == 'pending' for e in state['events']) else 'conflict' if any(e['delivery'] == 'conflict' for e in state['events']) else 'delivered', 'event_id': None, 'diagnostic': None}


TASK_STATUSES = ('backlog', 'todo', 'in_progress', 'blocked', 'in_review', 'done', 'cancelled')


def task(repo, project, key, title, status, note='', dry_run=False, api_factory=API):
    """Create or update one board task identified by a caller-chosen key.

    The task has no plan behind it. The checkout only supplies the board
    connection; the task's identity is the project and the key. The marker is
    '<!-- mstack-plan:' + sha256('task:' + project + '\\n' + 'task-' +
    sha256(key)[:40]) + ' -->' (hex digests of the UTF-8 text) and must stay
    stable: tasks marked by other tools rely on it. Nothing is ever deleted.
    """
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return {'delivery': 'disabled', 'event_id': None, 'diagnostic': None, 'issue_id': None}
    refused = lambda diagnostic: {'delivery': 'refused', 'event_id': None, 'diagnostic': diagnostic, 'issue_id': None}
    texts = {'project': project, 'key': key, 'title': title}
    if any(not isinstance(v, str) or not v.strip() or len(v) > 500 or any(ord(c) < 32 for c in v) for v in texts.values()):
        return refused('task requires a plain single-line project, key and title')
    if status not in TASK_STATUSES or not isinstance(note, str):
        return refused('invalid task status or note')
    binding = dict(binding, project_id=project, repository_id='task:' + project, task=True)
    plan = 'task-' + hashlib.sha256(key.encode()).hexdigest()[:40]

    def build(sequence):
        digest = hashlib.sha256('\n'.join([plan, str(sequence), status, title, note]).encode()).hexdigest()
        return validate_event({'schema_version': 1, 'repository_id': binding['repository_id'], 'plan_id': plan,
                               'event_id': 'task-' + digest, 'sequence': sequence, 'outcome': status,
                               'metadata': {'title': title}, 'notes': note}, binding)
    try:
        build(1)  # The credential filter sees title and note before any lock, ledger or request.
    except config.ConfigError as error:
        return refused(str(error))
    path = state_path(repo).with_name('tasks-' + hashlib.sha256(project.encode()).hexdigest()[:16] + '.json')

    def make_event(state):
        peers = [e['event'] for e in state['events'] if e['event']['plan_id'] == plan]
        latest = max(peers, key=lambda e: e['sequence'], default=None)
        same = lambda event: event['outcome'] == status and event['notes'] == note
        if latest and same(latest):
            return latest  # A repeated call is a retry of the same intent, never a second comment.
        waiting = [e['event'] for e in state['events'] if e['event']['plan_id'] == plan and e['delivery'] != 'delivered' and same(e['event'])]
        if waiting:
            return waiting[-1]  # Retrying an earlier call that is still queued must not queue it twice.
        return build(latest['sequence'] + 1 if latest else 1)

    try:
        if dry_run:
            return task_preview(binding, load_state(path), make_event, plan, api_factory)
        holder = {}
        def remember(state):
            holder['state'] = state
            return make_event(state)
        # Every note is a comment a reader expects, so an older pending call is sent, not superseded.
        result = operate_state(binding, path, remember, api_factory=api_factory, focus=plan, supersede=False)
    except config.ConfigError as error:
        # Local state trouble (a busy lock, an unreadable ledger or profile): the same call can be retried.
        return {'delivery': 'pending', 'event_id': None, 'diagnostic': str(error), 'issue_id': None}
    state = holder['state']
    if result['delivery'] == 'pending' and not result['diagnostic'] and any(e['delivery'] == 'conflict' and e['event']['plan_id'] == plan for e in state['events']):
        result['diagnostic'] = 'an earlier conflict on this task must be resolved first; inspect manually'
    return dict(result, issue_id=state['mappings'].get(plan, {}).get('issue_id'))


def task_preview(binding, state, make_event, plan, api_factory):
    """Report what a task call would do. Reads only: no ledger write, no board write."""
    event = make_event(state)  # Validation, including the credential filter, comes before any request.
    result = lambda action, issue_id=None, diagnostic=None: {'delivery': 'dry-run', 'action': action, 'event_id': event['event_id'], 'diagnostic': diagnostic, 'issue_id': issue_id}
    mapping = state['mappings'].get(plan)
    if mapping:
        known = next((e for e in state['events'] if e['event']['event_id'] == event['event_id']), None)
        return result('none' if known and known['delivery'] == 'delivered' else 'update', mapping['issue_id'])
    try:
        profile = config.validate_profiles(config.read_json(config.profile_path()))['profiles'][binding['profile']]
        api = api_factory(profile['api_base'], profile['auth_file'], time.monotonic() + 30)
        stamp = plan_marker(event)
        path = '/companies/' + quote(binding['company_id'], safe='') + '/issues?' + urlencode({'projectId': binding['project_id']})
        found = [row['id'] for row in api.pages(path) if stamp in (full_issue(api, row['id']).get('description') or '')]
    except DeliveryError as error:
        return result('unknown', diagnostic=str(error))
    if len(found) > 1:
        return result('conflict', diagnostic='duplicate task markers require reconciliation')
    return result('update', found[0]) if found else result('create')


def status(repo):
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return dict(binding, delivery='disabled', pending=0)
    path = state_path(repo)
    state = load_state(path)
    return dict(binding, delivery='pending' if any(e['delivery'] == 'pending' for e in state['events']) else 'conflict' if any(e['delivery'] == 'conflict' for e in state['events']) else 'delivered', pending=sum(e['delivery'] == 'pending' for e in state['events']))


SEED_RESULTS = ('seeded', 'changed', 'closed', 'already', 'errors')


def seed_snapshots(repo, api_factory=API):
    """Give an existing mapping a snapshot when its task is unchanged since mstack's last write.

    Reads the board only. Under the ledger lock it reads each open mapping without a
    valid snapshot and seeds one only when the task still has the status and updatedAt
    mstack recorded. Any other task is left alone: it fails closed as before. The
    ledger is written once, at the end. Every mapping gets one row in 'tasks'.
    """
    binding = config.status(repo)
    counts = dict.fromkeys(SEED_RESULTS, 0)
    if binding['mode'] != 'enabled':
        return dict(counts, delivery='disabled', tasks=[])
    path = state_path(repo)
    tasks, seeded, api = [], {}, None
    with config.locked(path, timeout=3):
        state = load_state(path)
        for plan in sorted(state['mappings']):
            mapping = state['mappings'][plan]
            issue_id = mapping.get('issue_id') if isinstance(mapping, dict) else None
            row = {'plan': plan, 'issue_id': issue_id, 'result': None, 'diagnostic': None}
            tasks.append(row)
            if not isinstance(issue_id, str) or not issue_id:
                row.update(result='error', diagnostic='invalid local mapping')
            elif mapping.get('status') in ('done', 'cancelled'):
                row['result'] = 'closed'
            elif valid_snapshot(mapping.get('snapshot')):
                row['result'] = 'already'
            else:
                try:
                    if api is None:
                        try:
                            profile = config.validate_profiles(config.read_json(config.profile_path()))['profiles'][binding['profile']]
                        except (config.ConfigError, KeyError, TypeError):
                            raise DeliveryError('reporting profile unavailable') from None
                        api = api_factory(profile['api_base'], profile['auth_file'], time.monotonic() + 120)
                    issue = full_issue(api, issue_id)
                    if not isinstance(issue, dict) or issue.get('id') != issue_id or not isinstance(issue.get('status'), str):
                        raise DeliveryError('unexpected board response')
                    guard(issue, api, binding)
                except DeliveryError as error:
                    row.update(result='error', diagnostic=str(error))
                else:
                    if board_change(mapping, issue)[0] == 'same':
                        seeded[plan] = snapshot_of(issue)
                        row['result'] = 'seeded'
                    else:
                        row.update(result='changed', diagnostic='changed on the board since the last report; not seeded')
        if seeded:
            for plan, snapshot in seeded.items():
                state['mappings'][plan]['snapshot'] = snapshot
            config.atomic_write(path, state)
    for row in tasks:
        counts['errors' if row['result'] == 'error' else row['result']] += 1
    return dict(counts, tasks=tasks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['emit', 'reconcile', 'seed-snapshots', 'status', 'task'])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--json', dest='json_file')
    parser.add_argument('--limit', type=int, default=10)
    parser.add_argument('--project')
    parser.add_argument('--key')
    parser.add_argument('--title')
    parser.add_argument('--status')
    parser.add_argument('--note', default='')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'emit' and not args.json_file:
            raise config.ConfigError('emit requires --json FILE')
        if args.command == 'task':
            try:
                result = task(args.repo, args.project, args.key, args.title, args.status, args.note, args.dry_run)
            except AttributeError:
                raise ValueError('unexpected board response') from None
            result.setdefault('issue_id', None)
        elif args.command == 'seed-snapshots':
            result = seed_snapshots(args.repo)
        else:
            result = status(args.repo) if args.command == 'status' else operate(args.repo, config.read_json(args.json_file) if args.command == 'emit' and args.json_file else None, args.limit)
    except (config.ConfigError, OSError, KeyError, TypeError, ValueError):
        result = {'delivery': 'pending', 'event_id': None, 'diagnostic': 'invalid local reporting state; inspect configuration'}
        if args.command == 'task':
            result['issue_id'] = None
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
