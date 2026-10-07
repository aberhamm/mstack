"""Import parity and reversible ordinary-directory installation fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parent))
import paperclip
import paperclip_adoption as adoption
import paperclip_config as config
import paperclip_install as installer


def isolated_environment(root):
    home=root/'isolated-home';home.mkdir()
    environment={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(HOME=str(home),XDG_CONFIG_HOME=str(home/'config'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_ALLOW_PROTOCOL='file')
    return patch.dict(os.environ,environment,clear=True)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.environment=isolated_environment(self.root);self.environment.start()
        self.repo=self.root/'repo';subprocess.run(['git','init','-q',str(self.repo)],check=True)
        directory=self.repo/'docs/plans/archive';directory.mkdir(parents=True)
        (directory/'001-old-name.md').write_text('---\nid: 7\nstatus: pending\n---\nReal authored source\n')
        (self.repo/'TODO.md').write_text('- [ ] Separate todo\n')
        self.manifest=self.root/'sources.json'
        self.manifest.write_text(json.dumps({'projects':[{'name':'Fixture','path':str(self.repo),'tasks':[{'source':'docs/plans/001-old-name.md'},{'source':'TODO.md#Separate todo'}]}]}))
        self.issues={}
        for index,source in enumerate(['docs/plans/001-old-name.md','TODO.md#Separate todo'],1):
            marker=adoption.source_marker('Fixture',source)
            self.issues[str(index)]={'id':str(index),'companyId':'c','projectId':'p','status':'backlog','updatedAt':'1','description':'Human note\n'+marker+'\n'+marker}
        self.calls=[]
        self.auth=self.root/'auth.json';self.auth.write_text(json.dumps({'credentials':{'http://fixture.invalid':{'token':'fixture','userId':'human'}}}))
        self.profiles=self.root/'profiles.json';self.profiles.write_text(json.dumps({'version':1,'profiles':{'fixture':{'api_base':'http://fixture.invalid','auth_file':str(self.auth)}}}))
        self.profile_patch=patch.object(config,'profile_path',return_value=self.profiles);self.profile_patch.start()
        def request(api,method,path,data=None):
            self.calls.append((method,path,data))
            if path.endswith('/projects'):return [{'id':'p','name':'Fixture','companyId':'c'}]
            if '/companies/' in path:return [{'id':identity,'description':'truncated'} for identity in self.issues]
            issue=self.issues[path.split('/')[-1]]
            if method=='PATCH':
                self.assertEqual(set(data),{'description'})
                issue.update(data,updatedAt=str(int(issue['updatedAt'])+1))
            return dict(issue)
        self.api_patch=patch.object(paperclip.API,'request',new=request);self.api_patch.start()
    def tearDown(self):
        self.api_patch.stop();self.profile_patch.stop();self.environment.stop();self.tmp.cleanup()
    def report(self,apply=False):return adoption.adopt(self.repo,self.manifest,'fixture','c',apply)
    def test_fixture_git_boundary_uses_only_temporary_repository(self):
        result=subprocess.run(['git','-C',str(self.repo),'rev-parse','--absolute-git-dir'],capture_output=True,text=True,check=True)
        self.assertEqual(Path(result.stdout.strip()).resolve(),(self.repo/'.git').resolve())
        self.assertNotIn('GIT_DIR',os.environ)
        self.assertNotIn('GIT_INDEX_FILE',os.environ)
        self.assertEqual(os.environ['GIT_ALLOW_PROTOCOL'],'file')
        self.assertEqual(Path(os.environ['HOME']).parent,self.root)
    def test_read_only_marker_occurrences_and_archived_frontmatter_identity(self):
        result=self.report()
        self.assertEqual(result['verified'],2);self.assertTrue(result['apply_allowed'])
        self.assertEqual(result['report'][0]['plan_id'],'7')
        self.assertIsNone(result['report'][1]['plan_id'])
        self.assertFalse(config.binding_path(self.repo).exists())
        self.assertFalse(any(method=='PATCH' for method,path,data in self.calls))
    def test_apply_preserves_notes_workflow_and_independent_todo(self):
        result=self.report(True);self.assertEqual(result['verified'],2)
        directory=config.binding_path(self.repo).parent
        self.assertEqual(config.status(self.repo)['project_id'],'p')
        state=json.loads((directory/'events.json').read_text())
        self.assertEqual(set(state['mappings']),{'7'})
        self.assertEqual(state['mappings']['7']['issue_id'],'1')
        records=json.loads((directory/'adoption.json').read_text())['records']
        self.assertEqual(len(records),2)
        self.assertTrue((directory/'adoption-backup.json').exists())
        self.assertTrue(all(issue['status']=='backlog' and issue['description'].startswith('Human note') for issue in self.issues.values()))
        self.assertEqual(self.report()['verified'],2)
    def test_ambiguous_marker_aborts_all_apply(self):
        self.issues['3']=dict(self.issues['1'],id='3')
        self.assertFalse(self.report()['apply_allowed'])
        with self.assertRaises(config.ConfigError):self.report(True)
        self.assertFalse(any(method=='PATCH' for method,path,data in self.calls))
    def test_missing_source_identity_retained_and_apply_refused(self):
        (self.repo/'docs/plans/archive/001-old-name.md').unlink()
        report=self.report();self.assertFalse(report['apply_allowed'])
        self.assertEqual(report['report'][0]['state']['status'],'missing-source')
        with self.assertRaises(config.ConfigError):self.report(True)
        self.assertEqual(len(self.issues),2)
    def test_partial_refresh_keeps_durable_originals_across_retry(self):
        original={key:adoption.source_block(issue['description']) for key,issue in self.issues.items()}
        real=paperclip.API.request
        def fail_second(api,method,path,data=None):
            if method=='PATCH' and path=='/issues/2':raise paperclip.DeliveryError('fixture outage')
            return real(api,method,path,data)
        with patch.object(paperclip.API,'request',new=fail_second):
            with self.assertRaises(paperclip.DeliveryError):self.report(True)
        target=config.binding_path(self.repo).parent/'adoption-remote-backup.json'
        saved=json.loads(target.read_text())
        self.assertEqual({key:row['source_block'] for key,row in saved['issues'].items()},original)
        self.report(True)
        self.assertEqual(json.loads(target.read_text()),saved)
    def test_human_credential_labels_are_not_copied_or_scanned(self):
        self.issues['1']['description']+='\nHuman documentation password: placeholder-only; API key: example-label'
        self.report(True)
        directory=config.binding_path(self.repo).parent
        for name in ('adoption-remote-backup.json','adoption.json'):
            self.assertNotIn('Human documentation',(directory/name).read_text())
            self.assertNotIn('placeholder-only',(directory/name).read_text())
        self.assertIn('Human documentation',self.issues['1']['description'])
    def test_restore_block_preserves_current_human_notes(self):
        original=adoption.BEGIN+'\nOriginal owned state\n'+adoption.END
        current=adoption.managed_description('Human password: documentation',{'status':'pending','location':'source'})+'\nNew human note after migration'
        restored=adoption.restore_source_block(current,original)
        self.assertTrue(restored.startswith('Human password: documentation'))
        self.assertTrue(restored.endswith('New human note after migration'))
        self.assertIn(original,restored)
        removed=adoption.restore_source_block(current,None)
        self.assertNotIn(adoption.BEGIN,removed)
        self.assertIn('New human note after migration',removed)
    def test_existing_source_block_original_survives_partial_refresh(self):
        block=adoption.BEGIN+'\nSource status (current checkout): old\nSource location: old\n'+adoption.END
        self.issues['1']['description']+='\n'+block
        self.report(True)
        backup=json.loads((config.binding_path(self.repo).parent/'adoption-remote-backup.json').read_text())
        self.assertEqual(backup['issues']['1']['source_block'],block)
        self.assertIsNone(backup['issues']['2']['source_block'])
    def test_duplicate_local_identity_retained_source_only_and_lifecycle_refused(self):
        (self.repo/'docs/plans/duplicate.md').write_text('---\nid: 7\nstatus: pending\n---\n')
        result=self.report()
        self.assertTrue(result['apply_allowed'])
        self.assertIsNone(result['report'][0]['plan_id'])
        self.assertIn('collision',result['report'][0]['diagnostic'])
        self.report(True)
        state=paperclip.load_state(config.binding_path(self.repo).parent/'events.json')
        self.assertEqual(state['mappings'],{})
        self.assertEqual(self.issues['1']['status'],'backlog')
        self.assertTrue(self.issues['1']['description'].startswith('Human note'))
        import paperclip_lifecycle
        with self.assertRaises(config.ConfigError):
            paperclip_lifecycle.identity(self.repo,'docs/plans/archive/001-old-name.md')
    def test_refresh_advances_only_known_baseline(self):
        self.report(True)
        directory=config.binding_path(self.repo).parent
        (self.repo/'docs/plans/archive/001-old-name.md').write_text('---\nid: 7\nstatus: in-progress\n---\n')
        self.report(True)
        state=paperclip.load_state(directory/'events.json')
        self.assertEqual(state['mappings']['7']['updated_at'],self.issues['1']['updatedAt'])
        self.issues['1']['status']='done';self.issues['1']['updatedAt']='90'
        (self.repo/'docs/plans/archive/001-old-name.md').write_text('---\nid: 7\nstatus: failed\n---\n')
        self.report(True)
        retained=paperclip.load_state(directory/'events.json')['mappings']['7']
        self.assertEqual(retained['status'],'backlog')
        self.assertNotEqual(retained['updated_at'],self.issues['1']['updatedAt'])
    def test_mappings_only_retains_missing_sources_without_remote_refresh(self):
        (self.repo/'docs/plans/archive/001-old-name.md').unlink()
        original={key:dict(issue) for key,issue in self.issues.items()}
        result=adoption.adopt(self.repo,self.manifest,'fixture','c',True,True)
        self.assertEqual(result['verified'],2)
        self.assertIn('native-source-unresolved',result['report'][0]['diagnostic'])
        self.assertEqual(self.issues,original)
        self.assertFalse(any(method=='PATCH' for method,path,data in self.calls))
        directory=config.binding_path(self.repo).parent
        self.assertEqual(paperclip.load_state(directory/'events.json')['mappings'],{})
        self.assertEqual(len(json.loads((directory/'adoption.json').read_text())['records']),2)
        self.assertEqual(config.status(self.repo)['mode'],'enabled')
    def test_empty_project_still_gets_binding(self):
        manifest=json.loads(self.manifest.read_text());manifest['projects'][0]['tasks']=[];self.manifest.write_text(json.dumps(manifest))
        self.assertEqual(self.report(True)['projects'],1)
        self.assertEqual(config.status(self.repo)['project_id'],'p')


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.environment=isolated_environment(self.root);self.environment.start()
        self.source=self.root/'reviewed source';self.target=self.root/'skills with spaces';self.backup=self.root/'rollback with spaces'
        self.target.mkdir();(self.source/'skills/mstack-paperclip').mkdir(parents=True)
        (self.source/'skills/mstack-paperclip/SKILL.md').write_text('native source')
        (self.source/'skills/mstack-run').mkdir();(self.source/'skills/mstack-run/SKILL.md').write_text('run source')
        (self.target/'mstack-paperclip').mkdir();(self.target/'mstack-paperclip/SKILL.md').write_text('prototype preserved')
        (self.target/'mstack-run').symlink_to('/original/run/source')
    def tearDown(self):self.environment.stop();self.tmp.cleanup()
    def test_explicit_prototype_backup_repeat_and_restore(self):
        result=installer.install(self.source,self.target,self.backup,True)
        self.assertTrue((self.target/'mstack-paperclip').is_symlink())
        self.assertEqual((self.backup/'mstack-paperclip/SKILL.md').read_text(),'prototype preserved')
        self.assertEqual(installer.install(self.source,self.target,self.backup,True)['state'],'already-installed')
        installer.restore(result['manifest'])
        self.assertEqual((self.target/'mstack-paperclip/SKILL.md').read_text(),'prototype preserved')
        self.assertEqual(os.readlink(self.target/'mstack-run'),'/original/run/source')
    def test_default_skips_ordinary_directories(self):
        installer.install(self.source,self.target,self.backup)
        self.assertFalse((self.target/'mstack-paperclip').is_symlink())
        self.assertEqual((self.target/'mstack-paperclip/SKILL.md').read_text(),'prototype preserved')
    def test_changed_user_target_refuses_restore(self):
        result=installer.install(self.source,self.target,self.backup,True)
        (self.target/'mstack-run').unlink();(self.target/'mstack-run').mkdir();(self.target/'mstack-run/custom').write_text('user change')
        with self.assertRaises(ValueError):installer.restore(result['manifest'])
        self.assertEqual((self.target/'mstack-run/custom').read_text(),'user change')
        self.assertTrue((self.target/'mstack-paperclip').is_symlink())
    def test_partial_failure_restores_prior_targets(self):
        real=Path.symlink_to;count=0
        def fail_once(path,*args,**kwargs):
            nonlocal count
            count+=1
            if count==2:raise OSError('fixture partial failure')
            return real(path,*args,**kwargs)
        with patch.object(Path,'symlink_to',new=fail_once):
            with self.assertRaises(OSError):installer.install(self.source,self.target,self.backup,True)
        self.assertEqual((self.target/'mstack-paperclip/SKILL.md').read_text(),'prototype preserved')
        self.assertEqual(os.readlink(self.target/'mstack-run'),'/original/run/source')
    def test_corrupted_backup_refuses_restore_before_changes(self):
        result=installer.install(self.source,self.target,self.backup,True)
        (self.backup/'mstack-paperclip/SKILL.md').write_text('changed backup')
        with self.assertRaises(ValueError):installer.restore(result['manifest'])
        self.assertTrue((self.target/'mstack-paperclip').is_symlink())
    def test_partial_copy_failure_restores_prior_targets(self):
        real=shutil.copytree
        def fail_install(source,destination,*args,**kwargs):
            if Path(destination).name=='skill':
                Path(destination).mkdir();(Path(destination)/'partial').touch()
                raise OSError('fixture partial copy')
            return real(source,destination,*args,**kwargs)
        with patch.object(shutil,'copytree',side_effect=fail_install):
            with self.assertRaises(OSError):installer.install(self.source,self.target,self.backup,True,'copy')
        self.assertEqual((self.target/'mstack-paperclip/SKILL.md').read_text(),'prototype preserved')
        self.assertEqual(os.readlink(self.target/'mstack-run'),'/original/run/source')
    def test_setup_end_to_end_flags(self):
        root=Path(__file__).resolve().parents[3]
        shutil.copy2(root/'setup',self.source/'setup')
        scripts=self.source/'skills/mstack-run/scripts';scripts.mkdir();shutil.copy2(root/'skills/mstack-run/scripts/paperclip_install.py',scripts/'paperclip_install.py')
        env=dict(os.environ,HOME=str(self.root/'isolated home'),MSTACK_SKILL_DIR=str(self.target),MSTACK_SKIP_SKILLSHARE_SYNC='1',GIT_ALLOW_PROTOCOL='file')
        result=subprocess.run(['bash',str(self.source/'setup'),'--without-gstack','--skip-hooks','--replace-paperclip-prototype','--backup-dir',str(self.backup)],env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.target/'mstack-paperclip').is_symlink())


if __name__=='__main__':unittest.main()
