"""HMAC-key rotation worker for the STS bridge CronJob."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import logging
import os

log = logging.getLogger("sts-bridge.rotate")


def rotate_old_keys(gcs, project: str, max_age_hours: int = 24) -> int:
    """Deactivate and delete ACTIVE HMAC keys older than `max_age_hours`."""
    cutoff = datetime.now(timezone.utc) - timedelta(hours=max_age_hours)
    count = 0
    for key in gcs.list_hmac_keys(project_id=project):
        if getattr(key, "state", None) != "ACTIVE":
            continue
        created = getattr(key, "time_created", None)
        if created is None or created >= cutoff:
            continue
        key.state = "INACTIVE"
        key.update()
        try:
            key.delete()
        except Exception as exc:
            log.warning("delete failed for HMAC key %s: %s", getattr(key, "access_id", "?"), exc)
        count += 1
    return count


def main() -> int:
    from google.cloud import storage

    project = os.environ["PROJECT_ID"]
    rotated = rotate_old_keys(storage.Client(), project)
    log.info("rotated %s expired HMAC keys", rotated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
