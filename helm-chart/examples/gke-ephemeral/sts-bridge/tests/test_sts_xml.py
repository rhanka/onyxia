import xml.etree.ElementTree as ET

from app.sts_xml import assume_role_response

NS = "https://sts.amazonaws.com/doc/2011-06-15/"


def test_assume_role_xml_shape():
    xml = assume_role_response("AKIA...", "sk...", "abc", 3600)
    root = ET.fromstring(xml)
    assert root.tag == f"{{{NS}}}AssumeRoleWithWebIdentityResponse"
    ak = root.find(f".//{{{NS}}}AccessKeyId").text
    sk = root.find(f".//{{{NS}}}SecretAccessKey").text
    assert ak == "AKIA..." and sk == "sk..."


def test_assume_role_xml_contains_session_token_and_expiration():
    xml = assume_role_response("AKIA...", "sk...", "abc", 3600)
    root = ET.fromstring(xml)
    # Onyxia / AWS SDK clients expect both elements even if SessionToken is empty.
    session = root.find(f".//{{{NS}}}SessionToken")
    assert session is not None
    exp = root.find(f".//{{{NS}}}Expiration")
    assert exp is not None and exp.text and exp.text.endswith("Z")


def test_assume_role_xml_subject_present():
    xml = assume_role_response("AKIA...", "sk...", "subj-xyz", 3600)
    root = ET.fromstring(xml)
    subj = root.find(f".//{{{NS}}}SubjectFromWebIdentityToken")
    assert subj is not None and subj.text == "subj-xyz"
