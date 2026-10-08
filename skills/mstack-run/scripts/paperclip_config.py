#!/usr/bin/env python3
"""Private, machine-local Paperclip settings. Never performs network requests."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.parse
import uuid


class ConfigError(Exception):
    """A safe diagnostic, containing no configuration values."""


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise ConfigError('cannot read valid settings JSON') from None


def common_directory(repo):
    try:
        output = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--path-format=absolute', '--git-common-dir'], stderr=subprocess.DEVNULL, text=True)
        return Path(output.strip()).resolve()
    except (OSError, subprocess.CalledProcessError):
        raise ConfigError('repository is not an accessible Git checkout') from None


def binding_path(repo):
    return common_directory(repo) / 'mstack-paperclip' / 'binding.json'


def profile_path():
    return Path.home() / '.config' / 'mstack' / 'paperclip.json'


def closed_schema(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys) or type(value.get('version')) is not int or value['version'] != 1:
        raise ConfigError('invalid settings schema')


def validate_binding(value):
    closed_schema(value, ['version', 'mode', 'profile', 'company_id', 'project_id', 'repository_id'])
    if not isinstance(value['mode'], str) or value['mode'] not in ('unconfigured', 'declined', 'disabled', 'enabled'):
        raise ConfigError('invalid integration mode')
    for key in ('profile', 'company_id', 'project_id', 'repository_id'):
        if value[key] is not None and (not isinstance(value[key], str) or not value[key].strip() or any(ord(c) < 32 for c in value[key])):
            raise ConfigError('invalid binding identifier')
    if value['mode'] == 'enabled' and any(value[k] is None for k in ('profile', 'company_id', 'project_id', 'repository_id')):
        raise ConfigError('enabled binding requires explicit project and profile identifiers')
    return value


def validate_profiles(value):
    closed_schema(value, ['version', 'profiles'])
    if not isinstance(value['profiles'], dict):
        raise ConfigError('invalid profiles map')
    for name, profile in value['profiles'].items():
        if not isinstance(name, str) or not name.strip() or not isinstance(profile, dict) or set(profile) != {'api_base', 'auth_file'}:
            raise ConfigError('invalid profile schema')
        if not all(isinstance(profile[k], str) and profile[k] for k in profile):
            raise ConfigError('invalid profile fields')
        try:
            url = urllib.parse.urlsplit(profile['api_base'])
            if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
                raise ValueError()
            url.port
        except ValueError:
            raise ConfigError('invalid profile API address') from None
        if not Path(profile['auth_file']).expanduser().is_absolute():
            raise ConfigError('credential-store reference must be an absolute path')
    return value


@contextlib.contextmanager
def locked(path, timeout=3):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = path.with_suffix('.lock')
    deadline = time.monotonic() + timeout
    while True:
        try:
            lock.mkdir(mode=0o700)
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise ConfigError('settings are locked; retry after the active writer finishes') from None
            time.sleep(0.05)
    try:
        yield
    finally:
        lock.rmdir()


def atomic_write(path, value):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.settings-')
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def status(repo):
    path = binding_path(repo)
    value = validate_binding(read_json(path)) if path.exists() else dict(version=1, mode='unconfigured', profile=None, company_id=None, project_id=None, repository_id=None)
    result = {key: value[key] for key in ('mode', 'repository_id', 'profile', 'company_id', 'project_id')}
    result.update(state=value['mode'], diagnostic=None)
    if value['mode'] == 'enabled':
        profiles = validate_profiles(read_json(profile_path()))['profiles']
        if value['profile'] not in profiles:
            raise ConfigError('configured user profile is missing; reconnect Paperclip')
    return result


def configure(repo, value):
    value = validate_binding(value)
    if value['mode'] == 'enabled':
        profiles = validate_profiles(read_json(profile_path()))['profiles']
        if value['profile'] not in profiles:
            raise ConfigError('configured user profile is missing; reconnect Paperclip')
    path = binding_path(repo)
    with locked(path):
        if path.exists():
            old = validate_binding(read_json(path))
            if old['repository_id'] and old['repository_id'] != value['repository_id']:
                raise ConfigError('repository identity cannot be silently replaced')
        atomic_write(path, value)
    return status(repo)


def disable(repo):
    path = binding_path(repo)
    with locked(path):
        value = validate_binding(read_json(path)) if path.exists() else dict(version=1, mode='unconfigured', profile=None, company_id=None, project_id=None, repository_id=str(uuid.uuid4()))
        value['mode'] = 'disabled'
        atomic_write(path, value)
    return status(repo)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['status', 'configure', 'disable'])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--json', dest='json_file')
    args = parser.parse_args()
    try:
        if args.command == 'configure':
            if not args.json_file:
                raise ConfigError('configure requires --json FILE')
            result = configure(args.repo, read_json(args.json_file))
        elif args.command == 'disable':
            result = disable(args.repo)
        else:
            result = status(args.repo)
        print(json.dumps(result))
        return 0
    except ConfigError as error:
        print(json.dumps({'diagnostic': str(error)}))
        return 2
    except OSError:
        print(json.dumps({'diagnostic': 'settings operation failed; check local file permissions'}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
