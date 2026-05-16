"""Per-user GCP service-account + HMAC provisioner with K8s Secret cache.

For each Keycloak `sub` we:
1. derive a stable 12-hex `sub_short` (SHA-256 prefix);
2. look up a cached HMAC pair in a K8s Secret `onyxia-user-hmac-<short>`;
3. on cache miss: create a per-user GCP SA `onyxia-user-<short>@<proj>.iam`,
   bind it with `roles/storage.objectAdmin` *only* on the
   `user-<short>/*` prefix via an IAM Condition, mint a fresh HMAC key,
   persist it in the cache Secret, and return it.

The HMAC key is what Onyxia hands back to launched services as
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. GCS interop endpoint
(`storage.googleapis.com`) honours it via the S3-compatible API.
"""
from __future__ import annotations

import base64
import hashlib
import logging
from typing import Optional, Tuple

log = logging.getLogger("sts-bridge.gcp_provision")


def sub_short(sub: str) -> str:
    """Stable, short, GCP-SA-name-safe identifier derived from a JWT sub."""
    return hashlib.sha256(sub.encode()).hexdigest()[:12]


def _secret_name(short: str) -> str:
    return f"onyxia-user-hmac-{short}"


# -------- K8s helpers -------------------------------------------------------

def _k8s_client():
    """Lazy import + load Kubernetes config (in-cluster first, kubeconfig fallback)."""
    from kubernetes import client as kc, config as kconf

    try:
        kconf.load_incluster_config()
    except Exception:
        kconf.load_kube_config()
    return kc.CoreV1Api()


def _k8s_secret_get(k8s, namespace: str, name: str) -> Optional[Tuple[str, str]]:
    """Return (access_key, secret_key) if the cache Secret exists, else None."""
    try:
        s = k8s.read_namespaced_secret(name, namespace)
    except Exception:
        return None
    data = {k: base64.b64decode(v).decode() for k, v in (s.data or {}).items()}
    ak = data.get("access_key")
    sk = data.get("secret_key")
    if ak and sk:
        return ak, sk
    return None


def _k8s_secret_put(k8s, namespace: str, name: str, ak: str, sk: str) -> None:
    """Upsert the cache Secret idempotently."""
    from kubernetes import client as kc

    data = {
        "access_key": base64.b64encode(ak.encode()).decode(),
        "secret_key": base64.b64encode(sk.encode()).decode(),
    }
    body = kc.V1Secret(
        metadata=kc.V1ObjectMeta(name=name),
        data=data,
        type="Opaque",
    )
    try:
        k8s.replace_namespaced_secret(name, namespace, body)
    except Exception:
        k8s.create_namespaced_secret(namespace, body)


# -------- GCP helpers -------------------------------------------------------

def _gcp_clients():
    """Build the IAM admin + GCS clients on first use."""
    from googleapiclient import discovery
    from google.cloud import storage

    return discovery.build("iam", "v1", cache_discovery=False), storage.Client()


def _gcp_get_or_create_sa(iam, project: str, short: str) -> str:
    """Idempotent: return the per-user SA email, creating it on first call."""
    name = f"onyxia-user-{short}"
    email = f"{name}@{project}.iam.gserviceaccount.com"
    sas = iam.projects().serviceAccounts()
    try:
        sas.get(name=f"projects/{project}/serviceAccounts/{email}").execute()
    except Exception:
        sas.create(
            name=f"projects/{project}",
            body={
                "accountId": name,
                "serviceAccount": {"displayName": f"Onyxia user {short}"},
            },
        ).execute()
    return email


def _gcp_bind_prefix_iam(gcs, bucket: str, sa_email: str, short: str) -> None:
    """Grant objectAdmin scoped to `user-<short>/*` via IAM Condition."""
    b = gcs.bucket(bucket)
    policy = b.get_iam_policy(requested_policy_version=3)
    policy.version = 3
    cond = {
        "title": f"prefix-{short}",
        "description": f"Only user-{short}/* in {bucket}",
        "expression": (
            f'resource.name.startsWith("projects/_/buckets/{bucket}'
            f'/objects/user-{short}/")'
        ),
    }
    policy.bindings.append(
        {
            "role": "roles/storage.objectAdmin",
            "members": {f"serviceAccount:{sa_email}"},
            "condition": cond,
        }
    )
    b.set_iam_policy(policy)


def _gcp_mint_hmac(gcs, project: str, sa_email: str) -> Tuple[str, str]:
    """Mint a fresh HMAC pair for the given SA. Quota: 10 active keys / SA."""
    key_meta, secret = gcs.create_hmac_key(
        service_account_email=sa_email,
        project_id=project,
    )
    return key_meta.access_id, secret


# -------- Entrypoint --------------------------------------------------------

def provision_user_credentials(
    sub: str,
    project: str,
    bucket: str,
    namespace: str,
    k8s=None,
    gcp=None,
) -> Tuple[str, str]:
    """Return (access_key, secret_key) for a Keycloak user, provisioning as needed."""
    short = sub_short(sub)
    if k8s is None:
        k8s = _k8s_client()
    cached = _k8s_secret_get(k8s, namespace, _secret_name(short))
    if cached and cached[0] and cached[1]:
        log.info("cache hit for sub_short=%s", short)
        return cached

    iam, gcs = gcp if gcp else _gcp_clients()
    sa_email = _gcp_get_or_create_sa(iam, project, short)
    _gcp_bind_prefix_iam(gcs, bucket, sa_email, short)
    ak, sk = _gcp_mint_hmac(gcs, project, sa_email)
    _k8s_secret_put(k8s, namespace, _secret_name(short), ak, sk)
    log.info("provisioned new HMAC for sub_short=%s sa=%s", short, sa_email)
    return ak, sk
