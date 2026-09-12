"""Unit tests for lambda.py's pure decision logic — no AWS, no network, no model.

Deliberately narrow: `_wake_decision` and `_lock_is_stale` are pure functions
(every input already fetched, no I/O inside), so they're tested directly with
plain values. The I/O-touching wrappers around them (`wake`, `_claim_lock`,
`_launch_worker`, ...) are verified by hand-curl against the deployed endpoint,
the same way every other AWS-touching route in this file already is — see
control-plane/README.md.

Run: python3 test_lambda.py
"""

import base64
import importlib.util
import json
import os
import re
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


class MergedLastTurnAtTests(unittest.TestCase):
    """`_merged_last_turn_at` is the fix for a live incident (2026-09-10): the
    wake sweep re-launched a redundant cloud worker for "Fin" every ~10-20
    minutes for 10+ hours because it only ever consulted the legacy flat
    status a cloud-launched worker writes, never the resident Mac daemon's
    own per-site status document — so a fully-answered agent looked
    permanently uncovered. This is the pure "which timestamp wins" half of
    that fix; `_known_last_turn_ats` (the S3-listing half that gathers the
    candidates) is an I/O wrapper verified by hand-curl, per this file's
    module docstring."""

    def test_no_candidates_is_none(self):
        self.assertIsNone(lam._merged_last_turn_at([]))

    def test_all_none_is_none(self):
        self.assertIsNone(lam._merged_last_turn_at([None, None]))

    def test_skips_nones_and_returns_the_only_real_value(self):
        t = NOW - timedelta(minutes=5)
        self.assertEqual(lam._merged_last_turn_at([None, t, None]), t)

    def test_a_resident_sites_more_recent_turn_wins_over_a_stale_legacy_status(self):
        # Exactly the live bug: the legacy flat status (an old, dead cloud
        # worker) is frozen hours in the past; the resident Mac site's own
        # status is recent. The merge must surface the recent one.
        stale_legacy = NOW - timedelta(hours=10)
        fresh_site = NOW - timedelta(minutes=1)
        self.assertEqual(lam._merged_last_turn_at([stale_legacy, fresh_site]), fresh_site)

    def test_multiple_sites_take_the_most_recent(self):
        older_site = NOW - timedelta(minutes=30)
        newer_site = NOW - timedelta(minutes=2)
        self.assertEqual(
            lam._merged_last_turn_at([older_site, newer_site, None]), newer_site
        )


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
        self.assertFalse(lam._already_notified("user-1", "Nimbus", NOW))

    def test_marker_for_the_same_message_suppresses_a_repeat(self):
        touched = NOW - timedelta(hours=100)
        lam._read_lock = lambda key: {"forLastModified": _iso(touched)}
        self.assertTrue(lam._already_notified("user-1", "Nimbus", touched))

    def test_a_newer_message_since_the_marker_notifies_again(self):
        old_touch = NOW - timedelta(hours=200)
        lam._read_lock = lambda key: {"forLastModified": _iso(old_touch)}
        new_touch = NOW - timedelta(hours=80)
        self.assertFalse(lam._already_notified("user-1", "Nimbus", new_touch))


def _b64url_uint(value):
    length = (value.bit_length() + 7) // 8
    return base64.urlsafe_b64encode(value.to_bytes(length, "big")).rstrip(b"=").decode()


class AppleIdentityTokenTests(unittest.TestCase):
    """`_verify_apple_identity_token`/`_rsa_pkcs1v15_verify` are hand-rolled
    RS256 (no vendored crypto library — see the doc comment above them), so
    this is the one place in this file where correctness is verified against
    REAL signatures rather than just internal self-consistency: every token
    below was signed by the `cryptography` library (a real, independently-
    implemented RSA implementation) with a throwaway 2048-bit key, generated
    once and hardcoded here — this test file itself has no crypto dependency
    at runtime, only the fixture generation did."""

    # A real RS256-signed token: sub "001234.abcdef1234567890.5678",
    # iss/aud correct, exp far in the future (2100).
    N_HEX = (
        "f97695a2e5f4f78d0e8cb28912321f7babd3f3abcbfe55876f864e6ed6c420210bbb837ef8"
        "16c22daa9ecd60aab26cc355d4f2088545670aec0baae44128b69f2aeb16c2003cae9e2fb0"
        "804ddbeda5b8a19b87920ac7c516c1e0f7827b7662b2704bf2ba90b37966fcd45b570b6d9c"
        "b74f6342c000da8fe377c645c300e091006ceece67897d6c1b1f29c59186b856c39d5aec5"
        "aae89330e99130861b35bc05966467098dcdd19e78365a051f9f5a9da3684ebae4576d3e0"
        "60cfc11445d76672ef8919938bc978fbae46e4863b5b51c64d2a5c4305570f860de1bee86"
        "54623bc2000869c596ff184bf468cc80c78f6dde5b738a89f1238050ca1aa2536574727"
    )
    E = 65537
    KID = "test-key-1"
    TOKEN = (
        "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEifQ."
        "eyJpc3MiOiJodHRwczovL2FwcGxlaWQuYXBwbGUuY29tIiwiYXVkIjoiZGV2LmxldmlzY2hvZW4"
        "uZmluIiwic3ViIjoiMDAxMjM0LmFiY2RlZjEyMzQ1Njc4OTAuNTY3OCIsImV4cCI6NDEwMjQ0ND"
        "gwMCwiaWF0IjoxNzAwMDAwMDAwfQ."
        "7xEMxVdmVJGrXQF_DRScs69lgHYZgmwACXejGyx7eovbWDY8JWlKtccGAxLJRd1bEI_KPTL5IK"
        "-E_Gkm5KnBGGO7X_KHDf91a_dx9EyuDhlmZ3kU60CtI30L5wMhWQYVjFx9tKBugGUQTg6HGuNs"
        "7Rr5y1__Z04tPubcdCOu60Kao4fzQTPuFioSn3O9kLr9TC5ThWUyoAQTGV4srWsjz4TImDDNM4"
        "h2xIOoKdd8aULS7gFtZs_gJ4fOQbnvV99XUDLlOWxYJ7sE0ZmZBvRXmpD8S-86fII-rXx_6Zs4"
        "UEMk5ROA1qK_sdFhA1KNHtgpKJP-ZKZAIcg4WreQtmqWwQ"
    )

    # A second key, signing an expired token and a wrong-audience token.
    N2_HEX = (
        "d7006858fc52bf081b340bcccb3075b6d8fa91ac84cbfd2eca9c39cb249d10197e18eb7865"
        "5c93d9ef9b358e07f2d97c540958e87d14aacbacf1cfdd1301c0503e03067cf98abb401798"
        "1fd923c320c2dc9f95c5430e009d358a788d7c57c1ca44a3091513f450dfa60499460f3330"
        "64f35c5ac55a7716ff82e1160598dd3cade5f32f6b11a6ce54c18fd94560d596b1e2134a2c"
        "8d4f4e337e43577f0a8f7b42ff8ef5ba99bc06df0aea9570060bf9309ecf61d98592b03b59"
        "bbf8431aff621da84ef8586952d519f5eae6cca2fc01a760d5a69212d505c09d4b5ec3b4b6"
        "44309ac4785ca9c35934808a01e5e2c12383404c261a64870129a9bb7e102e320661"
    )
    E2 = 65537
    KID2 = "test-key-2"
    EXPIRED_TOKEN = (
        "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTIifQ."
        "eyJpc3MiOiJodHRwczovL2FwcGxlaWQuYXBwbGUuY29tIiwiYXVkIjoiZGV2LmxldmlzY2hvZW4"
        "uZmluIiwic3ViIjoiZXhwaXJlZC1zdWIiLCJleHAiOjEwMDAwMDAwMDAsImlhdCI6OTk5OTk5MD"
        "AwfQ."
        "nRt0FLoznJEj4lNk2VykyZF0y1tgl-XTiuYMxbmDlaW76w1KQPfMXfQLd_Z2IrIG-Xqg4lfbVb"
        "5Fqyeow7uXixMJQVVb79MX4sA0Km31pd5KmEVOmaxnxv0G2Qgu9OzcROSb2VbZbdPZsIllQL33"
        "BM5Yes_yLPb-cx321A8BC6D4g5PVmH9jZXyhVhmsgmX4OE2JbreiHaSg_eSikQopQGHmlFVpe3"
        "Repxo4qe4MSlyfjCvTyibWz8wRJz_2jW7COBGO6QQwRtbd8Rkvx_e-tkvRRwyjvJcOZNZPQnC1"
        "E3JGn0bK99w4hQbFyqB2fMTINDJcQqOMJYw42qkTHJ0OZg"
    )
    WRONG_AUD_TOKEN = (
        "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTIifQ."
        "eyJpc3MiOiJodHRwczovL2FwcGxlaWQuYXBwbGUuY29tIiwiYXVkIjoiY29tLnNvbWVvbmVlbHN"
        "lLmFwcCIsInN1YiI6Im90aGVyLXN1YiIsImV4cCI6NDEwMjQ0NDgwMCwiaWF0IjoxNzAwMDAwMD"
        "AwfQ."
        "EqqCsArAOl88loJb3QYey_03FKJllTr5pqcfLiv2hBJkvWHLSbuhZvcLu22KQANfgfsyrOYx0t"
        "TQnjcT90orsFfCPaAjK4sYguDJoFwy8ZV1VJRP9GjcqkaCblnV_wYspsaLy-Bz-g-GCOmfYnME"
        "bNfIKiuzimvBWLzuL-RtemfIFrSfU-_aVuITOoAZysvcvWVIFPvWYaU8kzH1wfVLetsCRZPGq4"
        "ghK7Nn2uhFYZirtQM8-zTfiSRZxQoAx1dwGu86cQYkRuHLNUlfhUGBCow96ZjJ2u7lvGSK8nCG"
        "wY_v8vz4KRqPNXz37dR4mg4pcYWl6WBfwu-7Je8UMFZ4KQ"
    )

    def setUp(self):
        n1, e1 = int(self.N_HEX, 16), self.E
        n2, e2 = int(self.N2_HEX, 16), self.E2
        self._jwks = [
            {"kty": "RSA", "kid": self.KID, "n": _b64url_uint(n1), "e": _b64url_uint(e1)},
            {"kty": "RSA", "kid": self.KID2, "n": _b64url_uint(n2), "e": _b64url_uint(e2)},
        ]
        self._orig_jwks = lam._apple_jwks
        lam._apple_jwks = lambda *a, **kw: self._jwks

    def tearDown(self):
        lam._apple_jwks = self._orig_jwks

    def test_a_genuinely_signed_valid_token_verifies(self):
        sub = lam._verify_apple_identity_token(self.TOKEN)
        self.assertEqual(sub, "001234.abcdef1234567890.5678")

    def test_tampering_the_payload_invalidates_the_signature(self):
        header, payload, sig = self.TOKEN.split(".")
        tampered = header + "." + payload[:-1] + ("A" if payload[-1] != "A" else "B") + "." + sig
        with self.assertRaises(lam.ApiError) as ctx:
            lam._verify_apple_identity_token(tampered)
        self.assertEqual(ctx.exception.status, 401)

    def test_tampering_the_signature_invalidates_it(self):
        header, payload, sig = self.TOKEN.split(".")
        tampered_sig = ("A" if sig[0] != "A" else "B") + sig[1:]
        with self.assertRaises(lam.ApiError):
            lam._verify_apple_identity_token(header + "." + payload + "." + tampered_sig)

    def test_an_expired_token_is_rejected(self):
        with self.assertRaises(lam.ApiError) as ctx:
            lam._verify_apple_identity_token(self.EXPIRED_TOKEN)
        self.assertIn("expired", ctx.exception.message)

    def test_a_wrong_audience_token_is_rejected(self):
        with self.assertRaises(lam.ApiError) as ctx:
            lam._verify_apple_identity_token(self.WRONG_AUD_TOKEN)
        self.assertIn("audience", ctx.exception.message)

    def test_an_unknown_signing_key_is_rejected(self):
        header, payload, sig = self.TOKEN.split(".")
        # Same shape, but claim a kid that isn't in the (mocked) JWKS at all.
        import json
        h = json.loads(base64.urlsafe_b64decode(header + "=="))
        h["kid"] = "no-such-key"
        new_header = base64.urlsafe_b64encode(json.dumps(h).encode()).rstrip(b"=").decode()
        with self.assertRaises(lam.ApiError) as ctx:
            lam._verify_apple_identity_token(new_header + "." + payload + "." + sig)
        self.assertIn("signing key", ctx.exception.message)

    def test_a_non_rs256_algorithm_is_rejected(self):
        header, payload, sig = self.TOKEN.split(".")
        import json
        h = json.loads(base64.urlsafe_b64decode(header + "=="))
        h["alg"] = "none"
        new_header = base64.urlsafe_b64encode(json.dumps(h).encode()).rstrip(b"=").decode()
        with self.assertRaises(lam.ApiError) as ctx:
            lam._verify_apple_identity_token(new_header + "." + payload + "." + sig)
        self.assertEqual(ctx.exception.status, 401)

    def test_malformed_tokens_are_rejected_not_crashed_on(self):
        for bad in ["", "not.a.jwt.token", "onlyonepart", "a.b", "!!!.!!!.!!!"]:
            with self.assertRaises(lam.ApiError):
                lam._verify_apple_identity_token(bad)


class GetOrCreateUserTests(unittest.TestCase):
    """`_get_or_create_user` mints a fresh uuid4 for a new appleSub and
    reuses the existing one on a repeat sign-in — pinned against a stubbed
    table since the real thing needs AWS."""

    class _FakeTable:
        def __init__(self):
            self.items = {}
            self.updates = []

        def get_item(self, Key):
            item = self.items.get(Key["appleSub"])
            return {"Item": item} if item else {}

        def put_item(self, Item):
            self.items[Item["appleSub"]] = Item

        def update_item(self, Key, UpdateExpression, ExpressionAttributeValues):
            self.updates.append(Key["appleSub"])

    def setUp(self):
        self._orig_table = lam.USERS_TABLE
        lam.USERS_TABLE = self._FakeTable()

    def tearDown(self):
        lam.USERS_TABLE = self._orig_table

    def test_a_new_sub_mints_a_fresh_user_id(self):
        user_id = lam._get_or_create_user("apple-sub-1")
        self.assertTrue(user_id)
        self.assertEqual(lam.USERS_TABLE.items["apple-sub-1"]["userId"], user_id)

    def test_the_same_sub_returns_the_same_user_id_and_touches_last_seen(self):
        first = lam._get_or_create_user("apple-sub-2")
        second = lam._get_or_create_user("apple-sub-2")
        self.assertEqual(first, second)
        self.assertIn("apple-sub-2", lam.USERS_TABLE.updates)

    def test_two_different_subs_get_two_different_user_ids(self):
        a = lam._get_or_create_user("apple-sub-3")
        b = lam._get_or_create_user("apple-sub-4")
        self.assertNotEqual(a, b)


class DeleteWorkerOwnershipTests(unittest.TestCase):
    """The live IDOR this multi-tenancy pass fixed: delete_worker used to
    terminate any worker by id with no ownership check at all. Pinned
    directly, not just hand-curled, because a regression here is a real
    any-user-can-kill-any-other-users-instance bug, not just a data leak."""

    class _FakeTable:
        def __init__(self, item):
            self._item = item

        def get_item(self, Key):
            if self._item and Key["workerId"] == self._item["workerId"]:
                return {"Item": self._item}
            return {}

    def setUp(self):
        self._orig_table = lam.TABLE

    def tearDown(self):
        lam.TABLE = self._orig_table

    def test_someone_elses_worker_404s_not_403(self):
        # 404, not 403 — never confirm existence to a caller who shouldn't
        # know about it, same reasoning as every other ownership check here.
        lam.TABLE = self._FakeTable({"workerId": "w1", "userId": "owner-a", "status": "live"})
        event = {"_userId": "attacker-b"}
        with self.assertRaises(lam.ApiError) as ctx:
            lam.delete_worker(event, "w1")
        self.assertEqual(ctx.exception.status, 404)

    def test_a_worker_with_no_userid_at_all_is_not_deletable_by_anyone(self):
        # Legacy-fallback-era records with no userId must not be treated as
        # "ownerless, anyone may act on it."
        lam.TABLE = self._FakeTable({"workerId": "w2", "status": "live"})
        with self.assertRaises(lam.ApiError) as ctx:
            lam.delete_worker({"_userId": "someone"}, "w2")
        self.assertEqual(ctx.exception.status, 404)

    def test_a_nonexistent_worker_id_404s(self):
        lam.TABLE = self._FakeTable(None)
        with self.assertRaises(lam.ApiError) as ctx:
            lam.delete_worker({"_userId": "owner-a"}, "no-such-worker")
        self.assertEqual(ctx.exception.status, 404)

    def test_the_owner_can_fetch_an_already_terminated_worker(self):
        # No EC2 call on this path (already terminated) — safe to exercise
        # without stubbing EC2, and confirms the ownership check doesn't
        # false-reject the actual owner.
        lam.TABLE = self._FakeTable({"workerId": "w3", "userId": "owner-a", "status": "terminated"})
        response = lam.delete_worker({"_userId": "owner-a"}, "w3")
        self.assertEqual(response["statusCode"], 200)


class WorkerListingScopingTests(unittest.TestCase):
    """list_workers/usage used to scan every user's records unfiltered — the
    fix is a FilterExpression on userId; pinned by capturing what actually
    gets sent to DynamoDB rather than trusting the code reads right."""

    class _FakeTable:
        def __init__(self):
            self.scan_calls = []

        def scan(self, **kwargs):
            self.scan_calls.append(kwargs)
            return {"Items": []}

    def setUp(self):
        self._orig_table = lam.TABLE
        lam.TABLE = self._FakeTable()

    def tearDown(self):
        lam.TABLE = self._orig_table

    def test_list_workers_scopes_the_scan_to_the_caller(self):
        lam.list_workers({"_userId": "user-x"})
        self.assertEqual(len(lam.TABLE.scan_calls), 1)
        call = lam.TABLE.scan_calls[0]
        self.assertEqual(call["ExpressionAttributeValues"][":user"], "user-x")
        self.assertIn("userId", call["FilterExpression"])

    def test_usage_scopes_the_scan_to_the_caller(self):
        lam.usage({"_userId": "user-y"})
        self.assertEqual(len(lam.TABLE.scan_calls), 1)
        call = lam.TABLE.scan_calls[0]
        self.assertEqual(call["ExpressionAttributeValues"][":user"], "user-y")
        self.assertIn("userId", call["FilterExpression"])

    def test_live_workers_with_no_user_id_scans_unfiltered_for_the_schedules(self):
        lam._live_workers()
        call = lam.TABLE.scan_calls[0]
        self.assertNotIn(":user", call["ExpressionAttributeValues"])

    def test_live_workers_with_a_user_id_scopes_the_scan(self):
        lam._live_workers("user-z")
        call = lam.TABLE.scan_calls[0]
        self.assertEqual(call["ExpressionAttributeValues"][":user"], "user-z")


class DeviceStatusIamPolicySanityTests(unittest.TestCase):
    """Sanity-checks the IAM policy diff reported alongside the per-device status key
    change (deploy.sh's DeviceStatusWrite Sid): does the new statement's Resource ARN
    pattern actually match the new key format lambda.py mints (a common copy-paste
    mistake — e.g. forgetting a `/*/` segment or matching the OLD single-file key), and
    does an existing ListBucket/GetObject condition already cover the new prefix (so no
    statement was silently missed)."""

    @classmethod
    def setUpClass(cls):
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "deploy.sh")) as f:
            cls.deploy_sh = f.read()

    @staticmethod
    def _arn_to_regex(pattern):
        # IAM ARN / StringLike wildcards: '*' matches any run of characters,
        # including '/'. $BUCKET / $REGION / $ACCOUNT are shell interpolations,
        # not real wildcards, so pin them to a placeholder that can't collide
        # with a real key segment before quoting the rest.
        import re as _re
        pattern = pattern.replace("$BUCKET", "\0BUCKET\0")
        escaped = _re.escape(pattern).replace(_re.escape("*"), ".*")
        escaped = escaped.replace(_re.escape("\0BUCKET\0"), "test-bucket")
        return _re.compile("^" + escaped + "$")

    def _find_resource(self, sid, action_hint):
        """Pulls the Resource value(s) out of the one JSON-ish statement block whose
        Sid matches, by locating the block's braces textually (the policy is built as
        an f-string-flavored heredoc, not real JSON, until $VARS are substituted, so a
        real JSON parser can't be pointed at it directly)."""
        import re as _re
        block_start = self.deploy_sh.index('"Sid": "%s"' % sid)
        block_open = self.deploy_sh.rindex("{", 0, block_start)
        depth = 0
        i = block_open
        while True:
            if self.deploy_sh[i] == "{":
                depth += 1
            elif self.deploy_sh[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = self.deploy_sh[block_open:i + 1]
        self.assertIn(action_hint, block, "Sid %r doesn't cover the expected action" % sid)
        resources = _re.findall(r'"arn:aws:s3:::\$BUCKET/[^"]*"', block)
        self.assertTrue(resources, "no S3 Resource ARNs found in Sid %r's block" % sid)
        return [r.strip('"') for r in resources]

    def test_device_status_write_resource_matches_the_new_per_device_key_format(self):
        resources = self._find_resource("DeviceStatusWrite", "s3:PutObject")
        candidate_key = "test-bucket/" + lam.DEVICE_STATUS_KEY.format(user="user-abc", device="11112222")
        matched = [r for r in resources if self._arn_to_regex(r).match("arn:aws:s3:::" + candidate_key)]
        self.assertTrue(
            matched,
            "DeviceStatusWrite's Resource %r does not match a real DEVICE_STATUS_KEY "
            "(%r) — this is exactly the copy-paste-mistake shape to catch (wrong "
            "segment count, or still pointing at the old shared status.json key)."
            % (resources, candidate_key)
        )

    def test_device_status_write_resource_does_not_still_match_the_old_shared_key(self):
        # Regression against "renamed the Sid but left the Resource pointing at the
        # single shared file" — the whole point of the per-device key change was that
        # two devices no longer share one object.
        resources = self._find_resource("DeviceStatusWrite", "s3:PutObject")
        old_shared_key = "test-bucket/users/user-abc/fin/status.json"
        matched = [r for r in resources if self._arn_to_regex(r).match("arn:aws:s3:::" + old_shared_key)]
        self.assertFalse(matched, "DeviceStatusWrite must not still match the old single shared-file key")

    def test_agent_objects_get_covers_the_new_devices_prefix(self):
        resources = self._find_resource("AgentObjects", "s3:GetObject")
        candidate_key = "test-bucket/" + lam.DEVICE_STATUS_KEY.format(user="user-abc", device="11112222")
        matched = [r for r in resources if self._arn_to_regex(r).match("arn:aws:s3:::" + candidate_key)]
        self.assertTrue(matched, "no existing GetObject Resource covers the new devices/ prefix — "
                                  "the daemon's /devices/status route (S3.get_object per device) would 403")

    def test_see_missing_agent_objects_listbucket_condition_covers_the_new_prefix(self):
        import re as _re
        block_start = self.deploy_sh.index('"Sid": "SeeMissingAgentObjects"')
        block_open = self.deploy_sh.rindex("{", 0, block_start)
        depth, i = 0, block_open
        while True:
            if self.deploy_sh[i] == "{":
                depth += 1
            elif self.deploy_sh[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = self.deploy_sh[block_open:i + 1]
        prefixes = _re.findall(r'"(users/\*|fin/agentd/\*)"', block)
        self.assertTrue(prefixes, "expected a users/* (or fin/agentd/*) StringLike prefix condition")
        device_status_prefix = lam.DEVICE_STATUS_PREFIX.format(user="user-abc")
        matched = [
            p for p in prefixes
            if _re.match("^" + _re.escape(p).replace(r"\*", ".*") + "$", device_status_prefix)
        ]
        self.assertTrue(
            matched,
            "no ListBucket StringLike prefix condition (%r) covers the new device-status "
            "list prefix (%r) — list_device_status's list_objects_v2 call would 403"
            % (prefixes, device_status_prefix)
        )


class ListDeviceStatusTests(unittest.TestCase):
    """`GET /devices/status` — the aggregation/read path: lists every
    users/{user}/fin/devices/*/status.json object for the caller and GETs each one.
    Covers eval scenarios (a) two devices' independently-written objects don't clobber
    each other, (b) the read path enumerates + fetches multiple device documents, and
    the 0-devices-ever-registered edge of (c)."""

    class _FakeS3:
        def __init__(self, objects):
            # objects: {key: json-bytes-or-str}
            self.objects = objects
            self.list_calls = []
            self.get_calls = []

        def list_objects_v2(self, **kwargs):
            self.list_calls.append(kwargs)
            prefix = kwargs.get("Prefix", "")
            keys = sorted(k for k in self.objects if k.startswith(prefix))
            return {"Contents": [{"Key": k} for k in keys]}

        def get_object(self, **kwargs):
            self.get_calls.append(kwargs)
            key = kwargs["Key"]
            body = self.objects[key]
            if isinstance(body, str):
                body = body.encode("utf-8")

            class _Body:
                def read(_self):
                    return body
            return {"Body": _Body()}

    def setUp(self):
        self._orig_s3 = lam.S3
        self.addCleanup(lambda: setattr(lam, "S3", self._orig_s3))

    def test_two_devices_written_under_distinct_keys_both_survive_aggregation(self):
        # Two devices, each having PUT its OWN object — the schema's whole point.
        key_a = lam.DEVICE_STATUS_KEY.format(user="user-1", device="aaaa1111")
        key_b = lam.DEVICE_STATUS_KEY.format(user="user-1", device="bbbb2222")
        lam.S3 = self._FakeS3({
            key_a: json.dumps({"device": "iMac", "state": "idle", "updated_at": "2026-09-11T20:00:00Z"}),
            key_b: json.dumps({"device": "MacBook Air", "state": "thinking", "updated_at": "2026-09-11T20:02:00Z"}),
        })
        result = lam.list_device_status({"_userId": "user-1"})
        body = json.loads(result["body"]) if isinstance(result.get("body"), str) else result["body"]
        devices = {d["device_id8"]: d for d in body["devices"]}
        self.assertEqual(set(devices), {"aaaa1111", "bbbb2222"})
        self.assertEqual(devices["aaaa1111"]["device"], "iMac")
        self.assertEqual(devices["aaaa1111"]["state"], "idle")
        self.assertEqual(devices["bbbb2222"]["device"], "MacBook Air")
        self.assertEqual(devices["bbbb2222"]["state"], "thinking")

    def test_device_id8_is_taken_from_the_key_path_not_the_documents_own_field(self):
        # "status["device_id8"] = device_id8  # overwrite any self-reported mismatch" —
        # pin that the path segment wins even when the document disagrees with it.
        key = lam.DEVICE_STATUS_KEY.format(user="user-1", device="11112222")
        lam.S3 = self._FakeS3({
            key: json.dumps({"device": "MacBook", "device_id8": "wrongwrong", "state": "idle", "updated_at": "2026-09-11T20:00:00Z"}),
        })
        result = lam.list_device_status({"_userId": "user-1"})
        body = json.loads(result["body"])
        self.assertEqual(body["devices"][0]["device_id8"], "11112222")

    def test_zero_devices_ever_registered_returns_an_empty_list_not_an_error(self):
        lam.S3 = self._FakeS3({})
        result = lam.list_device_status({"_userId": "user-1"})
        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertEqual(body["devices"], [])

    def test_malformed_device_document_is_skipped_not_fatal(self):
        good_key = lam.DEVICE_STATUS_KEY.format(user="user-1", device="11112222")
        bad_key = lam.DEVICE_STATUS_KEY.format(user="user-1", device="22223333")
        lam.S3 = self._FakeS3({
            good_key: json.dumps({"device": "MacBook", "state": "idle", "updated_at": "2026-09-11T20:00:00Z"}),
            bad_key: "not json at all",
        })
        result = lam.list_device_status({"_userId": "user-1"})
        body = json.loads(result["body"])
        self.assertEqual(len(body["devices"]), 1)
        self.assertEqual(body["devices"][0]["device_id8"], "11112222")

    def test_listing_is_scoped_to_the_callers_own_user_prefix(self):
        mine = lam.DEVICE_STATUS_KEY.format(user="user-1", device="11112222")
        theirs = lam.DEVICE_STATUS_KEY.format(user="user-2", device="99998888")
        lam.S3 = self._FakeS3({
            mine: json.dumps({"device": "Mine", "state": "idle", "updated_at": "2026-09-11T20:00:00Z"}),
            theirs: json.dumps({"device": "TheirMac", "state": "idle", "updated_at": "2026-09-11T20:00:00Z"}),
        })
        result = lam.list_device_status({"_userId": "user-1"})
        body = json.loads(result["body"])
        self.assertEqual([d["device_id8"] for d in body["devices"]], ["11112222"])


class PresignSupervisionStatusBackCompatTests(unittest.TestCase):
    """Every client build shipped before `deviceId8` existed asks for kind
    supervisionStatus without one. Those builds stay installed for as long as it
    takes users to update, so the per-device migration must not turn their status
    uplink into a hard error — these pin that it doesn't."""

    def setUp(self):
        self._orig = lam._presign
        self.signed = []

        def fake_presign(method, key):
            self.signed.append((method, key))
            return "https://example.invalid/{}".format(key)

        lam._presign = fake_presign
        self.addCleanup(lambda: setattr(lam, "_presign", self._orig))

    def _presign_event(self, body):
        return {"_userId": "user-1", "body": json.dumps(body)}

    def test_absent_device_id_falls_back_to_the_legacy_flat_key(self):
        lam.presign(self._presign_event({"kinds": ["supervisionStatus"]}))
        self.assertEqual(
            self.signed, [("put_object", "users/user-1/fin/status.json")]
        )

    def test_valid_device_id_uses_the_per_device_key(self):
        lam.presign(
            self._presign_event({"kinds": ["supervisionStatus"], "deviceId8": "a4a1d987"})
        )
        self.assertEqual(
            self.signed,
            [("put_object", "users/user-1/fin/devices/a4a1d987/status.json")],
        )

    def test_malformed_device_id_is_still_rejected_rather_than_silently_legacy(self):
        with self.assertRaises(lam.ApiError) as caught:
            lam.presign(
                self._presign_event({"kinds": ["supervisionStatus"], "deviceId8": "nope"})
            )
        self.assertEqual(caught.exception.status, 400)
        self.assertEqual(self.signed, [])



class _FakeDynamoTable:
    """Enough DynamoDB for the sites/messages routes, in memory: get/put/update/
    scan with a real evaluator for the handful of expression shapes lambda.py
    uses (SET/REMOVE, attribute_not_exists, =, <, IN, AND/OR/parentheses) and
    a FilterExpression evaluator for the same grammar. A fake rather than moto
    on purpose: the point of these tests is the routes' own logic, and the
    conditional write is the only DynamoDB behaviour they depend on — this
    evaluates it for real instead of pattern-matching strings, so a condition
    that is subtly wrong fails here the way it would fail live."""

    def __init__(self, key, items=()):
        self.key = key
        self.items = {i[key]: dict(i) for i in items}

    # -- expression evaluation ---------------------------------------------
    @staticmethod
    def _resolve(token, names, values):
        token = token.strip()
        if token.startswith(":"):
            return values[token]
        if token.startswith("#"):
            return names[token]
        return token

    def _field(self, item, token, names):
        name = names.get(token, token) if token.startswith("#") else token
        return item.get(name)

    def _eval(self, expr, item, names, values):
        expr = expr.strip()
        # Strip one layer of enclosing parentheses if they wrap the whole thing.
        if expr.startswith("(") and expr.endswith(")"):
            depth = 0
            wraps = True
            for i, ch in enumerate(expr):
                depth += (ch == "(") - (ch == ")")
                if depth == 0 and i < len(expr) - 1:
                    wraps = False
                    break
            if wraps:
                return self._eval(expr[1:-1], item, names, values)
        for op in (" OR ", " AND "):
            depth = 0
            for i in range(len(expr)):
                ch = expr[i]
                depth += (ch == "(") - (ch == ")")
                if depth == 0 and expr[i:i + len(op)] == op:
                    left = self._eval(expr[:i], item, names, values)
                    right = self._eval(expr[i + len(op):], item, names, values)
                    return (left or right) if op == " OR " else (left and right)
        m = re.match(r"^attribute_not_exists\((\S+)\)$", expr)
        if m:
            return self._field(item, m.group(1), names) is None
        m = re.match(r"^(\S+) IN \((.+)\)$", expr)
        if m:
            wanted = [values[v.strip()] for v in m.group(2).split(",")]
            return self._field(item, m.group(1), names) in wanted
        m = re.match(r"^(\S+) (=|<|>|<=|>=) (\S+)$", expr)
        if m:
            left = self._field(item, m.group(1), names)
            right = values[m.group(3)]
            op = m.group(2)
            if left is None:
                return False
            return {"=": left == right, "<": left < right, ">": left > right,
                    "<=": left <= right, ">=": left >= right}[op]
        raise AssertionError("unsupported expression: " + expr)

    def _apply_update(self, item, update, names, values):
        rest = update
        remove = None
        if " REMOVE " in rest:
            rest, remove = rest.split(" REMOVE ", 1)
        assert rest.startswith("SET "), update
        for clause in rest[4:].split(", "):
            field, _, value = clause.partition(" = ")
            field = names.get(field.strip(), field.strip())
            item[field] = values[value.strip()]
        if remove:
            for field in remove.split(","):
                item.pop(names.get(field.strip(), field.strip()), None)

    @staticmethod
    def _conditional_failure(op):
        return lam.ClientError(
            {"Error": {"Code": "ConditionalCheckFailedException", "Message": "no"}}, op
        )

    # -- the API surface the code uses --------------------------------------
    def get_item(self, Key):
        item = self.items.get(Key[self.key])
        return {"Item": dict(item)} if item else {}

    def put_item(self, Item, ConditionExpression=None, ExpressionAttributeValues=None,
                 ExpressionAttributeNames=None):
        existing = self.items.get(Item[self.key])
        if ConditionExpression and not self._eval(
            ConditionExpression, existing or {}, ExpressionAttributeNames or {}, ExpressionAttributeValues or {}
        ):
            raise self._conditional_failure("PutItem")
        self.items[Item[self.key]] = dict(Item)

    def update_item(self, Key, UpdateExpression, ExpressionAttributeValues=None,
                    ExpressionAttributeNames=None, ConditionExpression=None):
        names = ExpressionAttributeNames or {}
        values = ExpressionAttributeValues or {}
        item = self.items.get(Key[self.key])
        if ConditionExpression and not self._eval(ConditionExpression, item or {}, names, values):
            raise self._conditional_failure("UpdateItem")
        if item is None:
            item = {self.key: Key[self.key]}
            self.items[Key[self.key]] = item
        self._apply_update(item, UpdateExpression, names, values)

    def scan(self, FilterExpression=None, ExpressionAttributeValues=None,
             ExpressionAttributeNames=None, **kwargs):
        rows = list(self.items.values())
        if FilterExpression:
            rows = [r for r in rows if self._eval(
                FilterExpression, r, ExpressionAttributeNames or {}, ExpressionAttributeValues or {}
            )]
        return {"Items": [dict(r) for r in rows]}


class _SitesTestCase(unittest.TestCase):
    def setUp(self):
        for attr, key in (("SITES_TABLE", "siteId"), ("MESSAGES_TABLE", "messageId"), ("AGENTS_TABLE", "agentKey")):
            orig = getattr(lam, attr)
            setattr(lam, attr, _FakeDynamoTable(key))
            self.addCleanup(setattr, lam, attr, orig)
        self._orig_presign = lam._presign
        lam._presign = lambda method, key: "https://example.invalid/{}".format(key)
        self.addCleanup(setattr, lam, "_presign", self._orig_presign)

    def enroll(self, user="user-1", **body):
        payload = {"agent": "Fin", "kind": "resident", "enrollKey": "levis-imac/deepspacenine"}
        payload.update(body)
        response = lam.enroll_site({"_userId": user, "body": json.dumps(payload)})
        return json.loads(response["body"])


class SiteEnrollmentTests(_SitesTestCase):
    def test_enrolling_twice_with_the_same_key_returns_the_same_site(self):
        # The installer is re-run whenever a Mac is reconfigured; that must not
        # accumulate a row per run, or "Fin's computers" fills with ghosts of
        # the same physical machine.
        first = self.enroll()
        second = self.enroll()
        self.assertEqual(first["siteId"], second["siteId"])
        self.assertTrue(second["reEnrolled"])
        self.assertEqual(len(lam.SITES_TABLE.items), 1)

    def test_re_enrolling_rotates_the_token(self):
        # Re-enrolling IS the revocation story: a leaked site token is killed by
        # running the installer again, so the old one must stop working.
        first = self.enroll()
        second = self.enroll()
        self.assertNotEqual(first["siteToken"], second["siteToken"])
        stored = lam.SITES_TABLE.items[first["siteId"]]["tokenSha256"]
        self.assertEqual(stored, lam._site_token_hash(second["siteToken"]))

    def test_the_token_is_never_stored_in_the_clear(self):
        result = self.enroll()
        row = lam.SITES_TABLE.items[result["siteId"]]
        self.assertNotIn(result["siteToken"], json.dumps(row, default=str))

    def test_the_same_enroll_key_under_two_users_is_two_sites(self):
        # enrollKey is the operator's name for a place, not a global identifier;
        # two users may each call their own machine "imac".
        mine = self.enroll(user="user-1")
        theirs = self.enroll(user="user-2")
        self.assertNotEqual(mine["siteId"], theirs["siteId"])

    def test_an_adopted_siteid_is_kept_verbatim(self):
        # The resident iMac's device_id8 is already stamped on its status
        # objects and transcript lines; re-minting an id would orphan them.
        adopted = "a4a1d987-0000-4000-8000-000000000000"
        result = self.enroll(siteId=adopted)
        self.assertEqual(result["siteId"], adopted)
        self.assertEqual(result["siteId8"], "a4a1d987")

    def test_kind_sets_the_default_priority(self):
        self.assertEqual(
            lam.SITES_TABLE.items[self.enroll()["siteId"]]["priority"],
            lam.SITE_DEFAULT_PRIORITY["resident"],
        )

    def test_an_unknown_kind_is_rejected(self):
        with self.assertRaises(lam.ApiError) as caught:
            self.enroll(kind="toaster")
        self.assertEqual(caught.exception.status, 400)


class SiteLeaseTests(_SitesTestCase):
    def setUp(self):
        super().setUp()
        self.site = self.enroll()

    def _beat(self, user="user-1", **body):
        event = {"_userId": user, "body": json.dumps(body)}
        return json.loads(lam.site_heartbeat(event, self.site["siteId"])["body"])

    def test_a_heartbeat_extends_the_lease_from_the_lambdas_own_clock(self):
        # Sites send durations, never timestamps: a site with a skewed clock
        # must not be able to grant itself a longer lease than anyone else.
        before = lam._now()
        result = self._beat(state="working")
        lease = lam._parse_iso(result["leaseUntil"])
        self.assertGreaterEqual((lease - before).total_seconds(), lam.SITE_LEASE_SECONDS - 2)
        self.assertLessEqual((lease - before).total_seconds(), lam.SITE_LEASE_SECONDS + 2)

    def test_a_working_site_is_live(self):
        # The reason the heartbeat runs off the turn loop at all: a long turn on
        # a local model would otherwise read as a dead body.
        self._beat(state="working")
        row = lam.SITES_TABLE.items[self.site["siteId"]]
        self.assertEqual(row["state"], "working")
        self.assertTrue(lam._site_is_live(row))

    def test_a_site_past_its_lease_is_not_live(self):
        row = dict(lam.SITES_TABLE.items[self.site["siteId"]])
        row["leaseUntil"] = _iso(lam._now() - timedelta(seconds=1))
        self.assertFalse(lam._site_is_live(row))

    def test_a_retired_site_is_never_live_however_fresh_its_lease(self):
        row = dict(lam.SITES_TABLE.items[self.site["siteId"]])
        row["state"] = "retired"
        row["leaseUntil"] = _iso(lam._now() + timedelta(hours=1))
        self.assertFalse(lam._site_is_live(row))

    def test_urls_are_refreshed_when_the_sites_copies_are_nearly_expired(self):
        soon = _iso(lam._now() + timedelta(minutes=5))
        self.assertIn("urls", self._beat(urlsExpireAt=soon))

    def test_urls_are_not_re_signed_while_the_sites_copies_are_fresh(self):
        later = _iso(lam._now() + timedelta(minutes=55))
        self.assertNotIn("urls", self._beat(urlsExpireAt=later))

    def test_the_status_url_is_the_sites_own_per_device_key(self):
        urls = self._beat()["urls"]
        self.assertIn("/fin/devices/{}/status.json".format(self.site["siteId8"]), urls["supervisionStatusPut"])

    def test_a_heartbeat_drains_queued_commands_exactly_once(self):
        lam.queue_site_command(
            {"_userId": "user-1", "body": json.dumps({"kind": "restart"})}, self.site["siteId"]
        )
        self.assertEqual([c["kind"] for c in self._beat()["commands"]], ["restart"])
        self.assertEqual(self._beat()["commands"], [])

    def test_oversized_capabilities_are_rejected_rather_than_stored(self):
        with self.assertRaises(lam.ApiError) as caught:
            self._beat(capabilities={"junk": "x" * (lam.MAX_CAPABILITIES_BYTES + 1)})
        self.assertEqual(caught.exception.status, 413)

    def test_another_users_site_404s_rather_than_403s(self):
        with self.assertRaises(lam.ApiError) as caught:
            self._beat(user="attacker-b")
        self.assertEqual(caught.exception.status, 404)

    def test_retiring_a_site_destroys_its_token_hash(self):
        # Retirement IS revocation; a kept token hash would leave a retired
        # body able to authenticate.
        lam.delete_site({"_userId": "user-1"}, self.site["siteId"])
        row = lam.SITES_TABLE.items[self.site["siteId"]]
        self.assertEqual(row["state"], "retired")
        self.assertNotIn("tokenSha256", row)


class SiteTokenScopeTests(_SitesTestCase):
    """A site token attaches the owner's `_userId` exactly like a session token
    does, and every route reads only that — so this allow-list is the ENTIRE
    boundary between "one body" and "full account access". Pinned directly."""

    def _parts(self, path):
        return [p for p in path.split("/") if p]

    def _assert_denied(self, method, path, site_id="site-a"):
        with self.assertRaises(lam.ApiError) as caught:
            lam._require_site_scope({"_siteId": site_id}, method, self._parts(path))
        self.assertEqual(caught.exception.status, 403)

    def test_a_site_may_heartbeat_itself(self):
        lam._require_site_scope({"_siteId": "site-a"}, "POST", self._parts("/sites/site-a/heartbeat"))

    def test_a_site_may_retire_itself(self):
        lam._require_site_scope({"_siteId": "site-a"}, "DELETE", self._parts("/sites/site-a"))

    def test_a_site_may_not_heartbeat_another_site(self):
        self._assert_denied("POST", "/sites/site-b/heartbeat")

    def test_a_site_may_not_retire_another_site(self):
        self._assert_denied("DELETE", "/sites/site-b")

    def test_a_site_may_not_enumerate_its_siblings(self):
        self._assert_denied("GET", "/sites")

    def test_a_site_may_not_enroll_new_sites(self):
        self._assert_denied("POST", "/sites/enroll")

    def test_a_site_may_not_queue_commands_even_for_itself(self):
        # Commands are what an operator tells a body to do; a body that can
        # queue its own is a body that can tell itself to update from S3.
        self._assert_denied("POST", "/sites/site-a/commands")

    def test_a_site_may_not_touch_ec2(self):
        self._assert_denied("POST", "/workers")
        self._assert_denied("GET", "/workers")
        self._assert_denied("DELETE", "/workers/i-123")

    def test_a_site_may_not_read_secrets_or_memory(self):
        self._assert_denied("GET", "/secrets")
        self._assert_denied("GET", "/memory")
        self._assert_denied("GET", "/memory/profile")

    def test_a_site_may_re_sign_its_own_urls_and_notify_its_owner(self):
        lam._require_site_scope({"_siteId": "site-a"}, "POST", self._parts("/presign"))
        lam._require_site_scope({"_siteId": "site-a"}, "POST", self._parts("/notify"))

    def test_an_unlisted_future_route_is_denied_by_default(self):
        # The allow-list is deny-by-default on purpose: a route added later
        # should be unreachable by a site until someone decides otherwise.
        self._assert_denied("POST", "/some/route/added/later")

    def test_an_operator_token_is_unaffected_by_the_guard(self):
        lam._require_site_scope({"_userId": "user-1"}, "POST", self._parts("/workers"))




class _MessagesTestCase(_SitesTestCase):
    """Two enrolled bodies for one user's agent: the resident iMac (100) and a
    cloud worker (10), both beating so both are live."""

    def setUp(self):
        super().setUp()
        self.imac = self.enroll(enrollKey="imac", displayName="Levi's iMac", kind="resident")
        self.cloud = self.enroll(enrollKey="cloud-1", displayName="Cloud computer", kind="ec2")
        self.beat(self.imac, capabilities={"tmux_sessions": [
            {"session": "main", "tasks": ["fin project work", "pocketdj"]},
        ]})
        self.beat(self.cloud, capabilities={"tmux_sessions": [{"session": "agent", "tasks": ["deploys"]}]})

    def beat(self, site, user="user-1", **body):
        event = {"_userId": user, "_siteId": site["siteId"], "body": json.dumps(body)}
        return json.loads(lam.site_heartbeat(event, site["siteId"])["body"])

    def send(self, text, user="user-1", **extra):
        payload = {"agent": "Fin", "text": text}
        payload.update(extra)
        return json.loads(lam.send_message({"_userId": user, "body": json.dumps(payload)})["body"])

    def claim(self, site, message_id, **body):
        event = {"_userId": "user-1", "_siteId": site["siteId"], "body": json.dumps(body)}
        response = lam.claim_message(event, message_id)
        return response["statusCode"], json.loads(response["body"])

    def ack(self, site, message_id, state, **body):
        payload = {"state": state}
        payload.update(body)
        event = {"_userId": "user-1", "_siteId": site["siteId"], "body": json.dumps(payload)}
        return lam.ack_message(event, message_id)

    def row(self, message_id):
        return lam.MESSAGES_TABLE.items[message_id]


class PinForTests(unittest.TestCase):
    """§3.4 as a pure function."""

    def _site(self, sid, sessions):
        return {"siteId": sid, "siteId8": sid[:8], "displayName": sid,
                "capabilities": {"tmux_sessions": sessions}}

    def setUp(self):
        self.imac = self._site("imac-0000-4000-8000-000000000000", [
            {"session": "main", "tasks": ["fin project work"]}])
        self.cloud = self._site("cloud-000-4000-8000-000000000000", [
            {"session": "agent", "tasks": ["deploys"]}])

    def test_a_site_hint_naming_a_live_site_pins(self):
        pin, by, _ = lam._pin_for("anything", {"siteHint": self.cloud["siteId8"]}, [self.imac, self.cloud])
        self.assertEqual((pin, by), (self.cloud["siteId"], "hint"))

    def test_a_site_hint_naming_a_dead_site_is_ignored(self):
        pin, by, _ = lam._pin_for("anything", {"siteHint": "nope"}, [self.imac])
        self.assertEqual((pin, by), (None, None))

    def test_a_whole_word_session_mention_pins_to_that_site(self):
        pin, by, _ = lam._pin_for("what is the agent session doing", {}, [self.imac, self.cloud])
        self.assertEqual((pin, by), (self.cloud["siteId"], "context"))

    def test_a_substring_is_not_a_mention(self):
        # "mainly" must not route to the "main" session — same rule as the app.
        pin, by, _ = lam._pin_for("mainly wondering", {}, [self.imac, self.cloud])
        self.assertEqual((pin, by), (None, None))

    def test_the_senders_active_session_names_count_as_context(self):
        pin, by, _ = lam._pin_for("run the tests", {"activeSessionNames": ["main"]}, [self.imac, self.cloud])
        self.assertEqual((pin, by), (self.imac["siteId"], "context"))

    def test_two_matching_sites_ask_for_clarification_rather_than_guess(self):
        pin, by, candidates = lam._pin_for("check main and agent", {}, [self.imac, self.cloud])
        self.assertIsNone(pin)
        self.assertEqual(by, "clarify")
        self.assertEqual(sorted(candidates), sorted([self.imac["displayName"], self.cloud["displayName"]]))


class EligibilityTests(unittest.TestCase):
    """§6.2 as a pure function. `now` is fixed; leases are relative to it."""

    def _row(self, **fields):
        row = {"state": "queued"}
        row.update(fields)
        return row

    def test_a_pinned_row_is_only_eligible_to_the_pinned_site(self):
        row = self._row(pinSiteId="a")
        self.assertTrue(lam._eligible(row, "a", False, True, lambda _: True, NOW))
        self.assertFalse(lam._eligible(row, "b", True, True, lambda _: True, NOW))

    def test_a_targeted_row_goes_to_its_target_while_that_target_is_live(self):
        row = self._row(targetSiteId="a")
        self.assertTrue(lam._eligible(row, "a", False, True, lambda _: True, NOW))
        self.assertFalse(lam._eligible(row, "b", True, True, lambda _: True, NOW))

    def test_a_stale_target_falls_through_to_the_primary(self):
        row = self._row(targetSiteId="dead")
        self.assertTrue(lam._eligible(row, "b", True, True, lambda _: False, NOW))
        self.assertFalse(lam._eligible(row, "c", False, True, lambda _: False, NOW))

    def test_with_no_live_primary_any_live_site_may_take_it(self):
        # Last-resort failover: better a standby answers than nobody does.
        row = self._row()
        self.assertTrue(lam._eligible(row, "anyone", False, False, lambda _: False, NOW))

    def test_a_row_under_a_fresh_claim_is_offered_to_nobody(self):
        row = self._row(state="claimed", leaseUntil=_iso(NOW + timedelta(seconds=30)))
        self.assertFalse(lam._eligible(row, "a", True, True, lambda _: True, NOW))

    def test_a_row_whose_claim_lapsed_is_offered_again(self):
        row = self._row(state="claimed", leaseUntil=_iso(NOW - timedelta(seconds=1)))
        self.assertTrue(lam._eligible(row, "a", True, True, lambda _: True, NOW))

    def test_applied_and_answered_rows_are_never_offered(self):
        for state in ("applied", "answered", "expired"):
            self.assertFalse(lam._eligible(self._row(state=state), "a", True, True, lambda _: True, NOW))


class PrimaryElectionTests(_MessagesTestCase):
    def test_the_higher_priority_site_preempts_on_its_first_beat(self):
        # The cloud worker beat first in setUp; the iMac beat second and won.
        self.assertEqual(self.beat(self.cloud)["role"], "standby")
        self.assertEqual(self.beat(self.imac)["role"], "primary")

    def test_a_lower_priority_site_cannot_take_the_role_while_the_lease_is_fresh(self):
        self.beat(self.imac)
        self.assertEqual(self.beat(self.cloud)["role"], "standby")

    def test_a_silent_primary_is_replaced_once_its_lease_lapses(self):
        self.beat(self.imac)
        row = lam.AGENTS_TABLE.items[lam._agent_key("user-1", "Fin")]
        row["primaryLeaseUntil"] = _iso(lam._now() - timedelta(seconds=1))
        self.assertEqual(self.beat(self.cloud)["role"], "primary")

    def test_a_site_that_does_not_want_the_role_never_takes_it(self):
        lam.AGENTS_TABLE.items.clear()
        self.assertEqual(self.beat(self.cloud, wantsPrimary=False)["role"], "standby")
        self.assertNotIn(lam._agent_key("user-1", "Fin"), lam.AGENTS_TABLE.items)

    def test_only_the_primary_is_handed_the_legacy_inbox(self):
        # §6.5: the legacy document keeps exactly one consumer.
        self.assertIn("legacyInboxGet", self.beat(self.imac))
        self.assertNotIn("legacyInboxGet", self.beat(self.cloud))


class SendMessageTests(_MessagesTestCase):
    def test_a_retry_with_the_same_id_is_a_no_op(self):
        first = self.send("hello", messageId="m-11111111-aaaa")
        second = self.send("hello again", messageId="m-11111111-aaaa")
        self.assertEqual(first["messageId"], second["messageId"])
        self.assertTrue(second["duplicate"])
        self.assertEqual(self.row("m-11111111-aaaa")["text"], "hello")

    def test_an_unaddressed_message_targets_the_live_primary(self):
        self.beat(self.imac)
        result = self.send("what's up")
        self.assertEqual(result["targetSiteId"], self.imac["siteId"])
        self.assertEqual(result["targetSiteName"], "Levi's iMac")
        self.assertEqual(result["routedBy"], "primary")

    def test_a_session_mention_pins_regardless_of_who_is_primary(self):
        self.beat(self.imac)
        result = self.send("restart the deploys in the agent session")
        self.assertEqual(result["pinSiteId"], self.cloud["siteId"])
        self.assertEqual(result["routedBy"], "context")

    def test_with_no_live_site_the_row_still_queues(self):
        lam.SITES_TABLE.items.clear()
        lam.AGENTS_TABLE.items.clear()
        result = self.send("anyone there?")
        self.assertEqual(result["state"], "queued")
        self.assertIsNone(result["targetSiteId"])

    def test_another_users_message_is_invisible(self):
        sent = self.send("mine")
        with self.assertRaises(lam.ApiError) as caught:
            lam.get_message({"_userId": "user-2"}, sent["messageId"])
        self.assertEqual(caught.exception.status, 404)


class ClaimProtocolTests(_MessagesTestCase):
    """§6.3 / §6.4 — the exclusion guarantees, pinned on the real condition."""

    def test_exactly_one_of_two_claimants_is_granted(self):
        sent = self.send("do the thing")
        a_status, _ = self.claim(self.imac, sent["messageId"])
        b_status, _ = self.claim(self.cloud, sent["messageId"])
        self.assertEqual((a_status, b_status), (200, 409))

    def test_the_claimant_may_re_claim_its_own_message(self):
        sent = self.send("do the thing")
        self.claim(self.imac, sent["messageId"])
        status, _ = self.claim(self.imac, sent["messageId"])
        self.assertEqual(status, 200)

    def test_a_lapsed_claim_can_be_taken_by_another_site(self):
        sent = self.send("do the thing")
        self.claim(self.imac, sent["messageId"])
        self.row(sent["messageId"])["leaseUntil"] = _iso(lam._now() - timedelta(seconds=1))
        status, _ = self.claim(self.cloud, sent["messageId"])
        self.assertEqual(status, 200)

    def test_an_applied_message_cannot_be_reclaimed_even_after_its_lease_lapses(self):
        # §6.4's one at-least-once window is a death BETWEEN submit and ack;
        # once acked, the lease no longer matters.
        sent = self.send("do the thing")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        self.row(sent["messageId"])["leaseUntil"] = _iso(lam._now() - timedelta(seconds=1))
        status, _ = self.claim(self.cloud, sent["messageId"])
        self.assertEqual(status, 409)

    def test_only_the_claimant_may_ack(self):
        sent = self.send("do the thing")
        self.claim(self.imac, sent["messageId"])
        with self.assertRaises(lam.ApiError) as caught:
            self.ack(self.cloud, sent["messageId"], "applied")
        self.assertEqual(caught.exception.status, 409)

    def test_acks_only_move_forward(self):
        sent = self.send("do the thing")
        self.claim(self.imac, sent["messageId"])
        with self.assertRaises(lam.ApiError):
            self.ack(self.imac, sent["messageId"], "answered")  # not applied yet
        self.ack(self.imac, sent["messageId"], "applied", runId="run-1")
        self.ack(self.imac, sent["messageId"], "answered", replyPreview="done")
        row = self.row(sent["messageId"])
        self.assertEqual((row["state"], row["appliedRunId"], row["replyPreview"]), ("answered", "run-1", "done"))
        self.assertIn("ttl", row)

    def test_a_site_cannot_claim_another_agents_message(self):
        other = self.enroll(agent="Nimbus", enrollKey="nimbus-box")
        sent = self.send("for fin only")
        with self.assertRaises(lam.ApiError) as caught:
            self.claim(other, sent["messageId"])
        self.assertEqual(caught.exception.status, 404)


class HeartbeatDispatchTests(_MessagesTestCase):
    def test_the_primary_is_offered_an_unaddressed_message(self):
        self.beat(self.imac)
        sent = self.send("hello")
        offered = [m["id"] for m in self.beat(self.imac)["messages"]]
        self.assertEqual(offered, [sent["messageId"]])
        self.assertEqual([m["id"] for m in self.beat(self.cloud)["messages"]], [])

    def test_a_held_message_is_renewed_not_re_offered(self):
        self.beat(self.imac)
        sent = self.send("hello")
        self.claim(self.imac, sent["messageId"])
        self.row(sent["messageId"])["leaseUntil"] = _iso(lam._now() + timedelta(seconds=5))
        result = self.beat(self.imac, held=[sent["messageId"]])
        self.assertEqual(result["messages"], [])
        renewed = lam._parse_iso(self.row(sent["messageId"])["leaseUntil"])
        self.assertGreater(renewed, lam._now() + timedelta(seconds=60))

    def test_unacked_ids_are_acked_on_the_next_beat_before_anyone_else_sees_them(self):
        # §6.4 "site dies after submit, before ack", restarted within the lease.
        self.beat(self.imac)
        sent = self.send("hello")
        self.claim(self.imac, sent["messageId"])
        self.beat(self.imac, unacked=[sent["messageId"]])
        self.assertEqual(self.row(sent["messageId"])["state"], "applied")
        self.assertEqual(self.beat(self.cloud)["messages"], [])

    def test_a_standby_takes_over_when_the_primary_goes_silent(self):
        self.beat(self.imac)
        sent = self.send("hello")  # targeted at the iMac
        lam.SITES_TABLE.items[self.imac["siteId"]]["leaseUntil"] = _iso(lam._now() - timedelta(seconds=1))
        lam.AGENTS_TABLE.items[lam._agent_key("user-1", "Fin")]["primaryLeaseUntil"] = _iso(lam._now() - timedelta(seconds=1))
        result = self.beat(self.cloud)
        self.assertEqual(result["role"], "primary")
        self.assertEqual([m["id"] for m in result["messages"]], [sent["messageId"]])


class LegacyRegisterTests(_MessagesTestCase):
    def test_registering_twice_creates_once(self):
        event = {"_userId": "user-1", "_siteId": self.imac["siteId"], "body": json.dumps({"text": "old build says hi"})}
        first = json.loads(lam.register_message(event, "m-legacy-0001")["body"])
        second = json.loads(lam.register_message(event, "m-legacy-0001")["body"])
        self.assertEqual((first["created"], second["created"]), (True, False))
        self.assertEqual(self.row("m-legacy-0001")["pinSiteId"], self.imac["siteId"])
        self.assertEqual(self.row("m-legacy-0001")["source"], "legacy")


class StaleSiteSweepTests(_SitesTestCase):
    def test_a_site_silent_for_three_leases_is_marked_stale_never_retired(self):
        site = self.enroll()
        lam.SITES_TABLE.items[site["siteId"]]["leaseUntil"] = _iso(lam._now() - timedelta(seconds=4 * lam.SITE_LEASE_SECONDS))
        lam.SITES_TABLE.items[site["siteId"]]["lastHeartbeatAt"] = "2026-01-01T00:00:00Z"
        self.assertEqual(lam._mark_stale_sites(lam._now()), [site["siteId"]])
        self.assertEqual(lam.SITES_TABLE.items[site["siteId"]]["state"], "stale")

    def test_an_enrolled_site_that_never_beat_is_not_stale(self):
        site = self.enroll()
        self.assertEqual(lam._mark_stale_sites(lam._now()), [])


class SiteTokenMessageScopeTests(unittest.TestCase):
    def test_a_site_may_claim_ack_and_register(self):
        for action in ("claim", "ack", "register"):
            lam._require_site_scope({"_siteId": "s"}, "POST", ["messages", "m-1", action])

    def test_a_site_may_not_send_or_list_messages(self):
        for method, parts in (("POST", ["messages"]), ("GET", ["messages"]), ("GET", ["messages", "m-1"])):
            with self.assertRaises(lam.ApiError):
                lam._require_site_scope({"_siteId": "s"}, method, parts)


class SiteRouteRegistrationTests(unittest.TestCase):
    """Every handler in lambda.py's router also needs a route in deploy.sh's
    ROUTES heredoc, or API Gateway 404s a path the Lambda handles perfectly —
    exactly how `GET /devices/status` shipped broken. The sites routes are new
    surface, so pin them rather than trusting a careful reading."""

    @classmethod
    def setUpClass(cls):
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "deploy.sh")) as f:
            cls.deploy_sh = f.read()

    def test_every_sites_route_is_registered(self):
        for route in (
            "POST /sites/enroll",
            "GET /sites",
            "POST /sites/{siteId}/heartbeat",
            "POST /sites/{siteId}/commands",
            "DELETE /sites/{siteId}",
            "POST /messages",
            "GET /messages",
            "GET /messages/{messageId}",
            "POST /messages/{messageId}/claim",
            "POST /messages/{messageId}/ack",
            "POST /messages/{messageId}/register",
        ):
            self.assertIn(route + "\n", self.deploy_sh, route)

    def test_the_sites_table_is_created_and_granted(self):
        self.assertIn("SITES_TABLE=fin-sites", self.deploy_sh)
        self.assertIn("MESSAGES_TABLE=fin-messages", self.deploy_sh)
        self.assertIn("AGENTS_TABLE=fin-agents", self.deploy_sh)
        self.assertIn('"Sid": "MessagesTable"', self.deploy_sh)
        self.assertIn('"Sid": "AgentsTable"', self.deploy_sh)
        self.assertIn('"Sid": "SitesTable"', self.deploy_sh)
        # Scan is load-bearing: enrollment idempotency and the site list are
        # both scans, and a policy with only Get/Put would 403 at runtime.
        sid = self.deploy_sh.split('"Sid": "SitesTable"', 1)[1].split("}", 1)[0]
        self.assertIn("dynamodb:Scan", sid)


if __name__ == "__main__":
    unittest.main()
