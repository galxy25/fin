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


if __name__ == "__main__":
    unittest.main()
