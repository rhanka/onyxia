"""AWS STS XML response builder for AssumeRoleWithWebIdentity.

Onyxia's frontend speaks the AWS STS XML protocol. We mint static HMAC pairs
but hand them back inside an STS-shaped envelope so the existing Onyxia code
path stays unchanged. GCS HMAC has no session-token concept, so we omit
SessionToken instead of returning a dummy value that S3 clients would sign.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import escape

_NS = "https://sts.amazonaws.com/doc/2011-06-15/"


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
