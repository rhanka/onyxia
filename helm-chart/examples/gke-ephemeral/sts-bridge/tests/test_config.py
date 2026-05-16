import pytest
from app.config import load_config, MissingEnv


def test_load_config_ok(monkeypatch):
    for k, v in {
        "PROJECT_ID": "p",
        "BUCKET": "b",
        "OIDC_ISSUER": "https://kc/realms/onyxia",
        "OIDC_AUDIENCE": "onyxia",
        "K8S_NAMESPACE": "onyxia",
        "BRIDGE_SA_EMAIL": "bridge@p.iam.gserviceaccount.com",
    }.items():
        monkeypatch.setenv(k, v)
    c = load_config()
    assert c.project_id == "p" and c.default_duration_seconds == 86400


def test_load_config_missing(monkeypatch):
    for k in ("PROJECT_ID", "BUCKET", "OIDC_ISSUER", "OIDC_AUDIENCE", "K8S_NAMESPACE", "BRIDGE_SA_EMAIL"):
        monkeypatch.delenv(k, raising=False)
    with pytest.raises(MissingEnv):
        load_config()
