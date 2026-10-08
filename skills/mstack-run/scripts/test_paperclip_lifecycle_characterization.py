"""Pre-change characterization of the documented local Step 7a sequence.

These fixtures execute existing gate CLIs and Git operations, rather than a new
completion helper. Their explicit order pins the existing orchestration contract.
Every repository, HOME, config, index and remote is disposable; Git accepts file
transport only. No Paperclip runtime or network is needed.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class LifecycleCharacterization(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.home = self.root / 'home'
        self.home.mkdir()
        environment = dict(os.environ)
        names = subprocess.check_output(['git', 'rev-parse', '--local-env-vars'], text=True).splitlines()
        for name in names:
            environment.pop(name, None)
        environment.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home/'config'),
                           GIT_CONFIG_GLOBAL=str(self.home/'gitconfig'), GIT_CONFIG_NOSYSTEM='1',
                           GIT_ALLOW_PROTOCOL='file')
        self.env = environment
        self.run_cmd(['git', 'init', '-q', str(self.repo)], cwd=self.root)
        self.git('config', 'user.name', 'Disposable Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.plan = self.repo / 'docs/plans/001-disposable.md'
        self.plan.parent.mkdir(parents=True)
        self.plan.write_text('''---
id: 1
title: Disposable lifecycle fixture
status: in-progress
blocked-by: []
needs-review: none
review-required: code
created: 2026-10-07
---

## Requirements
- Produce fixture output.
## Tasks
1. Produce output.
2. Verify output.
## Verification
- [cmd] test -f output.txt
''')
        (self.repo/'AGENTS.md').write_text('## Health Stack\n\n- none: disposable fixture has no health tools\n')
        (self.repo/'.gitignore').write_text('.mstack/\n')
        self.git('add', 'docs', 'AGENTS.md', '.gitignore')
        self.git('commit', '-qm', 'initial fixture')
        (self.repo/'.mstack').mkdir()
        (self.repo/'.mstack/pre-dirty-1.txt').write_text('')
        self.result = self.repo/'.mstack/result-1.txt'
        self.result.write_text('---MSTACK-RESULT---\nSTATUS: pass\nHEALTH_VERDICT: NONE-DECLARED\nHEALTH_COMPOSITE: n/a\n---END---\n')
        self.archive = self.repo/'docs/plans/archive/001-disposable.md'
        self.tag = 'mstack/plan-1-done'
    def tearDown(self):
        self.tmp.cleanup()
    def run_cmd(self, command, cwd=None, check=True):
        result = subprocess.run(command, cwd=cwd or self.repo, env=self.env,
                                capture_output=True, text=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        return result
    def git(self, *args, check=True):
        return self.run_cmd(['git', *args], check=check)
    def gate(self, script, operation, *args, check=True):
        relative = [str(arg.relative_to(self.repo)) if isinstance(arg, Path) else str(arg) for arg in args]
        return self.run_cmd(['bash', str(SCRIPTS/script), operation, *relative], check=check)
    def approve_fixture(self):
        # This is synthetic fixture verdict data, not approval of product code.
        self.gate('review-gate.sh', 'record', self.plan, 'code', 'pass', 'mstack-code-review')
        self.git('add', str(self.plan.relative_to(self.repo)))
        self.git('commit', '-qm', 'fixture review recorded')
    def complete_before_archive(self):
        self.gate('result-gate.sh', 'assert-health-result', self.result)
        self.gate('review-gate.sh', 'assert-completable', self.plan)
        self.gate('review-gate.sh', 'assert-no-downgrade', self.plan)
        self.plan.write_text(self.plan.read_text().replace('status: in-progress', 'status: done'))
        (self.repo/'output.txt').write_text('verified fixture output\n')
        self.git('add', 'docs/plans/001-disposable.md', 'output.txt')
        self.git('commit', '-qm', 'fixture completed work')
        # Real sequence has a hash-backfill amend before the work-committed gate.
        content = self.plan.read_text()+'\n## Implementation Notes\nWork commit: '+self.git('rev-parse','HEAD').stdout.strip()+'\n'
        self.plan.write_text(content)
        self.git('add', 'docs/plans/001-disposable.md')
        self.git('commit', '--amend', '--no-edit')
        self.gate('review-gate.sh', 'assert-work-committed', self.plan)
    def assert_no_completion(self):
        self.assertTrue(self.plan.exists())
        self.assertFalse(self.archive.exists())
        self.assertNotEqual(self.git('rev-parse', '--verify', 'refs/tags/'+self.tag, check=False).returncode, 0)
    def test_watched_success_archive_and_tag_order(self):
        health = self.run_cmd(['bash', str(SCRIPTS/'health-check.sh'), 'run'])
        self.assertIn('VERDICT:NONE-DECLARED', health.stdout)
        self.assertIn('COMPOSITE:n/a', health.stdout)
        self.approve_fixture()
        self.complete_before_archive()
        self.assert_no_completion()  # Committed work alone is not archive/tag completion.
        self.archive.parent.mkdir()
        self.git('mv', str(self.plan.relative_to(self.repo)), str(self.archive.relative_to(self.repo)))
        self.git('commit', '-qm', 'fixture archive')
        self.git('tag', '-a', self.tag, '-m', 'fixture completion')
        self.assertFalse(self.plan.exists())
        self.assertTrue(self.archive.exists())
        self.assertEqual(self.git('rev-parse', self.tag+'^{commit}').stdout, self.git('rev-parse', 'HEAD').stdout)
        self.assertEqual(self.git('status','--porcelain').stdout, '')
        self.gate('review-gate.sh', 'assert-completable', self.archive)
        print('WATCHED: work commit -> clean gate -> archive commit -> completion tag; all local file-only Git')
    def test_missing_review_blocks_before_done(self):
        result = self.gate('review-gate.sh', 'assert-completable', self.plan, check=False)
        self.assertEqual(result.returncode, 23)
        self.assertIn('status: in-progress', self.plan.read_text())
        self.assert_no_completion()
    def test_failed_health_result_blocks_before_done(self):
        self.approve_fixture()
        self.result.write_text('---MSTACK-RESULT---\nSTATUS: pass\nHEALTH_VERDICT: FAIL\nHEALTH_COMPOSITE: 2\n---END---\n')
        self.assertEqual(self.gate('result-gate.sh','assert-health-result',self.result,check=False).returncode,30)
        self.assertIn('status: in-progress',self.plan.read_text())
        self.assert_no_completion()
    def test_uncommitted_work_gate_prevents_archive_and_tag(self):
        self.approve_fixture()
        (self.repo/'output.txt').write_text('uncommitted output')
        self.assertEqual(self.gate('review-gate.sh','assert-work-committed',self.plan,check=False).returncode,28)
        self.assert_no_completion()
    def test_archive_failure_leaves_committed_work_without_tag(self):
        self.approve_fixture()
        self.complete_before_archive()
        self.archive.parent.mkdir()
        self.archive.write_text('existing unrelated archived artifact')
        result = self.git('mv',str(self.plan.relative_to(self.repo)),str(self.archive.relative_to(self.repo)),check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertTrue(self.plan.exists())
        self.assertEqual(self.archive.read_text(),'existing unrelated archived artifact')
        self.assertNotEqual(self.git('rev-parse','--verify','refs/tags/'+self.tag,check=False).returncode,0)
    def test_tag_failure_retains_archived_state_without_done_tag(self):
        self.approve_fixture()
        self.complete_before_archive()
        self.archive.parent.mkdir()
        self.git('mv',str(self.plan.relative_to(self.repo)),str(self.archive.relative_to(self.repo)))
        self.git('commit','-qm','fixture archive')
        # Git cannot create the desired ref beneath an existing parent ref.
        self.git('tag','mstack/plan-1-done/occupied')
        self.assertNotEqual(self.git('tag','-a',self.tag,'-m','fixture completion',check=False).returncode,0)
        self.assertTrue(self.archive.exists())
        self.assertFalse(self.plan.exists())
        self.assertNotEqual(self.git('rev-parse','--verify','refs/tags/'+self.tag,check=False).returncode,0)
    def test_failed_local_outcome_remains_unarchived(self):
        self.plan.write_text(self.plan.read_text().replace('status: in-progress','status: failed')+'\nfailed-reason: fixture verification failed\n')
        self.git('add','docs/plans/001-disposable.md')
        self.git('commit','-qm','fixture failure outcome')
        self.assertIn('status: failed',self.plan.read_text())
        self.assert_no_completion()


if __name__ == '__main__': unittest.main()
