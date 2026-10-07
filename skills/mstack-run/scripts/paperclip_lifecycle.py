#!/usr/bin/env python3
"""Translate authoritative local plan boundaries into optional board events."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

import paperclip
import paperclip_config as config

SCRIPTS = Path(__file__).resolve().parent
OUTCOMES = {'authored', 'claimed', 'blocked', 'failed', 'review', 'continuation', 'done'}


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
    fingerprint = hashlib.sha256((json.dumps(payload, sort_keys=True)+'\n'+text).encode()).hexdigest()
    ledger = config.binding_path(repo).parent/'lifecycle.json'
    with config.locked(ledger):
        state = config.read_json(ledger) if ledger.exists() else {'version': 1, 'plans': {}}
        plan = state['plans'].setdefault(fields['id'], {'sequence': 0, 'events': {}})
        if fingerprint not in plan['events']:
            event = dict(payload, event_id='lifecycle-'+fingerprint, sequence=plan['sequence']+1)
            paperclip.validate_event(event, binding)
            plan['sequence'] += 1
            plan['events'][fingerprint] = event
            config.atomic_write(ledger, state)
        event = plan['events'][fingerprint]
        return paperclip.operate(repo, event)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['emit', 'reconcile', 'status'])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--plan')
    parser.add_argument('--outcome', choices=sorted(OUTCOMES))
    parser.add_argument('--json', dest='json_file')
    parser.add_argument('--limit', type=int, default=10)
    args = parser.parse_args()
    try:
        if args.command == 'emit':
            if not all((args.plan, args.outcome, args.json_file)):
                raise config.ConfigError('emit requires plan, outcome and metadata file')
            result = emit(args.repo, args.plan, args.outcome, config.read_json(args.json_file))
        elif args.command == 'status': result = paperclip.status(args.repo)
        else: result = paperclip.operate(args.repo, limit=args.limit)
    except (config.ConfigError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        result = {'delivery': 'conflict', 'event_id': None, 'diagnostic': 'local lifecycle evidence invalid; execution remains authoritative'}
    print(json.dumps(result))
    return 0


if __name__ == '__main__': raise SystemExit(main())
