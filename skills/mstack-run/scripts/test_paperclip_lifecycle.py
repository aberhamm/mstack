"""Actual lifecycle CLI boundaries against disposable Git and HTTP fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parent))
import paperclip_config as config
import test_paperclip_lifecycle_characterization as characterization
import test_paperclip_transport as transport_fixture


class LifecycleTests(characterization.LifecycleCharacterization):
    def setUp(self):
        super().setUp()
        self.net = transport_fixture.TransportTests('test_delivery_and_deduplication')
        with patch.dict(os.environ, self.env, clear=True):
            self.net.setUp()
        self.net.profile_patch.stop()
        profiles = self.home/'.config/mstack/paperclip.json'
        profiles.parent.mkdir(parents=True)
        profiles.write_bytes(self.net.profiles.read_bytes())
        # Global Python config is not needed: every boundary is a real subprocess.
        binding = config.binding_path(self.repo)
        binding.parent.mkdir()
        binding.write_text(json.dumps({'version':1,'mode':'enabled','repository_id':'r','profile':'test','company_id':'c','project_id':'p'}))
        self.metadata = {'session':'disposable-watched-session','worktree':str(self.repo.resolve()),'review_evidence':'synthetic fixture review only','test_evidence':'actual fixture gate assertions','health_result':'.mstack/result-1.txt'}
        self.metadata_file = self.repo/'.mstack/session.json'
        self.metadata_file.write_text(json.dumps(self.metadata))
    def tearDown(self):
        self.net.server.shutdown()
        self.net.server.server_close()
        self.net.thread.join()
        self.net.tmp.cleanup()
        super().tearDown()
    def boundary(self, outcome, plan=None):
        result = self.run_cmd(['bash', str(characterization.SCRIPTS/'paperclip_lifecycle.sh'), 'emit', '--repo', str(self.repo), '--plan',str((plan or self.plan).relative_to(self.repo)), '--outcome',outcome,'--json',str(self.metadata_file)])
        return json.loads(result.stdout)
    def archive_and_tag(self):
        self.archive.parent.mkdir()
        self.git('mv',str(self.plan.relative_to(self.repo)),str(self.archive.relative_to(self.repo)))
        self.git('commit','-qm','fixture archive')
        self.git('tag','-a',self.tag,'-m','fixture completion')
        self.metadata['completion_tag_sha'] = self.git('rev-parse',self.tag+'^{commit}').stdout.strip()
        self.metadata_file.write_text(json.dumps(self.metadata))
    def test_watched_actual_boundaries_claim_review_archive_done(self):
        self.assertEqual(self.boundary('claimed')['delivery'],'delivered')
        self.assertEqual(self.boundary('review')['delivery'],'delivered')
        self.approve_fixture()
        self.complete_before_archive()
        self.assertEqual(self.boundary('done')['delivery'],'conflict')
        self.assertNotEqual(self.net.issues['1']['status'],'done')
        self.archive_and_tag()
        done = self.boundary('done',self.archive)
        self.assertEqual(done['delivery'],'delivered')
        self.assertEqual(self.net.issues['1']['status'],'done')
        self.assertIn(self.metadata['completion_tag_sha'],self.net.comments['1'][-1]['body'])
        count = len(self.net.comments['1'])
        self.assertEqual(self.boundary('done',self.archive)['delivery'],'delivered')
        self.assertEqual(len(self.net.comments['1']),count)
        self.assertFalse(any('wakeup' in path for method,path in self.net.calls))
        print('WATCHED NEW CALLERS: claim -> review -> local gates/commit/archive/tag -> done at actual lifecycle CLI')
    def test_padded_local_id_uses_actual_tag_name(self):
        self.plan.write_text(self.plan.read_text().replace('id: 1', 'id: 001'))
        self.git('add','docs');self.git('commit','-qm','fixture padded plan identity')
        self.tag = 'mstack/plan-001-done'
        self.approve_fixture();self.complete_before_archive();self.archive_and_tag()
        self.assertEqual(self.boundary('done',self.archive)['delivery'],'delivered')
    def drop_local_delivery_state(self):
        for name in ('events.json','lifecycle.json'):
            (config.binding_path(self.repo).parent/name).unlink()
        self.metadata['session']='different-disposable-session'
        self.metadata_file.write_text(json.dumps(self.metadata))
    def test_fresh_local_state_adopts_stable_remote_identity(self):
        self.assertEqual(self.boundary('claimed')['delivery'],'delivered')
        self.drop_local_delivery_state()
        self.assertEqual(self.boundary('claimed')['delivery'],'delivered')
        self.assertEqual(len(self.net.issues),1)
        self.assertEqual(len(self.net.comments['1']),2)
    def test_fresh_state_cannot_overwrite_manual_terminal_outcome(self):
        self.assertEqual(self.boundary('claimed')['delivery'],'delivered')
        self.net.issues['1']['status']='done'
        self.drop_local_delivery_state()
        self.assertEqual(self.boundary('claimed')['delivery'],'conflict')
        self.assertEqual(len(self.net.issues),1)
        self.assertEqual(self.net.issues['1']['status'],'done')
    def test_ambiguous_remote_plan_markers_refuse_adoption(self):
        self.assertEqual(self.boundary('claimed')['delivery'],'delivered')
        self.net.issues['2']=dict(self.net.issues['1'],id='2')
        self.net.comments['2']=[]
        self.drop_local_delivery_state()
        self.assertEqual(self.boundary('claimed')['delivery'],'conflict')
        self.assertEqual(len(self.net.issues),2)
    def test_missing_review_never_reports_done(self):
        self.plan.write_text(self.plan.read_text().replace('status: in-progress','status: done'))
        self.git('add','docs/plans/001-disposable.md');self.git('commit','-qm','synthetic uncleared local completion')
        self.archive_and_tag()
        self.assertEqual(self.boundary('done',self.archive)['delivery'],'conflict')
        self.assertEqual(self.net.calls,[])
    def test_archive_or_tag_failure_never_reports_done(self):
        self.approve_fixture();self.complete_before_archive()
        self.assertEqual(self.boundary('done')['delivery'],'conflict')
        self.archive.parent.mkdir();self.git('mv',str(self.plan.relative_to(self.repo)),str(self.archive.relative_to(self.repo)));self.git('commit','-qm','fixture archive without tag')
        self.assertEqual(self.boundary('done',self.archive)['delivery'],'conflict')
        self.assertEqual(self.net.calls,[])
    def test_outage_does_not_block_local_completion_checkpoint(self):
        self.net.server.shutdown();self.net.server.server_close();self.net.thread.join()
        claimed = self.boundary('claimed')
        self.assertEqual(claimed['delivery'],'pending')
        self.approve_fixture();self.complete_before_archive();self.archive_and_tag()
        self.assertEqual(self.boundary('done',self.archive)['delivery'],'pending')
        checkpoint=self.repo/'.mstack/checkpoint.json';checkpoint.write_text(json.dumps({'plan_id':1,'status':'done','tag':self.tag}))
        self.assertEqual(json.loads(checkpoint.read_text())['status'],'done')
        self.assertTrue(self.archive.exists())
        self.assertEqual(len(json.loads((config.binding_path(self.repo).parent/'events.json').read_text())['events']),2)
    def test_duplicate_ids_and_ownership_conflicts(self):
        duplicate=self.plan.with_name('001-duplicate.md');duplicate.write_text(self.plan.read_text())
        self.assertEqual(self.boundary('claimed')['delivery'],'conflict')
        self.assertEqual(self.net.calls,[])
        duplicate.unlink()
        self.assertEqual(self.boundary('claimed')['delivery'],'delivered')
        self.net.issues['1']['assigneeAgentId']='agent'
        self.assertEqual(self.boundary('review')['delivery'],'conflict')
        self.assertNotEqual(self.net.issues['1']['status'],'in_review')
    def test_source_restrictions_and_archive_identity(self):
        self.plan.write_text(self.plan.read_text().replace('status: in-progress','status: deferred'))
        self.git('add','docs');self.git('commit','-qm','fixture deferred source')
        self.assertEqual(self.boundary('authored')['delivery'],'delivered')
        self.assertEqual(self.net.issues['1']['status'],'blocked')
        self.assertIn('Local source status: deferred',self.net.comments['1'][-1]['body'])
        self.plan.write_text(self.plan.read_text().replace('status: deferred','status: in-progress'));self.git('add','docs');self.git('commit','-qm','fixture claim')
        self.assertEqual(self.boundary('claimed')['delivery'],'delivered')
        self.approve_fixture();self.complete_before_archive();self.archive_and_tag()
        self.assertEqual(self.boundary('done',self.archive)['delivery'],'delivered')
        self.assertEqual(len(self.net.issues),1)
    def test_failed_outcome_maps_blocked(self):
        self.plan.write_text(self.plan.read_text().replace('status: in-progress','status: failed'))
        self.git('add','docs');self.git('commit','-qm','fixture failed')
        self.assertEqual(self.boundary('failed')['delivery'],'delivered')
        self.assertEqual(self.net.issues['1']['status'],'blocked')
        self.assertIn('Local outcome: failed',self.net.comments['1'][-1]['body'])
    def test_disabled_boundary_never_starts_python(self):
        binding=config.binding_path(self.repo);value=json.loads(binding.read_text());value['mode']='disabled';binding.write_text(json.dumps(value))
        fake=self.root/'bin';fake.mkdir();python=fake/'python3';python.write_text('#!/bin/sh\nexit 99\n');python.chmod(0o755)
        self.env['PATH']=str(fake)+':'+self.env['PATH']
        self.assertEqual(self.boundary('done')['delivery'],'disabled')
        self.assertEqual(self.net.calls,[])
    def report(self, repo, session, note, outcome='continuation'):
        return ['bash', str(characterization.SCRIPTS/'paperclip_lifecycle.sh'), 'emit', '--repo', str(repo), '--plan', str(self.plan.relative_to(self.repo)), '--outcome', outcome, '--session='+session, '--worktree='+str(Path(repo).resolve()), '--note='+note]
    def tree(self, repo):
        return sorted((str(path.relative_to(repo)), path.read_bytes() if path.is_file() else None) for path in Path(repo).rglob('*') if '.git' not in path.relative_to(repo).parts)
    def test_report_with_direct_values_lands_and_writes_no_file(self):
        self.metadata_file.unlink()
        before = self.tree(self.repo)
        note = 'Handoff saved; quotes "$(untouched)" and `backticks` stay text'
        result = json.loads(self.run_cmd(self.report(self.repo, 'direct-session', note)).stdout)
        self.assertEqual(result['delivery'], 'delivered')
        self.assertEqual(self.tree(self.repo), before)
        self.assertEqual(self.git('status', '--porcelain', '--ignored').stdout.strip(), '!! .mstack/')
        body = self.net.comments['1'][-1]['body']
        self.assertIn('session: direct-session', body)
        self.assertIn('note: '+note, body)
    def test_report_with_metadata_file_still_lands(self):
        self.assertEqual(self.boundary('continuation')['delivery'], 'delivered')
        self.assertIn('session: disposable-watched-session', self.net.comments['1'][-1]['body'])
    def test_report_direct_values_keep_the_metadata_rules(self):
        command = self.report(self.repo, 'direct-session', 'note')
        mixed = json.loads(self.run_cmd(command+['--json', str(self.metadata_file)]).stdout)
        elsewhere = json.loads(self.run_cmd(command[:-2]+['--worktree='+str(self.root), '--note=note']).stdout)
        nameless = json.loads(self.run_cmd([part for part in command if not part.startswith('--session=')]).stdout)
        neither = json.loads(self.run_cmd(command[:-3]).stdout)
        self.assertEqual(json.loads(self.run_cmd(command[:-3]+['--session=', '--note=']).stdout)['delivery'], 'conflict')
        secret = json.loads(self.run_cmd(self.report(self.repo, 'direct-session', 'password: hunter2')).stdout)
        self.assertEqual([r['delivery'] for r in (mixed, elsewhere, nameless, neither, secret)], ['conflict']*5)
        self.assertEqual(self.net.calls, [])
    def test_done_report_with_direct_evidence_values_keeps_the_strict_rule(self):
        self.metadata_file.unlink()
        self.approve_fixture();self.complete_before_archive()
        self.archive.parent.mkdir()
        self.git('mv', str(self.plan.relative_to(self.repo)), str(self.archive.relative_to(self.repo)))
        self.git('commit', '-qm', 'fixture archive')
        self.git('tag', '-a', self.tag, '-m', 'fixture completion')
        sha = self.git('rev-parse', self.tag+'^{commit}').stdout.strip()
        command = ['bash', str(characterization.SCRIPTS/'paperclip_lifecycle.sh'), 'emit', '--repo', str(self.repo), '--plan', str(self.archive.relative_to(self.repo)), '--outcome', 'done',
                   '--session=direct-session', '--worktree='+str(self.repo.resolve()), '--review-evidence=synthetic fixture review only', '--test-evidence=actual fixture gate assertions', '--health-result=.mstack/result-1.txt']
        self.assertEqual(json.loads(self.run_cmd(command).stdout)['delivery'], 'conflict')
        self.assertEqual(json.loads(self.run_cmd(command+['--completion-tag-sha='+'0'*40]).stdout)['delivery'], 'conflict')
        self.assertEqual(self.net.calls, [])
        before = self.tree(self.repo)
        self.assertEqual(json.loads(self.run_cmd(command+['--completion-tag-sha='+sha]).stdout)['delivery'], 'delivered')
        self.assertEqual(self.net.issues['1']['status'], 'done')
        self.assertIn('review_evidence: synthetic fixture review only', self.net.comments['1'][-1]['body'])
        self.assertEqual(self.tree(self.repo), before)
    def test_report_values_starting_with_a_dash_or_naming_a_flag_stay_values(self):
        for note in ('--apply', '-x', '--repo', '--json'):
            result = json.loads(self.run_cmd(self.report(self.repo, 'direct-session', note)).stdout)
            self.assertEqual(result['delivery'], 'delivered')
            self.assertIn('note: '+note, self.net.comments['1'][-1]['body'])
        self.assertEqual(len(self.net.comments['1']), 4)
    def test_two_worktrees_reporting_at_the_same_moment_both_land(self):
        self.two_worktrees_report(delay=0)
    def test_two_worktrees_both_land_when_the_board_is_slower_than_the_ledger_wait(self):
        # One reporter holds the ledgers for longer than the 3 s ledger wait; the other must queue, not fail.
        elapsed = self.two_worktrees_report(delay=1.0)
        self.assertGreater(elapsed, 6)
    def two_worktrees_report(self, delay):
        second = self.root/'second-worktree'
        self.git('worktree', 'add', '-q', '--detach', str(second))
        before = self.tree(self.repo), self.tree(second)
        self.net.delay, started = delay, time.monotonic()
        running = [subprocess.Popen(self.report(repo, session, 'report from '+session), cwd=repo, env=self.env, stdout=subprocess.PIPE, text=True)
                   for repo, session in ((self.repo, 'first-session'), (second, 'second-session'))]
        self.assertTrue(all(process.poll() is None for process in running))
        results = [json.loads(process.communicate(timeout=90)[0]) for process in running]
        elapsed = time.monotonic()-started
        self.net.delay = 0
        self.assertEqual([r['delivery'] for r in results], ['delivered', 'delivered'])
        self.assertEqual(len(self.net.issues), 1)
        bodies = '\n'.join(comment['body'] for comment in self.net.comments['1'])
        self.assertEqual(len(self.net.comments['1']), 2)
        self.assertIn('report from first-session', bodies)
        self.assertIn('report from second-session', bodies)
        shared = config.binding_path(self.repo).parent
        self.assertEqual(shared, config.binding_path(second).parent)
        ledger = json.loads((shared/'lifecycle.json').read_text())['plans']['1']
        self.assertEqual((ledger['sequence'], len(ledger['events'])), (2, 2))
        events = json.loads((shared/'events.json').read_text())['events']
        self.assertEqual(sorted(e['event']['metadata']['session'] for e in events), ['first-session', 'second-session'])
        self.assertEqual([e['delivery'] for e in events], ['delivered', 'delivered'])
        self.assertEqual((self.tree(self.repo), self.tree(second)), before)
        return elapsed


for name in list(characterization.LifecycleCharacterization.__dict__):
    if name.startswith('test_') and name not in LifecycleTests.__dict__: setattr(LifecycleTests,name,None)

if __name__ == '__main__': unittest.main()
