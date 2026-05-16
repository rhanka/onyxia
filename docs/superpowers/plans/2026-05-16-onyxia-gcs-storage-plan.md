# Onyxia GCS storage (Option B — STS bridge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Onyxia on GKE to Google Cloud Storage via a small, in-cluster STS bridge that mints per-user HMAC pairs scoped to a per-user GCP service account, so every Onyxia user transparently gets `boto3`-compatible access to their own GCS prefix from launched services (Jupyter, VSCode, Spark…).

**Architecture:**
- A FastAPI bridge pod implements the AWS STS `AssumeRoleWithWebIdentity` XML response. Onyxia API's `region.data.S3.sts.URL` points at it. The bridge validates the Keycloak JWT, derives a stable `sub_short` (12 hex chars of `sub`), provisions on first call a per-user GCP service account `onyxia-user-${sub_short}@${PROJECT_ID}.iam.gserviceaccount.com` with `roles/storage.objectAdmin` on `gs://${PROJECT_ID}-onyxia-data` *prefix-scoped* via IAM Conditions, mints an HMAC key, caches it in a K8s Secret, and returns `{AccessKeyId, SecretAccessKey, SessionToken=""}` in AWS STS XML. A daily CronJob rotates keys (10/SA quota).
- Terraform creates the bucket, the bridge SA, IAM bindings, the K8s deployment, an HTTPS Ingress, and feeds the bridge URL into the Onyxia Helm values. The service-template gets `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` injected to neutralize the AWS SDK v2.30+ checksum-vs-GCS incompatibility.

**Tech Stack:**
- Bridge: Python 3.12 + FastAPI + `google-cloud-iam` + `google-cloud-storage` + `python-jose[cryptography]` (JWT) + `uvicorn`. Packaged as a distroless container.
- Infra: Terraform (OpenTofu) modules under `helm-chart/examples/gke-ephemeral/terraform/data/`, reusing existing `terraform/app/` patterns.
- Onyxia: Helm values overlays in `onyxia-gke-public-values.yaml` and service-template env patches.
- CI: extend `.github/workflows/onyxia-gke-ephemeral.yml` with a new phase `1.7 — gcs-bridge`.

**Dependencies with sibling brainstorms:**
- **`brainstorm/iceberg-lakehouse`** depends on this plan being merged first — Iceberg's catalog needs a working GCS bucket and S3-compatible creds.
- **`brainstorm/sentropic-helm-app`** is independent and can ship in parallel.

**Cost estimate:** bridge pod ~$0.03/day (50 mCPU, 64 Mi req) + bucket storage at $0.020/GB-month (≈ negligible at demo volumes) + GCS ops at $0.005/10k Class-A ops + Ingress LB share already paid. Total marginal: **~$0.05/day**.

**Dev time estimate:** ~**2 days** (1 day bridge + Dockerfile + unit tests, 0.5 day TF + Helm, 0.5 day CI + E2E).

---

## File Structure

**New files (created):**

- `helm-chart/examples/gke-ephemeral/sts-bridge/Dockerfile` — distroless container for the bridge.
- `helm-chart/examples/gke-ephemeral/sts-bridge/pyproject.toml` — Python deps (FastAPI, google-cloud-iam, google-cloud-storage, python-jose).
- `helm-chart/examples/gke-ephemeral/sts-bridge/app/__init__.py`
- `helm-chart/examples/gke-ephemeral/sts-bridge/app/main.py` — FastAPI app + `/` (STS XML endpoint) + `/healthz`.
- `helm-chart/examples/gke-ephemeral/sts-bridge/app/jwt_verify.py` — Keycloak JWKS fetch + verify, returns `claims`.
- `helm-chart/examples/gke-ephemeral/sts-bridge/app/gcp_provision.py` — idempotent SA + IAM binding + HMAC mint, with K8s-secret cache.
- `helm-chart/examples/gke-ephemeral/sts-bridge/app/sts_xml.py` — AWS STS XML response builder.
- `helm-chart/examples/gke-ephemeral/sts-bridge/app/config.py` — env-var loader (`PROJECT_ID`, `BUCKET`, `OIDC_ISSUER`, `OIDC_AUDIENCE`, `K8S_NAMESPACE`, `BRIDGE_SA_EMAIL`, `DEFAULT_DURATION_SECONDS`).
- `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_jwt_verify.py`
- `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_gcp_provision.py`
- `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_sts_xml.py`
- `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_main.py`
- `helm-chart/examples/gke-ephemeral/sts-bridge/README.md`
- `helm-chart/examples/gke-ephemeral/terraform/data/main.tf` — bucket + bridge SA + IAM + K8s resources.
- `helm-chart/examples/gke-ephemeral/terraform/data/variables.tf`
- `helm-chart/examples/gke-ephemeral/terraform/data/outputs.tf`
- `helm-chart/examples/gke-ephemeral/terraform/data/bridge_deployment.tf` — Deployment, Service, Ingress, RBAC.
- `helm-chart/examples/gke-ephemeral/terraform/data/rotation_cronjob.tf` — daily HMAC rotation.
- `helm-chart/examples/gke-ephemeral/scripts/sts-bridge-e2e.sh` — E2E smoke test triggered from CI.
- `helm-chart/examples/gke-ephemeral/tests/e2e_gcs_boto3.py` — Python client that lists/writes from inside a launched Jupyter (executed via `kubectl exec`).

**Modified files:**

- `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml` — add `region.data` block and service-template `extraEnv`.
- `helm-chart/examples/gke-ephemeral/onyxia-private-values.local.yaml.tmpl` — add `STS_BRIDGE_HOSTNAME` placeholder.
- `helm-chart/examples/gke-ephemeral/terraform/app/main.tf` — wire the `data` module + pass outputs to the Helm release.
- `helm-chart/examples/gke-ephemeral/terraform/app/variables.tf` — add `gcs_data_bucket_name`, `sts_bridge_hostname`.
- `helm-chart/examples/gke-ephemeral/.env.local.example` (create if absent) — declare `STS_BRIDGE_HOSTNAME`, `GCS_DATA_BUCKET`.
- `helm-chart/examples/gke-ephemeral/README.md` — new "GCS data" section.
- `.github/workflows/onyxia-gke-ephemeral.yml` — phase `1.7 — gcs-bridge` + E2E step.

---

## Section 0 — Preamble & branch hygiene

**Acceptance criterion:** `git status` clean on `brainstorm/gcs-buckets`; `git log -1` points at this plan commit; `.claude/` is not added.

- [ ] **Step 0.1: Verify branch**

  Run: `git rev-parse --abbrev-ref HEAD`
  Expected: `brainstorm/gcs-buckets`

- [ ] **Step 0.2: Confirm plan file exists**

  Run: `test -f docs/superpowers/plans/2026-05-16-onyxia-gcs-storage-plan.md && echo OK`
  Expected: `OK`

- [ ] **Step 0.3: Commit plan**

  ```bash
  git add docs/superpowers/plans/2026-05-16-onyxia-gcs-storage-plan.md
  git commit -m "plan: implementation plan for GCS STS bridge"
  ```

---

## Section 1 — STS bridge service

**Acceptance criterion:** `pytest -q` passes; `docker run -e PROJECT_ID=... bridge:dev` serves `GET /healthz` → `200 {"status":"ok"}`; `POST /` with a forged-but-signed JWT returns valid AWS STS XML containing `<AccessKeyId>` and `<SecretAccessKey>`.

### Task 1.1 — Project skeleton + Dockerfile

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/pyproject.toml`
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/Dockerfile`

- [ ] **Step 1.1.1: Write pyproject**

  ```toml
  [project]
  name = "onyxia-gcs-sts-bridge"
  version = "0.1.0"
  requires-python = ">=3.12"
  dependencies = [
    "fastapi==0.115.0",
    "uvicorn[standard]==0.30.6",
    "python-jose[cryptography]==3.3.0",
    "google-cloud-iam==2.15.2",
    "google-cloud-storage==2.18.2",
    "google-api-python-client==2.149.0",
    "kubernetes==30.1.0",
    "httpx==0.27.2",
  ]
  [project.optional-dependencies]
  test = ["pytest==8.3.3", "pytest-asyncio==0.24.0", "respx==0.21.1"]
  [tool.pytest.ini_options]
  asyncio_mode = "auto"
  ```

- [ ] **Step 1.1.2: Write Dockerfile**

  ```Dockerfile
  FROM python:3.12-slim AS build
  WORKDIR /app
  COPY pyproject.toml .
  RUN pip install --prefix=/install --no-cache-dir .
  COPY app/ ./app/

  FROM gcr.io/distroless/python3-debian12:nonroot
  COPY --from=build /install /usr/local
  COPY --from=build /app/app /app/app
  WORKDIR /app
  USER nonroot
  EXPOSE 8080
  ENTRYPOINT ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
  ```

- [ ] **Step 1.1.3: Commit**

  ```bash
  git add helm-chart/examples/gke-ephemeral/sts-bridge/pyproject.toml \
          helm-chart/examples/gke-ephemeral/sts-bridge/Dockerfile
  git commit -m "feat(sts-bridge): pyproject + distroless Dockerfile"
  ```

### Task 1.2 — Config loader (TDD)

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/app/config.py`
- Test: `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_config.py`

- [ ] **Step 1.2.1: Write failing test**

  ```python
  import os, pytest
  from app.config import load_config, MissingEnv

  def test_load_config_ok(monkeypatch):
      for k, v in {
        "PROJECT_ID": "p", "BUCKET": "b", "OIDC_ISSUER": "https://kc/realms/onyxia",
        "OIDC_AUDIENCE": "onyxia", "K8S_NAMESPACE": "onyxia",
        "BRIDGE_SA_EMAIL": "bridge@p.iam.gserviceaccount.com",
      }.items(): monkeypatch.setenv(k, v)
      c = load_config()
      assert c.project_id == "p" and c.default_duration_seconds == 86400

  def test_load_config_missing(monkeypatch):
      monkeypatch.delenv("PROJECT_ID", raising=False)
      with pytest.raises(MissingEnv): load_config()
  ```

- [ ] **Step 1.2.2: Run, expect FAIL**

  Run: `pytest helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_config.py -v`
  Expected: `ImportError: cannot import name 'load_config'`

- [ ] **Step 1.2.3: Implement**

  ```python
  from dataclasses import dataclass
  import os

  class MissingEnv(RuntimeError): pass

  @dataclass(frozen=True)
  class Config:
      project_id: str
      bucket: str
      oidc_issuer: str
      oidc_audience: str
      k8s_namespace: str
      bridge_sa_email: str
      default_duration_seconds: int

  _REQUIRED = ["PROJECT_ID","BUCKET","OIDC_ISSUER","OIDC_AUDIENCE","K8S_NAMESPACE","BRIDGE_SA_EMAIL"]

  def load_config() -> Config:
      missing = [k for k in _REQUIRED if not os.environ.get(k)]
      if missing: raise MissingEnv(f"missing env: {missing}")
      return Config(
        project_id=os.environ["PROJECT_ID"], bucket=os.environ["BUCKET"],
        oidc_issuer=os.environ["OIDC_ISSUER"], oidc_audience=os.environ["OIDC_AUDIENCE"],
        k8s_namespace=os.environ["K8S_NAMESPACE"], bridge_sa_email=os.environ["BRIDGE_SA_EMAIL"],
        default_duration_seconds=int(os.environ.get("DEFAULT_DURATION_SECONDS", "86400")),
      )
  ```

- [ ] **Step 1.2.4: Run, expect PASS**

  Run: `pytest helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_config.py -v`
  Expected: 2 passed

- [ ] **Step 1.2.5: Commit**

  ```bash
  git add helm-chart/examples/gke-ephemeral/sts-bridge/app/config.py \
          helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_config.py
  git commit -m "feat(sts-bridge): typed config loader"
  ```

### Task 1.3 — JWT verifier (TDD)

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/app/jwt_verify.py`
- Test: `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_jwt_verify.py`

- [ ] **Step 1.3.1: Write failing test**

  ```python
  from jose import jwt
  from cryptography.hazmat.primitives.asymmetric import rsa
  from cryptography.hazmat.primitives import serialization
  from app.jwt_verify import verify_token, InvalidToken
  import pytest, json, base64

  def _kp():
      k = rsa.generate_private_key(65537, 2048)
      pem = k.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
      pub = k.public_key().public_numbers()
      def b64u(n): return base64.urlsafe_b64encode(n.to_bytes((n.bit_length()+7)//8,"big")).rstrip(b"=").decode()
      jwk = {"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","n":b64u(pub.n),"e":b64u(pub.e)}
      return pem, {"keys":[jwk]}

  def test_verify_ok(monkeypatch):
      pem, jwks = _kp()
      tok = jwt.encode({"sub":"abc","aud":"onyxia","iss":"https://kc/realms/onyxia"},
                       pem, algorithm="RS256", headers={"kid":"k1"})
      monkeypatch.setattr("app.jwt_verify._fetch_jwks", lambda iss: jwks)
      claims = verify_token(tok, "https://kc/realms/onyxia", "onyxia")
      assert claims["sub"] == "abc"

  def test_verify_bad_aud(monkeypatch):
      pem, jwks = _kp()
      tok = jwt.encode({"sub":"abc","aud":"other","iss":"https://kc/realms/onyxia"},
                       pem, algorithm="RS256", headers={"kid":"k1"})
      monkeypatch.setattr("app.jwt_verify._fetch_jwks", lambda iss: jwks)
      with pytest.raises(InvalidToken): verify_token(tok, "https://kc/realms/onyxia", "onyxia")
  ```

- [ ] **Step 1.3.2: Run, expect FAIL** — `pytest ...test_jwt_verify.py -v` → ImportError.

- [ ] **Step 1.3.3: Implement**

  ```python
  import httpx
  from jose import jwt, jwk
  from jose.exceptions import JWTError
  from functools import lru_cache

  class InvalidToken(ValueError): pass

  @lru_cache(maxsize=4)
  def _fetch_jwks(issuer: str) -> dict:
      url = issuer.rstrip("/") + "/protocol/openid-connect/certs"
      r = httpx.get(url, timeout=5.0); r.raise_for_status(); return r.json()

  def verify_token(token: str, issuer: str, audience: str) -> dict:
      try:
          hdr = jwt.get_unverified_header(token)
          jwks = _fetch_jwks(issuer)
          key = next((k for k in jwks["keys"] if k["kid"] == hdr.get("kid")), None)
          if key is None: raise InvalidToken("kid not found")
          return jwt.decode(token, key, algorithms=[key.get("alg","RS256")],
                            audience=audience, issuer=issuer)
      except JWTError as e:
          raise InvalidToken(str(e)) from e
  ```

- [ ] **Step 1.3.4: Run, expect PASS** — `pytest ...test_jwt_verify.py -v` → 2 passed.

- [ ] **Step 1.3.5: Commit** — `git commit -m "feat(sts-bridge): Keycloak JWT verifier with JWKS cache"`.

### Task 1.4 — STS XML builder (TDD)

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/app/sts_xml.py`
- Test: `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_sts_xml.py`

- [ ] **Step 1.4.1: Write failing test**

  ```python
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
  ```

- [ ] **Step 1.4.2: Run, expect FAIL.**

- [ ] **Step 1.4.3: Implement**

  ```python
  from datetime import datetime, timedelta, timezone

  _NS = "https://sts.amazonaws.com/doc/2011-06-15/"

  def assume_role_response(access_key: str, secret_key: str, subject: str, duration_s: int) -> str:
      exp = (datetime.now(timezone.utc) + timedelta(seconds=duration_s)).strftime("%Y-%m-%dT%H:%M:%SZ")
      return f"""<AssumeRoleWithWebIdentityResponse xmlns="{_NS}">
    <AssumeRoleWithWebIdentityResult>
      <SubjectFromWebIdentityToken>{subject}</SubjectFromWebIdentityToken>
      <Credentials>
        <AccessKeyId>{access_key}</AccessKeyId>
        <SecretAccessKey>{secret_key}</SecretAccessKey>
        <SessionToken></SessionToken>
        <Expiration>{exp}</Expiration>
      </Credentials>
      <AssumedRoleUser>
        <Arn>arn:aws:sts::000000000000:assumed-role/onyxia-user/{subject}</Arn>
        <AssumedRoleId>onyxia-user:{subject}</AssumedRoleId>
      </AssumedRoleUser>
    </AssumeRoleWithWebIdentityResult>
    <ResponseMetadata><RequestId>00000000-0000-0000-0000-000000000000</RequestId></ResponseMetadata>
  </AssumeRoleWithWebIdentityResponse>"""
  ```

- [ ] **Step 1.4.4: Run, expect PASS.**

- [ ] **Step 1.4.5: Commit** — `git commit -m "feat(sts-bridge): AWS STS XML response builder"`.

### Task 1.5 — GCP provisioner with K8s Secret cache (TDD)

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/app/gcp_provision.py`
- Test: `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_gcp_provision.py`

- [ ] **Step 1.5.1: Write failing test** (mocks both `google.cloud.iam_credentials_v1` and the IAM admin client)

  ```python
  from unittest.mock import MagicMock, patch
  from app.gcp_provision import provision_user_credentials, sub_short

  def test_sub_short_stable():
      assert sub_short("e7c1d4d2-1234-4abc-9def-deadbeef0000") == sub_short("e7c1d4d2-1234-4abc-9def-deadbeef0000")
      assert len(sub_short("x"*36)) == 12

  @patch("app.gcp_provision._k8s_secret_get", return_value=None)
  @patch("app.gcp_provision._k8s_secret_put")
  @patch("app.gcp_provision._gcp_get_or_create_sa", return_value="onyxia-user-abc@p.iam.gserviceaccount.com")
  @patch("app.gcp_provision._gcp_bind_prefix_iam")
  @patch("app.gcp_provision._gcp_mint_hmac", return_value=("AKIATEST","SECRETTEST"))
  def test_provision_creates_when_absent(mint, bind, sa, put, get):
      ak, sk = provision_user_credentials(sub="abc", project="p", bucket="b",
                                          namespace="onyxia", k8s=MagicMock(), gcp=MagicMock())
      assert (ak, sk) == ("AKIATEST","SECRETTEST")
      sa.assert_called_once(); bind.assert_called_once(); put.assert_called_once()
  ```

- [ ] **Step 1.5.2: Run, expect FAIL.**

- [ ] **Step 1.5.3: Implement**

  ```python
  import hashlib, base64, json
  from kubernetes import client as kc, config as kconf
  from google.cloud import storage
  from googleapiclient import discovery

  def sub_short(sub: str) -> str:
      return hashlib.sha256(sub.encode()).hexdigest()[:12]

  def _k8s_client():
      try: kconf.load_incluster_config()
      except Exception: kconf.load_kube_config()
      return kc.CoreV1Api()

  def _gcp_clients():
      return discovery.build("iam", "v1", cache_discovery=False), storage.Client()

  def _secret_name(short: str) -> str: return f"onyxia-user-hmac-{short}"

  def _k8s_secret_get(k8s, namespace, name):
      try:
          s = k8s.read_namespaced_secret(name, namespace)
          d = {k: base64.b64decode(v).decode() for k, v in (s.data or {}).items()}
          return d.get("access_key"), d.get("secret_key")
      except Exception:
          return None

  def _k8s_secret_put(k8s, namespace, name, ak, sk):
      data = {"access_key": base64.b64encode(ak.encode()).decode(),
              "secret_key": base64.b64encode(sk.encode()).decode()}
      body = kc.V1Secret(metadata=kc.V1ObjectMeta(name=name), data=data, type="Opaque")
      try: k8s.replace_namespaced_secret(name, namespace, body)
      except Exception: k8s.create_namespaced_secret(namespace, body)

  def _gcp_get_or_create_sa(iam, project: str, short: str) -> str:
      name = f"onyxia-user-{short}"
      email = f"{name}@{project}.iam.gserviceaccount.com"
      try:
          iam.projects().serviceAccounts().get(name=f"projects/{project}/serviceAccounts/{email}").execute()
      except Exception:
          iam.projects().serviceAccounts().create(name=f"projects/{project}",
            body={"accountId": name, "serviceAccount": {"displayName": f"Onyxia user {short}"}}).execute()
      return email

  def _gcp_bind_prefix_iam(gcs, bucket: str, sa_email: str, short: str):
      b = gcs.bucket(bucket)
      policy = b.get_iam_policy(requested_policy_version=3)
      policy.version = 3
      cond = {
        "title": f"prefix-{short}",
        "description": f"Only user-{short}/* in {bucket}",
        "expression": f'resource.name.startsWith("projects/_/buckets/{bucket}/objects/user-{short}/")'
      }
      policy.bindings.append({
        "role": "roles/storage.objectAdmin",
        "members": {f"serviceAccount:{sa_email}"},
        "condition": cond,
      })
      b.set_iam_policy(policy)

  def _gcp_mint_hmac(gcs, project: str, sa_email: str):
      key_meta, secret = gcs.create_hmac_key(service_account_email=sa_email, project_id=project)
      return key_meta.access_id, secret

  def provision_user_credentials(sub, project, bucket, namespace, k8s=None, gcp=None) -> tuple[str, str]:
      short = sub_short(sub)
      k8s = k8s or _k8s_client()
      cached = _k8s_secret_get(k8s, namespace, _secret_name(short))
      if cached and cached[0] and cached[1]: return cached
      iam, gcs = gcp if gcp else _gcp_clients()
      sa_email = _gcp_get_or_create_sa(iam, project, short)
      _gcp_bind_prefix_iam(gcs, bucket, sa_email, short)
      ak, sk = _gcp_mint_hmac(gcs, project, sa_email)
      _k8s_secret_put(k8s, namespace, _secret_name(short), ak, sk)
      return ak, sk
  ```

- [ ] **Step 1.5.4: Run, expect PASS.**

- [ ] **Step 1.5.5: Commit** — `git commit -m "feat(sts-bridge): per-user GCP SA + HMAC provisioner with K8s cache"`.

### Task 1.6 — FastAPI entrypoint glue (TDD)

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/app/main.py`
- Test: `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_main.py`

- [ ] **Step 1.6.1: Write failing test**

  ```python
  from fastapi.testclient import TestClient
  from unittest.mock import patch
  from app.main import app

  def test_health():
      assert TestClient(app).get("/healthz").json()["status"] == "ok"

  @patch("app.main.verify_token", return_value={"sub": "abc"})
  @patch("app.main.provision_user_credentials", return_value=("AK","SK"))
  def test_assume_role(_p, _v):
      r = TestClient(app).post("/", data={
        "Action": "AssumeRoleWithWebIdentity",
        "WebIdentityToken": "fake.jwt.here",
        "DurationSeconds": "3600",
      })
      assert r.status_code == 200
      assert "<AccessKeyId>AK</AccessKeyId>" in r.text
  ```

- [ ] **Step 1.6.2: Run, expect FAIL.**

- [ ] **Step 1.6.3: Implement**

  ```python
  from fastapi import FastAPI, Form, HTTPException, Response
  from app.config import load_config
  from app.jwt_verify import verify_token, InvalidToken
  from app.gcp_provision import provision_user_credentials
  from app.sts_xml import assume_role_response
  import logging

  logging.basicConfig(level=logging.INFO)
  log = logging.getLogger("sts-bridge")
  app = FastAPI()
  cfg = load_config()

  @app.get("/healthz")
  def healthz(): return {"status": "ok"}

  @app.post("/")
  def assume_role(Action: str = Form(...), WebIdentityToken: str = Form(...),
                  DurationSeconds: int = Form(default=None)):
      if Action != "AssumeRoleWithWebIdentity":
          raise HTTPException(400, f"unsupported Action={Action}")
      try:
          claims = verify_token(WebIdentityToken, cfg.oidc_issuer, cfg.oidc_audience)
      except InvalidToken as e:
          raise HTTPException(401, f"invalid token: {e}")
      sub = claims["sub"]
      ak, sk = provision_user_credentials(sub, cfg.project_id, cfg.bucket, cfg.k8s_namespace)
      dur = DurationSeconds or cfg.default_duration_seconds
      log.info("issued creds for sub_short=%s dur=%s", sub[:8], dur)
      return Response(content=assume_role_response(ak, sk, sub, dur), media_type="text/xml")
  ```

- [ ] **Step 1.6.4: Run, expect PASS.**

- [ ] **Step 1.6.5: Local docker smoke test**

  ```bash
  cd helm-chart/examples/gke-ephemeral/sts-bridge
  docker build -t onyxia-sts-bridge:dev .
  docker run --rm -e PROJECT_ID=x -e BUCKET=x -e OIDC_ISSUER=https://k -e OIDC_AUDIENCE=onyxia \
    -e K8S_NAMESPACE=onyxia -e BRIDGE_SA_EMAIL=b@x.iam onyxia-sts-bridge:dev &
  sleep 2 && curl -fsS localhost:8080/healthz
  ```
  Expected: `{"status":"ok"}`.

- [ ] **Step 1.6.6: Commit** — `git commit -m "feat(sts-bridge): FastAPI endpoint + main wiring"`.

### Validation 1

- [ ] Run `pytest helm-chart/examples/gke-ephemeral/sts-bridge/tests/ -v` → all green.
- [ ] `docker build` succeeds and image < 200 MB (`docker images onyxia-sts-bridge:dev`).
- [ ] Manual `curl` against `/healthz` returns 200.

---

## Section 2 — Per-user provisioner & HMAC rotation

**Acceptance criterion:** A subsequent call for the same `sub` reuses the cached HMAC (no new GCS API call for `create_hmac_key`); a CronJob deletes HMAC keys older than 24 h and re-mints.

### Task 2.1 — Idempotency unit test

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_gcp_provision.py`

- [ ] **Step 2.1.1: Add cache-hit test**

  ```python
  from unittest.mock import patch
  from app.gcp_provision import provision_user_credentials

  @patch("app.gcp_provision._k8s_secret_get", return_value=("AKCACHED","SKCACHED"))
  @patch("app.gcp_provision._gcp_mint_hmac")
  def test_provision_cache_hit(mint, _g):
      ak, sk = provision_user_credentials("abc","p","b","onyxia", k8s=object(), gcp=(object(),object()))
      assert (ak, sk) == ("AKCACHED","SKCACHED")
      mint.assert_not_called()
  ```

- [ ] **Step 2.1.2: Run → PASS** (no code changes needed; this confirms cache short-circuit).

- [ ] **Step 2.1.3: Commit** — `git commit -m "test(sts-bridge): assert cache short-circuits HMAC mint"`.

### Task 2.2 — Rotation CronJob script

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/sts-bridge/app/rotate.py`
- Test: `helm-chart/examples/gke-ephemeral/sts-bridge/tests/test_rotate.py`

- [ ] **Step 2.2.1: Write failing test**

  ```python
  from datetime import datetime, timedelta, timezone
  from unittest.mock import MagicMock
  from app.rotate import rotate_old_keys

  def test_rotate_deletes_keys_older_than_24h():
      gcs = MagicMock()
      old = MagicMock(); old.time_created = datetime.now(timezone.utc) - timedelta(hours=30); old.state = "ACTIVE"
      young = MagicMock(); young.time_created = datetime.now(timezone.utc) - timedelta(hours=2); young.state = "ACTIVE"
      gcs.list_hmac_keys.return_value = [old, young]
      n = rotate_old_keys(gcs, "p", max_age_hours=24)
      assert n == 1
      old.update.assert_called()
  ```

- [ ] **Step 2.2.2: Run, expect FAIL.**

- [ ] **Step 2.2.3: Implement**

  ```python
  from datetime import datetime, timedelta, timezone
  import logging
  log = logging.getLogger("rotate")

  def rotate_old_keys(gcs, project: str, max_age_hours: int = 24) -> int:
      cutoff = datetime.now(timezone.utc) - timedelta(hours=max_age_hours)
      n = 0
      for k in gcs.list_hmac_keys(project_id=project):
          if k.state == "ACTIVE" and k.time_created < cutoff:
              k.state = "INACTIVE"; k.update()
              try: k.delete()
              except Exception as e: log.warning("delete failed for %s: %s", getattr(k,"access_id","?"), e)
              n += 1
      return n

  if __name__ == "__main__":
      from google.cloud import storage
      import os, sys
      sys.exit(0 if rotate_old_keys(storage.Client(), os.environ["PROJECT_ID"]) >= 0 else 1)
  ```

- [ ] **Step 2.2.4: Run, expect PASS.**

- [ ] **Step 2.2.5: Commit** — `git commit -m "feat(sts-bridge): HMAC rotation worker for CronJob"`.

### Validation 2

- [ ] `pytest` green for `test_rotate.py` and `test_gcp_provision.py`.
- [ ] `python -m app.rotate` runs (with `PROJECT_ID` and creds) without exception against a real test project.

---

## Section 3 — Terraform: bucket, bridge SA, Deployment, Ingress, CronJob

**Acceptance criterion:** `tofu apply` in `terraform/data/` against an empty project creates: 1 bucket (`<project>-onyxia-data`), 1 SA `onyxia-sts-bridge`, 1 KSA bound via Workload Identity, 1 Deployment+Service+Ingress, 1 CronJob, and exposes `output.sts_bridge_url`.

### Task 3.1 — Bucket + bridge SA + IAM (`terraform/data/main.tf`)

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/terraform/data/main.tf`
- Create: `helm-chart/examples/gke-ephemeral/terraform/data/variables.tf`
- Create: `helm-chart/examples/gke-ephemeral/terraform/data/outputs.tf`

- [ ] **Step 3.1.1: Write `variables.tf`**

  ```hcl
  variable "project_id"        { type = string }
  variable "region"            { type = string  default = "us-central1" }
  variable "bucket_location"   { type = string  default = "US" }
  variable "bucket_name"       { type = string }
  variable "namespace"         { type = string  default = "onyxia" }
  variable "bridge_image"      { type = string }
  variable "bridge_hostname"   { type = string }
  variable "oidc_issuer"       { type = string }
  variable "oidc_audience"     { type = string  default = "onyxia" }
  variable "managed_cert_name" { type = string  default = "onyxia-sts-bridge-cert" }
  ```

- [ ] **Step 3.1.2: Write `main.tf`**

  ```hcl
  terraform {
    required_providers {
      google     = { source = "hashicorp/google",     version = "~> 5.45" }
      kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    }
  }

  resource "google_storage_bucket" "data" {
    name                        = var.bucket_name
    location                    = var.bucket_location
    uniform_bucket_level_access = true
    force_destroy               = true
    versioning { enabled = false }
    lifecycle_rule {
      action    { type = "Delete" }
      condition { age = 30 }
    }
  }

  resource "google_service_account" "bridge" {
    account_id   = "onyxia-sts-bridge"
    display_name = "Onyxia STS bridge"
    project      = var.project_id
  }

  # bridge SA needs storage.admin (mint HMAC) + iam.serviceAccountAdmin (create per-user SA)
  resource "google_project_iam_member" "bridge_storage_admin" {
    project = var.project_id
    role    = "roles/storage.admin"
    member  = "serviceAccount:${google_service_account.bridge.email}"
  }
  resource "google_project_iam_member" "bridge_sa_admin" {
    project = var.project_id
    role    = "roles/iam.serviceAccountAdmin"
    member  = "serviceAccount:${google_service_account.bridge.email}"
  }
  # And the right to mutate bucket IAM (for prefix conditions)
  resource "google_storage_bucket_iam_member" "bridge_bucket_admin" {
    bucket = google_storage_bucket.data.name
    role   = "roles/storage.legacyBucketOwner"
    member = "serviceAccount:${google_service_account.bridge.email}"
  }

  # Workload Identity: bind KSA -> GSA
  resource "kubernetes_service_account" "bridge" {
    metadata {
      name      = "onyxia-sts-bridge"
      namespace = var.namespace
      annotations = {
        "iam.gke.io/gcp-service-account" = google_service_account.bridge.email
      }
    }
  }
  resource "google_service_account_iam_member" "wi" {
    service_account_id = google_service_account.bridge.name
    role               = "roles/iam.workloadIdentityUser"
    member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/onyxia-sts-bridge]"
  }

  # RBAC: KSA needs to read/write the per-user cache Secrets
  resource "kubernetes_role" "bridge_secrets" {
    metadata { name = "onyxia-sts-bridge-secrets" namespace = var.namespace }
    rule {
      api_groups = [""]
      resources  = ["secrets"]
      verbs      = ["get","list","create","update","patch"]
      resource_names = []
    }
  }
  resource "kubernetes_role_binding" "bridge_secrets" {
    metadata { name = "onyxia-sts-bridge-secrets" namespace = var.namespace }
    role_ref { api_group = "rbac.authorization.k8s.io" kind = "Role" name = kubernetes_role.bridge_secrets.metadata[0].name }
    subject  { kind = "ServiceAccount" name = kubernetes_service_account.bridge.metadata[0].name namespace = var.namespace }
  }
  ```

- [ ] **Step 3.1.3: Write `outputs.tf`**

  ```hcl
  output "bucket_name"      { value = google_storage_bucket.data.name }
  output "bridge_sa_email"  { value = google_service_account.bridge.email }
  output "sts_bridge_url"   { value = "https://${var.bridge_hostname}/" }
  ```

- [ ] **Step 3.1.4: `tofu init && tofu validate`**

  Run from `terraform/data/`: `tofu init -backend=false && tofu validate`
  Expected: `Success! The configuration is valid.`

- [ ] **Step 3.1.5: Commit** — `git commit -m "feat(tf/data): GCS bucket + bridge SA + KSA + RBAC"`.

### Task 3.2 — Bridge Deployment, Service, Ingress

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/terraform/data/bridge_deployment.tf`

- [ ] **Step 3.2.1: Write resources**

  ```hcl
  resource "kubernetes_deployment" "bridge" {
    metadata { name = "onyxia-sts-bridge" namespace = var.namespace }
    spec {
      replicas = 1
      selector { match_labels = { app = "onyxia-sts-bridge" } }
      template {
        metadata { labels = { app = "onyxia-sts-bridge" } }
        spec {
          service_account_name = kubernetes_service_account.bridge.metadata[0].name
          container {
            name  = "bridge"
            image = var.bridge_image
            port  { container_port = 8080 }
            env { name = "PROJECT_ID"        value = var.project_id }
            env { name = "BUCKET"            value = google_storage_bucket.data.name }
            env { name = "OIDC_ISSUER"       value = var.oidc_issuer }
            env { name = "OIDC_AUDIENCE"     value = var.oidc_audience }
            env { name = "K8S_NAMESPACE"     value = var.namespace }
            env { name = "BRIDGE_SA_EMAIL"   value = google_service_account.bridge.email }
            env { name = "DEFAULT_DURATION_SECONDS" value = "86400" }
            resources {
              requests = { cpu = "50m"  memory = "64Mi" }
              limits   = { cpu = "300m" memory = "256Mi" }
            }
            readiness_probe { http_get { path = "/healthz" port = 8080 } period_seconds = 5 }
          }
        }
      }
    }
  }

  resource "kubernetes_service" "bridge" {
    metadata { name = "onyxia-sts-bridge" namespace = var.namespace }
    spec {
      selector = { app = "onyxia-sts-bridge" }
      port { port = 80 target_port = 8080 }
    }
  }

  resource "kubernetes_manifest" "bridge_managed_cert" {
    manifest = {
      apiVersion = "networking.gke.io/v1"
      kind       = "ManagedCertificate"
      metadata   = { name = var.managed_cert_name, namespace = var.namespace }
      spec       = { domains = [var.bridge_hostname] }
    }
  }

  resource "kubernetes_ingress_v1" "bridge" {
    metadata {
      name      = "onyxia-sts-bridge"
      namespace = var.namespace
      annotations = {
        "kubernetes.io/ingress.class"          = "gce"
        "networking.gke.io/managed-certificates" = var.managed_cert_name
      }
    }
    spec {
      rule {
        host = var.bridge_hostname
        http {
          path {
            path      = "/"
            path_type = "Prefix"
            backend { service { name = kubernetes_service.bridge.metadata[0].name port { number = 80 } } }
          }
        }
      }
    }
  }
  ```

- [ ] **Step 3.2.2: `tofu validate`** → success.

- [ ] **Step 3.2.3: Commit** — `git commit -m "feat(tf/data): bridge Deployment + Service + Ingress + ManagedCertificate"`.

### Task 3.3 — Rotation CronJob

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/terraform/data/rotation_cronjob.tf`

- [ ] **Step 3.3.1: Write resource**

  ```hcl
  resource "kubernetes_cron_job_v1" "rotate" {
    metadata { name = "onyxia-sts-bridge-rotate" namespace = var.namespace }
    spec {
      schedule = "0 3 * * *"
      job_template {
        metadata { name = "onyxia-sts-bridge-rotate" }
        spec {
          template {
            metadata {}
            spec {
              service_account_name = kubernetes_service_account.bridge.metadata[0].name
              restart_policy       = "OnFailure"
              container {
                name    = "rotate"
                image   = var.bridge_image
                command = ["python", "-m", "app.rotate"]
                env { name = "PROJECT_ID" value = var.project_id }
              }
            }
          }
        }
      }
    }
  }
  ```

- [ ] **Step 3.3.2: `tofu validate`** → success.

- [ ] **Step 3.3.3: Commit** — `git commit -m "feat(tf/data): daily HMAC rotation CronJob"`.

### Task 3.4 — Wire `terraform/data/` into `terraform/app/`

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/terraform/app/main.tf` (add `module "data"`).
- Modify: `helm-chart/examples/gke-ephemeral/terraform/app/variables.tf` (add `gcs_data_bucket_name`, `sts_bridge_hostname`).

- [ ] **Step 3.4.1: Add module call in `app/main.tf`**

  ```hcl
  module "data" {
    source           = "../data"
    project_id       = var.project_id
    bucket_name      = var.gcs_data_bucket_name
    bridge_image     = var.sts_bridge_image
    bridge_hostname  = var.sts_bridge_hostname
    oidc_issuer      = "https://${var.keycloak_hostname}/realms/onyxia"
    oidc_audience    = "onyxia"
    namespace        = "onyxia"
  }
  ```

- [ ] **Step 3.4.2: Add vars**

  ```hcl
  variable "gcs_data_bucket_name" { type = string  default = "" }
  variable "sts_bridge_hostname"  { type = string }
  variable "sts_bridge_image"     { type = string  default = "ghcr.io/rhanka/onyxia-sts-bridge:latest" }
  ```

- [ ] **Step 3.4.3: Default the bucket name when blank** (replicate existing `backup_bucket_name` pattern from commit `7fa096f5`)

  ```hcl
  locals {
    gcs_data_bucket_name_effective = var.gcs_data_bucket_name != "" ? var.gcs_data_bucket_name : "${var.project_id}-onyxia-data"
  }
  ```
  Pass `local.gcs_data_bucket_name_effective` to the module.

- [ ] **Step 3.4.4: `tofu validate` in `terraform/app/`** → success.

- [ ] **Step 3.4.5: Commit** — `git commit -m "feat(tf/app): wire data module + default bucket name"`.

### Validation 3

- [ ] `tofu init && tofu validate` in `terraform/app/` and `terraform/data/`.
- [ ] `tofu plan` against the dev project shows: 1 bucket, 1 GSA, 1 KSA, 1 Deployment, 1 Service, 1 Ingress, 1 ManagedCertificate, 1 CronJob, 4–6 IAM bindings, 1 Role/RoleBinding pair.

---

## Section 4 — Onyxia Helm values

**Acceptance criterion:** Onyxia API `/api/configuration` returns a `regions[0].data` block with `S3.URL=https://storage.googleapis.com`, `sts.URL=https://${bridge_hostname}/`, and launched Jupyter pods receive `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED`.

### Task 4.1 — Patch `onyxia-gke-public-values.yaml`

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml`

- [ ] **Step 4.1.1: Add `region.data` block under `api.config.regions[0]`**

  ```yaml
  data:
    type: S3
    defaultDurationSeconds: 86400
    monitoring:
      enabled: false
    S3:
      URL: https://storage.googleapis.com
      region: auto
      pathStyleAccess: true
      sts:
        URL: https://${STS_BRIDGE_HOSTNAME}/
        durationSeconds: 86400
        oidcConfiguration:
          issuerUri: https://${KEYCLOAK_HOSTNAME}/realms/onyxia
          clientID: onyxia
  ```

- [ ] **Step 4.1.2: Add service-template `extraEnv`** under `api.config.catalogs[].extraEnv` or the equivalent per-template stanza (depends on the chart version pinned in `Chart.yaml` v10.33):

  ```yaml
  extraEnvForServices:
    - name: AWS_REQUEST_CHECKSUM_CALCULATION
      value: WHEN_REQUIRED
    - name: AWS_RESPONSE_CHECKSUM_VALIDATION
      value: WHEN_REQUIRED
  ```

  > If the chart pinned does not yet expose `extraEnvForServices`, fall back to injecting via the service-template fork (out of scope, see follow-up).

- [ ] **Step 4.1.3: Commit** — `git commit -m "feat(values): wire region.data to GCS + STS bridge"`.

### Task 4.2 — Patch local template + .env example

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/onyxia-private-values.local.yaml.tmpl`
- Create or modify: `helm-chart/examples/gke-ephemeral/.env.local.example`

- [ ] **Step 4.2.1: In the tmpl**, add `STS_BRIDGE_HOSTNAME: "${STS_BRIDGE_HOSTNAME}"` to the substitution list (if the example uses envsubst).

- [ ] **Step 4.2.2: In `.env.local.example`**, append:

  ```bash
  STS_BRIDGE_HOSTNAME=sts.onyxia.example.com
  GCS_DATA_BUCKET=          # leave empty to auto-default to <project_id>-onyxia-data
  ```

- [ ] **Step 4.2.3: Commit** — `git commit -m "feat(env): expose STS_BRIDGE_HOSTNAME / GCS_DATA_BUCKET"`.

### Validation 4

- [ ] `helm template helm-chart/ -f helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml` succeeds.
- [ ] Output contains `https://storage.googleapis.com` and `AWS_REQUEST_CHECKSUM_CALCULATION`.

---

## Section 5 — Keycloak audience + bridge JWT validation

**Acceptance criterion:** `curl -H "Authorization: Bearer $TOKEN"` against the bridge with a token from the `onyxia` client returns STS XML (200); the same call with `aud=other` returns 401.

### Task 5.1 — Verify `aud` mapper

**Files:** (manual or via existing Keycloak terraform if present — otherwise documented)

- [ ] **Step 5.1.1: Inspect the realm export** in `helm-chart/examples/gke-ephemeral/keycloak/` (file location TBC from current repo). If `aud=onyxia` is not present in token, add an *Audience Mapper* on client scope `roles` of the `onyxia` client:

  - Mapper type: `Audience`
  - Included Client Audience: `onyxia`
  - Add to ID token: off
  - Add to access token: on

- [ ] **Step 5.1.2: Document in README**

  Add the manual step to `helm-chart/examples/gke-ephemeral/README.md` under a "Keycloak audience mapper" heading.

- [ ] **Step 5.1.3: Commit** — `git commit -m "docs(keycloak): require aud=onyxia in access token"`.

### Validation 5

- [ ] Manual: log into Onyxia, copy the access token from `https://onyxia.<host>/api/configuration` page (browser devtools), `curl -X POST -d "Action=AssumeRoleWithWebIdentity&WebIdentityToken=<TOKEN>" https://${STS_BRIDGE_HOSTNAME}/` returns 200 + XML.

---

## Section 6 — README + .env example

**Acceptance criterion:** A reader following only `README.md` can fill in `.env.local`, run `make up`, and reach a Jupyter session with working GCS access.

### Task 6.1 — README section "GCS data"

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/README.md`

- [ ] **Step 6.1.1: Append a new section after the existing storage section**

  ````markdown
  ## GCS data

  Onyxia exposes per-user object storage via Google Cloud Storage's
  [S3-interoperable API](https://cloud.google.com/storage/docs/interoperability).
  Authentication is mediated by a small in-cluster bridge (`onyxia-sts-bridge`)
  that the Onyxia API calls via its STS endpoint.

  Required env vars (`.env.local`):

  ```bash
  STS_BRIDGE_HOSTNAME=sts.onyxia.example.com   # must DNS-point to the GKE LB
  GCS_DATA_BUCKET=                              # empty = <project>-onyxia-data
  ```

  At runtime each user gets:
  - a GCP service account `onyxia-user-<sub_short>@<project>.iam.gserviceaccount.com`
  - an HMAC key pair (cached in K8s Secret `onyxia-user-hmac-<sub_short>`)
  - prefix-scoped IAM on `gs://${GCS_DATA_BUCKET}/user-<sub_short>/`

  Quota: up to ~80 distinct users per project (10 HMAC keys / SA × 100 SA / project).
  Beyond that, switch to the shared-SA fallback (see brainstorm spec).

  HMAC keys older than 24 h are rotated nightly by a CronJob.
  Audit visibility is partial: HMAC operations do not appear in Cloud Audit Logs.
  ````

- [ ] **Step 6.1.2: Commit** — `git commit -m "docs(readme): describe GCS data + STS bridge"`.

### Validation 6

- [ ] `grep -q "GCS data" helm-chart/examples/gke-ephemeral/README.md` → exit 0.
- [ ] `markdownlint helm-chart/examples/gke-ephemeral/README.md` (if available) → no errors.

---

## Section 7 — GitHub Actions: phase 1.7 — gcs-bridge

**Acceptance criterion:** `gh workflow run onyxia-gke-ephemeral.yml -f mode=init` succeeds with a new step "phase 1.7 — provision GCS bridge + bucket" that produces a `tofu apply` log mentioning `kubernetes_deployment.bridge` and `google_storage_bucket.data`. The subsequent "phase 2 — E2E" step exits 0.

### Task 7.1 — Build & push bridge image

**Files:**
- Modify: `.github/workflows/onyxia-gke-ephemeral.yml`

- [ ] **Step 7.1.1: Add a job `build-bridge` before `terraform-apply`**

  ```yaml
  build-bridge:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    outputs:
      image: ${{ steps.meta.outputs.image }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
      - id: meta
        run: echo "image=ghcr.io/${{ github.repository_owner }}/onyxia-sts-bridge:${{ github.sha }}" >> $GITHUB_OUTPUT
      - uses: docker/build-push-action@v6
        with:
          context: helm-chart/examples/gke-ephemeral/sts-bridge
          push: true
          tags: ${{ steps.meta.outputs.image }}
  ```

### Task 7.2 — Apply data module in init/resume phase

- [ ] **Step 7.2.1: Add step "phase 1.7 — provision GCS bridge + bucket"** to the existing terraform job (right after the cert-manager two-phase apply added in commit `9a212407`):

  ```yaml
  - name: phase 1.7 — provision GCS bridge + bucket
    if: inputs.mode == 'init' || inputs.mode == 'resume'
    working-directory: helm-chart/examples/gke-ephemeral/terraform/app
    env:
      TF_VAR_sts_bridge_image:    ${{ needs.build-bridge.outputs.image }}
      TF_VAR_sts_bridge_hostname: ${{ vars.STS_BRIDGE_HOSTNAME }}
    run: |
      tofu apply -auto-approve \
        -target=module.data.google_storage_bucket.data \
        -target=module.data.google_service_account.bridge \
        -target=module.data.kubernetes_deployment.bridge \
        -target=module.data.kubernetes_service.bridge \
        -target=module.data.kubernetes_ingress_v1.bridge \
        -target=module.data.kubernetes_cron_job_v1.rotate
  ```

  Then a follow-up unbounded `tofu apply -auto-approve` to reconcile.

- [ ] **Step 7.2.2: Add `STS_BRIDGE_HOSTNAME` to the workflow inputs / vars** in `inputs:` and the README of the workflow file.

- [ ] **Step 7.2.3: Commit** — `git commit -m "ci: phase 1.7 — provision GCS bridge + bucket"`.

### Validation 7

- [ ] `act -W .github/workflows/onyxia-gke-ephemeral.yml -j terraform-apply --dryrun` parses without error (or `gh workflow view` lint).
- [ ] Manual `gh workflow run` against a test branch produces green logs through phase 1.7.

---

## Section 8 — E2E test from a Jupyter pod

**Acceptance criterion:** `kubectl exec` into a freshly-launched Jupyter pod (under namespace `user-<sub_short>`) runs `python /tmp/e2e_gcs_boto3.py` and exits 0 after listing+writing+reading+deleting a file from `gs://${GCS_DATA_BUCKET}/user-<sub_short>/`.

### Task 8.1 — Write the test client

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/tests/e2e_gcs_boto3.py`

- [ ] **Step 8.1.1: Implement**

  ```python
  #!/usr/bin/env python3
  """Onyxia GCS E2E. Reads AWS_* + AWS_S3_ENDPOINT from env (injected by Onyxia)."""
  import os, sys, uuid, boto3
  from botocore.config import Config

  endpoint = os.environ["AWS_S3_ENDPOINT"]
  bucket   = os.environ["AWS_BUCKET_NAME"]
  prefix   = os.environ["AWS_BUCKET_PREFIX"]  # injected by Onyxia as user-<sub_short>/

  s3 = boto3.client("s3", endpoint_url=endpoint, region_name="auto",
                    config=Config(s3={"addressing_style": "path"}))

  key = f"{prefix}e2e-{uuid.uuid4().hex}.txt"
  s3.put_object(Bucket=bucket, Key=key, Body=b"hello-gcs")
  body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
  assert body == b"hello-gcs", body
  listing = s3.list_objects_v2(Bucket=bucket, Prefix=prefix).get("Contents", [])
  assert any(o["Key"] == key for o in listing)
  s3.delete_object(Bucket=bucket, Key=key)
  print(f"OK: roundtrip on gs://{bucket}/{key}")
  ```

### Task 8.2 — E2E runner script

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/scripts/sts-bridge-e2e.sh`

- [ ] **Step 8.2.1: Implement**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  : "${ONYXIA_USER_NAMESPACE:?}"
  POD=$(kubectl -n "$ONYXIA_USER_NAMESPACE" get pod -l app=jupyter-python -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$ONYXIA_USER_NAMESPACE" cp helm-chart/examples/gke-ephemeral/tests/e2e_gcs_boto3.py "$POD":/tmp/e2e.py
  kubectl -n "$ONYXIA_USER_NAMESPACE" exec "$POD" -- python /tmp/e2e.py
  ```

- [ ] **Step 8.2.2: `chmod +x` and commit** — `git commit -m "test(e2e): boto3 roundtrip against GCS interop"`.

### Task 8.3 — Wire E2E into CI

- [ ] **Step 8.3.1: Add post-apply step in `onyxia-gke-ephemeral.yml`**

  ```yaml
  - name: phase 2.5 — E2E gcs bridge
    if: inputs.mode == 'init' || inputs.mode == 'resume'
    env: { ONYXIA_USER_NAMESPACE: user-ci }
    run: ./helm-chart/examples/gke-ephemeral/scripts/sts-bridge-e2e.sh
  ```

- [ ] **Step 8.3.2: Commit** — `git commit -m "ci: phase 2.5 — E2E GCS roundtrip from Jupyter"`.

### Validation 8

- [ ] In a manual workflow run, the step "phase 2.5 — E2E gcs bridge" prints `OK: roundtrip on gs://...`.

---

## Section 9 — Rollout / down hygiene

**Acceptance criterion:** `make down_full` (or the equivalent `mode=down_full` workflow input) deletes all per-user SAs and HMAC keys *before* destroying the bucket; the bucket's contents are listed in a "would delete" log line for auditability.

### Task 9.1 — Pre-destroy audit job

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/scripts/gcs-audit-before-destroy.sh`

- [ ] **Step 9.1.1: Implement**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  : "${PROJECT_ID:?}"; : "${BUCKET:?}"
  echo "==== HMAC keys before destroy ===="
  gcloud --project "$PROJECT_ID" storage hmac list --format='table(accessId,serviceAccountEmail,state,timeCreated)' || true
  echo "==== Per-user SAs ===="
  gcloud --project "$PROJECT_ID" iam service-accounts list --filter='email:onyxia-user-' --format='value(email)' || true
  echo "==== Bucket inventory (top 200) ===="
  gcloud --project "$PROJECT_ID" storage ls --recursive "gs://${BUCKET}/" | head -200 || true
  ```

### Task 9.2 — Pre-destroy purge

- [ ] **Step 9.2.1: Append a cleanup loop** to the same script (gated by `PURGE=1`):

  ```bash
  if [[ "${PURGE:-0}" == "1" ]]; then
    for sa in $(gcloud --project "$PROJECT_ID" iam service-accounts list --filter='email:onyxia-user-' --format='value(email)'); do
      for ak in $(gcloud --project "$PROJECT_ID" storage hmac list --filter="serviceAccountEmail=$sa" --format='value(accessId)'); do
        gcloud --project "$PROJECT_ID" storage hmac update "$ak" --inactive || true
        gcloud --project "$PROJECT_ID" storage hmac delete "$ak" || true
      done
      gcloud --project "$PROJECT_ID" iam service-accounts delete "$sa" --quiet || true
    done
  fi
  ```

- [ ] **Step 9.2.2: Hook into workflow `mode=down_full`**

  ```yaml
  - name: phase 9 — audit + purge GCS users
    if: inputs.mode == 'down_full'
    env: { PROJECT_ID: ${{ vars.GCP_PROJECT_ID }}, BUCKET: ${{ vars.GCS_DATA_BUCKET }}, PURGE: "1" }
    run: ./helm-chart/examples/gke-ephemeral/scripts/gcs-audit-before-destroy.sh
  ```

- [ ] **Step 9.2.3: Commit** — `git commit -m "feat(scripts): GCS audit + purge before destroy"`.

### Validation 9

- [ ] Run script locally against the dev project: `PROJECT_ID=foo BUCKET=foo-onyxia-data ./...sh` lists keys without error.
- [ ] `mode=down_full` workflow run leaves `gcloud iam service-accounts list --filter='email:onyxia-user-'` empty.

---

## Final review checkpoint

Before declaring the plan executed:

- [ ] Sections 1–9 all green (acceptance criterion + validation steps).
- [ ] `pytest` green across `sts-bridge/tests/`.
- [ ] `tofu validate` green in `terraform/data/` and `terraform/app/`.
- [ ] CI run on a feature branch: phases 1.7 + 2.5 both green.
- [ ] Manual login as a fresh Keycloak user → Onyxia "My files" displays the `user-<sub_short>/` prefix → upload+list+delete from the Onyxia UI works.
- [ ] Cost dashboard 24h after deploy shows < $0.10/day delta against the pre-bridge baseline.
- [ ] Open a PR `feat/gcs-storage` against `main`, link this plan, request review from a second maintainer (per `superpowers:requesting-code-review`).

**Total estimated dev time:** 2 days. **Marginal cost:** ~$0.05/day.
