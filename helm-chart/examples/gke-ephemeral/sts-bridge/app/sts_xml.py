"""AWS STS XML response builder for AssumeRoleWithWebIdentity.

Onyxia's frontend speaks the AWS STS XML protocol. We mint static HMAC pairs
but hand them back inside an STS-shaped envelope so the existing Onyxia code
path stays unchanged.

GCS HMAC has no real session-token concept. However, the released Onyxia
runtime currently deployed in the GKE example still expects a non-empty
`SessionToken` field in the STS response before it accepts the credentials.
We therefore return a stable sentinel token value.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import escape

_NS = "https://sts.amazonaws.com/doc/2011-06-15/"
_SESSION_TOKEN_SENTINEL = "unused-by-gcs"


def assume_role_response(access_key: str, secret_key: str, subject: str, duration_s: int) -> str:
    exp = (datetime.now(timezone.utc) + timedelta(seconds=duration_s)).strftime("%Y-%m-%dT%H:%M:%SZ")
    ak = escape(access_key)
    sk = escape(secret_key)
    sub = escape(subject)
    return (
        f'<AssumeRoleWithWebIdentityResponse xmlns="{_NS}">\n'
        "  <AssumeRoleWithWebIdentityResult>\n"
        f"    <SubjectFromWebIdentityToken>{sub}</SubjectFromWebIdentityToken>\n"
        "    <Credentials>\n"
        f"      <AccessKeyId>{ak}</AccessKeyId>\n"
        f"      <SecretAccessKey>{sk}</SecretAccessKey>\n"
        f"      <SessionToken>{_SESSION_TOKEN_SENTINEL}</SessionToken>\n"
        f"      <Expiration>{exp}</Expiration>\n"
        "    </Credentials>\n"
        "    <AssumedRoleUser>\n"
        f"      <Arn>arn:aws:sts::000000000000:assumed-role/onyxia-user/{sub}</Arn>\n"
        f"      <AssumedRoleId>onyxia-user:{sub}</AssumedRoleId>\n"
        "    </AssumedRoleUser>\n"
        "  </AssumeRoleWithWebIdentityResult>\n"
        "  <ResponseMetadata><RequestId>00000000-0000-0000-0000-000000000000</RequestId></ResponseMetadata>\n"
        "</AssumeRoleWithWebIdentityResponse>"
    )
