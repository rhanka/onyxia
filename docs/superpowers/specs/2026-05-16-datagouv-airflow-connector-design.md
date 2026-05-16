# Design — data.gouv.fr connector via Airflow on Onyxia GKE

**Status:** Brainstorm, ready for review
**Branch:** `brainstorm/datagouv-airflow`
**Related work:**
- `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml` — the `automation` catalog already exposes the InseeFrLab Airflow chart (commit `1a81e8b`).
- `brainstorm/gcs-buckets` — STS bridge / per-user bucket layer (app layer merged, deploy pending).
- `brainstorm/iceberg-lakehouse` (Apache Polaris pivot) — lakehouse catalog landing as stub.

---

## Context

The user wants Onyxia users on `https://onyxia.sent-tech.ca` to be able to consume **data.gouv.fr** open datasets from their notebooks/Trino/Spark, without each user having to write boilerplate `httpx`/`requests` code, juggle pagination, or re-download a 2 GB CSV every time a notebook restarts.

data.gouv.fr exposes two relevant HTTP APIs:

1. **udata catalog API** — `https://www.data.gouv.fr/api/1/` — search/list datasets, get resources metadata (URL, mime, checksum, last-modified). No auth needed for reads.
2. **Tabular API** — `https://tabular-api.data.gouv.fr/api/` — for resources that the platform has been able to parse as CSV/Parquet, returns tidy rows with server-side filtering, ordering and pagination. Rate-limited to ~100 req/s anonymous.

A previous research pass surveyed the integration ecosystem and concluded:

- **No Airbyte / Singer / Meltano / dlt-verified connector exists for data.gouv.fr.** Building one would be 2–3 weeks of yak-shaving (Singer tap spec, JSON schema discovery per dataset, Meltano variant for the rate limits) for a use case that does not need CDC.
- **Airflow is already at the Onyxia catalog** (`automation` catalog, highlighted chart, ligne 148 du values file). Users can spin up an Airflow with one click.
- The official Python lib **`datagouv-client` 0.3.0** (PyPI, MIT, maintained by Etalab) wraps both APIs, handles pagination, resource discovery, and tabular pulls with `polars`/`pandas`/`pyarrow` adapters.

So the cheapest path is "let Airflow do the orchestration, let `datagouv-client` do the API, write the result as Parquet on GCS". No new long-running daemon, no new ingress, no new Helm release — we ride on top of the Airflow chart that is already in the catalog.

## Goal

After `mode=init` with `enable_datagouv_dag=true`:

- A shared GCS bucket `gs://<project>-onyxia-datagouv/` exists, readable by every Onyxia user (object viewer) and writable by the Airflow worker SA only.
- A pre-baked Airflow image with `datagouv-client` installed is available in Artifact Registry.
- A single DAG `datagouv_sync` is mounted into any Airflow instance launched from the Onyxia catalog. The DAG reads an Airflow Variable `DATAGOUV_DATASETS` (JSON list of `{id, resource_id?, name}`), pulls each entry via the tabular API, writes Parquet to `gs://<project>-onyxia-datagouv/<dataset_id>/dt=YYYY-MM-DD/part-0000.parquet`.
- A Jupyter user can then do:
  ```python
  import polars as pl
  df = pl.read_parquet("gs://<project>-onyxia-datagouv/sirene/dt=2026-05-16/*.parquet")
  ```
  and get rows without ever calling the upstream API themselves.
- Toggle `ENABLE_DATAGOUV_DAG=false` by default — opt-in per cluster.
- Surcoût cible: < $0.01/jour on Autopilot (one ephemeral worker pod per run, ~5 min/day, scale-to-zero between runs).

Out of scope for v1 (parked for v2):
- Iceberg / Polaris table registration (just Parquet files for now).
- Non-tabular resources (GeoJSON, SHP, PDF) — only what the tabular API serves.
- Per-user buckets / per-user filtering — single shared bucket, single Airflow Variable.
- Backfill of historical snapshots — we keep the latest run, daily.
- API key / authenticated writes back to data.gouv.fr.

## Chosen approach: Airflow DAG + `datagouv-client`

```
   ┌────────────────────────────────────────────┐
   │ Onyxia catalog (automation)                │
   │  highlightedCharts: [ airflow, ... ]       │
   └──────────────────┬─────────────────────────┘
                      │  user clicks "Launch"
                      ▼
   ┌────────────────────────────────────────────┐
   │ Airflow Helm release (per-user namespace)  │
   │  image: ${AR}/airflow-datagouv:<sha>       │
   │  extraConfigMaps: dag-datagouv-sync        │
   │  airflowVars: DATAGOUV_DATASETS=[…]        │
   └──────────────────┬─────────────────────────┘
                      │  KubernetesExecutor spawns
                      ▼
   ┌────────────────────────────────────────────┐
   │ datagouv_sync DAG (1 task per dataset)     │
   │   1. dgc.Dataset(id).resources              │
   │   2. tabular_api.fetch → polars.DataFrame   │
   │   3. df.write_parquet(gs://…/dt=…)         │
   └──────────────────┬─────────────────────────┘
                      │  Workload Identity → SA
                      ▼
   ┌────────────────────────────────────────────┐
   │ gs://<project>-onyxia-datagouv/            │
   │   <dataset_id>/dt=YYYY-MM-DD/part-*.parquet│
   └──────────────────┬─────────────────────────┘
                      │
                      ▼
   ┌────────────────────────────────────────────┐
   │ Onyxia user pods (Jupyter, VSCode, Trino)  │
   │   read-only via STS bridge or anon-RO IAM  │
   └────────────────────────────────────────────┘
```

### Pieces

1. **Custom Airflow image** — `helm-chart/examples/gke-ephemeral/airflow/Dockerfile` based on `apache/airflow:2.10.x-python3.11`, `pip install datagouv-client==0.3.0 polars==1.* google-cloud-storage gcsfs`. Tag: `${AR}/airflow-datagouv:<git-sha>`. Built+pushed by GHA (new phase).
2. **DAG file** — `helm-chart/examples/gke-ephemeral/airflow/dags/datagouv_sync.py`. ~80 LOC: read Variable, loop over entries, one PythonOperator per dataset using `KubernetesExecutor`. Idempotent (overwrites the day's partition).
3. **ConfigMap mounting the DAG** — `kubernetes_manifest.airflow_dag_datagouv` in `helm-chart/examples/gke-ephemeral/terraform/app/main.tf`, mounted into the Airflow chart via `dags.gitSync.enabled=false` + `dags.persistence.enabled=false` + `extraVolumeMounts`.
4. **GCS bucket** — `google_storage_bucket.datagouv` in `helm-chart/examples/gke-ephemeral/terraform/base/main.tf`, name `${var.project_id}-onyxia-datagouv`, location `var.bucket_location`, uniform access, lifecycle rule "delete partitions > 90 days". Mirrors the existing `google_storage_bucket.backup` pattern.
5. **SA + bindings** — one GCP SA `airflow-datagouv@<project>.iam.gserviceaccount.com` with `roles/storage.objectAdmin` scoped to the bucket; Workload Identity binding to the Airflow worker KSA. Plus `roles/storage.objectViewer` for `allAuthenticatedUsers` (or for the Onyxia STS audience) so user pods can read.
6. **Airflow Helm values overlay** — `helm-chart/examples/gke-ephemeral/airflow/values-overlay.yaml`, passed via Onyxia chart init-options injection. Sets the custom image, the configmap mount, and a default `DATAGOUV_DATASETS` Variable (3 sample datasets: SIRENE light, base-adresse-nationale-departement-75, demandes-de-valeurs-foncieres-75).
7. **Feature flag** — `enable_datagouv_dag` (bool, default `false`) in `terraform/app/variables.tf`. When false, none of pieces 3/4/5/6 are applied; the custom image is still built (cheap) so the chart is one-step away from being usable.
8. **Tests** — `tests/datagouv_sync_dag_test.py` using `pytest` + `respx` to mock `https://www.data.gouv.fr` and `https://tabular-api.data.gouv.fr`, asserting (a) the DAG parses, (b) one task per dataset, (c) the writer uses the correct GCS path, (d) the Variable is honored. Plus a `kind`-based smoke test in CI that runs the DAG with a fake `LocalExecutor` and writes to a temp dir.
9. **GHA workflow phase** — new step in `.github/workflows/example-gke-ephemeral.yml` (or equivalent) to `docker buildx build --push` the image, run unit tests, and tag with `git rev-parse --short HEAD`. Image lives in `${AR_REPO}/airflow-datagouv`.

### Why not …

| Option | Why rejected |
|---|---|
| Build a real Airbyte source-datagouv | 2–3 weeks; no CDC need; Airbyte runtime is +500m CPU floor on Autopilot, blows past $0.01/day. |
| Singer / Meltano tap | Same effort, and tabular API already does discovery; we'd reinvent it. |
| dlt pipeline | dlt is fine but adds a second orchestrator beside Airflow that we already ship — split-brain for a DAG that runs once a day. |
| Argo Workflows + raw httpx | Saves the Airflow dependency but Airflow is *already* in the catalog and users know it; Argo would be a new piece. |
| Run as a CronJob, no Airflow | Cheapest, but the user explicitly asked for an "Onyxia ecosystem" connector — surfacing it in Airflow gives discoverability and a UI for the Variable. |

## Open questions

1. **Per-user vs. shared bucket.** v1 chooses shared (simpler, one bucket, one SA, one DAG, one Variable). Per-user (`gs://<project>-user-${sub}-datagouv/`) would need the STS bridge from `brainstorm/gcs-buckets` and a DAG-per-user model — defer to v2 once STS bridge is deployed.
2. **Polaris/Iceberg registration.** Should the DAG, after writing Parquet, also call `polaris.create_table()` so the data lands as an Iceberg table queryable from Trino out-of-the-box? Easy +30 LOC once `brainstorm/iceberg-lakehouse` is live. Parked for v2.
3. **Rate-limit guardrails.** 100 req/s anonymous is generous, but if the Variable lists 200 large datasets we will hit it during a single run. Do we want a built-in `asyncio.Semaphore(20)` or do we rely on the operator to scale via `max_active_tasks`? Default to Airflow's `max_active_tasks_per_dag=8` for v1.
4. **Resource-id resolution.** `datagouv-client` lets you point at a `dataset_id` and auto-pick the "main" CSV resource — but datasets often have several CSVs. Should the Variable schema force `resource_id`, or do we let the DAG pick the largest tabular resource heuristically? Heuristic for v1, allow override.
5. **Storage class.** v1 defaults to `STANDARD`. For < 90-day rolling data, `STANDARD` is right; if we later want long-term archives, we add a lifecycle rule transitioning to `NEARLINE` at 30 days. Listed as v2.
6. **Catalog surfacing.** Do we ship a custom Onyxia chart "datagouv-explorer" (a pre-configured Jupyter with a sample notebook that reads from the bucket) or do we just document the gs:// path in the README? README-first for v1.
7. **Region.** Bucket sits in the same region as the cluster (re-uses `var.bucket_location`). data.gouv.fr CDN is FR-based; egress GCP → FR is ~$0.12/GB. Cap by limiting the DAG to sample-size datasets in the default Variable.

## Acceptance criteria

- `git grep enable_datagouv_dag helm-chart/examples/gke-ephemeral/` finds a variable defaulting to `false`.
- With `enable_datagouv_dag=true`, `tofu apply` creates the bucket, the SA, the IAM bindings, the configmap, and outputs `datagouv_bucket_url`.
- The GHA workflow builds `airflow-datagouv:<sha>`, pushes to Artifact Registry, and unit tests pass (`pytest tests/datagouv_sync_dag_test.py`).
- Launching Airflow from the Onyxia catalog and triggering the DAG manually (with the default 3-dataset Variable) writes 3 Parquet partitions to `gs://<project>-onyxia-datagouv/` within 10 min.
- Reading one of those partitions from a fresh Jupyter pod with `polars.read_parquet("gs://…")` returns a non-empty DataFrame.
- Per-day cost on Autopilot (measured via GCP billing label `app=airflow-datagouv`) stays under $0.01 in steady state (1 run/day, ~5 min, scale-to-zero).

## Next step

Move to `docs/superpowers/plans/2026-05-16-datagouv-airflow-connector-plan.md` for the step-by-step, TDD-style implementation plan. The plan numbers each piece (1–9 above), gives the validation command for each, and includes one review checkpoint after the image-build phase.
