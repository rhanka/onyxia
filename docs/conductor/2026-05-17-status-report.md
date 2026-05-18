# Status Report

Date: 2026-05-17

## Fait

### Theme Sentropic

- Bug MUI `colorManipulator` corrige: les tokens `oklch(...)` sont convertis en hex avant injection.
- `FONT` reste desactive par defaut avec `SENTROPIC_INJECT_FONT=false`.
- Logo/favion temporaires bascules vers `/logo.svg`, car les URLs Sent-Tech/jsdelivr ne sont pas disponibles.
- Tests theme: `npm test` -> 16 tests passent.
- Playwright: shell Onyxia charge sans erreur console.

### GCS

- GCS active dans la configuration Onyxia live:
  - endpoint `https://storage.googleapis.com`
  - `pathStyleAccess=true`
  - bucket `sent-tech-onyxia-data`
  - prefixes `user-` et `project-`
  - STS `https://sts.onyxia.sent-tech.ca/`
- OpenTofu avec image STS immuable: `No changes`.
- STS bridge health: `https://sts.onyxia.sent-tech.ca/healthz` -> `{"status":"ok"}`.
- Kubernetes `onyxia`: API, web, STS bridge en `1/1`; ingress `onyxia` et `sts` sur `34.135.88.193`.
- Tests STS bridge: `24 passed`.
- Matrice UAT creee: `docs/conductor/2026-05-17-gcs-uat-traceability.md`.

### Iceberg / Polaris

- Le track reste en UAT a preparer, dependant de GCS.
- Bucket warehouse et GSA Polaris deja raccordes par le travail GCS.
- Tests offline init Polaris/Keycloak:
  - `tests/scripts/test_polaris_init.sh` -> `PASS`
  - `tests/scripts/test_keycloak_init_polaris.sh` -> `PASS`

### Catalog contributeur

- Note de recherche creee: `docs/conductor/2026-05-17-contributor-catalog-research-note.md`.
- Conclusion locale: Onyxia a un catalogue de services Helm et `X-Onyxia` pour injection runtime, mais pas encore un meta-catalogue donnees/API/MCP/workflows.
- Draft GitOps cree: `docs/contributor-catalog/`.
- Schema minimal + validateur + 9 items:
  - `gcs-storage`
  - `iceberg-polaris`
  - `data-gouv`
  - `api-catalog`
  - `api-gouv`
  - `mcp-catalog`
  - `sent-tech-mcp`
  - `matchid-backend`
  - `matchid-deces`
- Validation catalogue: `node docs/contributor-catalog/validate.mjs` -> `validated 9 catalog items`.

### Suivi conductor

- Conductor multi-track cree et mis a jour: `docs/conductor/2026-05-17-onyxia-contributor-catalog-conductor.md`.
- Backlog Claude reconstruit via agent lecture seule.
- Copie temporaire `.env.local` dans `/tmp/work-gcs-deploy` supprimee.

## A faire

### GCS

- UAT authentifiee Onyxia:
  - login
  - page fichiers
  - list/upload/download/delete
  - creation dossier
  - URL signee
  - token STS reel via OIDC
- UAT IDE:
  - Jupyter: boto3/s3fs/aws-cli ou equivalent
  - RStudio: acces GCS depuis env injectees
  - VS Code: acces GCS depuis SDK/CLI
- UAT isolation:
  - utilisateur A vs utilisateur B
  - user prefix vs project prefix
  - bookmarks admin si configures
- UAT exploitation:
  - rotation HMAC
  - logs sans secrets
  - quotas IAM/service accounts
- Stabiliser le worktree GCS et choisir la strategie image definitive (`gcr.io/...:gcs-deploy-...` vs publication `ghcr.io/...`).

### Iceberg / Polaris

- Attendre le socle GCS UAT minimal.
- Activer Polaris dans un mode controle.
- Tester endpoint REST catalog.
- Tester PyIceberg create/read/write.
- Verifier objets warehouse dans `sent-tech-onyxia-warehouse`.
- Definir l'injection `ICEBERG_REST_*` dans les services.

### Catalog contributeur

- Faire relire le draft GitOps.
- Promouvoir le draft en spec produit si l'approche est validee.
- Decider le premier vertical fonctionnel:
  - Iceberg
  - data.gouv -> GCS -> dataprep/DB
  - api.gouv
  - MCP Sent-Tech
  - matchID marketplace
- Ajouter un rendu lisible du catalogue si besoin: Markdown genere ou future UI.

### data.gouv.fr

- Ne pas relancer l'ancien connecteur Airflow directement.
- Cadrer data.gouv comme item du catalog contributeur.
- Choisir datasets v1 et destination cible.

### api.gouv.fr / catalog API

- Choisir la premiere API cible.
- Definir schema API: endpoint, auth, scopes, rate limits, owner, sample calls.
- Decider si Kafka est une facette du catalog API ou un item separe.

### MCP

- Definir actions v1 autorisees.
- Commencer par actions read/report avant mutations.
- Definir auth, audit et limites de privilege.

### matchID

- Identifier images/charts/repos sources.
- Decider si `matchid-backend` et `matchid-deces` sont deux charts ou un bundle.
- Definir DB/storage/ingress/secrets/UAT.

## Attendus

### Decisions utilisateur

- Valider temporairement `/logo.svg` ou fournir une URL Sent-Tech stable pour logo/favion.
- Confirmer que le catalogue contributeur v1 peut commencer en GitOps JSON/YAML avant UI native.
- Choisir le premier vertical catalogue a specifier apres GCS.
- Definir le niveau de gouvernance du catalogue: inventaire, registre UAT, ou catalogue pilotant des actions.
- Confirmer les datasets data.gouv v1.
- Confirmer la premiere API api.gouv.fr cible.
- Confirmer le perimetre d'actions MCP v1.
- Fournir/valider les sources matchID: repos, images, charts, contraintes de deploiement.

### Actions utilisateur

- Se connecter a Onyxia pour permettre l'UAT authentifiee GCS.
- Lancer ou autoriser les parcours UI/IDE avec un compte reel.
- Verifier visuellement le branding si le logo Sent-Tech definitif est fourni.

### Blocages actuels

- Pas de session Onyxia authentifiee disponible dans Playwright: l'UAT fichier/IDE reste bloquee.
- Les tracks catalog/API/MCP/matchID sont cadrables, mais ne doivent pas devenir implementation runtime avant decision produit minimale.
