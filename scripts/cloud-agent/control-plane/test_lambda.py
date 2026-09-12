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
        # SET / REMOVE / ADD sections in any order, each a comma list.
        sections = re.split(r"\b(SET|REMOVE|ADD)\b", " " + update.strip())
        assert not sections[0].strip(), update
        for keyword, body in zip(sections[1::2], sections[2::2]):
            for clause in [c.strip() for c in body.split(",") if c.strip()]:
                if keyword == "SET":
                    field, _, value = clause.partition(" = ")
                    item[names.get(field.strip(), field.strip())] = values[value.strip()]
                elif keyword == "REMOVE":
                    item.pop(names.get(clause, clause), None)
                else:  # ADD field :value — numeric add, the only form used
                    field, _, value = clause.partition(" ")
                    field = names.get(field.strip(), field.strip())
                    item[field] = (item.get(field) or 0) + values[value.strip()]

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
                    ExpressionAttributeNames=None, ConditionExpression=None, ReturnValues=None):
        names = ExpressionAttributeNames or {}
        values = ExpressionAttributeValues or {}
        item = self.items.get(Key[self.key])
        if ConditionExpression and not self._eval(ConditionExpression, item or {}, names, values):
            raise self._conditional_failure("UpdateItem")
        if item is None:
            item = {self.key: Key[self.key]}
            self.items[Key[self.key]] = item
        self._apply_update(item, UpdateExpression, names, values)
        return {"Attributes": dict(item)} if ReturnValues == "ALL_NEW" else {}

    def scan(self, FilterExpression=None, ExpressionAttributeValues=None,
             ExpressionAttributeNames=None, **kwargs):
        rows = list(self.items.values())
        if FilterExpression:
            rows = [r for r in rows if self._eval(
                FilterExpression, r, ExpressionAttributeNames or {}, ExpressionAttributeValues or {}
            )]
        return {"Items": [dict(r) for r in rows]}


class _FakeEventsTable:
    """fin-thread-events: (threadId, seq) composite key, append-only, with the
    one Query shape `_thread_events_for` uses (`threadId = :thread AND seq >
    :after`, ascending, Limit)."""

    def __init__(self):
        self.rows = []

    def put_item(self, Item, **kwargs):
        self.rows.append(json.loads(json.dumps(Item, default=lam._json_default)))

    def query(self, KeyConditionExpression, ExpressionAttributeValues, ScanIndexForward=True,
              Limit=None, ExclusiveStartKey=None, **kwargs):
        assert KeyConditionExpression == "threadId = :thread AND seq > :after", KeyConditionExpression
        thread, after = ExpressionAttributeValues[":thread"], ExpressionAttributeValues[":after"]
        rows = sorted((r for r in self.rows if r["threadId"] == thread and r["seq"] > after), key=lambda r: r["seq"])
        if ExclusiveStartKey:
            rows = [r for r in rows if r["seq"] > ExclusiveStartKey["seq"]]
        page = rows[:Limit] if Limit else rows
        result = {"Items": [dict(r) for r in page]}
        if Limit and len(rows) > Limit:
            result["LastEvaluatedKey"] = {"threadId": thread, "seq": page[-1]["seq"]}
        return result

    def for_thread(self, thread_id):
        return sorted((r for r in self.rows if r["threadId"] == thread_id), key=lambda r: r["seq"])


class _SitesTestCase(unittest.TestCase):
    def setUp(self):
        for attr, key in (("SITES_TABLE", "siteId"), ("MESSAGES_TABLE", "messageId"), ("AGENTS_TABLE", "agentKey")):
            orig = getattr(lam, attr)
            setattr(lam, attr, _FakeDynamoTable(key))
            self.addCleanup(setattr, lam, attr, orig)
        self.addCleanup(setattr, lam, "THREAD_EVENTS_TABLE", lam.THREAD_EVENTS_TABLE)
        lam.THREAD_EVENTS_TABLE = _FakeEventsTable()
        self.events = lam.THREAD_EVENTS_TABLE
        # The CloudWatch line, captured instead of printed.
        self.event_lines = []
        self.addCleanup(setattr, lam, "_emit_thread_event_line", lam._emit_thread_event_line)
        lam._emit_thread_event_line = self.event_lines.append
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

    def test_a_site_may_do_its_own_work_but_never_write_secrets(self):
        # Phase 2: an EC2 body boots with only a site token, so its own work —
        # memory, transcript chunks, reading service credentials — is allowed.
        for method, path in (("GET", "/secrets"), ("GET", "/memory"), ("PUT", "/memory/profile"),
                             ("PUT", "/transcript-chunk"), ("GET", "/devices/status"),
                             ("GET", "/agents/Fin/goals"), ("PUT", "/agents/Fin/goals")):
            lam._require_site_scope({"_siteId": "site-a"}, method, self._parts(path))
        # Writing or deleting a credential is an operator's act, never a body's.
        self._assert_denied("PUT", "/secrets/github")
        self._assert_denied("DELETE", "/secrets/github")
        self._assert_denied("POST", "/sites/enroll-tokens")

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


class _PushHarness:
    """Wires `_push_to_user` to a fake APNs: a fake httpx module, a fixed
    bearer, and a recording `_apns_push`. Every push lands (200) unless the
    test says otherwise, so the assertions are about payload and count."""

    def __init__(self, case, tokens=(("tok-a", "user-1"),)):
        import sys
        import types

        self.sent = []  # (environment, token, payload)
        table = _FakeDynamoTable("token")
        for token, user in tokens:
            table.items[token] = {"token": token, "userId": user, "environment": "production"}
        case.addCleanup(setattr, lam, "DEVICE_TOKENS_TABLE", lam.DEVICE_TOKENS_TABLE)
        lam.DEVICE_TOKENS_TABLE = table
        case.addCleanup(setattr, lam, "_apns_configured", lam._apns_configured)
        lam._apns_configured = lambda: True
        case.addCleanup(setattr, lam, "_apns_bearer", lam._apns_bearer)
        lam._apns_bearer = lambda now_epoch=None: "jwt"
        case.addCleanup(setattr, lam, "_apns_push", lam._apns_push)

        def fake_push(client, environment, token, payload, bearer):
            self.sent.append((environment, token, json.loads(json.dumps(payload))))
            return True, ""

        lam._apns_push = fake_push

        class _Client:
            def __init__(self, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        fake_httpx = types.ModuleType("httpx")
        fake_httpx.Client = _Client
        previous = sys.modules.get("httpx")
        sys.modules["httpx"] = fake_httpx
        case.addCleanup(lambda: sys.modules.__setitem__("httpx", previous) if previous else sys.modules.pop("httpx", None))

    @property
    def payloads(self):
        return [payload for _, _, payload in self.sent]


class PushPayloadTests(unittest.TestCase):
    """Design §3.7.2: the Phase-1 APNs keys per event, all additive."""

    def test_every_push_is_mutable_with_a_category_and_thread(self):
        agent_id = str(lam.uuid.uuid4())
        for event in lam.NOTIFY_EVENTS:
            payload = lam._push_payload("Fin", "hi", aps_extra=lam._push_aps_extra(event, agent_id))
            aps = payload["aps"]
            self.assertEqual(aps["mutable-content"], 1, event)
            self.assertEqual(aps["thread-id"], agent_id, event)
            self.assertEqual(aps["alert"], {"title": "Fin", "body": "hi"})
            self.assertEqual(aps["sound"], "default")
            self.assertIn(aps["category"], (lam.PUSH_CATEGORY_INPUT, lam.PUSH_CATEGORY_REPLY))

    def test_category_and_interruption_level_per_event(self):
        expected = {
            "request-input": ("fin.input", "time-sensitive"),
            "agent-stalled": ("fin.input", "time-sensitive"),
            "task-complete": ("fin.reply", None),
            "notify": ("fin.reply", None),
            "answered": ("fin.reply", None),
        }
        for event, (category, level) in expected.items():
            extra = lam._push_aps_extra(event)
            self.assertEqual(extra["category"], category, event)
            self.assertEqual(extra.get("interruption-level"), level, event)
            self.assertNotIn("thread-id", extra)

    def test_unknown_or_absent_event_reads_as_notify(self):
        for raw in (None, "", "   ", "bogus", 7):
            self.assertEqual(lam._normalize_notify_event(raw), "notify")
        self.assertEqual(lam._normalize_notify_event("request-input"), "request-input")

    def test_fin_dict_is_only_present_when_given(self):
        self.assertNotIn("fin", lam._push_payload("t", "b"))
        self.assertNotIn("fin", lam._push_payload("t", "b", fin={}))
        payload = lam._push_payload("t", "b", fin={"agentName": "Fin", "messageId": "m-1"})
        self.assertEqual(payload["fin"], {"agentName": "Fin", "messageId": "m-1"})


class NotifyRouteTests(_MessagesTestCase):
    """POST /notify through the refactored fan-out: same wire contract as
    before plus the event / messageId fields."""

    def setUp(self):
        super().setUp()
        self.apns = _PushHarness(self)

    def notify(self, user="user-1", **body):
        payload = {"title": "Fin needs input", "body": "which branch?"}
        payload.update(body)
        response = lam.notify({"_userId": user, "body": json.dumps(payload)})
        return response["statusCode"], json.loads(response["body"])

    def test_request_input_carries_the_phase_one_keys(self):
        agent_id = str(lam.uuid.uuid4())
        status, result = self.notify(event="request-input", agent="Fin", agentID=agent_id, originDeviceID8="a4a1d987")
        self.assertEqual((status, result["delivered"], result["failed"], result["removed"]), (200, 1, 0, 0))
        payload = self.apns.payloads[0]
        self.assertEqual(payload["aps"]["category"], "fin.input")
        self.assertEqual(payload["aps"]["interruption-level"], "time-sensitive")
        self.assertEqual(payload["aps"]["thread-id"], agent_id)
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        self.assertEqual(payload["fin"], {"agentID": agent_id, "originDeviceID8": "a4a1d987", "agentName": "Fin"})

    def test_a_pre_phase_one_daemon_body_still_pushes_as_a_plain_notify(self):
        status, _ = self.notify()
        self.assertEqual(status, 200)
        aps = self.apns.payloads[0]["aps"]
        self.assertEqual(aps["category"], "fin.reply")
        self.assertNotIn("interruption-level", aps)
        self.assertNotIn("thread-id", aps)
        self.assertNotIn("fin", self.apns.payloads[0])

    def test_task_complete_is_not_time_sensitive(self):
        self.notify(event="task-complete", agent="Fin")
        self.assertNotIn("interruption-level", self.apns.payloads[0]["aps"])
        self.assertEqual(self.apns.payloads[0]["fin"], {"agentName": "Fin"})

    def test_message_id_lands_in_the_fin_dict_and_marks_the_row(self):
        sent = self.send("what time is it")
        status, _ = self.notify(event="task-complete", agent="Fin", messageId=sent["messageId"])
        self.assertEqual(status, 200)
        self.assertEqual(self.apns.payloads[0]["fin"]["messageId"], sent["messageId"])
        self.assertTrue(self.row(sent["messageId"]).get("pushedAt"))

    def test_a_message_id_that_is_not_the_callers_is_ignored(self):
        sent = self.send("mine", user="user-1")
        status, _ = self.notify(user="user-2", messageId=sent["messageId"])
        # user-2 has no tokens: no push, and user-1's row is untouched.
        self.assertEqual(status, 200)
        self.assertNotIn("pushedAt", self.row(sent["messageId"]))
        self.assertEqual(self.apns.sent, [])
        # A bogus or foreign messageId never suppresses the daemon's own push.
        status, result = self.notify(user="user-1", messageId=sent["messageId"].replace("m-", "m-0"))
        self.assertEqual((status, result["delivered"]), (200, 1))

    def test_a_message_already_pushed_by_its_ack_suppresses_the_daemon_push(self):
        sent = self.send("what time is it")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        self.ack(self.imac, sent["messageId"], "answered", replyPreview="noon")
        self.assertEqual(len(self.apns.sent), 1)
        status, result = self.notify(event="task-complete", agent="Fin", messageId=sent["messageId"])
        self.assertEqual((status, result["delivered"], result.get("suppressed")), (200, 0, True))
        self.assertEqual(len(self.apns.sent), 1, "the ack's push stands; the daemon's is the duplicate")
        # Without a messageId the same daemon push is not a duplicate of anything.
        status, result = self.notify(event="task-complete", agent="Fin")
        self.assertEqual((status, result["delivered"]), (200, 1))

    def test_no_tokens_is_a_200_with_a_note_and_502_when_nothing_lands(self):
        status, result = self.notify(user="user-2")
        self.assertEqual((status, result["delivered"]), (200, 0))
        self.assertIn("note", result)
        lam._apns_push = lambda *args: (False, "TooManyRequests")
        status, result = self.notify()
        self.assertEqual((status, result["reasons"]), (502, ["TooManyRequests"]))

    def test_503_without_an_apns_key(self):
        lam._apns_configured = lambda: False
        with self.assertRaises(lam.ApiError) as caught:
            self.notify()
        self.assertEqual(caught.exception.status, 503)

    def test_a_502_gives_the_claim_back_so_the_ack_push_can_still_fire(self):
        sent = self.send("deploy it")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        lam._apns_push = lambda *args: (False, "TooManyRequests")
        status, _ = self.notify(event="task-complete", agent="Fin", messageId=sent["messageId"])
        self.assertEqual(status, 502)
        self.assertNotIn("pushedAt", self.row(sent["messageId"]), "a push that reached nobody holds no claim")
        # APNs recovers; the answered ack's push is not suppressed by the failed one.
        self.apns.sent.clear()
        lam._apns_push = lambda client, environment, token, payload, bearer: (
            self.apns.sent.append((environment, token, payload)) or (True, ""))
        self.ack(self.imac, sent["messageId"], "answered", replyPreview="done")
        self.assertEqual(len(self.apns.sent), 1)
        self.assertTrue(self.row(sent["messageId"]).get("pushedAt"))

    def test_no_tokens_gives_the_claim_back(self):
        sent = self.send("hello", user="user-2")
        status, result = self.notify(user="user-2", messageId=sent["messageId"])
        self.assertEqual((status, result["delivered"]), (200, 0))
        self.assertIn("note", result)
        self.assertNotIn("pushedAt", self.row(sent["messageId"]))

    def test_a_request_input_push_claims_the_message_so_the_closing_reply_is_not_pushed_twice(self):
        # Daemon: a claimed message, the model calls request_input (a time-sensitive
        # fin.input push naming the message), then finishes the turn with text that
        # restates the question; the answered ack must NOT push that text again.
        sent = self.send("ship it")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        status, result = self.notify(event="request-input", agent="Fin", messageId=sent["messageId"])
        self.assertEqual((status, result["delivered"]), (200, 1))
        self.ack(self.imac, sent["messageId"], "answered", replyPreview="Which branch should I ship?")
        self.assertEqual(len(self.apns.sent), 1, "one push per message: the question, not its restatement")
        aps = self.apns.payloads[0]["aps"]
        self.assertEqual((aps["category"], aps["interruption-level"]), ("fin.input", "time-sensitive"))
        self.assertEqual(self.apns.payloads[0]["fin"]["messageId"], sent["messageId"])

    def test_a_site_token_may_still_notify(self):
        lam._require_site_scope({"_siteId": "site-a"}, "POST", ["notify"])


class AnsweredPushTests(_MessagesTestCase):
    """Design §3.7.3: the answered ack pushes the reply once, best-effort."""

    def setUp(self):
        super().setUp()
        self.apns = _PushHarness(self)

    def answer(self, text="what time is it", preview="It is noon.", **ack_body):
        sent = self.send(text)
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied", runId="run-1")
        response = self.ack(self.imac, sent["messageId"], "answered", replyPreview=preview, **ack_body)
        return sent["messageId"], response

    def test_answered_pushes_the_reply_exactly_once(self):
        agent_id = str(lam.uuid.uuid4())
        message_id, response = self.answer(agentID=agent_id)
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(len(self.apns.sent), 1)
        payload = self.apns.payloads[0]
        self.assertEqual(payload["aps"]["alert"], {"title": "Fin", "body": "It is noon."})
        self.assertEqual(payload["aps"]["category"], "fin.reply")
        # docs/THREADS.md §2: the Lock Screen groups by Fin thread, not agent.
        self.assertEqual(payload["aps"]["thread-id"], message_id)
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        self.assertNotIn("interruption-level", payload["aps"])
        self.assertEqual(payload["fin"], {
            "agentName": "Fin", "messageId": message_id, "agentID": agent_id, "threadId": message_id,
        })
        self.assertTrue(self.row(message_id)["pushedAt"])
        # A duplicate ack is a 409 and, separately, can never push again.
        with self.assertRaises(lam.ApiError):
            self.ack(self.imac, message_id, "answered", replyPreview="It is noon.")
        self.assertEqual(len(self.apns.sent), 1)

    def test_a_second_push_is_impossible_even_if_the_row_is_re_answered(self):
        message_id, _ = self.answer()
        self.assertEqual(len(self.apns.sent), 1)
        # Simulate the storage-level rewind a bug could produce: pushedAt wins anyway.
        self.row(message_id)["state"] = "applied"
        self.ack(self.imac, message_id, "answered", replyPreview="again")
        self.assertEqual(len(self.apns.sent), 1)

    def test_the_daemons_task_complete_push_suppresses_the_ack_push(self):
        sent = self.send("deploy it")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        lam.notify({"_userId": "user-1", "body": json.dumps({
            "title": "Fin: task complete", "body": "TASK COMPLETE", "agent": "Fin",
            "event": "task-complete", "messageId": sent["messageId"],
        })})
        self.assertEqual(len(self.apns.sent), 1)
        self.ack(self.imac, sent["messageId"], "answered", replyPreview="TASK COMPLETE")
        self.assertEqual(len(self.apns.sent), 1, "one push per message, the daemon's")
        self.assertEqual(self.apns.payloads[0]["aps"]["alert"]["title"], "Fin: task complete")

    def test_no_preview_means_no_push(self):
        sent = self.send("hmm")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        self.ack(self.imac, sent["messageId"], "answered", replyPreview="   ")
        self.assertEqual(self.apns.sent, [])
        self.assertNotIn("pushedAt", self.row(sent["messageId"]))

    def test_a_push_failure_never_fails_the_ack_and_leaves_the_row_pushable(self):
        def boom(*args, **kwargs):
            raise RuntimeError("apns is down")
        self.addCleanup(setattr, lam, "_push_to_user", lam._push_to_user)
        real_push = lam._push_to_user
        lam._push_to_user = boom
        message_id, response = self.answer()
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(self.row(message_id)["state"], "answered")
        self.assertNotIn("pushedAt", self.row(message_id), "a failed push must not blackhole the reply")
        # The daemon's task-complete /notify for the same message then delivers
        # instead of being suppressed as "already pushed".
        lam._push_to_user = real_push
        response = lam.notify({"_userId": "user-1", "body": json.dumps({
            "title": "Fin: task complete", "body": "TASK COMPLETE", "agent": "Fin",
            "event": "task-complete", "messageId": message_id,
        })})
        result = json.loads(response["body"])
        self.assertEqual((response["statusCode"], result["delivered"], result.get("suppressed")), (200, 1, None))
        self.assertTrue(self.row(message_id).get("pushedAt"))

    def test_apns_not_configured_never_fails_the_ack_and_holds_no_claim(self):
        lam._apns_configured = lambda: False
        message_id, response = self.answer()
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(self.apns.sent, [])
        self.assertNotIn("pushedAt", self.row(message_id))

    def test_a_push_that_reaches_nobody_gives_the_claim_back(self):
        lam._apns_push = lambda *args: (False, "TooManyRequests")
        message_id, response = self.answer()
        self.assertEqual(response["statusCode"], 200)
        self.assertNotIn("pushedAt", self.row(message_id))

    def test_the_answering_device_is_left_out_of_the_fan_out(self):
        # Two devices: the iMac (which hosted the turn and registered its token
        # with its deviceId8) and a phone. The ack names the iMac; only the phone
        # is pushed, and the payload says where the reply came from.
        self.apns = _PushHarness(self, tokens=(("tok-imac", "user-1"), ("tok-phone", "user-1")))
        lam.DEVICE_TOKENS_TABLE.items["tok-imac"]["deviceId8"] = "a4a1d987"
        agent_id = str(lam.uuid.uuid4())
        message_id, _ = self.answer(agentID=agent_id, originDeviceID8="a4a1d987")
        self.assertEqual([token for _, token, _ in self.apns.sent], ["tok-phone"])
        self.assertEqual(self.apns.payloads[0]["fin"], {
            "agentName": "Fin", "messageId": message_id, "agentID": agent_id, "originDeviceID8": "a4a1d987",
            "threadId": message_id,
        })
        self.assertTrue(self.row(message_id).get("pushedAt"))

    def test_only_the_answering_device_registered_means_nothing_to_push_and_no_claim(self):
        lam.DEVICE_TOKENS_TABLE.items["tok-a"]["deviceId8"] = "a4a1d987"
        message_id, _ = self.answer(originDeviceID8="a4a1d987")
        self.assertEqual(self.apns.sent, [])
        self.assertNotIn("pushedAt", self.row(message_id))

    def test_a_malformed_origin_device_is_ignored_not_fatal(self):
        message_id, response = self.answer(originDeviceID8="not-hex!")
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(len(self.apns.sent), 1)
        self.assertNotIn("originDeviceID8", self.apns.payloads[0]["fin"])

    def test_the_ack_push_carries_what_the_app_needs_to_reply_and_deep_link(self):
        """The app-side contract (AgentNotificationService.replyTarget /
        parseFinPayload, finTests/CommunicationNotificationTests
        testTheControlPlanesAckPushIsReplyableAndTappable): a typed Reply needs
        BOTH fin.agentID and fin.agentName, a tap needs fin.agentID, and the
        NSE threads on aps.thread-id — the Fin thread (docs/THREADS.md §2),
        which for a lone request is the message's own id. The daemon and the
        app both send agentID + originDeviceID8 on the answered ack; this pins
        the resulting shape."""
        agent_id = str(lam.uuid.uuid4())
        message_id, _ = self.answer(agentID=agent_id, originDeviceID8="a4a1d987")
        payload = self.apns.payloads[0]
        self.assertEqual(payload["aps"]["thread-id"], message_id)
        self.assertEqual(payload["aps"]["category"], "fin.reply")
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        self.assertEqual(set(payload["fin"]), {"agentName", "messageId", "agentID", "originDeviceID8", "threadId"})
        self.assertEqual(json.dumps(payload["fin"], sort_keys=True), json.dumps({
            "agentID": agent_id, "agentName": "Fin", "messageId": message_id, "originDeviceID8": "a4a1d987",
            "threadId": message_id,
        }, sort_keys=True))

    def test_the_push_is_not_gated_on_voice(self):
        for source in ("app", "voice"):
            sent = self.send("q " + source, source=source)
            self.claim(self.imac, sent["messageId"])
            self.ack(self.imac, sent["messageId"], "applied")
            self.ack(self.imac, sent["messageId"], "answered", replyPreview="a")
        self.assertEqual(len(self.apns.sent), 2)


class DeviceTokenRegistrationTests(unittest.TestCase):
    """PUT /device-tokens with the Phase-1 `deviceId8`: stored when sent so an
    answered ack from that device can leave its own tokens out, dropped when a
    (pre-Phase-1) re-registration omits it, rejected when malformed."""

    def setUp(self):
        self.table = _FakeDynamoTable("token")
        self.addCleanup(setattr, lam, "DEVICE_TOKENS_TABLE", lam.DEVICE_TOKENS_TABLE)
        lam.DEVICE_TOKENS_TABLE = self.table

    def put(self, **body):
        payload = {"token": "ab" * 32, "platform": "iOS"}
        payload.update(body)
        response = lam.put_device_token({"_userId": "user-1", "body": json.dumps(payload)})
        return response["statusCode"], json.loads(response["body"])

    def test_device_id8_is_stored_lowercased_and_dropped_when_omitted(self):
        status, _ = self.put(deviceId8="A4A1D987", deviceName="Levi's iPhone")
        self.assertEqual(status, 200)
        row = self.table.items["ab" * 32]
        self.assertEqual((row["deviceId8"], row["userId"], row["deviceName"]), ("a4a1d987", "user-1", "Levi's iPhone"))
        self.put()
        row = self.table.items["ab" * 32]
        self.assertNotIn("deviceId8", row)
        self.assertNotIn("deviceName", row)

    def test_a_malformed_device_id8_is_a_400(self):
        with self.assertRaises(lam.ApiError) as caught:
            self.put(deviceId8="zz")
        self.assertEqual(caught.exception.status, 400)
        self.assertEqual(self.table.items, {})


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



class _FakeS3:
    """Enough S3 for the config overlay, goals ledger, and the binary sidecar."""

    def __init__(self, objects=None):
        self.objects = dict(objects or {})

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise lam.ClientError({"Error": {"Code": "NoSuchKey", "Message": Key}}, "GetObject")
        import io
        return {"Body": io.BytesIO(self.objects[Key])}

    def put_object(self, Bucket, Key, Body, **kwargs):
        self.objects[Key] = Body if isinstance(Body, bytes) else Body.encode("utf-8")
        return {}

    def delete_object(self, Bucket, Key):
        self.objects.pop(Key, None)
        return {}

    def list_objects_v2(self, **kwargs):
        prefix = kwargs.get("Prefix", "")
        keys = sorted(k for k in self.objects if k.startswith(prefix))
        return {"Contents": [{"Key": k} for k in keys]}


class KeyVaultTests(unittest.TestCase):
    """The vault stores ciphertext only, per user, for session tokens only."""

    def setUp(self):
        self._orig_s3 = lam.S3
        lam.S3 = _FakeS3()
        self.addCleanup(setattr, lam, "S3", self._orig_s3)

    @staticmethod
    def _put(user, key_id, **fields):
        body = {"name": "laptop", "keyType": "ed25519", "ciphertext": base64.b64encode(b"sealed").decode()}
        body.update(fields)
        return lam.put_vault_key({"_userId": user, "body": json.dumps(body)}, key_id)

    @staticmethod
    def _list(user):
        return json.loads(lam.list_vault_keys({"_userId": user})["body"])["keys"]

    def test_entries_round_trip_per_user_and_never_cross_accounts(self):
        self._put("user-1", "0f0f0f0f-0000-4000-8000-000000000001")
        self._put("user-2", "0f0f0f0f-0000-4000-8000-000000000002", name="tv")
        mine = self._list("user-1")
        self.assertEqual([entry["keyId"] for entry in mine], ["0F0F0F0F-0000-4000-8000-000000000001"])
        self.assertEqual(mine[0]["ciphertext"], base64.b64encode(b"sealed").decode())
        self.assertTrue(mine[0]["updatedAt"])
        self.assertIsNone(mine[0]["vaultKeyFingerprint"])
        self._put("user-1", "0f0f0f0f-0000-4000-8000-000000000003", vaultKeyFingerprint="ab12cd34ab12cd34")
        self.assertEqual(self._list("user-1")[-1]["vaultKeyFingerprint"], "ab12cd34ab12cd34")
        with self.assertRaises(lam.ApiError):
            self._put("user-1", "0f0f0f0f-0000-4000-8000-000000000004", vaultKeyFingerprint="not hex!")
        self.assertEqual([entry["name"] for entry in self._list("user-2")], ["tv"])

    def test_delete_is_idempotent_and_scoped(self):
        self._put("user-1", "0f0f0f0f-0000-4000-8000-000000000001")
        lam.delete_vault_key({"_userId": "user-2"}, "0f0f0f0f-0000-4000-8000-000000000001")
        self.assertEqual(len(self._list("user-1")), 1)
        lam.delete_vault_key({"_userId": "user-1"}, "0f0f0f0f-0000-4000-8000-000000000001")
        lam.delete_vault_key({"_userId": "user-1"}, "0f0f0f0f-0000-4000-8000-000000000001")
        self.assertEqual(self._list("user-1"), [])

    def test_rejects_bad_ids_types_and_non_base64(self):
        for key_id, fields in (
            ("../etc", {}),
            ("0f0f0f0f-0000-4000-8000-000000000001", {"keyType": "dsa"}),
            ("0f0f0f0f-0000-4000-8000-000000000001", {"ciphertext": "not base64!!"}),
            ("0f0f0f0f-0000-4000-8000-000000000001", {"name": " "}),
        ):
            with self.assertRaises(lam.ApiError) as caught:
                self._put("user-1", key_id, **fields)
            self.assertEqual(caught.exception.status, 400)
        self.assertEqual(lam.S3.objects, {})

    def test_a_site_token_cannot_touch_the_vault(self):
        for method, parts in (("GET", ["vault", "keys"]), ("PUT", ["vault", "keys", "x"]), ("DELETE", ["vault", "keys", "x"])):
            with self.assertRaises(lam.ApiError) as caught:
                lam._require_site_scope({"_siteId": "site-1", "_userId": "user-1"}, method, parts)
            self.assertEqual(caught.exception.status, 403)


class EnrollTokenTests(_SitesTestCase):
    def setUp(self):
        super().setUp()
        orig = lam.ENROLL_TOKENS_TABLE
        lam.ENROLL_TOKENS_TABLE = _FakeDynamoTable("tokenSha256")
        self.addCleanup(setattr, lam, "ENROLL_TOKENS_TABLE", orig)
        # The fake has no delete_item; give it one that honours attribute_exists.
        def delete_item(Key, ConditionExpression=None):
            if Key["tokenSha256"] not in lam.ENROLL_TOKENS_TABLE.items:
                raise lam.ClientError({"Error": {"Code": "ConditionalCheckFailedException", "Message": "no"}}, "DeleteItem")
            del lam.ENROLL_TOKENS_TABLE.items[Key["tokenSha256"]]
        lam.ENROLL_TOKENS_TABLE.delete_item = delete_item

    def _mint(self):
        response = lam.mint_enroll_token({"_userId": "user-1", "body": json.dumps({"agent": "Fin", "displayName": "Studio Mac"})})
        return json.loads(response["body"])["enrollToken"]

    def test_a_token_enrolls_once_as_its_owner_then_dies(self):
        token = self._mint()
        event = {"body": json.dumps({"enrollToken": token, "enrollKey": "studio/levi"})}
        first = json.loads(lam.enroll_with_token(event)["body"])
        self.assertEqual(lam.SITES_TABLE.items[first["siteId"]]["userId"], "user-1")
        self.assertEqual(lam.SITES_TABLE.items[first["siteId"]]["displayName"], "Studio Mac")
        with self.assertRaises(lam.ApiError) as caught:
            lam.enroll_with_token({"body": json.dumps({"enrollToken": token, "enrollKey": "studio/levi"})})
        self.assertEqual(caught.exception.status, 401)

    def test_an_expired_token_is_unauthorized(self):
        token = self._mint()
        row = next(iter(lam.ENROLL_TOKENS_TABLE.items.values()))
        row["expiresAt"] = _iso(lam._now() - timedelta(seconds=1))
        with self.assertRaises(lam.ApiError) as caught:
            lam.enroll_with_token({"body": json.dumps({"enrollToken": token, "enrollKey": "x"})})
        self.assertEqual(caught.exception.status, 401)

    def test_an_unknown_token_is_unauthorized_not_404(self):
        with self.assertRaises(lam.ApiError) as caught:
            lam.enroll_with_token({"body": json.dumps({"enrollToken": "nope", "enrollKey": "x"})})
        self.assertEqual(caught.exception.status, 401)


class GoalsLedgerTests(_SitesTestCase):
    def setUp(self):
        super().setUp()
        self._orig_s3 = lam.S3
        lam.S3 = _FakeS3()
        self.addCleanup(setattr, lam, "S3", self._orig_s3)

    def _put(self, version, document, user="user-1", site_id=None):
        event = {"_userId": user, "headers": {"if-match": str(version)}, "body": json.dumps({"document": document})}
        if site_id:
            event["_siteId"] = site_id
        response = lam.put_goals(event, "Fin")
        return response["statusCode"], json.loads(response["body"])

    def test_first_write_needs_if_match_zero_and_yields_version_one(self):
        status, body = self._put(0, {"version": 1, "goals": [{"id": "g1"}]})
        self.assertEqual((status, body["version"]), (200, 1))
        got = json.loads(lam.get_goals({"_userId": "user-1"}, "Fin")["body"])
        self.assertEqual(got["version"], 1)
        self.assertEqual(got["document"]["goals"][0]["id"], "g1")

    def test_a_stale_write_gets_412_with_the_current_document(self):
        self._put(0, {"goals": ["a"]})
        self._put(1, {"goals": ["a", "b"]})
        status, body = self._put(1, {"goals": ["a", "c"]})  # based on v1, but v2 exists
        self.assertEqual(status, 412)
        self.assertEqual((body["version"], body["document"]), (2, {"goals": ["a", "b"]}))

    def test_missing_if_match_is_428(self):
        with self.assertRaises(lam.ApiError) as caught:
            lam.put_goals({"_userId": "user-1", "headers": {}, "body": json.dumps({"document": {}})}, "Fin")
        self.assertEqual(caught.exception.status, 428)

    def test_a_site_may_only_sync_its_own_agent(self):
        other = self.enroll(agent="Nimbus", enrollKey="nimbus-box")
        with self.assertRaises(lam.ApiError) as caught:
            self._put(0, {"goals": []}, site_id=other["siteId"])
        self.assertEqual(caught.exception.status, 404)

    def test_an_unwritten_ledger_reads_as_version_zero(self):
        got = json.loads(lam.get_goals({"_userId": "user-1"}, "Fin")["body"])
        self.assertEqual((got["version"], got["document"]), (0, None))


class WorkerSiteOverlayTests(_SitesTestCase):
    def test_overlay_adds_the_site_block_and_swaps_the_bearer(self):
        orig = lam.S3
        lam.S3 = _FakeS3({"cfg.json": json.dumps({
            "controlPlane": {"endpointURL": "https://cp", "token": "OPERATOR-SECRET"},
            "supervision": {"directiveURL": "d", "inboxURL": "i", "agentName": "Fin"},
        }).encode()})
        self.addCleanup(setattr, lam, "S3", orig)
        site = self.enroll(kind="ec2", enrollKey="ec2/w1")
        lam._overlay_site_onto_config("cfg.json", site)
        config = json.loads(lam.S3.objects["cfg.json"])
        self.assertEqual(config["site"]["id"], site["siteId"])
        self.assertEqual(config["controlPlane"]["token"], site["siteToken"])
        self.assertNotIn("OPERATOR-SECRET", json.dumps(config), "the operator bearer never boards an instance")
        self.assertNotIn("inboxURL", config["supervision"], "Phase 3: the inbox object is retired")


class SweepVerdictWithSiteTests(_SitesTestCase):
    def _worker(self, site_id):
        return {"workerId": "w1", "userId": "user-1", "agent": "Fin", "siteId": site_id,
                "idleMinutes": 30, "launchedAt": _iso(lam._now() - timedelta(hours=2))}

    def test_a_working_site_is_never_swept(self):
        site = self.enroll(kind="ec2", enrollKey="ec2/w1")
        row = lam.SITES_TABLE.items[site["siteId"]]
        row.update({"state": "working", "leaseUntil": _iso(lam._now() + timedelta(seconds=30)),
                    "lastHeartbeatAt": _iso(lam._now() - timedelta(hours=1))})
        self.assertIsNone(lam._sweep_verdict(self._worker(site["siteId"]), lam._now()))

    def test_a_site_idle_past_its_window_is_swept(self):
        site = self.enroll(kind="ec2", enrollKey="ec2/w1")
        row = lam.SITES_TABLE.items[site["siteId"]]
        row.update({"state": "idle", "leaseUntil": _iso(lam._now() + timedelta(seconds=30)),
                    "lastHeartbeatAt": _iso(lam._now() - timedelta(minutes=45))})
        self.assertIn("site idle since", lam._sweep_verdict(self._worker(site["siteId"]), lam._now()) or "")

    def test_a_site_whose_lease_lapsed_long_ago_is_swept(self):
        site = self.enroll(kind="ec2", enrollKey="ec2/w1")
        row = lam.SITES_TABLE.items[site["siteId"]]
        row.update({"state": "idle", "leaseUntil": _iso(lam._now() - timedelta(minutes=10)),
                    "lastHeartbeatAt": _iso(lam._now() - timedelta(minutes=11))})
        self.assertIn("lease lapsed", lam._sweep_verdict(self._worker(site["siteId"]), lam._now()) or "")


class WakeOnMessagesTests(_MessagesTestCase):
    def test_candidates_are_the_oldest_unclaimed_row_per_agent(self):
        a = self.send("first")
        self.row(a["messageId"])["createdAt"] = _iso(lam._now() - timedelta(minutes=10))
        self.send("second")
        claimed = self.send("claimed one")
        self.claim(self.imac, claimed["messageId"])
        candidates = lam._queued_message_candidates(lam._now())
        self.assertEqual(len(candidates), 1)
        user, agent, oldest = candidates[0]
        self.assertEqual((user, agent), ("user-1", "Fin"))
        self.assertEqual(_iso(oldest), self.row(a["messageId"])["createdAt"])

    def test_a_live_site_of_any_kind_counts_as_a_live_body(self):
        self.assertTrue(lam._any_live_site("user-1", "Fin", lam._now()))
        lam.SITES_TABLE.items.clear()
        self.assertFalse(lam._any_live_site("user-1", "Fin", lam._now()))


class StaleSiteNotifyTests(_SitesTestCase):
    def test_a_silent_resident_site_notifies_once_at_the_transition(self):
        sent = []
        orig = lam.notify
        lam.notify = lambda event: sent.append(json.loads(event["body"]))
        self.addCleanup(setattr, lam, "notify", orig)
        site = self.enroll(kind="resident", displayName="Levi's iMac")
        row = lam.SITES_TABLE.items[site["siteId"]]
        row.update({"leaseUntil": _iso(lam._now() - timedelta(minutes=5)), "lastHeartbeatAt": "2026-01-01T00:00:00Z"})
        lam._mark_stale_sites(lam._now())
        lam._mark_stale_sites(lam._now())
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["title"], "Fin lost contact with Levi's iMac")

    def test_a_silent_cloud_worker_does_not_page_the_owner(self):
        sent = []
        orig = lam.notify
        lam.notify = lambda event: sent.append(1)
        self.addCleanup(setattr, lam, "notify", orig)
        site = self.enroll(kind="ec2", enrollKey="ec2/w1")
        row = lam.SITES_TABLE.items[site["siteId"]]
        row.update({"leaseUntil": _iso(lam._now() - timedelta(minutes=5)), "lastHeartbeatAt": "2026-01-01T00:00:00Z"})
        lam._mark_stale_sites(lam._now())
        self.assertEqual(sent, [])


class BinaryPresignTests(unittest.TestCase):
    def test_agentd_binary_kind_returns_url_and_sidecar_digest(self):
        orig_s3, orig_presign = lam.S3, lam._presign
        lam.S3 = _FakeS3({lam.MACOS_BINARY_SHA256_KEY: b"abc123  fin-agentd-macos-arm64\n"})
        lam._presign = lambda method, key: "https://example.invalid/" + key
        self.addCleanup(setattr, lam, "S3", orig_s3)
        self.addCleanup(setattr, lam, "_presign", orig_presign)
        body = json.loads(lam.presign({"_userId": "u", "body": json.dumps({"kinds": ["agentdBinary"]})})["body"])
        self.assertTrue(body["urls"]["agentdBinaryGet"].endswith(lam.MACOS_BINARY_KEY))
        self.assertEqual(body["urls"]["agentdBinarySha256"], "abc123")

    def test_no_published_binary_is_a_404_not_a_500(self):
        orig_s3, orig_presign = lam.S3, lam._presign
        lam.S3 = _FakeS3()
        lam._presign = lambda method, key: "https://example.invalid/" + key
        self.addCleanup(setattr, lam, "S3", orig_s3)
        self.addCleanup(setattr, lam, "_presign", orig_presign)
        with self.assertRaises(lam.ApiError) as caught:
            lam.presign({"_userId": "u", "body": json.dumps({"kinds": ["agentdBinary"]})})
        self.assertEqual(caught.exception.status, 404)



class TranscriptChunkMergeTests(unittest.TestCase):
    """A restart must never erase an hour's earlier traces (live, 2026-09-12)."""

    def _line(self, id_, ts, seq=0, run="r1"):
        return json.dumps({"id": id_, "timestamp": ts, "run_id": run, "sequence": seq, "kind": "reasoning", "text": id_})

    def test_a_restarted_daemons_partial_hour_is_merged_not_substituted(self):
        before = [self._line("a", "2026-09-12T16:35:15Z", 1), self._line("b", "2026-09-12T16:35:46Z", 2)]
        after_restart = [self._line("c", "2026-09-12T16:44:01Z", 1, run="r2")]
        merged = lam._merge_transcript_lines(before, after_restart)
        self.assertEqual([json.loads(l)["id"] for l in merged], ["a", "b", "c"])

    def test_re_put_of_the_same_ring_is_idempotent(self):
        ring = [self._line("a", "2026-09-12T16:35:15Z", 1), self._line("b", "2026-09-12T16:35:46Z", 2)]
        self.assertEqual(lam._merge_transcript_lines(ring, ring), lam._merge_transcript_lines([], ring))

    def test_the_cap_drops_the_oldest(self):
        orig = lam.MAX_TRANSCRIPT_CHUNK_LINES
        lam.MAX_TRANSCRIPT_CHUNK_LINES = 2
        self.addCleanup(setattr, lam, "MAX_TRANSCRIPT_CHUNK_LINES", orig)
        lines = [self._line(str(i), "2026-09-12T16:0%d:00Z" % i, i) for i in range(4)]
        merged = lam._merge_transcript_lines(lines[:2], lines[2:])
        self.assertEqual([json.loads(l)["id"] for l in merged], ["2", "3"])

    def test_unparseable_lines_survive_by_text(self):
        merged = lam._merge_transcript_lines(["not json"], ["not json", self._line("a", "2026-09-12T16:00:00Z")])
        self.assertEqual(merged.count("not json"), 1)
        self.assertEqual(len(merged), 2)


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
            "POST /sites/enroll-tokens",
            "GET /agents/{agent}/goals",
            "PUT /agents/{agent}/goals",
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



# --- threads (docs/THREADS.md) -------------------------------------------------


class _ThreadsTestCase(_MessagesTestCase):
    """Messages harness plus a controllable clock, so ordering tests can put
    activity at distinct instants, and helpers for the read routes."""

    def setUp(self):
        super().setUp()
        self.clock = [NOW]
        self.addCleanup(setattr, lam, "_now", lam._now)
        lam._now = lambda: self.clock[0]

    def tick(self, seconds=1):
        self.clock[0] = self.clock[0] + timedelta(seconds=seconds)

    def kinds(self, thread_id):
        return [e["kind"] for e in self.events.for_thread(thread_id)]

    def list_threads(self, user="user-1", **params):
        query = {"agent": "Fin"}
        query.update(params)
        response = lam.list_threads({"_userId": user, "queryStringParameters": query})
        return response["statusCode"], json.loads(response["body"])

    def get_thread(self, thread_id, user="user-1"):
        response = lam.get_thread({"_userId": user}, thread_id)
        return response["statusCode"], json.loads(response["body"])

    def lifecycle(self, text="do the thing", site=None, preview="done", **send_extra):
        """send → claim → applied → answered on one site; returns the message id."""
        site = site or self.imac
        sent = self.send(text, **send_extra)
        self.tick()
        self.claim(site, sent["messageId"])
        self.tick()
        self.ack(site, sent["messageId"], "applied", runId="run-1")
        self.tick()
        self.ack(site, sent["messageId"], "answered", replyPreview=preview)
        self.tick()
        return sent["messageId"]


class ThreadAssignmentTests(_ThreadsTestCase):
    def test_a_message_roots_its_own_thread_by_default(self):
        sent = self.send("hello")
        self.assertEqual(sent["threadId"], sent["messageId"])
        self.assertEqual(self.row(sent["messageId"])["threadId"], sent["messageId"])
        self.assertNotIn("threadReason", self.row(sent["messageId"]))

    def test_an_explicit_thread_id_joins_that_thread(self):
        root = self.send("first")
        reply = self.send("second", threadId=root["messageId"])
        self.assertEqual(reply["threadId"], root["messageId"])
        self.assertEqual(self.row(reply["messageId"])["threadReason"], "explicit")
        # Naming a MEMBER resolves to the root, so a reply to a reply stays in one thread.
        third = self.send("third", threadId=reply["messageId"])
        self.assertEqual(third["threadId"], root["messageId"])

    def test_a_foreign_unknown_or_other_agent_thread_id_is_a_400(self):
        theirs = self.send("not yours", user="user-2")
        nimbus = self.enroll(agent="Nimbus", enrollKey="nimbus-box")
        self.beat(nimbus)
        other_agent = json.loads(lam.send_message({"_userId": "user-1", "body": json.dumps(
            {"agent": "Nimbus", "text": "nimbus thing"})})["body"])
        for bad in (theirs["messageId"], other_agent["messageId"], "m-00000000-does-not-exist", "garbage"):
            with self.assertRaises(lam.ApiError, msg=bad) as caught:
                self.send("reply", threadId=bad)
            self.assertEqual(caught.exception.status, 400)

    def test_the_site_may_propose_a_thread_at_applied_time_with_a_reason(self):
        root = self.send("send the PDF to the claw session")
        later = self.send("did it finish?")
        self.claim(self.imac, later["messageId"])
        response = self.ack(self.imac, later["messageId"], "applied", threadId=root["messageId"], threadReason="pane:main:2.0")
        self.assertEqual(json.loads(response["body"])["threadId"], root["messageId"])
        row = self.row(later["messageId"])
        self.assertEqual((row["threadId"], row["threadReason"]), (root["messageId"], "pane:main:2.0"))
        assigned = [e for e in self.events.for_thread(root["messageId"]) if e["kind"] == "thread.assigned"]
        self.assertEqual(len(assigned), 1)
        self.assertEqual(assigned[0]["detail"], {
            "messageId": later["messageId"], "threadId": root["messageId"], "reason": "pane:main:2.0",
        })
        self.assertEqual(assigned[0]["actor"], "system")

    def test_a_proposal_is_validated_like_an_explicit_id(self):
        theirs = self.send("not yours", user="user-2")
        mine = self.send("mine")
        self.claim(self.imac, mine["messageId"])
        with self.assertRaises(lam.ApiError) as caught:
            self.ack(self.imac, mine["messageId"], "applied", threadId=theirs["messageId"])
        self.assertEqual(caught.exception.status, 400)
        self.assertEqual(self.row(mine["messageId"])["state"], "claimed", "a refused proposal applies nothing")

    def test_explicit_membership_beats_the_sites_proposal(self):
        root = self.send("root")
        elsewhere = self.send("elsewhere")
        reply = self.send("reply", threadId=root["messageId"])
        self.claim(self.imac, reply["messageId"])
        self.ack(self.imac, reply["messageId"], "applied", threadId=elsewhere["messageId"], threadReason="pane:x:1")
        self.assertEqual(self.row(reply["messageId"])["threadId"], root["messageId"])
        assigned = [e for e in self.events.for_thread(root["messageId"]) if e["kind"] == "thread.assigned"]
        self.assertEqual(assigned[-1]["detail"]["reason"], "explicit")

    def test_no_proposal_means_root_and_a_long_reason_is_clipped(self):
        sent = self.send("alone")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        assigned = [e for e in self.events.for_thread(sent["messageId"]) if e["kind"] == "thread.assigned"]
        self.assertEqual(assigned[0]["detail"]["reason"], "root")
        other = self.send("other")
        another = self.send("another")
        self.claim(self.imac, another["messageId"])
        self.ack(self.imac, another["messageId"], "applied", threadId=other["messageId"], threadReason="x" * 100)
        self.assertEqual(len(self.row(another["messageId"])["threadReason"]), lam.MAX_THREAD_REASON_CHARS)

    # The turn-end fallback (docs/THREADS.md §2): the daemon only learns which pane
    # a turn relayed into once the turn has run, so the ANSWERED ack may carry the
    # proposal the applied ack could not.

    def test_the_site_may_propose_a_thread_on_the_answered_ack(self):
        root = self.send("send the PDF to the claw session")
        later = self.send("did it finish?")
        self.claim(self.imac, later["messageId"])
        self.ack(self.imac, later["messageId"], "applied")
        self.assertEqual(self.row(later["messageId"])["threadId"], later["messageId"], "rooted alone at applied time")
        response = self.ack(self.imac, later["messageId"], "answered", replyPreview="it did",
                            threadId=root["messageId"], threadReason="pane:main:2.0")
        self.assertEqual(json.loads(response["body"])["threadId"], root["messageId"])
        row = self.row(later["messageId"])
        self.assertEqual((row["state"], row["threadId"], row["threadReason"]), ("answered", root["messageId"], "pane:main:2.0"))
        on_root = self.events.for_thread(root["messageId"])
        assigned = [e for e in on_root if e["kind"] == "thread.assigned" and e["detail"]["messageId"] == later["messageId"]]
        self.assertEqual(len(assigned), 1)
        self.assertEqual(assigned[0]["detail"], {
            "messageId": later["messageId"], "threadId": root["messageId"], "reason": "pane:main:2.0",
        })
        answered = [e for e in on_root if e["kind"] == "message.answered"]
        self.assertEqual([e["detail"]["messageId"] for e in answered], [later["messageId"]],
                         "the answered event lands on the thread the message moved to")
        # The thread view still shows the member's early life (queued/claimed/applied
        # under its own id) — the timeline pulls those in.
        status, body = self.get_thread(root["messageId"])
        self.assertEqual(status, 200)
        self.assertIn("message.applied", [e["kind"] for e in body["events"]])

    def test_an_answered_proposal_is_validated_like_an_applied_one(self):
        theirs = self.send("not yours", user="user-2")
        mine = self.send("mine")
        self.claim(self.imac, mine["messageId"])
        self.ack(self.imac, mine["messageId"], "applied")
        with self.assertRaises(lam.ApiError) as caught:
            self.ack(self.imac, mine["messageId"], "answered", replyPreview="done", threadId=theirs["messageId"])
        self.assertEqual(caught.exception.status, 400)
        self.assertEqual(self.row(mine["messageId"])["state"], "applied", "a refused proposal answers nothing")

    def test_explicit_membership_beats_an_answered_proposal_too(self):
        root = self.send("root")
        elsewhere = self.send("elsewhere")
        reply = self.send("reply", threadId=root["messageId"])
        self.claim(self.imac, reply["messageId"])
        self.ack(self.imac, reply["messageId"], "applied")
        self.ack(self.imac, reply["messageId"], "answered", replyPreview="done",
                 threadId=elsewhere["messageId"], threadReason="pane:x:1")
        self.assertEqual(self.row(reply["messageId"])["threadId"], root["messageId"])
        kinds_elsewhere = self.kinds(elsewhere["messageId"])
        self.assertNotIn("message.answered", kinds_elsewhere)
        assigned = [e for e in self.events.for_thread(root["messageId"]) if e["kind"] == "thread.assigned"]
        self.assertEqual([e["detail"]["reason"] for e in assigned], ["explicit"], "one decision, logged once")

    def test_re_proposing_the_thread_the_row_is_already_in_is_not_a_transition(self):
        root = self.send("root")
        later = self.send("later")
        self.claim(self.imac, later["messageId"])
        self.ack(self.imac, later["messageId"], "applied", threadId=root["messageId"], threadReason="pane:main:2.0")
        self.ack(self.imac, later["messageId"], "answered", replyPreview="done",
                 threadId=root["messageId"], threadReason="pane:main:2.0")
        assigned = [e for e in self.events.for_thread(root["messageId"])
                    if e["kind"] == "thread.assigned" and e["detail"]["messageId"] == later["messageId"]]
        self.assertEqual(len(assigned), 1)
        self.assertEqual(self.kinds(root["messageId"])[-1], "message.answered")

    def test_an_answered_ack_without_a_proposal_keeps_the_thread_and_logs_no_assignment(self):
        sent = self.send("alone")
        self.claim(self.imac, sent["messageId"])
        self.ack(self.imac, sent["messageId"], "applied")
        self.ack(self.imac, sent["messageId"], "answered", replyPreview="done")
        kinds = self.kinds(sent["messageId"])
        self.assertEqual(kinds.count("thread.assigned"), 1, "only the applied-time decision")
        self.assertEqual(kinds[-1], "message.answered")

    def test_the_public_message_carries_thread_pushed_and_claimed_stamps(self):
        message_id = self.lifecycle()
        public = lam._public_message(self.row(message_id))
        for key in ("threadId", "pushedAt", "appliedRunId", "claimedAt"):
            self.assertIn(key, public)
        self.assertEqual((public["threadId"], public["appliedRunId"]), (message_id, "run-1"))
        self.assertTrue(public["claimedAt"])


class ThreadEventTests(_ThreadsTestCase):
    def test_one_event_per_transition_with_monotonic_seq(self):
        message_id = self.lifecycle()
        events = self.events.for_thread(message_id)
        self.assertEqual([e["seq"] for e in events], [1, 2, 3, 4, 5])
        self.assertEqual([e["kind"] for e in events], [
            "message.queued", "message.claimed", "message.applied", "thread.assigned", "message.answered",
        ])
        self.assertEqual(self.row(message_id)["threadEventSeq"], 5)
        self.assertEqual(len(self.event_lines), 5, "one CloudWatch line per event")
        self.assertEqual(self.event_lines[0]["kind"], "message.queued")
        for event in events:
            self.assertEqual((event["userId"], event["agent"]), ("user-1", "Fin"))
            self.assertTrue(event["ttl"] > int(NOW.timestamp()))

    def test_event_details_name_the_actors(self):
        message_id = self.lifecycle(context={"device_id8": "a4a1d987"})
        queued, claimed, applied, _assigned, answered = self.events.for_thread(message_id)
        self.assertEqual((queued["actor"], queued["detail"]["source"], queued["detail"]["routedBy"]), ("a4a1d987", "app", "primary"))
        self.assertEqual(queued["detail"]["authorSiteId8"], "a4a1d987")
        self.assertEqual((claimed["actor"], claimed["detail"]["siteId8"]), (self.imac["siteId8"], self.imac["siteId8"]))
        self.assertEqual(applied["detail"]["runId"], "run-1")
        self.assertEqual((answered["detail"]["replyPreview"], answered["detail"]["pushed"]), ("done", False))

    def test_a_delivered_answer_push_is_recorded_as_pushed(self):
        _PushHarness(self)
        message_id = self.lifecycle(preview="It is noon.")
        answered = self.events.for_thread(message_id)[-1]
        self.assertTrue(answered["detail"]["pushed"])

    def test_renewals_and_retries_are_not_transitions(self):
        sent = self.send("q", messageId="m-11111111-aaaa")
        self.send("q", messageId="m-11111111-aaaa")  # duplicate send
        self.claim(self.imac, sent["messageId"])
        self.claim(self.imac, sent["messageId"])  # holder renews
        self.assertEqual(self.kinds(sent["messageId"]), ["message.queued", "message.claimed"])

    def test_seq_is_per_thread_and_a_moved_message_keeps_its_early_events(self):
        root = self.send("root")
        moved = self.send("moved")
        self.claim(self.imac, moved["messageId"])
        self.ack(self.imac, moved["messageId"], "applied", threadId=root["messageId"], threadReason="pane:main:2.0")
        self.assertEqual(self.kinds(moved["messageId"]), ["message.queued", "message.claimed"])
        self.assertEqual(self.kinds(root["messageId"]), ["message.queued", "message.applied", "thread.assigned"])
        self.assertEqual([e["seq"] for e in self.events.for_thread(root["messageId"])], [1, 2, 3])

    def test_a_bookkeeping_failure_never_fails_the_route(self):
        class _Broken:
            def put_item(self, **kwargs):
                raise RuntimeError("dynamo down")

            def query(self, **kwargs):
                raise RuntimeError("dynamo down")

        lam.THREAD_EVENTS_TABLE = _Broken()
        sent = self.send("still works")
        self.assertEqual(sent["state"], "queued")
        status, body = self.get_thread(sent["messageId"])
        self.assertEqual((status, body["events"]), (200, []))

    def test_an_unknown_thread_never_gets_a_root_row_conjured(self):
        self.assertIsNone(lam._thread_event("user-1", "m-00000000-nothing", "notify.sent", "operator", {}))
        self.assertNotIn("m-00000000-nothing", lam.MESSAGES_TABLE.items)
        self.assertEqual(self.events.rows, [])

    def test_the_heartbeats_unacked_path_records_applied(self):
        sent = self.send("q")
        self.claim(self.imac, sent["messageId"])
        self.beat(self.imac, unacked=[sent["messageId"]])
        self.assertEqual(self.kinds(sent["messageId"]), [
            "message.queued", "message.claimed", "message.applied", "thread.assigned",
        ])


class NotifyThreadTests(_ThreadsTestCase):
    def setUp(self):
        super().setUp()
        self.apns = _PushHarness(self)

    def notify(self, user="user-1", site=None, **body):
        payload = {"title": "Fin", "body": "which branch?"}
        payload.update(body)
        event = {"_userId": user, "body": json.dumps(payload)}
        if site:
            event["_siteId"] = site["siteId"]
        response = lam.notify(event)
        return response["statusCode"], json.loads(response["body"])

    def test_notify_with_thread_id_records_notify_sent_and_groups_the_push(self):
        root = self.send("root")
        status, result = self.notify(event="request-input", agent="Fin", threadId=root["messageId"])
        self.assertEqual((status, result["delivered"]), (200, 1))
        events = self.events.for_thread(root["messageId"])
        self.assertEqual([e["kind"] for e in events], ["message.queued", "notify.sent"])
        self.assertEqual(events[-1]["actor"], "operator")
        self.assertEqual(events[-1]["detail"], {
            "event": "request-input", "title": "Fin", "body": "which branch?",
            "delivered": 1, "failed": 0, "suppressed": False, "threadId": root["messageId"],
        })
        payload = self.apns.payloads[0]
        self.assertEqual(payload["aps"]["thread-id"], root["messageId"])
        self.assertEqual(payload["fin"]["threadId"], root["messageId"])

    def test_notify_with_only_message_id_resolves_the_thread(self):
        root = self.send("root")
        reply = self.send("reply", threadId=root["messageId"])
        status, _ = self.notify(event="task-complete", messageId=reply["messageId"])
        self.assertEqual(status, 200)
        sent = self.events.for_thread(root["messageId"])[-1]
        self.assertEqual((sent["kind"], sent["detail"]["messageId"], sent["detail"]["threadId"]),
                         ("notify.sent", reply["messageId"], root["messageId"]))
        self.assertEqual(self.apns.payloads[0]["fin"]["threadId"], root["messageId"])

    def test_a_suppressed_push_is_still_an_event(self):
        message_id = self.lifecycle(preview="It is noon.")  # the ack pushed
        status, result = self.notify(event="task-complete", messageId=message_id)
        self.assertEqual((status, result.get("suppressed")), (200, True))
        sent = self.events.for_thread(message_id)[-1]
        self.assertEqual((sent["kind"], sent["detail"]["suppressed"], sent["detail"]["delivered"]), ("notify.sent", True, 0))

    def test_a_foreign_thread_id_is_ignored_not_fatal(self):
        theirs = self.send("theirs", user="user-2")
        status, _ = self.notify(threadId=theirs["messageId"])
        self.assertEqual(status, 200)
        self.assertEqual(self.events.for_thread(theirs["messageId"]), [
            e for e in self.events.rows if e["kind"] == "message.queued" and e["threadId"] == theirs["messageId"]
        ])
        self.assertNotIn("fin", self.apns.payloads[0])

    def test_a_site_is_the_actor_when_it_notifies(self):
        root = self.send("root")
        self.notify(site=self.imac, event="agent-stalled", threadId=root["messageId"])
        self.assertEqual(self.events.for_thread(root["messageId"])[-1]["actor"], self.imac["siteId8"])

    def test_without_a_thread_nothing_is_recorded(self):
        status, _ = self.notify()
        self.assertEqual(status, 200)
        self.assertEqual(self.events.rows, [])


class GoalFollowupEventTests(_ThreadsTestCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(setattr, lam, "S3", lam.S3)
        lam.S3 = _FakeS3()

    def put(self, version, goals, site=None):
        event = {"_userId": "user-1", "headers": {"if-match": str(version)}, "body": json.dumps({"document": {"goals": goals}})}
        if site:
            event["_siteId"] = site["siteId"]
        return lam.put_goals(event, "Fin")["statusCode"]

    def followup(self, message_id, target="main:2.0"):
        tail = message_id.replace("m-", "")[:8]
        return {
            "id": "g-followup-" + tail, "title": "Follow up: send the PDF", "state": "active", "priority": 1,
            "why": "The user asked for this by voice; it was handed to pane {}.".format(target),
            "next_action": "read_session {}. The pane's LATEST reply is the answer.".format(target),
            "tags": ["followup", "send_session"], "source": "daemon",
        }

    def test_a_new_followup_goal_is_an_event_on_the_requests_thread(self):
        sent = self.send("send the PDF to the claw session")
        self.assertEqual(self.put(0, [{"id": "g1", "title": "unrelated"}], site=self.imac), 200)
        self.assertEqual(self.put(1, [{"id": "g1", "title": "unrelated"}, self.followup(sent["messageId"])], site=self.imac), 200)
        events = self.events.for_thread(sent["messageId"])
        self.assertEqual([e["kind"] for e in events], ["message.queued", "goal.followup"])
        self.assertEqual(events[-1]["actor"], self.imac["siteId8"])
        self.assertEqual(events[-1]["detail"]["goalId"], "g-followup-" + sent["messageId"][2:10])
        self.assertEqual(events[-1]["detail"]["target"], "main:2.0")
        self.assertTrue(events[-1]["detail"]["nextAction"].startswith("read_session main:2.0"))

    def test_an_unchanged_followup_is_not_re_reported(self):
        sent = self.send("q")
        goal = self.followup(sent["messageId"])
        self.put(0, [goal])
        self.put(1, [goal, {"id": "g2", "title": "new but not a follow-up"}])
        self.assertEqual(self.kinds(sent["messageId"]), ["message.queued", "goal.followup"])

    def test_a_goal_naming_its_thread_outright_wins_over_the_id_tail(self):
        root = self.send("root")
        reply = self.send("reply", threadId=root["messageId"])
        goal = dict(self.followup("m-ffffffff-no-such-message"), message_id=reply["messageId"])
        self.put(0, [goal])
        self.assertEqual(self.kinds(root["messageId"])[-1], "goal.followup")

    def test_a_followup_with_no_matching_message_is_skipped(self):
        self.put(0, [self.followup("m-ffffffff-no-such-message")])
        self.assertEqual(self.events.rows, [])

    def test_new_followup_detection_is_pure(self):
        before = {"goals": [{"id": "g-followup-a"}, {"id": "g1"}]}
        after = {"goals": [{"id": "g-followup-a"}, {"id": "g-followup-b"}, {"id": "g2"}, "junk"]}
        self.assertEqual([g["id"] for g in lam._new_followup_goals(before, after)], ["g-followup-b"])
        self.assertEqual([g["id"] for g in lam._new_followup_goals(None, after)], ["g-followup-a", "g-followup-b"])
        self.assertEqual(lam._new_followup_goals(after, {"goals": "nope"}), [])


class RelayEventTests(_ThreadsTestCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(setattr, lam, "S3", lam.S3)
        lam.S3 = _FakeS3()

    def line(self, id_, tool, text, target="main:2.0", **extra):
        obj = {"id": id_, "timestamp": _iso(NOW), "run_id": "r1", "sequence": 1, "kind": "toolCall",
               "tool_name": tool, "text": text, "target": target}
        obj.update(extra)
        return json.dumps(obj)

    def put(self, lines, site=None):
        site = site or self.imac
        event = {"_userId": "user-1", "_siteId": site["siteId"], "body": json.dumps({
            "agent": "Fin", "hour": "2026-09-12T10", "lines": lines,
        })}
        return lam.put_transcript_chunk(event)["statusCode"]

    def test_send_and_read_session_lines_with_a_target_become_relay_events(self):
        root = self.send("send the PDF")
        reply = self.send("did it finish?", threadId=root["messageId"])
        status = self.put([
            self.line("l1", "send_session", "send_session: main:2.0 (127 chars)", in_reply_to=root["messageId"]),
            self.line("l2", "read_session", "read_session: main:2.0", thread_id=root["messageId"]),
            self.line("l3", "read_session", "read_session: main:2.0", in_reply_to=reply["messageId"]),
        ])
        self.assertEqual(status, 200)
        events = self.events.for_thread(root["messageId"])[2:]
        self.assertEqual([e["kind"] for e in events], ["relay.sent", "relay.read", "relay.read"])
        self.assertEqual(events[0]["actor"], self.imac["siteId8"])
        self.assertEqual(events[0]["detail"], {
            "target": "main:2.0", "text": "send_session: main:2.0 (127 chars)", "lineId": "l1", "runId": "r1",
            "inReplyTo": root["messageId"],
        })
        self.assertEqual(events[1]["detail"]["threadId"], root["messageId"])

    def test_re_sending_the_ring_does_not_duplicate_events(self):
        root = self.send("root")
        lines = [self.line("l1", "send_session", "sent", in_reply_to=root["messageId"])]
        self.put(lines)
        self.put(lines)
        self.put(lines + [self.line("l2", "read_session", "read", in_reply_to=root["messageId"])])
        self.assertEqual(self.kinds(root["messageId"]), ["message.queued", "relay.sent", "relay.read"])

    def test_lines_without_a_target_or_a_thread_are_not_relays(self):
        root = self.send("root")
        self.put([
            self.line("l1", "send_session", "no target", target="", in_reply_to=root["messageId"]),
            self.line("l2", "send_session", "heartbeat turn, no thread"),
            self.line("l3", "remember", "other tool", in_reply_to=root["messageId"]),
            json.dumps({"id": "l4", "kind": "reply", "text": "plain", "timestamp": _iso(NOW)}),
            "not json at all",
        ])
        self.assertEqual(self.kinds(root["messageId"]), ["message.queued"])

    def test_the_line_parser_is_pure(self):
        kind, detail, site8 = lam._relay_line_event(json.dumps({
            "kind": "toolCall", "tool_name": "read_session", "target": "agent:1", "text": "x" * 500,
            "site_id8": "deadbeef", "thread_id": "m-1",
        }))
        self.assertEqual((kind, site8, len(detail["text"]), detail["threadId"]), ("relay.read", "deadbeef", 200, "m-1"))
        self.assertIsNone(lam._relay_line_event("{}"))


class ThreadStatusTests(unittest.TestCase):
    """The one pure derivation, table-driven."""

    @staticmethod
    def notify(event):
        return {"kind": "notify.sent", "detail": {"event": event}}

    def test_status_table(self):
        answered = [{"state": "answered"}]
        open_msg = [{"state": "claimed"}]
        cases = [
            ("no events, open message", open_msg, [], "working"),
            ("no events, all answered", answered, [], "answered"),
            ("request-input last", answered, [{"kind": "message.answered"}, self.notify("request-input")], "waiting_on_you"),
            ("request-input then answered", answered, [self.notify("request-input"), {"kind": "message.answered"}], "answered"),
            ("agent-stalled last with open message", open_msg, [self.notify("agent-stalled")], "stalled"),
            ("agent-stalled then a new message", [{"state": "queued"}], [self.notify("agent-stalled"), {"kind": "message.queued"}], "working"),
            ("follow-up goal open", answered, [{"kind": "message.answered"}, {"kind": "goal.followup"}], "working"),
            ("follow-up then answered", answered, [{"kind": "goal.followup"}, {"kind": "message.answered"}], "answered"),
            ("task-complete last, all answered", answered, [self.notify("task-complete")], "answered"),
            ("empty thread", [], [], "answered"),
        ]
        for name, messages, events, expected in cases:
            self.assertEqual(lam._thread_status(messages, events), expected, name)

    def test_open_goal_is_the_latest_unanswered_followup(self):
        self.assertIsNone(lam._thread_open_goal([]))
        events = [{"kind": "goal.followup", "detail": {"goalId": "g-followup-1"}}]
        self.assertEqual(lam._thread_open_goal(events), "g-followup-1")
        self.assertIsNone(lam._thread_open_goal(events + [{"kind": "message.answered"}]))

    def test_participants_are_distinct_and_ordered(self):
        messages = [{"authorSiteId8": "a4a1d987"}, {}]
        events = [
            {"actor": "4cf8cfd8"}, {"actor": "system", "detail": {"target": "main:2.0"}},
            {"actor": "operator"}, {"actor": "4cf8cfd8", "detail": {"target": "main:2.0"}},
        ]
        self.assertEqual(lam._thread_participants(messages, events), ["a4a1d987", "4cf8cfd8", "main:2.0", "operator"])
        self.assertEqual(lam._thread_participants([{}], []), ["user"])


class ThreadListTests(_ThreadsTestCase):
    def test_threads_are_newest_activity_first_and_limited(self):
        first = self.lifecycle("first")
        second = self.send("second")["messageId"]
        self.tick()
        third = self.send("third")["messageId"]
        self.tick()
        # Activity on the FIRST thread makes it the newest.
        lam._thread_event("user-1", first, "notify.sent", "operator", {"event": "task-complete"})
        status, body = self.list_threads()
        self.assertEqual(status, 200)
        self.assertEqual([t["threadId"] for t in body["threads"]], [first, third, second])
        self.assertEqual([t["status"] for t in body["threads"]], ["answered", "working", "working"])
        status, body = self.list_threads(limit="2")
        self.assertEqual([t["threadId"] for t in body["threads"]], [first, third])

    def test_a_pre_threads_row_is_its_own_thread(self):
        legacy = {"messageId": "m-legacy-0001-aaaa", "userId": "user-1", "agent": "Fin", "text": "old",
                  "state": "answered", "createdAt": _iso(NOW - timedelta(days=1))}
        lam.MESSAGES_TABLE.items[legacy["messageId"]] = legacy
        status, body = self.list_threads()
        self.assertEqual([t["threadId"] for t in body["threads"]], [legacy["messageId"]])
        self.assertEqual(body["threads"][0]["title"], "old")
        status, body = self.get_thread(legacy["messageId"])
        self.assertEqual((status, body["thread"]["messageCount"], body["messages"][0]["threadId"]), (200, 1, legacy["messageId"]))

    def test_summary_fields(self):
        root = self.send("x" * 100, context={"device_id8": "a4a1d987"})
        reply = self.send("reply", threadId=root["messageId"])
        self.claim(self.cloud, reply["messageId"])
        _status, body = self.list_threads()
        summary = body["threads"][0]
        self.assertEqual(len(summary["title"]), lam.MAX_THREAD_TITLE_CHARS)
        self.assertTrue(summary["title"].endswith("…"))
        self.assertEqual((summary["messageCount"], summary["agent"], summary["status"]), (2, "Fin", "working"))
        self.assertEqual(summary["participants"], ["a4a1d987", self.cloud["siteId8"]])
        self.assertNotIn("openGoal", summary)
        self.assertEqual(summary["lastActivityAt"], self.row(reply["messageId"])["claimedAt"])

    def test_open_goal_surfaces(self):
        root = self.send("root")
        lam._thread_event("user-1", root["messageId"], "goal.followup", self.imac["siteId8"], {"goalId": "g-followup-abc"})
        _status, body = self.list_threads()
        self.assertEqual(body["threads"][0]["openGoal"], "g-followup-abc")

    def test_listing_is_scoped_to_caller_and_agent(self):
        self.send("mine")
        self.send("theirs", user="user-2")
        _status, body = self.list_threads(user="user-2")
        self.assertEqual([t["title"] for t in body["threads"]], ["theirs"])
        _status, body = self.list_threads(agent="Nimbus")
        self.assertEqual(body["threads"], [])
        with self.assertRaises(lam.ApiError):
            lam.list_threads({"_userId": "user-1", "queryStringParameters": {}})


class ThreadGetTests(_ThreadsTestCase):
    def test_get_returns_messages_and_a_merged_timeline_oldest_first(self):
        root = self.send("root")
        self.tick()
        moved = self.send("moved")
        self.tick()
        self.claim(self.imac, moved["messageId"])
        self.tick()
        self.ack(self.imac, moved["messageId"], "applied", threadId=root["messageId"], threadReason="pane:main:2.0")
        status, body = self.get_thread(root["messageId"])
        self.assertEqual(status, 200)
        self.assertEqual([m["messageId"] for m in body["messages"]], [root["messageId"], moved["messageId"]])
        self.assertEqual([e["kind"] for e in body["events"]], [
            "message.queued", "message.queued", "message.claimed", "message.applied", "thread.assigned",
        ])
        self.assertEqual([e["threadId"] for e in body["events"]][:3], [root["messageId"], moved["messageId"], moved["messageId"]])
        self.assertEqual(body["thread"]["status"], "working")
        self.assertEqual(body["thread"]["messageCount"], 2)
        for event in body["events"]:
            self.assertEqual(set(event), {"threadId", "seq", "agent", "kind", "actor", "detail", "at"})

    def test_a_member_id_a_foreign_id_and_garbage_are_404(self):
        root = self.send("root")
        reply = self.send("reply", threadId=root["messageId"])
        theirs = self.send("theirs", user="user-2")
        for bad in (reply["messageId"], theirs["messageId"], "m-00000000-nothing", "nope"):
            with self.assertRaises(lam.ApiError, msg=bad) as caught:
                lam.get_thread({"_userId": "user-1"}, bad)
            self.assertEqual(caught.exception.status, 404)

    def test_events_tail_after_seq(self):
        message_id = self.lifecycle()
        response = lam.get_thread_events({"_userId": "user-1", "queryStringParameters": {"after": "3"}}, message_id)
        body = json.loads(response["body"])
        self.assertEqual([e["seq"] for e in body["events"]], [4, 5])
        response = lam.get_thread_events({"_userId": "user-1"}, message_id)
        self.assertEqual(len(json.loads(response["body"])["events"]), 5)
        with self.assertRaises(lam.ApiError):
            lam.get_thread_events({"_userId": "user-1", "queryStringParameters": {"after": "x"}}, message_id)

    def test_the_router_reaches_all_three_routes(self):
        message_id = self.lifecycle()
        for path in ("/threads", "/threads/" + message_id, "/threads/" + message_id + "/events"):
            event = {"_userId": "user-1", "rawPath": path, "requestContext": {"http": {"method": "GET"}},
                     "queryStringParameters": {"agent": "Fin"}}
            self.assertEqual(lam._route(event)["statusCode"], 200, path)


class ThreadSiteScopeTests(unittest.TestCase):
    def test_a_site_may_read_threads(self):
        for parts in (["threads"], ["threads", "m-1"], ["threads", "m-1", "events"]):
            lam._require_site_scope({"_siteId": "s"}, "GET", parts)

    def test_a_site_may_not_write_threads(self):
        for method, parts in (("POST", ["threads"]), ("PUT", ["threads", "m-1"]), ("DELETE", ["threads", "m-1"])):
            with self.assertRaises(lam.ApiError) as caught:
                lam._require_site_scope({"_siteId": "s"}, method, parts)
            self.assertEqual(caught.exception.status, 403)


class ThreadRouteRegistrationTests(SiteRouteRegistrationTests):
    def test_every_threads_route_is_registered(self):
        for route in ("GET /threads", "GET /threads/{threadId}", "GET /threads/{threadId}/events"):
            self.assertIn(route + "\n", self.deploy_sh, route)

    def test_the_thread_events_table_is_created_and_granted(self):
        self.assertIn("THREAD_EVENTS_TABLE=fin-thread-events", self.deploy_sh)
        self.assertIn('"Sid": "ThreadEventsTable"', self.deploy_sh)
        sid = self.deploy_sh.split('"Sid": "ThreadEventsTable"', 1)[1].split("}", 1)[0]
        self.assertIn("dynamodb:Query", sid)
        self.assertIn("dynamodb:PutItem", sid)
        self.assertIn("AttributeName=seq,KeyType=RANGE", self.deploy_sh)


if __name__ == "__main__":
    unittest.main()
