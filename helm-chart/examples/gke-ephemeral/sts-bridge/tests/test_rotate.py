from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

from app.rotate import rotate_old_keys


def test_rotate_old_keys_deactivates_and_deletes_only_expired_active_keys():
    old = MagicMock()
    old.access_id = "old"
    old.state = "ACTIVE"
    old.time_created = datetime.now(timezone.utc) - timedelta(hours=30)

    young = MagicMock()
    young.access_id = "young"
    young.state = "ACTIVE"
    young.time_created = datetime.now(timezone.utc) - timedelta(hours=2)

    inactive = MagicMock()
    inactive.access_id = "inactive"
    inactive.state = "INACTIVE"
    inactive.time_created = datetime.now(timezone.utc) - timedelta(hours=30)

    gcs = MagicMock()
    gcs.list_hmac_keys.return_value = [old, young, inactive]

    assert rotate_old_keys(gcs, "p", max_age_hours=24) == 1
    assert old.state == "INACTIVE"
    old.update.assert_called_once()
    old.delete.assert_called_once()
    young.update.assert_not_called()
    young.delete.assert_not_called()
    inactive.update.assert_not_called()
    inactive.delete.assert_not_called()
