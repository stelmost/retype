#!/usr/bin/env python3
"""Synthetic checks for installed-archive evidence assertions, not production fidelity."""
import unittest

from installed import installed_fidelity_matches_builds


BUILDS = {
    'version': '7.1.2',
    'fingerprint': 'backend-build',
    'engine_version': '0.11.1',
    'engine_fingerprint': 'engine-build',
}


def output(state='earned'):
    return {'fidelity': {**BUILDS, 'state': state, 'claim': dict(BUILDS)}}


class InstalledFidelityTests(unittest.TestCase):
    def test_matching_builds_require_earned_evidence(self):
        self.assertTrue(installed_fidelity_matches_builds([output()]))
        self.assertFalse(installed_fidelity_matches_builds([output('unverified')]))

    def test_each_changed_build_requires_unverified_evidence(self):
        for field in BUILDS:
            with self.subTest(field=field):
                changed = output('unverified')
                changed['fidelity'][field] = 'another build'
                self.assertTrue(installed_fidelity_matches_builds([output(), changed]))
                changed['fidelity']['state'] = 'earned'
                self.assertFalse(installed_fidelity_matches_builds([changed]))

    def test_no_engine_uses_empty_engine_builds(self):
        current = output()
        for field in ('engine_version', 'engine_fingerprint'):
            current['fidelity'][field] = ''
            del current['fidelity']['claim'][field]
        self.assertTrue(installed_fidelity_matches_builds([current]))

    def test_missing_claim_is_not_installed_evidence(self):
        self.assertFalse(installed_fidelity_matches_builds([]))
        missing = output('new')
        del missing['fidelity']['claim']
        self.assertFalse(installed_fidelity_matches_builds([missing]))


if __name__ == '__main__':
    unittest.main()
