import base64

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from jose import jwt

from app.jwt_verify import InvalidToken, verify_token


def _kp():
    k = rsa.generate_private_key(65537, 2048)
    pem = k.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    pub = k.public_key().public_numbers()

    def b64u(n):
        return (
            base64.urlsafe_b64encode(n.to_bytes((n.bit_length() + 7) // 8, "big"))
            .rstrip(b"=")
            .decode()
        )

    jwk = {"kty": "RSA", "kid": "k1", "use": "sig", "alg": "RS256", "n": b64u(pub.n), "e": b64u(pub.e)}
    return pem, {"keys": [jwk]}


def test_verify_ok(monkeypatch):
    # clear the lru_cache so the monkeypatch always wins
    from app import jwt_verify
    jwt_verify._fetch_jwks.cache_clear()
    pem, jwks = _kp()
    tok = jwt.encode(
        {"sub": "abc", "aud": "onyxia", "iss": "https://kc/realms/onyxia"},
        pem,
        algorithm="RS256",
        headers={"kid": "k1"},
    )
    monkeypatch.setattr("app.jwt_verify._fetch_jwks", lambda iss: jwks)
    claims = verify_token(tok, "https://kc/realms/onyxia", "onyxia")
    assert claims["sub"] == "abc"


def test_verify_bad_aud(monkeypatch):
    from app import jwt_verify
    jwt_verify._fetch_jwks.cache_clear()
    pem, jwks = _kp()
    tok = jwt.encode(
        {"sub": "abc", "aud": "other", "iss": "https://kc/realms/onyxia"},
        pem,
        algorithm="RS256",
        headers={"kid": "k1"},
    )
    monkeypatch.setattr("app.jwt_verify._fetch_jwks", lambda iss: jwks)
    with pytest.raises(InvalidToken):
        verify_token(tok, "https://kc/realms/onyxia", "onyxia")


def test_verify_unknown_kid(monkeypatch):
    from app import jwt_verify
    jwt_verify._fetch_jwks.cache_clear()
    pem, jwks = _kp()
    tok = jwt.encode(
        {"sub": "abc", "aud": "onyxia", "iss": "https://kc/realms/onyxia"},
        pem,
        algorithm="RS256",
        headers={"kid": "unknown"},
    )
    monkeypatch.setattr("app.jwt_verify._fetch_jwks", lambda iss: jwks)
    with pytest.raises(InvalidToken):
        verify_token(tok, "https://kc/realms/onyxia", "onyxia")
