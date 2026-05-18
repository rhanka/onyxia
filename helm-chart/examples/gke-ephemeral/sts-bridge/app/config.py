"""Typed environment-variable loader for the STS bridge."""
from __future__ import annotations

import os
from dataclasses import dataclass


class MissingEnv(RuntimeError):
    """Raised when one or more required environment variables is missing."""


@dataclass(frozen=True)
class Config:
    project_id: str
    bucket: str
    oidc_issuer: str
    oidc_audience: str
    k8s_namespace: str
    bridge_sa_email: str
    default_duration_seconds: int
    cors_allow_origins: tuple[str, ...]


_REQUIRED = [
    "PROJECT_ID",
    "BUCKET",
    "OIDC_ISSUER",
    "OIDC_AUDIENCE",
    "K8S_NAMESPACE",
    "BRIDGE_SA_EMAIL",
]


def load_config() -> Config:
    missing = [k for k in _REQUIRED if not os.environ.get(k)]
    if missing:
        raise MissingEnv(f"missing env: {missing}")
    return Config(
        project_id=os.environ["PROJECT_ID"],
        bucket=os.environ["BUCKET"],
        oidc_issuer=os.environ["OIDC_ISSUER"],
        oidc_audience=os.environ["OIDC_AUDIENCE"],
        k8s_namespace=os.environ["K8S_NAMESPACE"],
        bridge_sa_email=os.environ["BRIDGE_SA_EMAIL"],
        default_duration_seconds=int(os.environ.get("DEFAULT_DURATION_SECONDS", "86400")),
        cors_allow_origins=tuple(
            origin.strip()
            for origin in os.environ.get("CORS_ALLOW_ORIGINS", "").split(",")
            if origin.strip()
        ),
    )
