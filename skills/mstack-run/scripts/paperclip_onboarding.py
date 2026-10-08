#!/usr/bin/env python3
"""Structured onboarding decisions; never prompts or launches login itself."""
import argparse
import json
from pathlib import Path
import uuid
from urllib.parse import quote
import paperclip
import paperclip_config as config


def eligibility(repo, interactive=False, offered=False):
    binding = config.status(repo)
    path = config.binding_path(repo).parent / 'onboarding.json'
    seen = path.exists() and config.read_json(path).get('offered') is True
    eligible = binding['mode'] == 'unconfigured' and not seen
    if offered and interactive and eligible:
        with config.locked(path):
            config.atomic_write(path, {'version': 1, 'offered': True})
    return {'mode': binding['mode'], 'eligible': eligible, 'offer': eligible and interactive, 'diagnostic': None}


def decline(repo):
    binding = config.status(repo)
    if binding['mode'] == 'enabled':
        raise config.ConfigError('use disable to turn off an enabled connection')
    value = {key: binding[key] for key in ('mode', 'profile', 'company_id', 'project_id', 'repository_id')}
    value.update(version=1, mode='declined', repository_id=binding['repository_id'] or str(uuid.uuid4()))
    return config.configure(repo, value)


def observation(error):
    message = str(error)
    state = 'authentication-expired' if 'authentication expired' in message else 'authentication-missing' if 'authentication missing' in message else 'conflict' if error.delivery == 'conflict' else 'offline'
    return {'state': state, 'diagnostic': message, 'login_required': state.startswith('authentication-')}


def selected_profile(name):
    profiles = config.validate_profiles(config.read_json(config.profile_path()))['profiles']
    if name not in profiles:
        raise config.ConfigError('selected user profile is missing')
    return profiles[name]


def choices(profile, company_id=None):
    try:
        value = selected_profile(profile)
        api = paperclip.API(value['api_base'], value['auth_file'])
        companies = api.pages('/companies')
        if company_id is None:
            return {'state': 'connected', 'companies': companies, 'login_required': False}
        if not any(row.get('id') == company_id for row in companies):
            raise config.ConfigError('company is not available to authenticated board user')
        projects = api.pages('/companies/' + quote(company_id, safe='') + '/projects')
        return {'state': 'connected', 'projects': [row for row in projects if row.get('companyId') == company_id], 'login_required': False}
    except paperclip.DeliveryError as error:
        return observation(error)


def save_profile(name, api_base, auth_file):
    # Explicit caller choice only. No credential copy, writes or login inference.
    path = config.profile_path()
    with config.locked(path):
        value = config.validate_profiles(config.read_json(path)) if path.exists() else {'version': 1, 'profiles': {}}
        selected = {'api_base': paperclip.normalize_base(api_base), 'auth_file': str(Path(auth_file).expanduser())}
        if name in value['profiles'] and value['profiles'][name] != selected:
            raise config.ConfigError('existing profile cannot be retargeted; choose a new profile name')
        value['profiles'][name] = selected
        config.validate_profiles(value)
        config.atomic_write(path, value)
    return {'state': 'profile-saved', 'profile': name}


def connect(repo, profile, company_id, project_id):
    result = choices(profile, company_id)
    if result['state'] != 'connected':
        return result
    if not any(row.get('id') == project_id and row.get('companyId') == company_id for row in result['projects']):
        raise config.ConfigError('project does not belong to selected company')
    binding = config.status(repo)
    if binding['mode'] == 'enabled' and any(binding[k] != v for k, v in [('profile', profile), ('company_id', company_id), ('project_id', project_id)]):
        raise config.ConfigError('enabled binding cannot be silently replaced; disable and explicitly reconnect')
    value = {'version': 1, 'mode': 'enabled', 'repository_id': binding['repository_id'] or str(uuid.uuid4()), 'profile': profile, 'company_id': company_id, 'project_id': project_id}
    return dict(config.configure(repo, value), state='connected', login_required=False)


def reconnect(repo):
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        raise config.ConfigError('connect explicitly before reconnecting')
    result = choices(binding['profile'], binding['company_id'])
    if result['state'] != 'connected':
        return result
    if not any(row.get('id') == binding['project_id'] and row.get('companyId') == binding['company_id'] for row in result['projects']):
        raise config.ConfigError('bound project membership cannot be confirmed')
    return dict(binding, state='connected', login_required=False)


def status(repo):
    binding = config.status(repo)
    if binding['mode'] != 'enabled':
        return dict(binding, login_required=False)
    result = reconnect(repo)
    return dict(binding, **{k: v for k, v in result.items() if k in ('state', 'diagnostic', 'login_required')})


def create_project(profile, company_id, name, chosen=False):
    if not chosen or not isinstance(name, str) or not name.strip() or len(name) > 200:
        raise config.ConfigError('project creation requires explicit user choice and a name')
    result = choices(profile, company_id)
    if result['state'] != 'connected':
        return result
    value = selected_profile(profile)
    api = paperclip.API(value['api_base'], value['auth_file'])
    try:
        project = api.request('POST', '/companies/' + quote(company_id, safe='') + '/projects', {'name': name})
        if not isinstance(project, dict) or project.get('companyId') != company_id:
            raise config.ConfigError('created project membership not confirmed; inspect before retry')
        return {'state': 'created', 'project': project}
    except paperclip.DeliveryError as error:
        return dict(observation(error), diagnostic='Project creation unconfirmed; inspect project list before any retry', uncertain=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['eligibility', 'decline', 'profile', 'choices', 'connect', 'reconnect', 'status', 'disable', 'create-project'])
    parser.add_argument('--repo', default='.')
    parser.add_argument('--profile')
    parser.add_argument('--api-base')
    parser.add_argument('--auth-file', default='~/.paperclip/auth.json')
    parser.add_argument('--company')
    parser.add_argument('--project')
    parser.add_argument('--name')
    parser.add_argument('--interactive', action='store_true')
    parser.add_argument('--offered', action='store_true')
    parser.add_argument('--user-chose-create', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'eligibility': result = eligibility(args.repo, args.interactive, args.offered)
        elif args.command == 'decline': result = decline(args.repo)
        elif args.command == 'profile': result = save_profile(args.profile, args.api_base, args.auth_file)
        elif args.command == 'choices': result = choices(args.profile, args.company)
        elif args.command == 'connect': result = connect(args.repo, args.profile, args.company, args.project)
        elif args.command == 'reconnect': result = reconnect(args.repo)
        elif args.command == 'status': result = status(args.repo)
        elif args.command == 'disable': result = config.disable(args.repo)
        else: result = create_project(args.profile, args.company, args.name, args.user_chose_create)
    except (config.ConfigError, OSError, ValueError, TypeError, KeyError):
        result = {'state': 'configuration-error', 'diagnostic': 'Inspect selected profile, company and project; previous binding retained', 'login_required': False}
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
