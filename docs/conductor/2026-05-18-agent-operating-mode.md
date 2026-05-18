# Agent Operating Mode

Date: 2026-05-18

Objectif: permettre une reprise immediate par un autre agent et imposer une
discipline de livraison par track.

## Regles

- Une PR par track.
- Merge frequent des qu'un diff est coherent et verifie.
- Pas de melange `runtime` + `proposal docs` dans une meme PR.
- Le reporting doit distinguer:
  - `fait techniquement`
  - `committe localement`
  - `pousse`
  - `merge sur main`

## Worktrees

- `/home/antoinefa/src/onyxia`
  - pilotage local
  - branche: `feat/example-gke-ephemeral`
- `/tmp/work-gcs-deploy`
  - runtime GCS / STS / theme / Iceberg
  - branche: `brainstorm/gcs-deploy`
- `/tmp/work-inter-paas-management`
  - proposition plugin inter-PaaS
  - branche: `proposal/inter-paas-management`

## File de PR

1. `inter-paas-proposal`
2. `gcs-sts`
3. `iceberg-polaris`
4. `mcp-read-report`
5. `sentropic-simple-service` si decision explicite

## Reprise en 5 minutes

Lire:

1. [PLAN.md](/home/antoinefa/src/onyxia/.claude/PLAN.md)
2. [Active priority structure](/tmp/work-gcs-deploy/docs/conductor/2026-05-18-active-priority-structure.md)
3. [GCS UAT](/tmp/work-gcs-deploy/docs/conductor/2026-05-17-gcs-uat-traceability.md)
4. [Inter-PaaS proposal](/tmp/work-inter-paas-management/docs/proposals/2026-05-18-inter-paas-management-priority.md)

Puis executer:

```bash
git -C /home/antoinefa/src/onyxia worktree list --porcelain
git -C /home/antoinefa/src/onyxia branch -vv
git -C /tmp/work-gcs-deploy status --short --branch
git -C /tmp/work-inter-paas-management status --short --branch
```

## Fin de session

- mettre a jour `PLAN.md`;
- mettre a jour le conductor si un statut change;
- noter `Fait / A faire / Attendus`;
- noter l'etat Git reel;
- publier un dossier visuel si une decision reste ouverte.
