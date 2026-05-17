"""FastAPI entrypoint for the Onyxia <-> GCS STS bridge.

POST / handles AWS STS `AssumeRoleWithWebIdentity` form-encoded requests
emitted by the Onyxia API on behalf of authenticated users.

GET /healthz is a liveness/readiness probe (no auth, no GCP I/O).
"""
from __future__ import annotations

import logging

from fastapi import FastAPI, Form, HTTPException, Response

from app.config import load_config
from app.gcp_provision import HmacQuotaExceeded, provision_user_credentials, sub_short
from app.jwt_verify import InvalidToken, verify_token
from app.sts_xml import assume_role_response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("sts-bridge")

app = FastAPI(title="onyxia-gcs-sts-bridge")
cfg = load_config()


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/")
def assume_role(
    Action: str = Form(...),
    WebIdentityToken: str = Form(...),
    DurationSeconds: int | None = Form(default=None),
):
    if Action != "AssumeRoleWithWebIdentity":
        raise HTTPException(status_code=400, detail=f"unsupported Action={Action}")
    try:
        claims = verify_token(WebIdentityToken, cfg.oidc_issuer, cfg.oidc_audience)
    except InvalidToken as e:
        raise HTTPException(status_code=401, detail=f"invalid token: {e}") from e

    sub = claims["sub"]
    try:
        ak, sk = provision_user_credentials(
            sub=sub,
            project=cfg.project_id,
            bucket=cfg.bucket,
            namespace=cfg.k8s_namespace,
        )
    except HmacQuotaExceeded as e:
        # GCS caps active HMAC keys at 10 per service account. The daily
        # rotation CronJob (app/rotate.py) recycles the oldest > 24 h keys,
        # so 503 is the right "retry later" signal for the Onyxia API.
        log.warning("HMAC quota exceeded for sub_short=%s: %s", sub_short(sub), e)
        raise HTTPException(
            status_code=503,
            detail="HMAC quota exceeded for service account; daily rotation will recycle keys",
        ) from e
    dur = DurationSeconds or cfg.default_duration_seconds
    log.info("issued creds sub_short=%s dur=%s", sub_short(sub), dur)
    return Response(
        content=assume_role_response(ak, sk, sub, dur),
        media_type="text/xml",
    )
