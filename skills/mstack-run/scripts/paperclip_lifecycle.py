#!/usr/bin/env python3
"""Translate authoritative local plan boundaries into optional board events."""
import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

import paperclip
import paperclip_config as config

SCRIPTS = Path(__file__).resolve().parent
OUTCOMES = {'authored', 'claimed', 'blocked', 'failed', 'review', 'continuation', 'done'}
# Catch-up closes a task from the plan file alone, so every such close says so.
CATCH_UP = {'done': 'done', 'skipped': 'cancelled', 'dropped': 'cancelled'}
CATCH_UP_NOTE = 'caught up from the plan file; not verified at completion'
CLOSED = {'done', 'cancelled'}


def command(repo, args):
    result = subprocess.run(args, cwd=repo, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise config.ConfigError('local lifecycle gate failed; dashboard update refused')
    return result.stdout.strip()


def plan_info(path):
    text = path.read_text()
    match = re.match(r'\A---\s*\n(.*?)\n---(?:\n|$)', text, re.S)
    if not match:
        raise config.ConfigError('plan frontmatter is missing')
    fields = {}
    for line in match[1].splitlines():
        item = re.match(r'^([a-z][a-z-]*):\s*(.*?)\s*$', line)
        if item:
            if item[1] in fields:
                raise config.ConfigError('duplicate plan frontmatter field')
            fields[item[1]] = item[2]
    if not re.fullmatch(r'\d+', fields.get('id', '')):
        raise config.ConfigError('plan requires a numeric stable identity')
    fields['local_id'] = fields['id']
    fields['id'] = str(int(fields['id']))
    return fields, text


def identity(repo, path):
    repo = Path(command(repo, ['git', 'rev-parse', '--show-toplevel'])).resolve()
    path = Path(path)
    path = (repo/path).resolve() if not path.is_absolute() else path.resolve()
    if not path.is_relative_to(repo):
        raise config.ConfigError('plan is outside selected checkout')
    fields, text = plan_info(path)
    root = path.parent.parent if path.parent.name == 'archive' else path.parent
    found = []
    for candidate in root.rglob('*.md'):
        try:
            value, _ = plan_info(candidate)
        except config.ConfigError:
            continue
        if value['id'] == fields['id']:
            found.append(candidate.resolve())
    if found != [path]:
        raise config.ConfigError('duplicate or ambiguous local plan identity')
    return repo, path, fields, text, root


def validate_metadata(repo, metadata):
    allowed = {'session', 'worktree', 'review_evidence', 'test_evidence', 'health_result', 'completion_tag_sha', 'note'}
    if not isinstance(metadata, dict) or set(metadata) - allowed or any(not isinstance(value, str) for value in metadata.values()):
        raise config.ConfigError('invalid lifecycle metadata schema')
    if not metadata.get('session') or not metadata.get('worktree'):
        raise config.ConfigError('actual session and worktree metadata required')
    worktree = Path(metadata['worktree'])
    if not worktree.is_absolute() or worktree.resolve() != repo:
        raise config.ConfigError('metadata must identify the actual selected worktree')


def gate(repo, operation, path):
    return command(repo, ['bash', str(SCRIPTS/'review-gate.sh'), operation, str(path.relative_to(repo))])


def check_done(repo, path, fields, metadata):
    if fields.get('status') != 'done' or path.parent.name != 'archive':
        raise config.ConfigError('done requires the archived completed plan')
    for field in ('review_evidence', 'test_evidence', 'health_result', 'completion_tag_sha'):
        if not metadata.get(field):
            raise config.ConfigError('done requires actual review, test, health and completion-tag evidence')
    tag = 'mstack/plan-' + fields['local_id'] + '-done'
    # Require annotated tag and the current archive commit, not an arbitrary SHA.
    if command(repo, ['git', 'cat-file', '-t', 'refs/tags/'+tag]) != 'tag':
        raise config.ConfigError('completion tag must be annotated')
    sha = command(repo, ['git', 'rev-parse', tag+'^{commit}'])
    if sha != metadata['completion_tag_sha'] or sha != command(repo, ['git', 'rev-parse', 'HEAD']):
        raise config.ConfigError('completion tag does not match actual completion commit')
    if command(repo, ['git', 'show', sha+':'+str(path.relative_to(repo))]) != path.read_text().strip():
        raise config.ConfigError('archived plan differs from completion-tag content')
    gate(repo, 'assert-completable', path)
    gate(repo, 'assert-no-downgrade', path)
    gate(repo, 'assert-work-committed', path)
    health = Path(metadata['health_result'])
    health = health if health.is_absolute() else repo/health
    if not health.resolve().is_relative_to(repo/'.mstack'):
        raise config.ConfigError('health evidence must belong to this checkout')
    command(repo, ['bash', str(SCRIPTS/'result-gate.sh'), 'assert-health-result', str(health)])
    return sha


def emit(repo, path, outcome, metadata):
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return {'delivery': 'disabled', 'event_id': None, 'diagnostic': None}
    if outcome not in OUTCOMES:
        raise config.ConfigError('invalid lifecycle outcome')
    repo, path, fields, text, root = identity(repo, path)
    validate_metadata(repo, metadata)
    authored = subprocess.run(['bash', str(SCRIPTS/'review-gate.sh'), 'plan-authored', str(path.relative_to(repo))], cwd=repo, capture_output=True, timeout=10)
    if authored.returncode != 0:
        raise config.ConfigError('template or unresolved plan is not publishable')
    local = fields.get('status')
    states = {'claimed': {'in-progress'}, 'blocked': {'blocked'}, 'failed': {'failed'}, 'review': {'in-progress', 'blocked'}, 'continuation': {'pending', 'in-progress', 'blocked', 'failed', 'done'}, 'authored': {'pending', 'blocked', 'deferred', 'draft', 'proposed'}}
    if outcome != 'done' and local not in states[outcome]:
        raise config.ConfigError('reported outcome does not match local plan state')
    commit = command(repo, ['git', 'rev-parse', 'HEAD'])
    if outcome not in {'authored', 'continuation', 'done'}:
        committed = command(repo, ['git', 'show', 'HEAD:'+str(path.relative_to(repo))])
        if committed != text.strip():
            raise config.ConfigError('local transition must be committed before reporting')
    if outcome == 'claimed':
        if fields.get('needs-review', 'none') != 'none':
            raise config.ConfigError('claim requires local readiness review clearance')
        dependencies = fields.get('blocked-by', '[]')
        if not re.fullmatch(r'\[\s*(?:\d+\s*(?:,\s*\d+\s*)*)?\]', dependencies):
            raise config.ConfigError('invalid local dependency list')
        for dependency in re.findall(r'\d+', dependencies):
            matches = []
            for candidate in root.rglob('*.md'):
                try:
                    info, _ = plan_info(candidate)
                except config.ConfigError:
                    continue
                if info['id'] == str(int(dependency)):
                    matches.append(info)
            if len(matches) != 1 or matches[0].get('status') != 'done':
                raise config.ConfigError('local dependency is not uniquely completed')
    if outcome == 'done':
        commit = check_done(repo, path, fields, metadata)
    remote = {'authored': 'blocked' if local in {'blocked', 'deferred', 'draft', 'proposed'} else 'backlog', 'claimed': 'in_progress', 'blocked': 'blocked', 'failed': 'blocked', 'review': 'in_review', 'continuation': 'note', 'done': 'done'}[outcome]
    notes = '\n'.join(['Local outcome: '+outcome, 'Local source status: '+str(local), 'Local restrictions: needs-review='+fields.get('needs-review','none')+'; blocked-by='+fields.get('blocked-by','[]'), 'Local commit: '+commit] + [key+': '+value for key,value in metadata.items() if key != 'worktree'])
    event_metadata = {'session': metadata['session'], 'worktree': str(repo), 'title': fields.get('title', 'Plan '+fields['id']), 'commit': commit}
    payload = {'schema_version': 1, 'repository_id': binding['repository_id'], 'plan_id': fields['id'], 'outcome': remote, 'metadata': event_metadata, 'notes': notes}
    with sequenced(repo, binding, payload, text) as event:
        return paperclip.operate(repo, event)


@contextlib.contextmanager
def sequenced(repo, binding, payload, text, floor=0):
    """Give a boundary its durable sequence; the ledger stays locked while it is delivered."""
    fingerprint = hashlib.sha256((json.dumps(payload, sort_keys=True)+'\n'+text).encode()).hexdigest()
    ledger = config.binding_path(repo).parent/'lifecycle.json'
    with config.locked(ledger):
        state = config.read_json(ledger) if ledger.exists() else {'version': 1, 'plans': {}}
        plan = state['plans'].setdefault(payload['plan_id'], {'sequence': 0, 'events': {}})
        if fingerprint not in plan['events']:
            event = dict(payload, event_id='lifecycle-'+fingerprint, sequence=max(plan['sequence'], floor)+1)
            paperclip.validate_event(event, binding)
            plan['sequence'] = event['sequence']
            plan['events'][fingerprint] = event
            config.atomic_write(ledger, state)
        yield plan['events'][fingerprint]


def catch_up(repo, apply=False, api_factory=paperclip.API, limit=10):
    """Close tasks whose plan file already says done, skipped or dropped.

    Only plans that already have a task are considered. Nothing is created
    and nothing is reopened; without apply nothing is sent or stored. An
    apply run writes at most limit tasks and stops writing at the first
    change the board does not confirm; what is left is listed as deferred.
    """
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return {'delivery': 'disabled', 'event_id': None, 'diagnostic': None}
    repo = Path(command(repo, ['git', 'rev-parse', '--show-toplevel'])).resolve()
    roots = [directory for directory in (repo/'docs/plans', repo/'plans') if directory.is_dir()]
    if not roots:
        raise config.ConfigError('checkout has no plans directory')
    plans = {}
    for candidate in sorted(path for root in roots for path in root.rglob('*.md')):
        try:
            fields, text = plan_info(candidate)
        except (config.ConfigError, OSError, ValueError):
            continue
        plans.setdefault(fields['id'], []).append((candidate, fields, text))
    events_path = paperclip.state_path(repo)
    state = paperclip.load_state(events_path)
    commit = command(repo, ['git', 'rev-parse', 'HEAD'])
    profile = config.validate_profiles(config.read_json(config.profile_path()))['profiles'][binding['profile']]
    report = {'mode': 'applied' if apply else 'dry-run', 'note': CATCH_UP_NOTE, 'counts': {}, 'changes': [], 'attention': [], 'skipped': [], 'diagnostic': None}
    writing, written = apply, 0
    for plan_id in sorted(set(plans) & set(state['mappings']), key=int):
        mapping, found = state['mappings'][plan_id], plans[plan_id]
        path, fields, text = found[0]
        row = {'plan': fields['local_id'], 'title': fields.get('title', 'Plan '+plan_id), 'issue_id': mapping.get('issue_id')}
        try:
            reason, change = catch_up_plan(repo, binding, profile, api_factory, state, plan_id, found, commit, writing and written < limit, events_path)
        except (config.ConfigError, paperclip.DeliveryError) as error:
            reason, change = str(error), None
        except (KeyError, TypeError, ValueError, AttributeError, OSError, subprocess.TimeoutExpired):
            reason, change = 'unexpected local or board data; inspect manually', None
        if change and 'status' in change:
            report['attention'].append(dict(row, **change))
        elif change:
            if apply and change['delivery'] == 'dry-run':
                change['delivery'] = 'deferred'
            elif apply:
                written += 1
            report['changes'].append(dict(row, **change))
            if writing and change['delivery'] not in ('delivered', 'deferred'):
                # One unconfirmed write is a reason to look, not to queue the rest behind it.
                report['diagnostic'] = 'stopped at the first change that was not confirmed; inspect it, then run again'
                writing = False
        elif reason:
            report['skipped'].append(dict(row, reason=reason))
    count = lambda *deliveries: sum(change['delivery'] in deliveries for change in report['changes'])
    report['counts'] = {'would_apply': count('dry-run'), 'applied': count('delivered'), 'failed': count('pending'), 'conflicts': count('conflict'),
                        'deferred': count('deferred'), 'skipped': len(report['skipped']), 'attention': len(report['attention'])}
    return report


def catch_up_plan(repo, binding, profile, api_factory, state, plan_id, found, commit, apply, events_path):
    """Decide one plan: (skip reason, None), (None, change or attention row) or (None, None)."""
    mapping = state['mappings'][plan_id]
    if len(found) > 1:
        return 'plan number is used more than once', None
    path, fields, text = found[0]
    local = fields.get('status')
    if mapping.get('status') in CLOSED:
        return None, None
    if local in ('in-progress', 'failed'):
        return None, {'status': local, 'task': mapping.get('status')}
    if local not in CATCH_UP:
        return None, None
    peers = [entry for entry in state['events'] if entry['event']['plan_id'] == plan_id]
    if any(entry['delivery'] == 'conflict' or entry['uncertain'] for entry in peers):
        return 'an earlier report for this plan is in conflict or unconfirmed; inspect it by hand', None
    if any(entry['delivery'] != 'delivered' for entry in peers):
        return 'an earlier report for this plan is still queued; reconcile it first', None
    committed = subprocess.run(['git', 'show', 'HEAD:'+str(path.relative_to(repo))], cwd=repo, capture_output=True, text=True, timeout=10)
    if committed.returncode or committed.stdout.strip() != text.strip():
        return 'plan file differs from the last commit', None
    api = api_factory(profile['api_base'], profile['auth_file'], time.monotonic()+30)
    issue = paperclip.full_issue(api, mapping['issue_id'])
    paperclip.guard(issue, api, binding)
    if issue['status'] in CLOSED:
        return 'task is already closed on the board', None
    if issue['status'] != mapping.get('status') or issue.get('updatedAt') != mapping.get('updated_at'):
        return 'task changed on the board since the last report; inspect manually', None
    change = {'from': issue['status'], 'to': CATCH_UP[local], 'delivery': 'dry-run', 'diagnostic': None}
    if not apply:
        return None, change
    notes = '\n'.join(['Local outcome: catch-up', 'Local source status: '+local, 'Local commit: '+commit, CATCH_UP_NOTE])
    payload = {'schema_version': 1, 'repository_id': binding['repository_id'], 'plan_id': plan_id, 'outcome': CATCH_UP[local],
               'metadata': {'worktree': str(repo), 'title': fields.get('title', 'Plan '+plan_id), 'commit': commit}, 'notes': notes}
    floor = max((entry['event']['sequence'] for entry in peers), default=0)
    with sequenced(repo, binding, payload, text, floor) as event, config.locked(events_path):
        # Deliver this one event only: queued reports for other plans are not catch-up's to send.
        live = paperclip.load_state(events_path)
        if live != state:
            return 'local reports changed during the run; run again', None
        entry = {'event': event, 'delivery': 'pending', 'uncertain': False, 'diagnostic': None}
        live['events'].append(entry)
        save = lambda: config.atomic_write(events_path, live)
        save()
        try:
            paperclip.deliver(entry, live, api, binding, save)
        except paperclip.DeliveryError as error:
            entry.update(delivery=error.delivery, diagnostic=str(error))
        except (KeyError, TypeError, ValueError, AttributeError):
            # The write may already have happened: report it as an unconfirmed change, never as a skip.
            entry.update(delivery='pending', diagnostic='unexpected board response around the write; inspect manually')
        save()
        state.update(live)
    change.update(delivery=entry['delivery'], diagnostic=entry['diagnostic'])
    return None, change


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['emit', 'reconcile', 'status', 'adopt', 'catch-up'])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--plan')
    parser.add_argument('--outcome', choices=sorted(OUTCOMES))
    parser.add_argument('--json', dest='json_file')
    parser.add_argument('--limit', type=int, default=10)
    parser.add_argument('--sources')
    parser.add_argument('--profile')
    parser.add_argument('--company')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--mappings-only', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'adopt':
            import paperclip_adoption
            result = paperclip_adoption.adopt(args.repo,args.sources,args.profile,args.company,args.apply,args.mappings_only)
        elif args.command == 'emit':
            if not all((args.plan, args.outcome, args.json_file)):
                raise config.ConfigError('emit requires plan, outcome and metadata file')
            result = emit(args.repo, args.plan, args.outcome, config.read_json(args.json_file))
        elif args.command == 'status': result = paperclip.status(args.repo)
        elif args.command == 'catch-up': result = catch_up(args.repo, args.apply, limit=max(args.limit, 0))
        else: result = paperclip.operate(args.repo, limit=args.limit)
    except (config.ConfigError, paperclip.DeliveryError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        result = {'delivery': 'conflict', 'event_id': None, 'diagnostic': 'local lifecycle evidence invalid; execution remains authoritative'}
    print(json.dumps(result))
    return 0


if __name__ == '__main__': raise SystemExit(main())
