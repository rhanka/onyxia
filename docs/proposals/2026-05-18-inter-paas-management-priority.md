# Inter-PaaS Management Proposal

Date: 2026-05-18
Branch: `proposal/inter-paas-management`
Status: proposal / orientation, not implementation

## Reorientation

The working hypothesis is now explicit:

- Onyxia today is primarily a **PaaS tool catalog and launcher**.
- It can launch tools and inject runtime context, but it does not centrally manage transverse interconnections, data grants, app-role bootstrap, dataset/API/MCP governance, or cross-service configuration.
- A data catalog can be managed externally by the operator, but if the goal is smooth end-to-end Onyxia workflows, a new **inter-PaaS management module** should be designed first.

This changes the priority order. Services that are not PaaS-managed components, such as `data.gouv.fr` and `api.gouv.fr`, are postponed as direct integrations. They remain important, but should first be modeled as external SaaS/source entries consumed by the future inter-PaaS layer.

## Current Onyxia Model

### What Onyxia already manages

- Service discovery through Helm catalogs: IDE, databases, dataviz, automation.
- Service launch through Helm releases.
- User/project namespace targeting.
- Runtime context injection through `x-onyxia`: user, project, S3, Kafka, Vault, Kubernetes, etc.
- Public configuration for regions and service catalogs.

### What Onyxia does not centrally manage today

- Dataset-level grants propagated across tools.
- DB schema/table grants and app datasources as a first-class model.
- Metabase/Superset internal roles and collection permissions.
- Airflow/OpenRefine/Jupyter access policies derived from a shared catalog.
- API and MCP tool governance.
- Cross-PaaS connection lifecycle: discover, connect, bootstrap, validate, audit, revoke.

## Proposed Module

Working name: **Inter-PaaS Management Plugin**.

The module would sit above the existing Onyxia service catalog and below/alongside future data/API/MCP catalogs.

It would manage **relationships between PaaS tools**, not replace the tools:

- Storage: GCS/S3 buckets, prefixes, STS credentials, Iceberg warehouse.
- Databases: Postgres/Mongo/OpenSearch/Neo4j/etc. as deployed services plus their grants.
- Dataviz: Superset/Metabase datasource bootstrap and app-role mapping.
- Dataprep/datascience: Jupyter/RStudio/VS Code/OpenRefine/Airflow access injection.
- API/Kafka: event/API connection metadata and runtime injection.
- MCP: agent-readable and action-safe management surface.

## Conceptual Objects

### `paas_service`

A service deployed or deployable by Onyxia.

Examples:

- Jupyter
- RStudio
- VS Code
- PostgreSQL
- Superset
- Metabase
- Airflow
- OpenRefine
- Polaris
- matchID

### `managed_resource`

A resource owned by or attached to a service.

Examples:

- GCS bucket/prefix
- Iceberg warehouse
- DB/schema/table
- Kafka topic
- Superset datasource/dashboard
- Metabase database/collection
- Airflow DAG connection

### `connection`

A declared relationship between source, target, identity, and permissions.

Examples:

- GCS prefix -> Jupyter env vars
- Postgres database -> Superset datasource
- Iceberg catalog -> Trino/Spark/PyIceberg clients
- data.gouv dataset -> GCS landing zone -> OpenRefine
- API endpoint -> Airflow connection

### `access_policy`

The intended authorization contract.

Examples:

- user-only
- project/group
- Keycloak group
- app-role mapping
- dataset-level read/write/admin
- service account scope

### `provisioning_hook`

The executable or semi-executable step that realizes the connection.

Examples:

- Helm values injection
- Kubernetes Secret creation
- SQL grants
- Superset CLI/API bootstrap
- Metabase API bootstrap
- Airflow connection creation
- MCP action
- OpenTofu resource

### `uat_check`

The evidence that a connection works and respects policy.

Examples:

- user can read dataset from Jupyter
- Superset sees datasource but not unauthorized schema
- Metabase group sees only allowed collection
- API key injected into service and probe passes
- MCP action can report state but cannot mutate without permission

## Priority Model

### P0 - Keep stabilizing the technical foundations

1. GCS UAT
2. STS bridge reliability
3. Iceberg/Polaris UAT

Reason: these are the storage and lakehouse foundations required by later data workflows.

### P1 - Design the inter-PaaS module

1. Define object model: `paas_service`, `managed_resource`, `connection`, `access_policy`, `provisioning_hook`, `uat_check`.
2. Map existing Onyxia concepts to the model: `api.catalogs`, `DeploymentRegion`, `X-Onyxia`, Helm releases.
3. Define plugin boundaries: what lives as metadata, what triggers provisioning, what remains manual.
4. Define audit and rollback.

Reason: this is the missing transverse layer.

### P2 - Apply the module to PaaS services first

1. Databases: Postgres as the first DB target.
2. Dataviz: Superset or Metabase, not both initially.
3. Dataprep/datascience: Jupyter/OpenRefine as first consumers.
4. MCP: read/report layer first, mutating actions later.
5. matchID: marketplace service once service dependencies are clear.
6. Sentropic chat: advanced service once shared connections/policies are modeled.

Reason: these are Onyxia/PaaS-managed surfaces where the plugin can actually provision or validate interconnections.

### P3 - Reintroduce external SaaS sources

1. data.gouv.fr as `external_data_source`.
2. api.gouv.fr as `external_api`.

Reason: they should feed the inter-PaaS model rather than bypass it. They are sources, not PaaS tools managed by Onyxia.

## Reprioritized Tracks

| Track | New priority | New role | Immediate action |
| --- | --- | --- | --- |
| GCS | P0 | Storage foundation | Finish UAT |
| Iceberg/Polaris | P0 | Lakehouse/catalog foundation | Start after GCS baseline |
| Inter-PaaS plugin | P1 | Missing transverse module | Brainstorm/spec now |
| Catalog MCP | P1/P2 | Control/report surface for plugin | Start read-only/reporting design |
| Databases | P2 | First managed resource domain | Add Postgres grants/datasource scenario |
| Superset/Metabase | P2 | First app-role/bootstrap domain | Choose one for v1 |
| Dataprep/datascience | P2 | First consumer tool domain | Jupyter/OpenRefine access test |
| matchID backend/front | P2/P3 | Marketplace PaaS service | Wait for dependency model |
| deces.matchid.io | P2/P3 | Marketplace PaaS service | Wait for matchID model |
| Sentropic chat | P2/P3 | Chat/agentic PaaS service | Decide simple service vs plugin-native integration |
| data.gouv.fr | P3 | External SaaS/data source | Postpone direct implementation |
| api.gouv.fr | P3 | External SaaS/API source | Postpone direct implementation |

## Parallel Work Streams

### Stream A - GCS/Iceberg UAT

Keep validating the foundations in the GCS worktree.

Output:

- UAT evidence
- gaps in S3/STS/Iceberg access model
- requirements for `managed_resource` and `access_policy`

### Stream B - Inter-PaaS plugin proposal

This branch.

Output:

- proposal
- object model
- first vertical scenarios
- future spec outline

### Stream C - SaaS backlog parking

Postpone data.gouv.fr and api.gouv.fr as direct builds.

Output:

- keep intent
- model them as external sources
- do not implement connectors before the inter-PaaS model exists

### Stream D - Optional early PaaS additions

Keep room for services that can enter Onyxia before the full plugin exists.

Output:

- identify services that can land as plain Helm/PaaS entries;
- separate "simple service launch" from "advanced transverse integration";
- use Sentropic chat as the reference example.

## First Vertical Candidate

Recommended first vertical:

```text
GCS prefix + Postgres database -> Jupyter/OpenRefine -> Superset or Metabase
```

Why:

- all parts are PaaS/manageable by Onyxia or adjacent infrastructure;
- it exercises storage, DB, app roles, datasource bootstrap, and user/project access;
- it creates reusable primitives before external SaaS ingestion.

Alternative vertical:

```text
Iceberg/Polaris warehouse -> Jupyter/PyIceberg -> Superset/Trino
```

Why:

- closer to lakehouse strategy;
- dependent on Polaris readiness.

## Sentropic Chat Integration Options

### Option A - Plain Onyxia service first

Treat Sentropic chat as a regular PaaS service in an Onyxia Helm catalog.

Use when:

- the immediate goal is "launch the chat service";
- runtime config can be carried by standard chart values and secrets;
- transverse policies are not yet required.

Pros:

- fast to add;
- no plugin dependency;
- useful as a first marketplace/service presence.

Limits:

- no central model for shared datasources, chat memory stores, MCP tools, or per-group access policies.

### Option B - MCP surface first

Treat Sentropic first as an MCP/reporting/action surface.

Use when:

- the first value is agentic control or orchestration rather than end-user chat UI;
- you want read/report actions before mutating ones.

Pros:

- aligns with low-risk MCP-first rollout;
- creates a bridge toward the plugin.

Limits:

- does not solve the chat-service integration itself;
- still needs a service model later if the chat UI/app is to be deployed in Onyxia.

### Option C - Plugin-native advanced service

Treat Sentropic chat as a first-class inter-PaaS service once the plugin model exists.

Use when:

- the chat service must connect to shared DBs, warehouses, APIs, MCP tools, and app policies;
- access must follow user/project/group rules centrally.

Pros:

- best long-term architecture;
- uses the plugin for real transverse value.

Limits:

- depends on the plugin design landing first.

Recommendation:

Start with A or B depending on the near-term goal, and reserve C for the advanced integrated version.

## Decisions Needed

1. Should the module be a GitOps metadata layer first, an Onyxia API extension, or an MCP-first service?
2. Which app should be the first app-role/bootstrap target: Superset or Metabase?
3. Should v1 focus on user-level access, project/group access, or both?
4. Should mutating provisioning be enabled in v1, or should v1 only generate plans/runbooks?
5. Should external SaaS sources wait until the first PaaS vertical passes UAT?
6. Should Sentropic chat enter first as a plain service, an MCP surface, or only after the plugin model is ready?

## Recommendation

Start with a GitOps-backed inter-PaaS management plugin proposal:

- metadata first;
- validation and UAT evidence;
- read-only/reporting MCP surface;
- optional provisioning hooks gated per connector;
- first vertical on GCS + DB + one consumer + one dataviz app.

This keeps the proposal upstreamable and avoids overloading Onyxia core before the model is proven.
