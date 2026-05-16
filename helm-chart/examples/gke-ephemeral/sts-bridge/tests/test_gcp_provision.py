from unittest.mock import MagicMock, patch

from app.gcp_provision import provision_user_credentials, sub_short


def test_sub_short_stable():
    a = sub_short("e7c1d4d2-1234-4abc-9def-deadbeef0000")
    b = sub_short("e7c1d4d2-1234-4abc-9def-deadbeef0000")
    assert a == b
    assert len(sub_short("x" * 36)) == 12


def test_sub_short_differs_for_different_sub():
    assert sub_short("alice") != sub_short("bob")


@patch("app.gcp_provision._k8s_secret_get", return_value=None)
@patch("app.gcp_provision._k8s_secret_put")
@patch(
    "app.gcp_provision._gcp_get_or_create_sa",
    return_value="onyxia-user-abc@p.iam.gserviceaccount.com",
)
@patch("app.gcp_provision._gcp_bind_prefix_iam")
@patch("app.gcp_provision._gcp_mint_hmac", return_value=("AKIATEST", "SECRETTEST"))
def test_provision_creates_when_absent(mint, bind, sa, put, get):
    ak, sk = provision_user_credentials(
        sub="abc",
        project="p",
        bucket="b",
        namespace="onyxia",
        k8s=MagicMock(),
        gcp=(MagicMock(), MagicMock()),
    )
    assert (ak, sk) == ("AKIATEST", "SECRETTEST")
    sa.assert_called_once()
    bind.assert_called_once()
    put.assert_called_once()
    mint.assert_called_once()
