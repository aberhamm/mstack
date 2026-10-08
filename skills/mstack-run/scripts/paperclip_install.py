#!/usr/bin/env python3
"""Transactional, explicit skill replacement with verified rollback snapshots."""
import argparse
import hashlib
import json
from pathlib import Path
import os
import shutil
import tempfile


def fingerprint(path):
    if path.is_symlink(): return 'link:'+os.readlink(path)
    if not path.exists(): return 'absent'
    if not path.is_dir(): raise ValueError('target is not a skill directory')
    digest=hashlib.sha256(str(path.stat().st_mode).encode())
    for entry in sorted(path.rglob('*')):
        digest.update(str(entry.relative_to(path)).encode())
        if entry.is_symlink(): digest.update(('link:'+os.readlink(entry)).encode())
        elif entry.is_file():
            digest.update(str(entry.stat().st_mode).encode());digest.update(entry.read_bytes())
    return 'directory:'+digest.hexdigest()


def remove_managed(path):
    if path.is_symlink(): path.unlink()
    elif path.is_dir(): shutil.rmtree(path)
    elif path.exists(): raise ValueError('refusing unexpected target type')


def write_manifest(path,value):
    with tempfile.NamedTemporaryFile(mode='w',dir=path.parent,delete=False) as file:
        json.dump(value,file,indent=2);file.write('\n');file.flush();os.fsync(file.fileno());temporary=file.name
    os.replace(temporary,path)


def restore(manifest):
    path=Path(manifest);value=json.loads(path.read_text())
    # Validate ALL targets before restoring any; changed user content is retained.
    for row in value['entries']:
        accepted=(row['installed'],row['original'],'absent') if value['state']=='preparing' else (row['installed'],row['original'])
        if row['original'].startswith('directory:') and fingerprint(Path(row['backup'])) != row['original']:
            raise ValueError('rollback backup changed; restore refused')
        if fingerprint(Path(row['target'])) not in accepted:
            raise ValueError('installed target changed; restore refused')
    for row in reversed(value['entries']):
        target=Path(row['target'])
        if fingerprint(target)==row['original']: continue
        remove_managed(target)
        if row['original'].startswith('link:'): target.symlink_to(row['original'][5:])
        elif row['original'].startswith('directory:'): shutil.copytree(row['backup'],target,symlinks=True)
    value['state']='restored';write_manifest(path,value)
    return {'state':'restored','manifest':str(path)}


def install(source,target,backup,replace=False,mode='symlink'):
    if not Path(backup).is_absolute(): raise ValueError('backup directory must be absolute')
    source,target,backup=Path(source).resolve(),Path(target).resolve(),Path(backup).resolve()
    if backup.is_relative_to(source) or backup.is_relative_to(target): raise ValueError('backup must be outside source and skill targets')
    if not source.is_dir() or not target.is_dir() or not backup.is_absolute(): raise ValueError('explicit source, target and absolute backup directory required')
    manifest=backup/'manifest.json'
    if manifest.exists():
        value=json.loads(manifest.read_text())
        if value.get('source')!=str(source) or value.get('target')!=str(target) or value.get('state')!='installed': raise ValueError('backup directory belongs to another or restored installation')
        if all(fingerprint(Path(row['target']))==row['installed'] for row in value['entries']): return {'state':'already-installed','manifest':str(manifest)}
        raise ValueError('installed targets changed; automatic replacement refused')
    backup.mkdir(parents=True,exist_ok=False,mode=0o700)
    value={'version':1,'source':str(source),'target':str(target),'state':'preparing','entries':[]}
    try:
        for skill in sorted((source/'skills').glob('mstack-*')):
            if not skill.is_dir(): continue
            destination=target/skill.name
            original=fingerprint(destination)
            if original.startswith('directory:') and not (destination/'.mstack-managed-copy').exists() and not (replace and skill.name=='mstack-paperclip'): continue
            row={'target':str(destination),'original':original,'backup':str(backup/skill.name),'installed':'link:'+str(skill) if mode=='symlink' else None}
            if original.startswith('directory:'): shutil.copytree(destination,row['backup'],symlinks=True)
            if mode=='copy':
                staging=backup/(skill.name+'.installed');shutil.copytree(skill,staging,symlinks=True);(staging/'.mstack-managed-copy').touch()
                if skill.name=='mstack-run': (staging/'.mstack-source-root').write_text(str(source)+'\n')
                row['installed']=fingerprint(staging)
            value['entries'].append(row);write_manifest(manifest,value)
        for row in value['entries']:
            destination=Path(row['target']);remove_managed(destination)
            if mode=='symlink': destination.symlink_to(source/'skills'/destination.name)
            else:
                with tempfile.TemporaryDirectory(dir=target) as temporary:
                    staged=Path(temporary)/'skill'
                    shutil.copytree(backup/(destination.name+'.installed'),staged,symlinks=True)
                    os.replace(staged,destination)
        value['state']='installed';write_manifest(manifest,value)
    except Exception:
        if manifest.exists(): restore(manifest)
        raise
    return {'state':'installed','manifest':str(manifest),'skills':len(value['entries'])}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source');parser.add_argument('--target');parser.add_argument('--backup-dir');parser.add_argument('--replace-paperclip-prototype',action='store_true');parser.add_argument('--restore-manifest');parser.add_argument('--mode',choices=['symlink','copy'],default='symlink')
    args=parser.parse_args()
    try:
        result=restore(args.restore_manifest) if args.restore_manifest else install(args.source,args.target,args.backup_dir,args.replace_paperclip_prototype,args.mode)
        print(json.dumps(result));return 0
    except (OSError,ValueError,TypeError,KeyError):
        print(json.dumps({'state':'refused','diagnostic':'installation failed or target changed; inspect retained rollback manifest'}));return 2

if __name__=='__main__': raise SystemExit(main())
