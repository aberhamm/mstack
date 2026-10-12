"""Actual lifecycle CLI boundaries against disposable Git and HTTP fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
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
    def test_disabled_boundary_never_starts_python(self):
        binding=config.binding_path(self.repo);value=json.loads(binding.read_text());value['mode']='disabled';binding.write_text(json.dumps(value))
        fake=self.root/'bin';fake.mkdir();python=fake/'python3';python.write_text('#!/bin/sh\nexit 99\n');python.chmod(0o755)
        self.env['PATH']=str(fake)+':'+self.env['PATH']
        self.assertEqual(self.boundary('done')['delivery'],'disabled')
        self.assertEqual(self.net.calls,[])


for name in list(characterization.LifecycleCharacterization.__dict__):
    if name.startswith('test_') and name not in LifecycleTests.__dict__: setattr(LifecycleTests,name,None)

if __name__ == '__main__': unittest.main()
