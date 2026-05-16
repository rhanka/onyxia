# Implementation plan — data.gouv.fr connector via Airflow on Onyxia GKE

**Status:** Plan, ready for review
**Branch:** `brainstorm/datagouv-airflow`
**Spec:** `docs/superpowers/specs/2026-05-16-datagouv-airflow-connector-design.md`
**Depends on:**
- The `automation` catalog already wired in `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml` (commit `1a81e8b`) — Airflow chart is reachable.
- The Terraform `base` module already used to provision `${project_id}-onyxia-backup` — same pattern is reused for `${project_id}-onyxia-datagouv`.

## Preamble — scope guardrails

This plan implements **only the v1 perimeter** of the spec:

- 1 DAG template, parameterised by a single Airflow Variable `DATAGOUV_DATASETS`.
- 1 shared bucket `gs://<project>-onyxia-datagouv/` (not per-user).
- Output format = Parquet, partitioned by `dataset_id/dt=YYYY-MM-DD/`.
- Schedule = `@daily`.
- Toggle `enable_datagouv_dag = false` by default.
- Out of scope: Iceberg/Polaris registration, non-tabular resources, per-user buckets, backfill. These are explicitly v2 — leave TODO markers, no code.

Each step below has (a) what to write, (b) where, (c) the failing test to write FIRST, (d) acceptance criteria, (e) the validation command to run before moving on. There is **one review checkpoint** after step 4 (image built and unit-tested) — do not proceed to Terraform/IAM without sign-off.

---

## 1. Write the failing unit tests for the DAG

### What

Create `helm-chart/examples/gke-ephemeral/airflow/tests/test_datagouv_sync_dag.py`. The DAG file does not exist yet — these tests MUST fail with `ImportError` first.

Tests:

1. `test_dag_parses` — `DagBag(dag_folder=…)` finds exactly one DAG `datagouv_sync`, no import errors.
2. `test_one_task_per_dataset` — with Variable `DATAGOUV_DATASETS=[{"id":"a"},{"id":"b"},{"id":"c"}]`, the DAG has 3 leaf tasks named `pull__a`, `pull__b`, `pull__c`.
3. `test_writer_uses_correct_gcs_path` — mocks `datagouv_client.Dataset` and `pandas.DataFrame.to_parquet`; asserts the path passed is `gs://test-bucket/<id>/dt=<execution_date>/part-0000.parquet`.
4. `test_variable_default_is_three_samples` — if Variable absent, DAG falls back to a hard-coded 3-sample list (SIRENE, BAN-75, DVF-75) so the chart is usable out-of-the-box.
5. `test_rate_limit_semaphore` — `max_active_tasks_per_dag` on the DAG object equals 8.
6. `test_idempotent_write` — calling the writer twice for the same `dt` results in the same object name (overwrite, not append).

### Where

```
helm-chart/examples/gke-ephemeral/airflow/
├── tests/
│   ├── conftest.py
│   └── test_datagouv_sync_dag.py
└── requirements-dev.txt   # apache-airflow==2.10.x, pytest, respx, polars
```

### Acceptance

- `pytest helm-chart/examples/gke-ephemeral/airflow/tests/ -x` exits non-zero with `ModuleNotFoundError: dags.datagouv_sync`.

### Validation

```bash
cd helm-chart/examples/gke-ephemeral/airflow
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest tests/ -x  # MUST FAIL — that's the point
```

---

## 2. Implement the DAG file to make tests pass

### What

Create `helm-chart/examples/gke-ephemeral/airflow/dags/datagouv_sync.py`. ~80 LOC. Outline:

```python
from __future__ import annotations
import os, datetime as dt
from airflow.decorators import dag, task
from airflow.models import Variable

DEFAULT_DATASETS = [
    {"id": "5b7ffc618b4c4169d30727e0", "name": "sirene"},                # SIRENE light
    {"id": "5cc1b94a634f4165e96436c1", "name": "ban-75"},                # BAN dept 75
    {"id": "5c4ae55a634f4117716d5656", "name": "dvf-75"},                # DVF dept 75
]
BUCKET = os.environ["DATAGOUV_BUCKET"]  # injected via helm values

@dag(
    dag_id="datagouv_sync",
    schedule="@daily",
    start_date=dt.datetime(2026, 5, 16),
    catchup=False,
    max_active_tasks=8,
    tags=["datagouv", "ingest"],
)
def datagouv_sync():
    datasets = Variable.get("DATAGOUV_DATASETS", deserialize_json=True, default_var=DEFAULT_DATASETS)
    for d in datasets:
        @task(task_id=f"pull__{d['name']}")
        def pull(entry=d):
            from datagouv_client import Dataset
            ds = Dataset(entry["id"])
            res = entry.get("resource_id") or _pick_largest_tabular(ds)
            df = ds.resource(res).to_polars()  # uses tabular API + pyarrow
            dt_str = dt.date.today().isoformat()
            path = f"gs://{BUCKET}/{entry['name']}/dt={dt_str}/part-0000.parquet"
            df.write_parquet(path)
        pull()

dag = datagouv_sync()
```

Plus `_pick_largest_tabular(ds)` helper (5 LOC).

### Acceptance

- `pytest tests/ -x` now green, all 6 tests pass.
- No call to the real `data.gouv.fr` API during tests (verify by running with no network: `pytest tests/ --disable-network` via `pytest-socket`).

### Validation

```bash
pytest helm-chart/examples/gke-ephemeral/airflow/tests/ -v
# expect: 6 passed
```

---

## 3. Build the custom Airflow image

### What

Create `helm-chart/examples/gke-ephemeral/airflow/Dockerfile`:

```dockerfile
ARG AIRFLOW_VERSION=2.10.5
FROM apache/airflow:${AIRFLOW_VERSION}-python3.11
USER airflow
RUN pip install --no-cache-dir \
      datagouv-client==0.3.0 \
      polars==1.* \
      google-cloud-storage==2.* \
      gcsfs==2024.*
COPY dags/ /opt/airflow/dags/
```

Pin versions in `helm-chart/examples/gke-ephemeral/airflow/requirements.txt` (used by both the Dockerfile and the test venv for parity).

### Acceptance

- `docker buildx build helm-chart/examples/gke-ephemeral/airflow/` exits 0.
- `docker run --rm <built-image> airflow dags list-import-errors` returns empty.

### Validation

```bash
docker buildx build --load -t airflow-datagouv:local helm-chart/examples/gke-ephemeral/airflow/
docker run --rm airflow-datagouv:local airflow dags list-import-errors
# expect: empty output
docker run --rm airflow-datagouv:local airflow dags list | grep datagouv_sync
# expect: 1 line
```

---

## 4. Wire the image build into GHA

### What

Edit `.github/workflows/example-gke-ephemeral.yml` (or create a new dedicated workflow if that file is getting crowded — author's call, but the existing two-phase tofu apply lives there already per commit `9a212407`, so adding a phase is cheaper than a new file).

New job `build-airflow-image`:

- triggers on changes to `helm-chart/examples/gke-ephemeral/airflow/**`.
- runs the pytest suite from step 2 in a job-level step.
- `docker/login-action` against Artifact Registry (use existing `GCP_SA_KEY` secret).
- `docker/build-push-action` with tags `${AR_REPO}/airflow-datagouv:${{ github.sha }}` and `:latest`.
- exposes the SHA tag as job output for downstream `deploy-app` to consume.

### Acceptance

- PR CI shows the new job green (pytest + build + push).
- `gcloud artifacts docker images list ${AR_REPO}/airflow-datagouv` shows the new SHA tag.

### Validation

```bash
# from a PR branch with a no-op change under airflow/
git commit --allow-empty -m "test: trigger airflow image build"
git push
gh run watch  # or gh run list --workflow example-gke-ephemeral.yml
```

---

### REVIEW CHECKPOINT — STOP HERE

Before continuing to Terraform and IAM, confirm with the user:

1. The image was built, pushed, and `airflow dags list` inside it shows `datagouv_sync`.
2. The 6 unit tests pass on every PR (visible in the GHA job).
3. The user is OK with the default 3-sample dataset list (SIRENE light, BAN-75, DVF-75) — these are small enough to fit < 50 MB each.

If any of the above is "no", iterate on steps 1–4 before touching Terraform. Touching Terraform first will provision a bucket nobody can write to.

---

## 5. Terraform: GCS bucket and SA

### What

Edit `helm-chart/examples/gke-ephemeral/terraform/base/main.tf`. Add, **gated on `var.enable_datagouv_dag`**:

```hcl
resource "google_storage_bucket" "datagouv" {
  count                       = var.enable_datagouv_dag ? 1 : 0
  name                        = "${var.project_id}-onyxia-datagouv"
  project                     = var.project_id
  location                    = var.bucket_location
  force_destroy               = false
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition { age = 90 }
    action    { type = "Delete" }
  }
  labels = { app = "airflow-datagouv", managed_by = "terraform" }
}

resource "google_service_account" "airflow_datagouv" {
  count        = var.enable_datagouv_dag ? 1 : 0
  account_id   = "airflow-datagouv"
  display_name = "Airflow writer for data.gouv DAG"
  project      = var.project_id
}

resource "google_storage_bucket_iam_member" "datagouv_writer" {
  count  = var.enable_datagouv_dag ? 1 : 0
  bucket = google_storage_bucket.datagouv[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow_datagouv[0].email}"
}

# Read access for any pod in the cluster (KSA-based, narrower than allUsers)
resource "google_storage_bucket_iam_member" "datagouv_reader_onyxia" {
  count  = var.enable_datagouv_dag ? 1 : 0
  bucket = google_storage_bucket.datagouv[0].name
  role   = "roles/storage.objectViewer"
  member = "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/namespace/user-*"
}
```

Add `variable "enable_datagouv_dag" { type = bool; default = false }` to `variables.tf`.

Add to `outputs.tf`:

```hcl
output "datagouv_bucket_name" {
  value       = try(google_storage_bucket.datagouv[0].name, "")
  description = "Name of the shared data.gouv.fr Parquet bucket, empty if disabled."
}
```

### Acceptance

- `tofu plan` with `enable_datagouv_dag=false` shows zero diff related to `datagouv`.
- `tofu plan` with `enable_datagouv_dag=true` shows exactly +1 bucket, +1 SA, +2 IAM bindings.

### Validation

```bash
cd helm-chart/examples/gke-ephemeral/terraform/base
tofu init -backend=false
tofu validate
tofu plan -var-file=../terraform.tfvars.example -var=enable_datagouv_dag=false  | grep -c "google_storage_bucket.datagouv"  # expect 0
tofu plan -var-file=../terraform.tfvars.example -var=enable_datagouv_dag=true   | grep -c "google_storage_bucket.datagouv"  # expect >=1
```

---

## 6. Terraform: ConfigMap + KSA + Workload Identity binding (app layer)

### What

Edit `helm-chart/examples/gke-ephemeral/terraform/app/main.tf`. Add, gated on the same flag (propagated from `base` via remote state or a duplicated variable — match the existing convention in the repo, the `helm_release.cnpg` block already follows it):

1. `kubernetes_config_map.datagouv_dag` — name `datagouv-dag`, namespace `airflow` (or whatever NS Onyxia uses for catalog-launched Airflows; default `user-<sub>` — see open question #3), data `datagouv_sync.py = file("../airflow/dags/datagouv_sync.py")`.
2. `kubernetes_service_account.airflow_worker` — annotated `iam.gke.io/gcp-service-account = airflow-datagouv@<project>.iam.gserviceaccount.com`.
3. `google_service_account_iam_member.airflow_wi` — `roles/iam.workloadIdentityUser`, member `serviceAccount:<project>.svc.id.goog[<ns>/airflow-worker]`.

Plus a helm values overlay file `helm-chart/examples/gke-ephemeral/airflow/values-overlay.yaml`:

```yaml
images:
  airflow:
    repository: ${AR_REPO}/airflow-datagouv
    tag: ${IMAGE_TAG}
serviceAccount:
  create: false
  name: airflow-worker
extraConfigMapMounts:
  - name: datagouv-dag
    mountPath: /opt/airflow/dags/datagouv_sync.py
    subPath: datagouv_sync.py
    configMap: datagouv-dag
    readOnly: true
env:
  - name: DATAGOUV_BUCKET
    value: ${PROJECT_ID}-onyxia-datagouv
airflow:
  variables:
    - key: DATAGOUV_DATASETS
      value: '[{"id":"5b7ffc618b4c4169d30727e0","name":"sirene"},{"id":"5cc1b94a634f4165e96436c1","name":"ban-75"},{"id":"5c4ae55a634f4117716d5656","name":"dvf-75"}]'
```

This overlay is referenced from the Onyxia catalog config for the Airflow chart (existing automation catalog values point to InseeFrLab Helm repo — we add a `helmValueOverrides` block in `onyxia-gke-public-values.yaml` pointing here).

### Acceptance

- `kubectl get configmap datagouv-dag -n airflow -o jsonpath='{.data}' | grep -c '@dag('` ≥ 1.
- `kubectl get sa airflow-worker -n airflow -o jsonpath='{.metadata.annotations}' | grep airflow-datagouv@` succeeds.

### Validation

```bash
tofu apply -auto-approve -var=enable_datagouv_dag=true
kubectl get configmap datagouv-dag -n airflow
kubectl get sa airflow-worker -n airflow -o yaml
```

---

## 7. End-to-end DAG run smoke test

### What

Manual (or scripted in `helm-chart/examples/gke-ephemeral/scripts/smoke-datagouv.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail
NS=${NS:-airflow}
kubectl -n "$NS" exec deploy/airflow-webserver -- \
  airflow dags trigger datagouv_sync
# wait up to 10 min
for i in {1..60}; do
  state=$(kubectl -n "$NS" exec deploy/airflow-webserver -- \
    airflow dags list-runs -d datagouv_sync -o plain | head -2 | tail -1 | awk '{print $4}')
  [[ "$state" == "success" ]] && break
  sleep 10
done
gsutil ls "gs://${PROJECT_ID}-onyxia-datagouv/sirene/dt=$(date -u +%F)/"
```

### Acceptance

- Script exits 0 within 10 min.
- 3 partitions visible under the bucket, one per default dataset.
- `gsutil du -sh gs://${PROJECT_ID}-onyxia-datagouv/` reports < 200 MB total.

### Validation

```bash
PROJECT_ID=<your-project> bash helm-chart/examples/gke-ephemeral/scripts/smoke-datagouv.sh
```

---

## 8. Reader-side validation from a Jupyter pod

### What

In a fresh Onyxia Jupyter service:

```python
import polars as pl
df = pl.read_parquet("gs://<project>-onyxia-datagouv/sirene/dt=2026-05-16/*.parquet")
print(df.shape)
```

Document this in `helm-chart/examples/gke-ephemeral/airflow/README.md` (new file, ~40 lines) — what the DAG does, how to customise the Variable, where the data lands, and the snippet above.

### Acceptance

- Snippet runs without auth error (Workload Identity passthrough handles GCS read for any pod in the cluster).
- `df.shape[0] > 0`.

### Validation

Manual — screenshot in the PR description.

---

## 9. Cost observation

### What

Add a billing label assertion in the smoke script:

```bash
gcloud billing accounts list-by-project ... # or BigQuery export query
# expect: cost line with label app=airflow-datagouv < $0.30/month after 30 days
```

### Acceptance

- After 30 days of `@daily` runs, `app=airflow-datagouv` line in GCP billing export is **under $0.30/month** (= ~$0.01/day target from the spec).

### Validation

Deferred to the 30-day mark — record initial baseline in the PR description as "T0".

---

## 10. Documentation tidy

### What

- Add a paragraph to `helm-chart/examples/gke-ephemeral/README.md` under a new "data.gouv.fr ingestion" section, linking to the spec + plan + airflow/README.
- Update `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml` if a `helmValueOverrides` block is needed to point Airflow at the custom image (only if step 6's overlay is not auto-picked).

### Acceptance

- `grep -r "data.gouv" helm-chart/examples/gke-ephemeral/README.md` returns ≥ 1 line.
- A new contributor can go from "what is this" → "how do I add a dataset" in < 5 min of reading.

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `datagouv-client` 0.3.0 breaks on a Polars 1.x major bump | medium | Pin both, watch upstream issues, add a Renovate group `datagouv-stack`. |
| One dataset in the Variable is huge (> 1 GB) and OOMs the worker | medium | Set `resources.limits.memory=2Gi` on the worker pod via helm values; document max recommended row count (~10M) in the README. |
| Rate-limit (100 req/s) hit on a fan-out run | low | `max_active_tasks_per_dag=8` already in the DAG; tabular API uses `?page_size=1000` so 10M rows ≈ 10K pages = 100s @ 8 parallel = manageable. |
| Bucket public reads become a leak vector | low | We do NOT grant `allUsers`; only Workload Identity members of the cluster. data.gouv data is already public, but principle-of-least-privilege still applies. |
| Image rebuild on every PR balloons Artifact Registry storage | low | Add a lifecycle rule on the AR repo: keep last 10 tags + `:latest`. |

## Out of scope (explicit v2 TODO list)

- Iceberg/Polaris table registration after the Parquet write.
- Per-user buckets via STS bridge (waits on `brainstorm/gcs-buckets` deploy).
- GeoJSON / SHP / PDF resource handlers.
- Backfill operator (`datagouv_backfill` DAG with `start_date` parameter).
- Authenticated writes back to data.gouv.fr (publishing user-curated datasets).
- Catalog discoverability: a tiny "datagouv-explorer" Onyxia chart with a pre-wired notebook.

Each v2 item gets a one-line TODO comment in the DAG file, referencing this plan section.
