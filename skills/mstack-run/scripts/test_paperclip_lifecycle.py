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
    NOTE = 'caught up from the plan file; not verified at completion'
    def catch_up(self, *flags):
        result = self.run_cmd(['bash', str(characterization.SCRIPTS/'paperclip_lifecycle.sh'), 'catch-up', '--repo', str(self.repo), *flags])
        self.assertEqual(result.stdout.count('\n'), 1)
        return json.loads(result.stdout)
    def local_status(self, status, plan=None):
        plan = plan or self.plan
        plan.write_text(plan.read_text().replace('status: in-progress', 'status: '+status))
        self.git('add', 'docs');self.git('commit', '-qm', 'fixture local '+status)
    def stale_task(self, status):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.local_status(status)
    def writes(self):
        return [(method, path) for method, path in self.net.calls if method != 'GET']
    def ledgers(self):
        directory = config.binding_path(self.repo).parent
        return {name: (directory/name).read_bytes() for name in ('events.json', 'lifecycle.json')}
    def assert_closed(self, local, remote):
        self.stale_task(local)
        report = self.catch_up('--apply')
        self.assertEqual([(c['plan'], c['from'], c['to'], c['delivery']) for c in report['changes']], [('1', 'in_progress', remote, 'delivered')])
        self.assertEqual(self.net.issues['1']['status'], remote)
        self.assertIn(self.NOTE, self.net.comments['1'][-1]['body'])
        self.assertIn('Local source status: '+local, self.net.comments['1'][-1]['body'])
        self.assertEqual(len(self.net.issues), 1)
        count, writes = len(self.net.comments['1']), self.writes()
        again = self.catch_up('--apply')
        self.assertEqual((again['changes'], again['skipped']), ([], []))
        self.assertEqual((len(self.net.comments['1']), self.writes()), (count, writes))
    def test_catch_up_done_plan_closes_task_as_done_with_the_note(self):
        self.assert_closed('done', 'done')
    def test_catch_up_skipped_plan_cancels_task_with_the_note(self):
        self.assert_closed('skipped', 'cancelled')
    def test_catch_up_dropped_plan_cancels_task_with_the_note(self):
        self.assert_closed('dropped', 'cancelled')
    def second_plan(self, number, status, directory=None):
        plan = (directory or self.plan.parent)/('%03d-second.md' % number)
        plan.parent.mkdir(parents=True, exist_ok=True)
        plan.write_text(self.plan.read_text().replace('id: 1', 'id: %d' % number).replace('Disposable lifecycle fixture', 'Second fixture'))
        self.git('add', '-A');self.git('commit', '-qm', 'fixture second plan')
        if status != 'in-progress':
            self.local_status(status, plan)
        return plan
    def test_catch_up_closes_several_plans_in_one_run(self):
        second = self.second_plan(2, 'in-progress')
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.assertEqual(self.boundary('claimed', second)['delivery'], 'delivered')
        self.local_status('done');self.local_status('dropped', second)
        report = self.catch_up('--apply')
        self.assertEqual([(c['plan'], c['issue_id'], c['to'], c['delivery']) for c in report['changes']], [('1', '1', 'done', 'delivered'), ('2', '2', 'cancelled', 'delivered')])
        self.assertEqual((self.net.issues['1']['status'], self.net.issues['2']['status']), ('done', 'cancelled'))
    def test_catch_up_never_sends_queued_reports_of_other_plans_or_creates_a_task(self):
        self.stale_task('done')
        second = self.second_plan(2, 'in-progress')
        events = config.binding_path(self.repo).parent/'events.json'
        state = json.loads(events.read_text())
        queued = dict(state['events'][0]['event'], plan_id='2', event_id='queued-offline', outcome='backlog')
        state['events'].append({'event': queued, 'delivery': 'pending', 'uncertain': False, 'diagnostic': None})
        events.write_text(json.dumps(state))
        report = self.catch_up('--apply')
        self.assertEqual([(c['plan'], c['delivery']) for c in report['changes']], [('1', 'delivered')])
        self.assertEqual(len(self.net.issues), 1)
        self.assertFalse(any(method == 'POST' for method, path in self.writes()[1:]))
        self.assertEqual(json.loads(events.read_text())['events'][1]['delivery'], 'pending')
    def test_catch_up_leaves_a_plan_with_an_unresolved_report_alone(self):
        self.stale_task('done')
        events = config.binding_path(self.repo).parent/'events.json'
        state = json.loads(events.read_text())
        state['events'][0]['delivery'] = 'conflict'
        events.write_text(json.dumps(state))
        writes, ledgers = self.writes(), self.ledgers()
        for flags in ((), ('--apply',), ('--apply',)):
            report = self.catch_up(*flags)
            self.assertEqual(report['changes'], [])
            self.assertIn('in conflict or unconfirmed', report['skipped'][0]['reason'])
        self.assertEqual((self.writes(), self.ledgers()), (writes, ledgers))
    def test_catch_up_sees_a_reused_number_across_both_plan_directories(self):
        self.stale_task('done')
        self.second_plan(1, 'in-progress', self.repo/'plans')
        report = self.catch_up('--apply')
        self.assertEqual((report['changes'], [s['reason'] for s in report['skipped']]), ([], ['plan number is used more than once']))
        self.assertEqual(self.net.issues['1']['status'], 'in_progress')
    def test_catch_up_keeps_its_report_when_a_later_task_is_unreadable(self):
        second = self.second_plan(2, 'in-progress')
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.assertEqual(self.boundary('claimed', second)['delivery'], 'delivered')
        self.local_status('done');self.local_status('done', second)
        del self.net.issues['2']['status']
        report = self.catch_up('--apply')
        self.assertEqual([(c['plan'], c['delivery']) for c in report['changes']], [('1', 'delivered')])
        self.assertEqual([(s['plan'], s['reason']) for s in report['skipped']], [('2', 'unexpected local or board data; inspect manually')])
    def test_catch_up_reports_a_write_with_an_unreadable_answer_as_unconfirmed(self):
        second = self.second_plan(2, 'in-progress')
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.assertEqual(self.boundary('claimed', second)['delivery'], 'delivered')
        self.local_status('done');self.local_status('done', second)
        class LosesStatusOnWrite(dict):
            def update(self, *args, **kwargs):
                super().update(*args, **kwargs)
                self.pop('status', None)
        self.net.issues['1'] = LosesStatusOnWrite(self.net.issues['1'])
        report = self.catch_up('--apply')
        self.assertEqual([(c['plan'], c['delivery']) for c in report['changes']], [('1', 'pending'), ('2', 'deferred')])
        self.assertIn('inspect manually', report['changes'][0]['diagnostic'])
        self.assertEqual((report['counts']['failed'], report['counts']['deferred'], report['skipped']), (1, 1, []))
        self.assertEqual(self.net.issues['2']['status'], 'in_progress')
        self.net.issues['1']['status'] = 'done'
        self.assertIn('inspect it by hand', self.catch_up('--apply')['skipped'][0]['reason'])
    def test_catch_up_stops_at_the_first_unconfirmed_change(self):
        second = self.second_plan(2, 'in-progress')
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.assertEqual(self.boundary('claimed', second)['delivery'], 'delivered')
        self.local_status('done');self.local_status('done', second)
        self.net.fail_patch = True
        report = self.catch_up('--apply')
        self.assertEqual([(c['plan'], c['delivery']) for c in report['changes']], [('1', 'pending'), ('2', 'deferred')])
        self.assertIn('stopped at the first change', report['diagnostic'])
        self.assertEqual(report['counts'], {'would_apply': 0, 'applied': 0, 'failed': 1, 'conflicts': 0, 'deferred': 1, 'skipped': 0, 'attention': 0})
        self.assertEqual(self.net.issues['2']['status'], 'in_progress')
        self.net.fail_patch = False
        again = self.catch_up('--apply')
        self.assertEqual([(c['plan'], c['delivery']) for c in again['changes']], [('2', 'delivered')])
        self.assertEqual((again['counts']['applied'], again['counts']['skipped']), (1, 1))
        self.assertEqual(len(self.net.comments['1']), 2)
    def test_catch_up_limit_caps_the_writes_of_one_run(self):
        second = self.second_plan(2, 'in-progress')
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.assertEqual(self.boundary('claimed', second)['delivery'], 'delivered')
        self.local_status('done');self.local_status('done', second)
        preview = self.catch_up('--limit', '1')
        self.assertEqual((preview['counts']['would_apply'], sorted(preview)), (2, sorted(self.catch_up('--apply', '--limit', '0'))))
        self.assertEqual(self.catch_up('--apply', '--limit', '0')['counts']['deferred'], 2)
        writes = len(self.writes())
        capped = self.catch_up('--apply', '--limit', '1')
        self.assertEqual([(c['plan'], c['delivery']) for c in capped['changes']], [('1', 'delivered'), ('2', 'deferred')])
        self.assertEqual(capped['counts'], {'would_apply': 0, 'applied': 1, 'failed': 0, 'conflicts': 0, 'deferred': 1, 'skipped': 0, 'attention': 0})
        self.assertEqual(len(self.writes()), writes+1)
        self.assertEqual(self.catch_up('--apply', '--limit', '1')['counts']['applied'], 1)
        self.assertEqual(self.net.issues['2']['status'], 'done')
    def test_catch_up_works_for_a_task_adopted_without_a_lifecycle_ledger(self):
        self.stale_task('done')
        (config.binding_path(self.repo).parent/'lifecycle.json').unlink()
        self.assertEqual(self.catch_up('--apply')['changes'][0]['delivery'], 'delivered')
        self.assertEqual(self.net.issues['1']['status'], 'done')
        self.assertEqual(self.boundary('continuation')['delivery'], 'delivered')
    def test_catch_up_without_apply_sends_nothing_and_changes_no_ledger(self):
        self.stale_task('done')
        writes, ledgers = self.writes(), self.ledgers()
        report = self.catch_up()
        self.assertEqual(report['mode'], 'dry-run')
        self.assertEqual(report['counts'], {'would_apply': 1, 'applied': 0, 'failed': 0, 'conflicts': 0, 'deferred': 0, 'skipped': 0, 'attention': 0})
        self.assertEqual([(c['plan'], c['title'], c['issue_id'], c['to'], c['delivery']) for c in report['changes']], [('1', 'Disposable lifecycle fixture', '1', 'done', 'dry-run')])
        self.assertEqual((self.writes(), self.ledgers()), (writes, ledgers))
        self.assertEqual(self.net.issues['1']['status'], 'in_progress')
        self.assertEqual(sorted(path.name for path in config.binding_path(self.repo).parent.iterdir()), ['binding.json', 'events.json', 'lifecycle.json'])
    def test_catch_up_skips_duplicate_number_in_progress_and_plan_without_task(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        untracked = self.plan.with_name('002-no-task.md')
        untracked.write_text(self.plan.read_text().replace('id: 1', 'id: 2').replace('status: in-progress', 'status: done'))
        self.git('add', 'docs');self.git('commit', '-qm', 'fixture plan without task')
        writes = self.writes()
        report = self.catch_up('--apply')
        self.assertEqual((report['changes'], report['skipped']), ([], []))
        self.assertEqual([(a['plan'], a['status'], a['task']) for a in report['attention']], [('1', 'in-progress', 'in_progress')])
        self.local_status('failed')
        self.assertEqual(self.catch_up('--apply')['attention'][0]['status'], 'failed')
        self.plan.write_text(self.plan.read_text().replace('status: failed', 'status: done'))
        duplicate = self.plan.with_name('001-duplicate.md');duplicate.write_text(self.plan.read_text())
        self.git('add', 'docs');self.git('commit', '-qm', 'fixture duplicate number')
        report = self.catch_up('--apply')
        self.assertEqual((report['changes'], [s['reason'] for s in report['skipped']]), ([], ['plan number is used more than once']))
        self.assertEqual(self.writes(), writes)
        self.assertEqual(len(self.net.issues), 1)
        self.assertEqual(self.net.issues['1']['status'], 'in_progress')
    def test_catch_up_never_reopens_or_overwrites_a_task(self):
        self.stale_task('skipped')
        self.net.issues['1'].update(status='done', updatedAt='manual')
        writes = self.writes()
        report = self.catch_up('--apply')
        self.assertEqual((report['changes'], [s['reason'] for s in report['skipped']]), ([], ['task is already closed on the board']))
        self.net.issues['1'].update(status='blocked')
        self.assertIn('changed on the board', self.catch_up('--apply')['skipped'][0]['reason'])
        self.net.issues['1'].update(status='in_progress', assigneeAgentId='agent')
        owned = self.catch_up('--apply')
        self.assertEqual((owned['changes'], [s['reason'] for s in owned['skipped']]), ([], ['agent or active execution ownership conflict']))
        self.assertEqual(self.writes(), writes)
        self.assertEqual(self.ledgers()['events.json'].count(b'catch-up'), 0)
    def test_catch_up_requires_the_committed_plan_file(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.plan.write_text(self.plan.read_text().replace('status: in-progress', 'status: done'))
        report = self.catch_up('--apply')
        self.assertEqual((report['changes'], [s['reason'] for s in report['skipped']]), ([], ['plan file differs from the last commit']))
        self.assertEqual(self.net.issues['1']['status'], 'in_progress')
    def test_catch_up_leaves_later_reports_working(self):
        self.stale_task('done')
        self.assertEqual(self.catch_up('--apply')['changes'][0]['delivery'], 'delivered')
        self.assertEqual(self.boundary('continuation')['delivery'], 'delivered')
        self.assertEqual(len(self.net.comments['1']), 3)
        self.assertEqual(self.net.issues['1']['status'], 'done')
    def test_catch_up_offline_reports_and_changes_nothing(self):
        self.stale_task('done')
        ledgers = self.ledgers()
        self.net.server.shutdown();self.net.server.server_close();self.net.thread.join()
        report = self.catch_up('--apply')
        self.assertEqual((report['changes'], len(report['skipped'])), ([], 1))
        self.assertEqual(self.ledgers(), ledgers)
    # Catch-up from origin: the plans come from origin's default branch after a fetch.
    def origin(self):
        """A bare scratch repository as origin, holding what the checkout has committed so far."""
        self.bare = self.root/'origin.git'
        self.run_cmd(['git', 'init', '-q', '--bare', str(self.bare)], cwd=self.root)
        self.branch = self.git('symbolic-ref', '--short', 'HEAD').stdout.strip()
        self.git('remote', 'add', 'origin', str(self.bare))
        self.git('push', '-q', 'origin', self.branch)
        self.run_cmd(['git', 'symbolic-ref', 'HEAD', 'refs/heads/'+self.branch], cwd=self.bare)
        return self.bare
    def upstream(self, edit, branch=None):
        """Change origin from a second clone, so the checkout under test never sees the commit."""
        other = self.root/'other'
        if not other.exists():
            self.run_cmd(['git', 'clone', '-q', str(self.bare), str(other)], cwd=self.root)
            self.run_cmd(['git', 'config', 'user.name', 'Disposable Fixture'], cwd=other)
            self.run_cmd(['git', 'config', 'user.email', 'fixture@example.invalid'], cwd=other)
        if branch:
            self.run_cmd(['git', 'checkout', '-q', '-b', branch], cwd=other)
        edit(other)
        self.run_cmd(['git', 'add', '-A'], cwd=other)
        self.run_cmd(['git', 'commit', '-qm', 'fixture upstream change'], cwd=other)
        self.run_cmd(['git', 'push', '-q', 'origin', 'HEAD'], cwd=other)
        return self.run_cmd(['git', 'rev-parse', 'HEAD'], cwd=other).stdout.strip()
    def upstream_status(self, status, branch=None):
        def edit(other):
            plan = other/self.plan.relative_to(self.repo)
            plan.write_text(plan.read_text().replace('status: in-progress', 'status: '+status))
        return self.upstream(edit, branch)
    def from_origin(self, *flags, repo=None):
        result = self.run_cmd(['bash', str(characterization.SCRIPTS/'paperclip_lifecycle.sh'), 'catch-up', '--repo', str(repo or self.repo), '--from-origin', *flags])
        self.assertEqual(result.stdout.count('\n'), 1)
        return json.loads(result.stdout)
    def outside_remote_refs(self):
        """Everything a fetch must leave alone: working files, index, HEAD, local branches, tags and the stash."""
        status = self.git('status', '--porcelain').stdout
        files = {str(path.relative_to(self.repo)): path.read_bytes() for path in sorted(self.repo.rglob('*'))
                 if path.is_file() and '.git' not in path.relative_to(self.repo).parts}
        refs = self.git('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/tags', 'refs/stash').stdout
        return (status, files, refs, self.git('rev-parse', 'HEAD').stdout, self.git('symbolic-ref', '-q', 'HEAD', check=False).stdout,
                self.git('stash', 'list').stdout, (self.repo/'.git/index').read_bytes())
    def assert_repository_skipped(self, reason, *flags):
        calls, ledgers, outside = list(self.net.calls), self.ledgers(), self.outside_remote_refs()
        report = self.from_origin('--apply', *flags)
        self.assertEqual((report['mode'], report['diagnostic']), ('skipped', 'repository skipped: '+reason))
        self.assertEqual(report['source'], {'from': 'origin', 'repository': str(self.repo.resolve()), 'skipped': reason})
        self.assertEqual((report['changes'], report['attention'], report['skipped'], set(report['counts'].values())), ([], [], [], {0}))
        # Not guessed from the working folder: the board is not even read, and nothing is stored.
        self.assertEqual((self.net.calls, self.ledgers(), self.outside_remote_refs()), (calls, ledgers, outside))
        self.assertEqual(self.net.issues['1']['status'], 'in_progress')
        # Same shape as an ordinary answer, plus the source.
        self.assertEqual(sorted(report), sorted(self.catch_up())+['source'])
    def fake_git(self, script):
        """Put a git in front of the real one that misbehaves for one subcommand."""
        import shutil
        directory = self.root/'bin'
        directory.mkdir()
        (directory/'git').write_text('#!/bin/sh\nREAL=%s\nfor argument in "$@"; do\n%s\ndone\nexec "$REAL" "$@"\n' % (shutil.which('git', path=self.env['PATH']), script))
        (directory/'git').chmod(0o755)
        self.env['PATH'] = str(directory)+os.pathsep+self.env['PATH']
    def test_catch_up_from_origin_closes_a_task_the_stale_checkout_does_not_show(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        tip, head = self.upstream_status('done'), self.git('rev-parse', 'HEAD').stdout
        stale = self.catch_up('--apply')
        self.assertEqual((stale['changes'], [a['status'] for a in stale['attention']]), ([], ['in-progress']))
        self.assertNotIn('source', stale)
        preview = self.from_origin()
        self.assertEqual((preview['mode'], preview['counts']['would_apply'], self.net.issues['1']['status']), ('dry-run', 1, 'in_progress'))
        report = self.from_origin('--apply')
        self.assertEqual([(c['plan'], c['from'], c['to'], c['delivery']) for c in report['changes']], [('1', 'in_progress', 'done', 'delivered')])
        self.assertEqual(report['source'], {'from': 'origin', 'branch': self.branch, 'commit': tip, 'absent': []})
        self.assertEqual(self.net.issues['1']['status'], 'done')
        body = self.net.comments['1'][-1]['body']
        self.assertIn('Origin commit: '+tip+' (branch '+self.branch+')', body)
        self.assertIn(self.NOTE, body)
        self.assertNotIn('Local commit', body)
        # The checkout itself is where it was.
        self.assertEqual((self.git('rev-parse', 'HEAD').stdout, 'status: in-progress' in self.plan.read_text()), (head, True))
        count, writes = len(self.net.comments['1']), self.writes()
        again = self.from_origin('--apply')
        self.assertEqual((again['changes'], again['skipped'], len(self.net.comments['1']), self.writes()), ([], [], count, writes))
    def test_catch_up_from_origin_keeps_a_task_open_while_done_is_only_on_an_unmerged_branch(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        self.git('checkout', '-q', '-b', 'side')
        self.local_status('done')
        self.git('push', '-q', 'origin', 'side')
        # The working folder alone would close it: this is the case the option exists for.
        self.assertEqual(self.catch_up()['counts']['would_apply'], 1)
        writes = self.writes()
        report = self.from_origin('--apply')
        self.assertEqual((report['changes'], report['skipped'], [(a['plan'], a['status']) for a in report['attention']]), ([], [], [('1', 'in-progress')]))
        self.assertEqual((report['source']['branch'], self.writes(), self.net.issues['1']['status']), (self.branch, writes, 'in_progress'))
    def test_catch_up_from_origin_works_on_a_detached_checkout(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        self.upstream_status('skipped')
        self.git('checkout', '-q', '--detach')
        self.assertEqual([(c['to'], c['delivery']) for c in self.from_origin('--apply')['changes']], [('cancelled', 'delivered')])
        self.assertEqual(self.git('symbolic-ref', '-q', 'HEAD', check=False).stdout, '')
    def test_catch_up_from_origin_works_on_a_shallow_checkout(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        shallow = self.root/'shallow'
        self.run_cmd(['git', 'clone', '-q', '--depth', '1', self.bare.as_uri(), str(shallow)], cwd=self.root)
        connection = shallow/'.git/mstack-paperclip'
        connection.mkdir()
        for name, content in self.ledgers().items():
            (connection/name).write_bytes(content)
        (connection/'binding.json').write_bytes(config.binding_path(self.repo).read_bytes())
        tip = self.upstream_status('done')
        report = self.from_origin('--apply', repo=shallow)
        self.assertEqual(([c['delivery'] for c in report['changes']], report['source']['commit']), (['delivered'], tip))
        self.assertEqual(self.run_cmd(['git', 'rev-parse', '--is-shallow-repository'], cwd=shallow).stdout.strip(), 'true')
    def test_catch_up_from_origin_skips_and_names_a_repository_without_origin(self):
        self.stale_task('done')
        self.assert_repository_skipped('no origin')
    def test_catch_up_from_origin_skips_an_unreachable_origin_and_does_not_use_the_last_fetched_state(self):
        self.stale_task('done')
        self.origin()
        self.assertEqual(self.git('rev-parse', 'refs/remotes/origin/'+self.branch).stdout, self.git('rev-parse', 'HEAD').stdout)
        self.git('remote', 'set-url', 'origin', str(self.root/'gone.git'))
        self.assert_repository_skipped('origin unreachable')
    def test_catch_up_from_origin_skips_a_repository_whose_fetch_fails(self):
        self.stale_task('done')
        self.origin()
        self.fake_git('  [ "$argument" = fetch ] && exit 1')
        self.assert_repository_skipped('fetch failed')
    def test_catch_up_from_origin_gives_up_on_an_origin_that_hangs(self):
        self.stale_task('done')
        self.origin()
        mark = self.root/'hanging.pid'
        self.hanging_git(mark)
        self.env['MSTACK_PAPERCLIP_FETCH_TIMEOUT'] = '1'
        started = time.monotonic()
        self.assert_repository_skipped('origin unreachable')
        self.assertLess(time.monotonic()-started, 25)
        self.assert_gone(mark)
    def hanging_git(self, mark):
        # The call that hangs is a child of the fake git, as a transport helper is a child of git.
        self.fake_git('  [ "$argument" = ls-remote ] && { sleep 60 & echo $! > %s; wait; }' % mark)
    def assert_gone(self, mark):
        """The hanging call is gone, not left behind."""
        def alive():
            try:
                os.kill(int(mark.read_text()), 0)
            except ProcessLookupError:
                return False
            return True
        deadline = time.monotonic()+5
        while alive() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(alive())
    def test_catch_up_from_origin_told_to_stop_leaves_no_hanging_call_behind(self):
        self.stale_task('done')
        self.origin()
        mark = self.root/'hanging.pid'
        self.hanging_git(mark)
        calls, ledgers = list(self.net.calls), self.ledgers()
        job = subprocess.Popen(['bash', str(characterization.SCRIPTS/'paperclip_lifecycle.sh'), 'catch-up', '--repo', str(self.repo), '--from-origin', '--apply'],
                               cwd=self.repo, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        deadline = time.monotonic()+20
        while not (mark.exists() and mark.read_text().strip()) and time.monotonic() < deadline:
            time.sleep(0.1)
        job.terminate()
        self.assertEqual((job.communicate(timeout=20)[0], job.returncode), (b'', 143))
        self.assert_gone(mark)
        self.assertEqual((self.net.calls, self.ledgers()), (calls, ledgers))
    def test_catch_up_from_origin_skips_a_repository_whose_plan_files_cannot_be_read(self):
        self.stale_task('done')
        self.origin()
        self.fake_git('  [ "$argument" = cat-file ] && exit 1')
        self.assert_repository_skipped('origin plan files unreadable')
    def test_catch_up_from_origin_skips_an_origin_whose_default_branch_is_called_HEAD(self):
        self.stale_task('done')
        self.origin()
        self.git('remote', 'set-head', 'origin', self.branch)
        self.run_cmd(['git', 'update-ref', 'refs/heads/HEAD', self.git('rev-parse', 'HEAD~1').stdout.strip()], cwd=self.bare)
        self.run_cmd(['git', 'symbolic-ref', 'HEAD', 'refs/heads/HEAD'], cwd=self.bare)
        ref = self.git('rev-parse', 'refs/remotes/origin/'+self.branch).stdout
        self.assert_repository_skipped('origin names no default branch')
        self.assertEqual(self.git('rev-parse', 'refs/remotes/origin/'+self.branch).stdout, ref)
    def test_catch_up_from_origin_runs_git_unattended_and_keeps_the_ssh_command_of_the_repository(self):
        self.stale_task('done')
        self.origin()
        seen = self.root/'seen.txt'
        self.fake_git('  [ "$argument" = ls-remote ] && echo "$GIT_TERMINAL_PROMPT|$GIT_NO_REPLACE_OBJECTS|${GIT_SSH_COMMAND-none}" > %s' % seen)
        self.env.pop('GIT_SSH_COMMAND', None)
        self.from_origin()
        self.assertEqual(seen.read_text().strip(), '0|1|ssh -o BatchMode=yes -o ConnectTimeout=10')
        self.git('config', 'core.sshCommand', 'ssh -i fixture-key')
        self.from_origin()
        self.assertEqual(seen.read_text().strip(), '0|1|none')
        self.env['GIT_SSH_COMMAND'] = 'ssh -F fixture-config'
        self.from_origin()
        self.assertEqual(seen.read_text().strip(), '0|1|ssh -F fixture-config')
    def test_catch_up_from_origin_does_not_close_a_task_of_another_plan_with_the_same_number(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        # A branch that is not merged took number 2 for its plan and has a task for it...
        self.git('checkout', '-q', '-b', 'side')
        second = self.second_plan(2, 'in-progress')
        self.assertEqual(self.boundary('claimed', second)['delivery'], 'delivered')
        # ...and origin's default branch took number 2 for a different plan, which is done.
        def edit(other):
            text = (other/'docs/plans/001-disposable.md').read_text()
            (other/'docs/plans/002-unrelated.md').write_text(text.replace('id: 1', 'id: 2').replace('Disposable lifecycle fixture', 'Unrelated plan').replace('status: in-progress', 'status: done'))
        self.upstream(edit)
        writes = self.writes()
        report = self.from_origin('--apply')
        self.assertEqual((report['changes'], [(s['plan'], s['title']) for s in report['skipped']]), ([], [('2', 'Unrelated plan')]))
        self.assertIn('the number may be reused', report['skipped'][0]['reason'])
        self.assertEqual((self.writes(), self.net.issues['2']['status'], self.net.issues['2']['title']), (writes, 'in_progress', 'Second fixture'))
    def adopted_task(self, source):
        """A task taken over by adoption: board title "Plan 001: ...", no report of its own, and an adoption record when source is given."""
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        directory = config.binding_path(self.repo).parent
        state = json.loads((directory/'events.json').read_text())
        state['events'] = []
        (directory/'events.json').write_text(json.dumps(state))
        self.net.issues['1']['title'] = 'Plan 001: Disposable lifecycle fixture'
        if source:
            (directory/'adoption.json').write_text(json.dumps({'version': 1, 'writer': 'native-mstack', 'records': [
                {'source': source, 'issue_id': '1', 'plan_id': '1', 'state': {'status': 'pending', 'location': source}}]}))
    def upstream_replace(self, name, title):
        """On origin, replace the plan file by one at name with this title, marked done."""
        def edit(other):
            old = other/self.plan.relative_to(self.repo)
            text = old.read_text().replace('Disposable lifecycle fixture', title).replace('status: in-progress', 'status: done')
            old.unlink()
            (other/name).parent.mkdir(parents=True, exist_ok=True)
            (other/name).write_text(text)
        self.upstream(edit)
    def test_catch_up_from_origin_closes_a_task_adopted_from_a_plan_file_of_the_same_name_moved_to_archive(self):
        self.adopted_task('docs/plans/001-disposable.md')
        # Neither the board title nor the plan title (renamed since) matches; the file name does.
        self.upstream_replace('docs/plans/archive/001-disposable.md', 'Renamed fixture')
        report = self.from_origin('--apply')
        self.assertEqual(([(c['plan'], c['to'], c['delivery']) for c in report['changes']], report['skipped']), ([('1', 'done', 'delivered')], []))
        self.assertEqual(self.net.issues['1']['status'], 'done')
        self.assertIn(self.NOTE, self.net.comments['1'][-1]['body'])
    def test_catch_up_from_origin_refuses_an_adopted_task_when_the_number_comes_with_a_new_file_name(self):
        self.adopted_task('docs/plans/001-disposable.md')
        self.upstream_replace('docs/plans/001-another-plan.md', 'Another plan')
        writes = self.writes()
        report = self.from_origin('--apply')
        self.assertEqual((report['changes'], [(s['plan'], s['title']) for s in report['skipped']]), ([], [('1', 'Another plan')]))
        self.assertIn('the number may be reused', report['skipped'][0]['reason'])
        self.assertEqual((self.writes(), self.net.issues['1']['status']), (writes, 'in_progress'))
    def test_catch_up_from_origin_refuses_a_task_whose_adoption_record_names_another_task_or_plan(self):
        self.adopted_task('docs/plans/001-disposable.md')
        self.upstream_replace('docs/plans/archive/001-disposable.md', 'Renamed fixture')
        adoption = config.binding_path(self.repo).parent/'adoption.json'
        record = json.loads(adoption.read_text())['records'][0]
        writes = self.writes()
        for other in (dict(record, issue_id='2'), dict(record, plan_id='2'), dict(record, plan_id=None)):
            adoption.write_text(json.dumps({'version': 1, 'writer': 'native-mstack', 'records': [other]}))
            report = self.from_origin('--apply')
            self.assertEqual((report['changes'], [s['plan'] for s in report['skipped']]), ([], ['1']))
            self.assertIn('the number may be reused', report['skipped'][0]['reason'])
        self.assertEqual((self.writes(), self.net.issues['1']['status']), (writes, 'in_progress'))
    def test_catch_up_from_origin_refuses_a_task_with_another_title_and_no_adoption_record(self):
        self.adopted_task(None)
        self.upstream_replace('docs/plans/archive/001-disposable.md', 'Renamed fixture')
        writes = self.writes()
        report = self.from_origin('--apply')
        self.assertEqual((report['changes'], [s['plan'] for s in report['skipped']]), ([], ['1']))
        self.assertIn('the number may be reused', report['skipped'][0]['reason'])
        self.assertEqual((self.writes(), self.net.issues['1']['status']), (writes, 'in_progress'))
    def test_catch_up_from_origin_ignores_a_local_replacement_of_a_plan_file(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        self.upstream_status('done')
        self.assertEqual(self.from_origin()['counts']['would_apply'], 1)
        path = str(self.plan.relative_to(self.repo))
        self.git('replace', self.git('rev-parse', 'refs/remotes/origin/'+self.branch+':'+path).stdout.strip(), self.git('rev-parse', 'HEAD:'+path).stdout.strip())
        self.assertIn('status: in-progress', self.git('show', 'refs/remotes/origin/'+self.branch+':'+path).stdout)
        self.assertEqual([c['delivery'] for c in self.from_origin('--apply')['changes']], ['delivered'])
    def test_catch_up_from_origin_skips_an_origin_that_names_no_default_branch(self):
        self.stale_task('done')
        self.origin()
        self.run_cmd(['git', 'update-ref', '--no-deref', 'HEAD', self.git('rev-parse', 'HEAD').stdout.strip()], cwd=self.bare)
        self.assert_repository_skipped('origin names no default branch')
    def test_catch_up_from_origin_asks_origin_for_its_default_branch(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        self.git('remote', 'set-head', 'origin', self.branch)
        tip = self.upstream_status('done', 'trunk')
        self.run_cmd(['git', 'symbolic-ref', 'HEAD', 'refs/heads/trunk'], cwd=self.bare)
        report = self.from_origin('--apply')
        self.assertEqual((report['source']['branch'], report['source']['commit'], [c['delivery'] for c in report['changes']]), ('trunk', tip, ['delivered']))
    def test_catch_up_from_origin_shows_but_never_acts_on_a_plan_that_is_only_local(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        second = self.second_plan(2, 'in-progress')
        self.assertEqual(self.boundary('claimed', second)['delivery'], 'delivered')
        self.local_status('done', second)
        # And an edit that was never committed anywhere.
        self.plan.write_text(self.plan.read_text().replace('status: in-progress', 'status: done'))
        writes = self.writes()
        report = self.from_origin('--apply')
        self.assertEqual((report['changes'], report['skipped'], [a['plan'] for a in report['attention']]), ([], [], ['1']))
        self.assertEqual((report['source']['absent'], report['counts']['skipped'], self.writes()), (['2'], 0, writes))
        self.assertEqual((self.net.issues['1']['status'], self.net.issues['2']['status']), ('in_progress', 'in_progress'))
    def test_catch_up_from_origin_is_not_stopped_by_an_uncommitted_local_edit(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        self.upstream_status('done')
        self.plan.write_text(self.plan.read_text()+'\nlocal scribble\n')
        scribbled = self.plan.read_bytes()
        self.assertEqual([c['delivery'] for c in self.from_origin('--apply')['changes']], ['delivered'])
        self.assertEqual(self.plan.read_bytes(), scribbled)
    def test_catch_up_from_origin_fetch_writes_one_remote_ref_and_nothing_else(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        self.git('tag', 'local-tag')
        (self.repo/'AGENTS.md').write_text('stashed edit\n')
        self.git('stash', 'push', '-q')
        (self.repo/'AGENTS.md').write_text('open edit\n')
        (self.repo/'untracked.txt').write_text('untracked\n')
        self.git('add', 'untracked.txt')
        self.run_cmd(['git', 'branch', 'elsewhere'], cwd=self.bare)
        self.run_cmd(['git', 'tag', 'upstream-tag'], cwd=self.bare)
        self.git('bundle', 'create', '-q', str(self.root/'fixture.bundle'), self.branch)
        self.git('config', 'fetch.bundleURI', (self.root/'fixture.bundle').as_uri())
        tip = self.upstream_status('done')
        remote_refs = lambda: self.git('for-each-ref', '--format=%(refname) %(objectname)').stdout.split('\n')
        before, outside, writes, ledgers = remote_refs(), self.outside_remote_refs(), self.writes(), self.ledgers()
        report = self.from_origin()
        self.assertEqual((report['mode'], report['counts']['would_apply'], report['source']['commit']), ('dry-run', 1, tip))
        self.assertEqual(self.outside_remote_refs(), outside)
        ref = 'refs/remotes/origin/'+self.branch
        self.assertEqual([line for line in remote_refs() if line not in before], [ref+' '+tip])
        self.assertEqual(len(remote_refs()), len(before))
        self.assertFalse((self.repo/'.git/FETCH_HEAD').exists())
        self.assertEqual((self.writes(), self.ledgers()), (writes, ledgers))
    def test_catch_up_from_origin_never_moves_a_local_branch_whatever_the_configured_refspec(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        self.git('config', 'remote.origin.fetch', '+refs/heads/*:refs/heads/*')
        self.git('config', 'remote.origin.tagOpt', '--tags')
        self.run_cmd(['git', 'tag', 'upstream-tag'], cwd=self.bare)
        self.upstream_status('done')
        self.git('checkout', '-q', '--detach')
        outside = self.outside_remote_refs()
        self.assertEqual([c['delivery'] for c in self.from_origin('--apply')['changes']], ['delivered'])
        self.assertEqual(self.outside_remote_refs(), outside)
    def test_catch_up_from_origin_reads_the_plan_files_of_origin_like_those_of_a_checkout(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        def edit(other):
            plans = other/'docs/plans'
            (plans/'unreadable.md').write_bytes(b'---\nid: 1\n\xff\xfe---\n')
            (plans/'link.md').symlink_to('001-disposable.md')
            (plans/'notes.txt').write_text((plans/'001-disposable.md').read_text())
            plan = plans/'001-disposable.md'
            plan.write_bytes(plan.read_text().replace('status: in-progress', 'status: dropped').replace('\n', '\r\n').encode())
        self.upstream(edit)
        self.assertEqual([(c['to'], c['delivery']) for c in self.from_origin('--apply')['changes']], [('cancelled', 'delivered')])
        def duplicate(other):
            (other/'plans').mkdir()
            (other/'plans/001-again.md').write_text((other/'docs/plans/001-disposable.md').read_text())
        self.net.issues['1'].update(status='in_progress')
        self.upstream(duplicate)
        events = config.binding_path(self.repo).parent/'events.json'
        state = json.loads(events.read_text())
        state['mappings']['1']['status'] = 'in_progress'
        events.write_text(json.dumps(state))
        report = self.from_origin('--apply')
        self.assertEqual((report['changes'], [s['reason'] for s in report['skipped']]), ([], ['plan number is used more than once']))
    def test_catch_up_from_origin_refuses_an_origin_branch_without_plans(self):
        self.assertEqual(self.boundary('claimed')['delivery'], 'delivered')
        self.origin()
        def edit(other):
            self.run_cmd(['git', 'rm', '-rq', 'docs'], cwd=other)
        self.upstream(edit)
        writes = self.writes()
        self.assertEqual((self.from_origin('--apply')['delivery'], self.writes()), ('conflict', writes))
        self.assertEqual(self.catch_up()['mode'], 'dry-run')
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
