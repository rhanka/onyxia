from unittest.mock import MagicMock, patch

import pytest

from app.gcp_provision import (
    HmacQuotaExceeded,
    _gcp_bind_prefix_iam,
    _gcp_mint_hmac,
    provision_user_credentials,
    sub_short,
)


def test_sub_short_stable():
    a = sub_short("e7c1d4d2-1234-4abc-9def-deadbeef0000")
    b = sub_short("e7c1d4d2-1234-4abc-9def-deadbeef0000")
    assert a == b
    assert len(sub_short("x" * 36)) == 12


def test_sub_short_differs_for_different_sub():
    assert sub_short("alice") != sub_short("bob")


@patch("app.gcp_provision._k8s_secret_get", return_value=None)
@patch("app.gcp_provision._k8s_secret_put")
@patch(
    "app.gcp_provision._gcp_get_or_create_sa",
    return_value="onyxia-user-abc@p.iam.gserviceaccount.com",
)
@patch("app.gcp_provision._gcp_bind_prefix_iam")
@patch("app.gcp_provision._gcp_mint_hmac", return_value=("AKIATEST", "SECRETTEST"))
def test_provision_creates_when_absent(mint, bind, sa, put, get):
    ak, sk = provision_user_credentials(
        sub="abc",
        project="p",
        bucket="b",
        namespace="onyxia",
        k8s=MagicMock(),
        gcp=(MagicMock(), MagicMock()),
    )
    assert (ak, sk) == ("AKIATEST", "SECRETTEST")
    sa.assert_called_once()
    bind.assert_called_once()
    put.assert_called_once()
    mint.assert_called_once()


@patch("app.gcp_provision._k8s_secret_get", return_value=("AKCACHED", "SKCACHED"))
@patch("app.gcp_provision._gcp_mint_hmac")
@patch("app.gcp_provision._gcp_get_or_create_sa")
@patch("app.gcp_provision._gcp_bind_prefix_iam")
def test_provision_cache_hit(bind, sa, mint, _get):
    """Cache hit short-circuits BEFORE any GCP I/O."""
    ak, sk = provision_user_credentials(
        sub="abc",
        project="p",
        bucket="b",
        namespace="onyxia",
        k8s=object(),
        gcp=(object(), object()),
    )
    assert (ak, sk) == ("AKCACHED", "SKCACHED")
    mint.assert_not_called()
    sa.assert_not_called()
    bind.assert_not_called()


# -- M3: _gcp_bind_prefix_iam must be idempotent ----------------------------


def _fake_bucket_with_existing_binding(short: str, sa_email: str):
    """Build a bucket mock whose IAM policy already carries the prefix binding."""
    bucket = MagicMock()
    policy = MagicMock()
    policy.bindings = [
        {
            "role": "roles/storage.objectAdmin",
            "members": {f"serviceAccount:{sa_email}"},
            "condition": {"title": f"prefix-{short}", "expression": "...", "description": ""},
        }
    ]
    bucket.get_iam_policy.return_value = policy
    gcs = MagicMock()
    gcs.bucket.return_value = bucket
    return gcs, bucket, policy


def test_bind_prefix_iam_does_not_duplicate_existing_binding():
    short = "abc123def456"
    sa_email = f"onyxia-user-{short}@p.iam.gserviceaccount.com"
    gcs, bucket, policy = _fake_bucket_with_existing_binding(short, sa_email)
    _gcp_bind_prefix_iam(gcs, "b", sa_email, short)
    # Existing binding already present → policy.bindings count must NOT grow,
    # and set_iam_policy must NOT be called (idempotent no-op).
    assert len(policy.bindings) == 1
    bucket.set_iam_policy.assert_not_called()


def test_bind_prefix_iam_appends_when_absent():
    short = "abc123def456"
    sa_email = f"onyxia-user-{short}@p.iam.gserviceaccount.com"
    bucket = MagicMock()
    policy = MagicMock()
    # Pre-existing binding for *another* user must not block ours.
    policy.bindings = [
        {
            "role": "roles/storage.objectAdmin",
            "members": {"serviceAccount:onyxia-user-other@p.iam.gserviceaccount.com"},
            "condition": {"title": "prefix-otherxxxxxxxx", "expression": "...", "description": ""},
        }
    ]
    bucket.get_iam_policy.return_value = policy
    gcs = MagicMock()
    gcs.bucket.return_value = bucket
    _gcp_bind_prefix_iam(gcs, "b", sa_email, short)
    assert len(policy.bindings) == 2
    bucket.set_iam_policy.assert_called_once_with(policy)


# -- M2: _gcp_mint_hmac must map quota errors to HmacQuotaExceeded ----------


def test_mint_hmac_maps_quota_exceeded_to_dedicated_exception():
    gcs = MagicMock()
    # GCS Python client raises google.api_core.exceptions.ResourceExhausted on
    # quota; we mimic the surface shape (str contains "quota") to stay client-
    # version-agnostic.
    gcs.create_hmac_key.side_effect = RuntimeError(
        "Quota exceeded: maximum number of HMAC keys (10) per service account"
    )
    with pytest.raises(HmacQuotaExceeded):
        _gcp_mint_hmac(gcs, "p", "sa@p.iam.gserviceaccount.com")


def test_mint_hmac_other_errors_pass_through():
    gcs = MagicMock()
    gcs.create_hmac_key.side_effect = RuntimeError("permission denied: caller lacks role")
    with pytest.raises(RuntimeError, match="permission denied"):
        _gcp_mint_hmac(gcs, "p", "sa@p.iam.gserviceaccount.com")


# -- Dead var fix: bridge_sa_email must be observable on the cache Secret ----


def test_cache_secret_carries_bridge_sa_label():
    """The K8s cache Secret must be labelled with the bridge SA that minted it,
    so an operator can audit `kubectl get secret -l onyxia.dev/bridge-sa=...`
    and trace each cached HMAC back to its issuing bridge identity."""
    from app.gcp_provision import _k8s_secret_put

    k8s = MagicMock()
    k8s.replace_namespaced_secret.side_effect = Exception("not found")
    _k8s_secret_put(
        k8s,
        namespace="onyxia",
        name="onyxia-user-hmac-abc",
        ak="AK",
        sk="SK",
        bridge_sa_email="bridge@p.iam.gserviceaccount.com",
    )
    # On the fallback create path, the V1Secret body should carry the label.
    _, kwargs = k8s.create_namespaced_secret.call_args
    body = kwargs.get("body") or k8s.create_namespaced_secret.call_args.args[1]
    labels = body.metadata.labels or {}
    assert labels.get("onyxia.dev/bridge-sa") == "bridge-p.iam.gserviceaccount.com"


def test_cache_secret_put_without_bridge_sa_stays_label_free():
    """Backwards-compatible: omitting bridge_sa_email keeps the old behaviour
    (Secret created with no extra labels)."""
    from app.gcp_provision import _k8s_secret_put

    k8s = MagicMock()
    k8s.replace_namespaced_secret.side_effect = Exception("not found")
    _k8s_secret_put(k8s, namespace="onyxia", name="onyxia-user-hmac-abc", ak="AK", sk="SK")
    _, kwargs = k8s.create_namespaced_secret.call_args
    body = kwargs.get("body") or k8s.create_namespaced_secret.call_args.args[1]
    assert (body.metadata.labels or {}) == {}
