from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient


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
    return TestClient(m.app), m


def test_health(client):
    c, _ = client
    r = c.get("/healthz")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_assume_role(client):
    c, m = client
    with patch.object(m, "verify_token", return_value={"sub": "abc"}), \
         patch.object(m, "provision_user_credentials", return_value=("AK", "SK")):
        r = c.post(
            "/",
            data={
                "Action": "AssumeRoleWithWebIdentity",
                "WebIdentityToken": "fake.jwt.here",
                "DurationSeconds": "3600",
            },
        )
    assert r.status_code == 200
    assert "<AccessKeyId>AK</AccessKeyId>" in r.text
    assert "<SecretAccessKey>SK</SecretAccessKey>" in r.text


def test_assume_role_invalid_token(client):
    c, m = client
    from app.jwt_verify import InvalidToken

    with patch.object(m, "verify_token", side_effect=InvalidToken("bad")):
        r = c.post(
            "/",
            data={
                "Action": "AssumeRoleWithWebIdentity",
                "WebIdentityToken": "bad.jwt",
            },
        )
    assert r.status_code == 401


def test_assume_role_unsupported_action(client):
    c, _ = client
    r = c.post(
        "/",
        data={"Action": "GetCallerIdentity", "WebIdentityToken": "x"},
    )
    assert r.status_code == 400


def test_assume_role_quota_exceeded_maps_to_503(client):
    """M2: HMAC quota exhaustion must surface as HTTP 503, not 500."""
    c, m = client
    from app.gcp_provision import HmacQuotaExceeded

    with patch.object(m, "verify_token", return_value={"sub": "abc"}), \
         patch.object(
             m,
             "provision_user_credentials",
             side_effect=HmacQuotaExceeded("10 keys cap reached"),
         ):
        r = c.post(
            "/",
            data={"Action": "AssumeRoleWithWebIdentity", "WebIdentityToken": "x"},
        )
    assert r.status_code == 503
    assert "quota" in r.text.lower() or "hmac" in r.text.lower()
