# Design — Apache Iceberg lakehouse on Onyxia GKE (Lakekeeper catalog)

**Status:** Brainstorm, ready for review
**Branch:** `brainstorm/iceberg-lakehouse`
**Related work:** `helm-chart/examples/gke-ephemeral/`, the new `databases` catalog (`trino`, `spark-thrift-server`, `hive-metastore` already shipped by InseeFrLab)

> ⚠️ **Decision reversal (2026-05-16)** — after user arbitration, the implementation **pivoted from Lakekeeper to Apache Polaris** for production-fidelity with SSPCloud (`polaris.lab.sspcloud.fr`). The recommendation in §"Chosen approach" below reflects the original Lakekeeper analysis; the actual plan lives in [`2026-05-16-iceberg-polaris-plan.md`](../plans/2026-05-16-iceberg-polaris-plan.md). Keep this spec for the comparison table and trade-offs, not for the implementation contract.

---


## Context

The user wants Onyxia users to be able to create, evolve, and query **Apache Iceberg** tables from their notebooks — full lakehouse on top of cheap object storage. Iceberg by itself is just a table format spec; on Kubernetes you need three independent layers:

1. **Catalog** — the metadata store that knows what tables exist, their schemas, their snapshots. The catalog is the integration point.
2. **Storage** — object store holding parquet files + Iceberg metadata json. Re-uses the GCS bucket layer (see sibling design `2026-05-16-onyxia-gcs-storage-design.md`).
3. **Engines** — Trino, Spark, DuckDB, Polars, Flink. All of them speak the Iceberg REST catalog protocol now.

Onyxia's `databases` catalog already exposes `trino`, `spark-thrift-server`, `hive-metastore`, `lakefs`. We're missing the central REST catalog — which is the single piece that turns "data on S3/GCS" into "an SQL lakehouse".

## Goal

- From a Jupyter / VSCode / Trino service in Onyxia, the user can run `CREATE TABLE x.y.z (…) USING iceberg` and the table lives in the bucket configured under their identity.
- All engines (Trino, Spark, Polars, DuckDB recent) share the same catalog and read each other's writes.
- The catalog authenticates against Keycloak so per-user namespaces map naturally to per-user Iceberg namespaces.
- Costs: a single Postgres + a small Rust binary, all together ~$0.30/day.

## Chosen approach: Lakekeeper

Lakekeeper is an Apache-2 Rust implementation of the Iceberg REST catalog spec. It speaks:

- Iceberg REST v1 (works with Trino, Spark, PyIceberg, DuckDB ≥ 1.2, Flink, Snowflake, Databricks).
- OIDC for authentication — points directly at Keycloak.
- Multi-warehouse (one warehouse = one bucket prefix + one set of credentials).

Trade-offs vs. rejected alternatives:

| | Lakekeeper (chosen) | Polaris (Snowflake) | Project Nessie |
|---|---|---|---|
| Stack | Rust + Postgres | Java + Postgres | Java + RocksDB/Postgres |
| Iceberg REST v1 | yes, complete | yes | yes |
| OIDC native | yes (Keycloak first-class) | yes | configurable |
| Versioning (branch/commit) | no | no | YES — its USP |
| Multi-tenant | yes | yes (rich RBAC) | yes |
| Pod footprint at idle | ~50m CPU / 128Mi | ~500m CPU / 1 Gi | ~300m / 512Mi |
| Helm chart maturity | OK (community) | growing | mature |
| When to pick | default | big org, strict RBAC | data versioning |

For our ephemeral GKE setup, Lakekeeper wins on footprint and simplicity. We can swap to Polaris later for the same Iceberg interface.

## Architecture

```
                      ┌──────────────────────────────┐
                      │ Keycloak                      │
                      │ realm: onyxia                 │
                      │ client: lakekeeper (PKCE off, │
                      │   confidential, audience map) │
                      └──────────────┬───────────────┘
                                     │ OIDC
                                     ▼
 ┌───────────┐    Iceberg REST    ┌─────────────┐    SQL parsing/   ┌─────────────┐
 │ Trino svc │ ────────────────► │  Lakekeeper  │ ─── metadata ───► │  Postgres   │
 │ (Onyxia)  │                    │  (Rust pod)  │                   │  (cnpg)     │
 └─────┬─────┘                    └──────┬──────┘                   └─────────────┘
       │                                 │ presigned URL / direct
       │                                 ▼
       │                          ┌─────────────┐
       └────────── reads ──────►  │ GCS bucket  │   gs://<project>-onyxia-warehouse
                                  │ Iceberg meta│
                                  │ + parquet   │
                                  └─────────────┘
```

### Pieces

1. **Lakekeeper Helm release** in namespace `lakekeeper`, behind ingress-nginx with cert-manager. URL: `https://lakekeeper.${PUBLIC_HOSTNAME}` (one more wildcard host) OR `${PUBLIC_HOSTNAME}/lakekeeper` if we want to keep one host. Default: own host.
2. **Postgres backend** — re-use `postgresql-cnpg` from the existing `databases` catalog. We can either deploy a dedicated Cluster CR in `lakekeeper` namespace, or piggy-back on a shared "infra postgres" and namespace-by-schema. Default: dedicated cnpg Cluster (cheap, ~256Mi).
3. **Keycloak integration** — add a confidential OIDC client `lakekeeper` to the realm. Configure Lakekeeper with `OPENFGA__AUTH__JWKS_URL`, `LAKEKEEPER__OPENID_PROVIDER_URI`, audience mapping to allow tokens minted for `onyxia` to be accepted (Lakekeeper supports `additional-issuers`).
4. **Warehouse provisioning** — a Lakekeeper "warehouse" maps to a bucket prefix + a set of credentials. On user provisioning (same trigger as the GCS bucket from the GCS spec), create a warehouse `user-${sub}` whose root is `gs://<project>-onyxia-user-${sub}/iceberg/`. Reuse the HMAC keys from the GCS spec.
5. **Engine wiring** — add an Onyxia `init.sh` snippet in the Jupyter / Trino chart values so each service receives `ICEBERG_REST_URI`, `ICEBERG_REST_OAUTH2_SERVER_URI` (Keycloak), `ICEBERG_REST_WAREHOUSE=user-${sub}` and warehouse-scoped creds. PyIceberg, Trino, Spark all read these.

### Terraform / Helm changes for the example

- `terraform/app/main.tf`: add `helm_release.lakekeeper`, `kubernetes_manifest.lakekeeper_ingress` (cert-manager), and an optional `kubernetes_manifest.cnpg_cluster_lakekeeper`. Gated behind a new variable `enable_lakekeeper` (default false to keep the example light).
- `scripts/keycloak-init.sh`: add a new `kc_safe_create` block for the `lakekeeper` confidential client.
- `onyxia-gke-public-values.yaml`: add Lakekeeper-friendly env vars to the `region.data` block: `S3.URL`, `S3.region`, and the new `S3.iceberg.warehouse` map that Onyxia exposes to launched services (already supported as of Onyxia API v4.10+, see `api.regions[].data.S3.useFileSystemForCheck`).
- `.env.local.example`: add `LAKEKEEPER_HOSTNAME=lakekeeper.onyxia.example.com`.
- New file `databases-catalog-extra.yaml.tmpl` if we also want to expose `lakekeeper` in the catalog so users can launch ad-hoc Iceberg clients.

## Open questions

1. **Warehouse-per-user vs. shared catalog.** Shared catalog (`onyxia` warehouse) is simpler but means anyone can see anyone's tables unless we enforce ACLs in Lakekeeper. Per-user warehouse is the cleanest isolation. Default: per-user warehouse, mirroring the GCS bucket strategy.
2. **Spark deployment model.** Spark on Kubernetes via the InseeFrLab `spark-thrift-server` chart? Or per-user Spark Operator? The catalog itself is engine-agnostic — this question is parked for a later spec.
3. **OpenFGA.** Lakekeeper uses OpenFGA for authorization (ABAC-style). Default OpenFGA store is embedded SQLite; we can leave it as is in dev, or wire a Postgres-backed OpenFGA. Default: embedded for the ephemeral example.
4. **Vended credentials.** Lakekeeper can vend short-lived S3 credentials to engines via the catalog API ("vended credentials" mode). On GCS interop this requires HMAC key minting in the warehouse, which Lakekeeper doesn't natively do for GCS — needs a small wrapper. Default: skip vended creds for the first version, use static creds via env vars.

## Cost impact

- Lakekeeper pod: ~50m CPU / 128Mi mem → ~$0.10/day on Autopilot.
- Postgres CNPG primary: ~200m CPU / 256Mi mem → ~$0.20/day.
- LB: reuses the existing single ingress-nginx LB.

Expected delta on the example's daily cost: **~$0.30/day** when `enable_lakekeeper=true`. Idle: $0 (toggle off).

## Acceptance criteria for the implementation plan

1. After `mode=init` with `enable_lakekeeper=true`, the REST endpoint `https://lakekeeper.<hostname>/catalog/v1/config` answers `200`.
2. A user logged into Onyxia can launch a Jupyter and execute:
   ```python
   from pyiceberg.catalog import load_catalog
   c = load_catalog("rest", uri="https://lakekeeper.<hostname>",
                    credential="oidc", token=<keycloak token>,
                    warehouse=f"user-{user_sub}")
   c.create_namespace(("demo",))
   ```
   and the namespace shows up under `gs://<project>-onyxia-user-<sub>/iceberg/demo/`.
3. The same notebook can read tables created by Trino and vice versa.
4. `mode=down_full` cleans Lakekeeper + Postgres + warehouses cleanly.
5. Cold `mode=init` reaches the acceptance criteria above without manual steps.

## Next step

Once approved, invoke `superpowers:writing-plans` to break this down into the TF + chart + keycloak-init delta. Implementation depends on the GCS storage spec landing first (warehouses need a bucket).

---

## Amendments — subagent review (2026-05-16)

Verified against Lakekeeper docs (0.10 + nightly), Polaris graduation announcement, Trino native-GCS docs, Onyxia API source, SSPCloud's live config. Five corrections.

**Correction 1 — Vended credentials on GCS work, but they're not HMAC.** Lakekeeper 0.8+ mints **GCP STS downscoped OAuth2 tokens** (`sts-enabled: true`), short-lived (1 h), scoped to the warehouse path. PyIceberg 0.6+, Trino 449+, Spark 3.5+ all accept them on `gs://`. **Consequence:** the engines do NOT need HMAC keys. Keep HMAC only for the "raw boto3 from notebook" path (covered by the GCS spec). Two cred surfaces, each shaped right.

**Correction 2 — OpenFGA is a separate pod, not embedded SQLite.** The Lakekeeper Helm chart deploys OpenFGA as its own deployment, with its own Postgres (the upstream chart packages it that way). Budget: +1 pod ~50m CPU + 1 small DB.

**Correction 3 — Onyxia API has no typed `region.data.S3.iceberg.warehouse` field.** The spec's claim was wrong. SSPCloud configures Iceberg via a **sibling array** `region.iceberg[]` (visible in `https://datalab.sspcloud.fr/api/public/configuration`). Concretely the env vars we want on launched services (`ICEBERG_REST_URI`, `ICEBERG_REST_WAREHOUSE`) come from the Helm chart's `serviceLauncher` extraEnv, not a typed Onyxia field.

**Correction 4 — Use Trino 481+ native GCS, not legacy `hive.gcs.*`.** `fs.native-gcs.enabled=true` + `iceberg.catalog.type=rest` + auth `ACCESS_TOKEN` consumes Lakekeeper's vended STS token directly. Pass `gcs.project-id=${GOOGLE_CLOUD_PROJECT}` from env.

**Correction 5 — SSPCloud uses Polaris in prod, not Lakekeeper.** Real prod path = `polaris.lab.sspcloud.fr` (Apache Polaris graduated 2026-02). For the ephemeral GKE demo Lakekeeper still wins on footprint, but document the "production migration = Polaris" exit.

### Updated cost

- Lakekeeper pod ~50m + 200m cnpg + ~50m OpenFGA + ~50m OpenFGA-pg = **~$0.40/day** (the spec said $0.30; OpenFGA is a pod, not embedded).

### Updated arbitration

| | Option A — Lakekeeper (ephemeral pick) | Option B — Apache Polaris (SSPCloud-fidelity) |
|---|---|---|
| $/day | ~$0.40 | ~$0.80–1.00 |
| Pod memory | ~512Mi total | ~1.5Gi total |
| Multi-tenancy | warehouse-per-user + OpenFGA ABAC | warehouse-per-user + Polaris RBAC |
| Auth | OIDC native (Keycloak first-class) | OIDC native |
| Helm chart maturity | community, fast cadence | community, stable |
| Prod path | swap to Polaris later | already prod |

Recommendation: **A for v1**, document Polaris as the migration target.

### Risks (updated)

- Keycloak `audience-mapper` must add both `onyxia` AND `lakekeeper` to user tokens, otherwise Lakekeeper 401s silently.
- Trino `fs.native-gcs.enabled` requires Trino ≥ 468. The `inseefrlab/trino` chart pin must allow that.
- Spark deployment is **out of scope** of this spec. Open a separate brainstorm for `apache/spark-kubernetes-operator` 0.7.0 (Apache TLP Jan 2026) before users actually try to write Iceberg from Spark.
