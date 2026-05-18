# Priority Reorientation

Date: 2026-05-18

## Fait

- Branch created: `proposal/inter-paas-management`.
- Worktree: `/tmp/work-inter-paas-management`.
- Reframed Onyxia as a PaaS/tool catalog plus launcher, not a transverse data/API/MCP governance platform.
- Defined the missing layer as an **Inter-PaaS Management Plugin**.
- Postponed direct implementation of SaaS sources (`data.gouv.fr`, `api.gouv.fr`) until the inter-PaaS model exists.

## A faire

### Proposal branch

- Turn this proposal into a formal design/spec after review.
- Add 2 or 3 concrete first vertical scenarios.
- Choose the first app-role/bootstrap target: Superset or Metabase.
- Choose the first DB target: likely PostgreSQL.
- Define whether v1 is metadata-only, plan-generating, or mutating.

### GCS/Iceberg branch

- Continue UAT on GCS.
- Start Polaris only after GCS baseline.
- Feed findings back into the inter-PaaS `managed_resource` and `access_policy` model.

### Postponed SaaS tracks

- Keep `data.gouv.fr` as external data source backlog.
- Keep `api.gouv.fr` as external API source backlog.
- Do not implement direct connectors until plugin semantics exist.

## Attendus

- Decision: GitOps metadata layer first vs Onyxia API extension vs MCP-first service.
- Decision: first vertical scenario.
- Decision: Superset or Metabase as the first app bootstrap target.
- Decision: user-only vs project/group permissions in v1.
