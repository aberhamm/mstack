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
            mapping = {'issue_id': issue['id'], 'status': issue['status'], 'updated_at': issue.get('updatedAt'), 'sequence': event['sequence']}
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
            mapping = {'issue_id': issue['id'], 'status': issue['status'], 'updated_at': issue.get('updatedAt'), 'sequence': 0}
            state['mappings'][plan] = mapping
            entry['uncertain'] = False
            save()
    issue = full_issue(api, mapping['issue_id'])
    guard(issue, api, binding)
    comments = api.pages('/issues/' + quote(issue['id'], safe='') + '/comments')
    if any(stamp in (comment.get('body') or '') for comment in comments):
        if issue.get('assigneeUserId') != api.user_id or (event['outcome'] != 'note' and issue['status'] != event['outcome']):
            raise DeliveryError('marker exists but issue outcome changed; inspect manually', 'conflict')
        mapping.update(status=issue['status'], updated_at=issue.get('updatedAt'), sequence=event['sequence'])
        entry['delivery'] = 'delivered'
        save()
        return
    if entry['uncertain']:
        raise DeliveryError('uncertain update unresolved; no blind resend')
    if issue['status'] != mapping['status'] or issue.get('updatedAt') != mapping.get('updated_at'):
        raise DeliveryError('issue manually changed; reconciliation required', 'conflict')
    if issue['status'] in ('done', 'cancelled') and event['outcome'] not in ('note', issue['status']):
        raise DeliveryError('terminal issue cannot be implicitly reopened', 'conflict')
    fresh = full_issue(api, issue['id'])
    guard(fresh, api, binding)
    if fresh != issue:
        raise DeliveryError('issue changed while preparing update', 'conflict')
    payload = {'comment': stamp + '\n' + event['notes'], 'commentClientRequestId': str(uuid.uuid5(uuid.NAMESPACE_URL, 'mstack-paperclip:'+event['event_id'])), 'assigneeUserId': api.user_id}
    if event['outcome'] != 'note':
        payload['status'] = event['outcome']
    entry['uncertain'] = True
    save()
    api.request('PATCH', '/issues/' + quote(issue['id'], safe=''), payload)
    confirmed = full_issue(api, issue['id'])
    comments = api.pages('/issues/' + quote(issue['id'], safe='') + '/comments')
    if not any(stamp in (comment.get('body') or '') for comment in comments):
        raise DeliveryError('update marker readback missing')
    guard(confirmed, api, binding)
    if confirmed.get('assigneeUserId') != api.user_id or (event['outcome'] != 'note' and confirmed['status'] != event['outcome']):
        raise DeliveryError('mutation outcome not confirmed; inspect manually', 'conflict')
    mapping.update(status=confirmed['status'], updated_at=confirmed.get('updatedAt'), sequence=event['sequence'])
    entry['delivery'] = 'delivered'
    entry['uncertain'] = False
    save()


def operate(repo, event=None, limit=10, api_factory=API):
    deadline = time.monotonic() + 30
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return {'delivery': 'disabled', 'event_id': None, 'diagnostic': None}
    path = state_path(repo)
    with config.locked(path, timeout=min(3, max(0, deadline-time.monotonic()))):
        state = load_state(path)
        save = lambda: config.atomic_write(path, state)
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
        for entry in sorted(pending, key=lambda e: (e['event']['plan_id'], e['event']['sequence']))[:min(max(limit, 0), 10)]:
            if entry['event']['plan_id'] in blocked_plans:
                continue
            peers = [e for e in state['events'] if e['event']['plan_id'] == entry['event']['plan_id']]
            latest = max(e['event']['sequence'] for e in peers)
            if entry['event']['sequence'] < latest and not entry['uncertain']:
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


def status(repo):
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return dict(binding, delivery='disabled', pending=0)
    path = state_path(repo)
    state = load_state(path)
    return dict(binding, delivery='pending' if any(e['delivery'] == 'pending' for e in state['events']) else 'conflict' if any(e['delivery'] == 'conflict' for e in state['events']) else 'delivered', pending=sum(e['delivery'] == 'pending' for e in state['events']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['emit', 'reconcile', 'status'])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--json', dest='json_file')
    parser.add_argument('--limit', type=int, default=10)
    args = parser.parse_args()
    try:
        if args.command == 'emit' and not args.json_file:
            raise config.ConfigError('emit requires --json FILE')
        result = status(args.repo) if args.command == 'status' else operate(args.repo, config.read_json(args.json_file) if args.command == 'emit' and args.json_file else None, args.limit)
    except (config.ConfigError, OSError, KeyError, TypeError, ValueError):
        result = {'delivery': 'pending', 'event_id': None, 'diagnostic': 'invalid local reporting state; inspect configuration'}
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
