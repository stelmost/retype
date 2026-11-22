#!/usr/bin/env python3
"""Synthetic checks for installed-archive evidence assertions, not production fidelity."""
import copy
import io
from pathlib import Path
import tempfile
import tomllib
import unittest
from unittest import mock

from installed import installed_fidelity_matches_builds, main, remove_windows_installation, review_inputs, without_installer_path


MANIFEST = tomllib.loads("""
version = 'retype-fidelity-1'
[[claim]]
source = 'png'
target = 'jpg'
backend = 'magick'
tier = 'converted'
engine = 'synthetic-engine'
version = '7.1.2'
fingerprint = 'backend-build'
engine_version = '0.11.1'
engine_fingerprint = 'engine-build'
fixture = 'synthetic reporting fixture'
earned = 1
""")
BUILDS = {field: MANIFEST['claim'][0][field] for field in
          ('version', 'fingerprint', 'engine_version', 'engine_fingerprint')}


def output(state='earned'):
    return {'format': 'jpg', 'fidelity': {
        **BUILDS, 'state': state, 'claim': dict(MANIFEST['claim'][0]),
    }}


def job(outputs):
    return {'source': {'format': 'png'}, 'backend': 'magick',
            'engine': {'candidate': 'synthetic-engine'}, 'outputs': outputs}


class InstalledArchiveTests(unittest.TestCase):
    def test_matching_builds_require_earned_evidence(self):
        self.assertTrue(installed_fidelity_matches_builds(job([output()]), MANIFEST))
        self.assertFalse(installed_fidelity_matches_builds(job([output('unverified')]), MANIFEST))

    def test_each_changed_build_requires_unverified_evidence(self):
        for field in BUILDS:
            with self.subTest(field=field):
                changed = output('unverified')
                changed['fidelity'][field] = 'another build'
                self.assertTrue(installed_fidelity_matches_builds(job([output(), changed]), MANIFEST))
                changed['fidelity']['state'] = 'earned'
                self.assertFalse(installed_fidelity_matches_builds(job([changed]), MANIFEST))

    def test_no_engine_uses_empty_engine_builds(self):
        current = output()
        manifest = copy.deepcopy(MANIFEST)
        request = job([current])
        del request['engine']
        for field in ('engine', 'engine_version', 'engine_fingerprint'):
            del manifest['claim'][0][field]
            del current['fidelity']['claim'][field]
        current['fidelity'].update(engine_version='', engine_fingerprint='')
        self.assertTrue(installed_fidelity_matches_builds(request, manifest))

    def test_missing_claim_is_not_installed_evidence(self):
        self.assertFalse(installed_fidelity_matches_builds(job([]), MANIFEST))
        missing = output('new')
        del missing['fidelity']['claim']
        self.assertFalse(installed_fidelity_matches_builds(job([missing]), MANIFEST))

    def test_self_consistent_json_cannot_replace_the_packaged_record(self):
        for field in ('fixture', 'fingerprint'):
            with self.subTest(field=field):
                wrong = output()
                wrong['fidelity']['claim'][field] = 'another manifest'
                if field in BUILDS:
                    wrong['fidelity'][field] = 'another manifest'
                self.assertFalse(installed_fidelity_matches_builds(job([wrong]), MANIFEST))
        wrong_target = output()
        wrong_target['format'] = 'webp'
        self.assertFalse(installed_fidelity_matches_builds(job([wrong_target]), MANIFEST))

    def test_review_snapshot_detects_changes_before_consent(self):
        with tempfile.TemporaryDirectory() as private:
            work = Path(private) / 'work'
            state = Path(private) / 'state'
            original = state / 'undo' / 'job' / 'source.HEIC'
            operation = state / 'recovery' / 'operation.json'
            work.mkdir()
            original.parent.mkdir(parents=True)
            operation.parent.mkdir()
            paths = [work / 'photo.jpg', work / 'photo.webp', original, operation, state / 'jobs.jsonl']
            for path in paths:
                path.write_bytes(b'before')
            before = review_inputs(work, state)
            for path in paths:
                with self.subTest(path=path.name):
                    path.write_bytes(b'edited')
                    self.assertNotEqual(review_inputs(work, state), before)
                    path.write_bytes(b'before')
            self.assertEqual(review_inputs(work, state), before)
            (work / 'photo.HEIC').write_bytes(b'restored')
            self.assertNotEqual(review_inputs(work, state), before)

    def test_windows_removal_uses_the_same_command_and_a_child_only_action(self):
        command = ['pwsh', '-NoProfile', '-NonInteractive', '-File', 'packaging/install.ps1']
        installer = command.copy()
        env = {'RETYPE_INSTALL_MODE': 'preview', 'RETYPE_PREFIX': r'C:\fixture'}
        original = env.copy()
        run = mock.Mock()
        remove_windows_installation(run, installer, env)
        run.assert_called_once_with('uninstall', command, child_env=original | {'RETYPE_ACTION': 'remove'})
        self.assertEqual(env, original)
        self.assertEqual(installer, command)

    def test_path_cleanup_removes_only_the_installer_added_token(self):
        binary_dir = r'C:\fixture\bin'
        cases = [
            (r';C:\Old;;C:\fixture\bin;C:\New;', r';C:\Old;;', r';C:\Old;;C:\New;'),
            (r'c:\FIXTURE\BIN;C:\New', None, r'C:\New'),
            (r'c:/fixture/bin/; C:\fixture\bin ;' + binary_dir, None, r'c:/fixture/bin/; C:\fixture\bin '),
            (binary_dir, None, None),
            (binary_dir + ';', None, ''),
            (binary_dir, '', ''),
            (None, '', None),
            (r'C:\New;' + binary_dir, binary_dir, r'C:\New;' + binary_dir),
        ]
        for current, before, expected in cases:
            with self.subTest(current=current, before=before):
                self.assertEqual(without_installer_path(current, before, binary_dir), expected)

    def test_scope_and_user_consent_refuse_before_any_archive_or_command(self):
        cases = [
            ('linux', [], 'required'),
            ('win32', ['--preview'], 'Windows requires --preview-cli-only'),
            ('win32', ['--preview-cli-only'], 'approve a disposable session first'),
            ('darwin', ['--preview'], 'approve a disposable session first'),
            ('linux', ['--preview-cli-only'], 'other hosts require --preview'),
        ]
        for host, options, message in cases:
            with self.subTest(host=host, options=options), \
                 mock.patch('installed.os.name', 'nt' if host == 'win32' else 'posix'), \
                 mock.patch('installed.sys.platform', host), mock.patch('installed.Path'), \
                 mock.patch('installed.sys.argv', ['installed.py', 'unused.tar.gz', '--report', 'unused', *options]), \
                 mock.patch('installed.sys.stderr', io.StringIO()) as stderr, \
                 mock.patch('installed.tarfile.open') as archive, \
                 mock.patch('installed.subprocess.Popen') as command:
                with self.assertRaises(SystemExit) as refused:
                    main()
                self.assertEqual(refused.exception.code, 2)
                self.assertIn(message, stderr.getvalue())
                archive.assert_not_called()
                command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
