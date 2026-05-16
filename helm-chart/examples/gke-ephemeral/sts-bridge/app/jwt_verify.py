"""Keycloak JWT verifier using the realm's JWKS endpoint."""
from __future__ import annotations

from functools import lru_cache

import httpx
from jose import jwt
from jose.exceptions import JWTError


class InvalidToken(ValueError):
    """Raised whenever a JWT fails signature/issuer/audience/kid validation."""


@lru_cache(maxsize=4)
def _fetch_jwks(issuer: str) -> dict:
    """Fetch the OpenID Connect JWKS for a Keycloak-style issuer.

    Cached per-issuer for the lifetime of the process. Keycloak rotates keys
    rarely; the daily restart of the bridge is enough churn to refresh the
    cache in practice.
    """
    url = issuer.rstrip("/") + "/protocol/openid-connect/certs"
    r = httpx.get(url, timeout=5.0)
    r.raise_for_status()
    return r.json()


def verify_token(token: str, issuer: str, audience: str) -> dict:
    """Validate signature, issuer, audience and expiration; return claims."""
    try:
        hdr = jwt.get_unverified_header(token)
    except JWTError as e:
        raise InvalidToken(f"unparseable header: {e}") from e

    jwks = _fetch_jwks(issuer)
    kid = hdr.get("kid")
    key = next((k for k in jwks.get("keys", []) if k.get("kid") == kid), None)
    if key is None:
        raise InvalidToken(f"kid {kid!r} not found in JWKS")

    try:
        return jwt.decode(
            token,
            key,
            algorithms=[key.get("alg", "RS256")],
            audience=audience,
            issuer=issuer,
        )
    except JWTError as e:
        raise InvalidToken(str(e)) from e
