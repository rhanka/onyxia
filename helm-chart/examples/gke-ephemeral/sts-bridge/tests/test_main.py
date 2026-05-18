from unittest.mock import patch

import pytest
from fastapi import HTTPException


@pytest.fixture
def client(monkeypatch):
    for k, v in {
        "PROJECT_ID": "p",
        "BUCKET": "b",
        "OIDC_ISSUER": "https://kc/realms/onyxia",
        "OIDC_AUDIENCE": "onyxia",
        "K8S_NAMESPACE": "onyxia",
        "BRIDGE_SA_EMAIL": "bridge@p.iam.gserviceaccount.com",
    }.items():
        monkeypatch.setenv(k, v)
    # Re-import the module so it picks up the fresh env.
    import importlib
    import app.main as m
    importlib.reload(m)
    return m


def test_health(client):
    assert client.healthz()["status"] == "ok"


def test_assume_role(client):
    m = client
    with patch.object(m, "verify_token", return_value={"sub": "abc"}), \
         patch.object(m, "provision_user_credentials", return_value=("AK", "SK")):
        r = m.assume_role(
            Action="AssumeRoleWithWebIdentity",
            WebIdentityToken="fake.jwt.here",
            DurationSeconds=3600,
        )
    assert r.status_code == 200
    assert "<AccessKeyId>AK</AccessKeyId>" in r.body.decode()
    assert "<SecretAccessKey>SK</SecretAccessKey>" in r.body.decode()


def test_assume_role_invalid_token(client):
    m = client
    from app.jwt_verify import InvalidToken

    with patch.object(m, "verify_token", side_effect=InvalidToken("bad")):
        with pytest.raises(HTTPException) as exc:
            m.assume_role(Action="AssumeRoleWithWebIdentity", WebIdentityToken="bad.jwt")
    assert exc.value.status_code == 401


def test_assume_role_unsupported_action(client):
    with pytest.raises(HTTPException) as exc:
        client.assume_role(Action="GetCallerIdentity", WebIdentityToken="x")
    assert exc.value.status_code == 400


def test_assume_role_quota_exceeded_maps_to_503(client):
    """M2: HMAC quota exhaustion must surface as HTTP 503, not 500."""
    m = client
    from app.gcp_provision import HmacQuotaExceeded

    with patch.object(m, "verify_token", return_value={"sub": "abc"}), \
         patch.object(
             m,
             "provision_user_credentials",
             side_effect=HmacQuotaExceeded("10 keys cap reached"),
         ):
        with pytest.raises(HTTPException) as exc:
            m.assume_role(Action="AssumeRoleWithWebIdentity", WebIdentityToken="x")
    assert exc.value.status_code == 503
    assert "quota" in exc.value.detail.lower() or "hmac" in exc.value.detail.lower()
