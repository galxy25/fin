"""Unit tests for lambda.py's pure decision logic — no AWS, no network, no model.

Deliberately narrow: `_wake_decision` and `_lock_is_stale` are pure functions
(every input already fetched, no I/O inside), so they're tested directly with
plain values. The I/O-touching wrappers around them (`wake`, `_claim_lock`,
`_launch_worker`, ...) are verified by hand-curl against the deployed endpoint,
the same way every other AWS-touching route in this file already is — see
control-plane/README.md.

Run: python3 test_lambda.py
"""

import importlib.util
import os
import unittest
from datetime import datetime, timedelta, timezone

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("cp_lambda", os.path.join(_HERE, "lambda.py"))
lam = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lam)


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


NOW = datetime(2026, 9, 9, 12, 0, 0, tzinfo=timezone.utc)


class LockIsStaleTests(unittest.TestCase):
    def test_no_lock_is_stale(self):
        self.assertTrue(lam._lock_is_stale(None, NOW))

    def test_unparseable_claimed_at_is_stale(self):
        self.assertTrue(lam._lock_is_stale({"holder": "x", "claimedAt": "not-a-date"}, NOW))

    def test_fresh_claim_is_not_stale(self):
        lock = {"holder": "x", "claimedAt": _iso(NOW - timedelta(minutes=1))}
        self.assertFalse(lam._lock_is_stale(lock, NOW))

    def test_claim_older_than_ttl_is_stale(self):
        lock = {"holder": "x", "claimedAt": _iso(NOW - timedelta(minutes=6))}
        self.assertTrue(lam._lock_is_stale(lock, NOW))

    def test_claim_at_exactly_the_ttl_boundary_is_not_yet_stale(self):
        lock = {"holder": "x", "claimedAt": _iso(NOW - timedelta(seconds=lam.LOCK_STALE_AFTER_SECONDS))}
        self.assertFalse(lam._lock_is_stale(lock, NOW))


class WakeDecisionTests(unittest.TestCase):
    """The wake sweep's whole safety story lives in this one pure function —
    every case here is a live failure mode the design was built to avoid:
    double-launching a worker, launching one nobody needed, or (the live
    incident that added the notify ceiling) spending real money auto-launching
    a worker for an agent whose inbox message is probably abandoned debris."""

    def _old_enough(self, minutes=lam.WAKE_GRACE_MINUTES + 1):
        return NOW - timedelta(minutes=minutes)

    def _past_ceiling(self):
        return NOW - timedelta(hours=lam.WAKE_NOTIFY_CEILING_HOURS + 1)

    def test_no_inbox_never_wakes(self):
        self.assertEqual(lam._wake_decision(False, None, None, None, NOW), (None, None))

    def test_a_live_worker_already_covers_the_agent(self):
        action, _ = lam._wake_decision(True, None, self._old_enough(), None, NOW)
        self.assertIsNone(action)

    def test_a_fresh_non_stale_lock_means_someone_is_already_driving(self):
        lock = {"holder": "mac-daemon", "claimedAt": _iso(NOW - timedelta(seconds=5))}
        action, _ = lam._wake_decision(False, lock, self._old_enough(), None, NOW)
        self.assertIsNone(action)

    def test_a_stale_lock_does_not_block_waking(self):
        lock = {"holder": "crashed-worker", "claimedAt": _iso(NOW - timedelta(minutes=10))}
        action, _ = lam._wake_decision(False, lock, self._old_enough(), None, NOW)
        self.assertEqual(action, "wake")

    def test_a_message_still_inside_the_grace_period_is_not_woken(self):
        # An active poller should get a fair chance to claim it first.
        fresh = NOW - timedelta(minutes=lam.WAKE_GRACE_MINUTES - 1)
        action, _ = lam._wake_decision(False, None, fresh, None, NOW)
        self.assertIsNone(action)

    def test_a_message_already_answered_by_a_later_turn_is_not_woken(self):
        status = {"last_turn_at": _iso(NOW - timedelta(minutes=1))}
        inbox_touched = NOW - timedelta(minutes=lam.WAKE_GRACE_MINUTES + 5)
        action, _ = lam._wake_decision(False, None, inbox_touched, status, NOW)
        self.assertIsNone(action)

    def test_a_turn_at_the_exact_same_moment_counts_as_answered(self):
        touched = self._old_enough()
        status = {"last_turn_at": _iso(touched)}
        action, _ = lam._wake_decision(False, None, touched, status, NOW)
        self.assertIsNone(action)

    def test_an_unanswered_message_past_grace_with_nothing_covering_it_wakes(self):
        status = {"last_turn_at": _iso(NOW - timedelta(hours=2))}
        action, _ = lam._wake_decision(False, None, self._old_enough(), status, NOW)
        self.assertEqual(action, "wake")

    def test_no_status_at_all_and_an_old_enough_message_still_wakes(self):
        # A first-time cloud-only user: no site has EVER answered this agent.
        action, _ = lam._wake_decision(False, None, self._old_enough(), None, NOW)
        self.assertEqual(action, "wake")

    # --- the 72-hour notify ceiling --------------------------------------

    def test_a_message_past_the_ceiling_notifies_instead_of_waking(self):
        action, detail = lam._wake_decision(False, None, self._past_ceiling(), None, NOW)
        self.assertEqual(action, "notify")
        self.assertIn("72", detail)

    def test_a_message_just_under_the_ceiling_still_wakes(self):
        just_under = NOW - timedelta(hours=lam.WAKE_NOTIFY_CEILING_HOURS - 1)
        action, _ = lam._wake_decision(False, None, just_under, None, NOW)
        self.assertEqual(action, "wake")

    def test_a_stale_lock_past_the_ceiling_still_notifies_not_wakes(self):
        lock = {"holder": "crashed-worker", "claimedAt": _iso(NOW - timedelta(hours=100))}
        action, _ = lam._wake_decision(False, lock, self._past_ceiling(), None, NOW)
        self.assertEqual(action, "notify")

    def test_a_live_worker_suppresses_notify_too(self):
        action, _ = lam._wake_decision(True, None, self._past_ceiling(), None, NOW)
        self.assertIsNone(action)


class AlreadyNotifiedTests(unittest.TestCase):
    """`_already_notified` reads via `_read_lock` (I/O) so it isn't pure, but
    its comparison logic is worth pinning directly against a stubbed reader —
    this is the "surfaced once, then sit quiet" guarantee that keeps a
    permanently-stale inbox from paging the user every single minute."""

    def setUp(self):
        self._orig = lam._read_lock

    def tearDown(self):
        lam._read_lock = self._orig

    def test_no_marker_means_not_yet_notified(self):
        lam._read_lock = lambda key: None
        self.assertFalse(lam._already_notified("Nimbus", NOW))

    def test_marker_for_the_same_message_suppresses_a_repeat(self):
        touched = NOW - timedelta(hours=100)
        lam._read_lock = lambda key: {"forLastModified": _iso(touched)}
        self.assertTrue(lam._already_notified("Nimbus", touched))

    def test_a_newer_message_since_the_marker_notifies_again(self):
        old_touch = NOW - timedelta(hours=200)
        lam._read_lock = lambda key: {"forLastModified": _iso(old_touch)}
        new_touch = NOW - timedelta(hours=80)
        self.assertFalse(lam._already_notified("Nimbus", new_touch))


if __name__ == "__main__":
    unittest.main()
