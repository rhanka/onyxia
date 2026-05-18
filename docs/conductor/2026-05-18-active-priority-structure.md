# Active Priority Structure

Date: 2026-05-18

Objectif: garder un pilotage court, actuel, et structure par dependance au plugin inter-PaaS.

## Contexte

- Le bug d'auth observe pendant l'activation d'un service n'est plus reproduit apres reconnexion.
- `/.claude/PLAN.md` a ete nettoye et sert maintenant de vue globale active.
- Les tracks historiques restent suivis via le conductor multi-track et les matrices UAT existantes.

## Etat de livraison Git

### Fait

- `origin/main` et `origin/feat/example-gke-ephemeral` sont actuellement alignes sur `963378ae`.
- Le correctif Sentropic/MUI deja merge est donc bien sur le remote principal.

### A faire

- Commiter et pousser les changements du worktree `brainstorm/gcs-deploy`.
- Commiter et pousser les docs de proposition du worktree `proposal/inter-paas-management`.
- Decider ensuite si l'integration se fait par PR vers `main` ou par branches intermediaires.

### Attendus

- Arbitrage utilisateur sur la strategie d'integration:
  - PR separees par track,
  - ou consolidation plus grosse apres UAT GCS.

## Tracks ajoutables ou stabilisables maintenant

### Fait

- Socle GKE / ingress / TLS actif.
- DNS public `onyxia.sent-tech.ca` et `sts.onyxia.sent-tech.ca` pointent vers `34.135.88.193`.
- Auth Keycloak/OIDC fonctionnelle; incident de session resolu apres reconnexion, sans recurrence confirmee pour l'instant.
- Theme Sentropic corrige cote MUI et stable sur shell public.
- GCS / STS deployes et verifies techniquement.
- Iceberg / Polaris prepare cote scripts et buckets.
- Catalog MCP en mode read/report identifie comme ajoutable avant le plugin complet.
- Sentropic chat peut entrer plus tot comme simple service Onyxia si le besoin est seulement "service lancable".

### A faire

- Finir l'UAT GCS authentifiee: fichiers, sharing, IDE, isolation, token lifecycle.
- Demarrer Polaris des que la baseline GCS est validee.
- Garder une piste MCP read/report avec schema, inventaire et evidences UAT.
- Decider si Sentropic chat v1 entre comme service simple avant l'integration avancee.

### Attendus

- Validation utilisateur sur la baseline GCS apres tests reels.
- Arbitrage utilisateur sur `Sentropic chat`: service simple maintenant, ou attente du plugin.
- Confirmation si le bug d'auth est bien clos apres les prochains tests service.

## Tracks dependants du plugin inter-PaaS

### Fait

- Branche dediee ouverte: `proposal/inter-paas-management`.
- Proposition posee pour un module transverse avec objets `paas_service`, `managed_resource`, `connection`, `access_policy`, `provisioning_hook`, `uat_check`.
- Re-priorisation posee: les SaaS externes ne doivent plus court-circuiter le modele transverse.

### A faire

- Cadrer le plugin inter-PaaS en mode metadata-first / GitOps-first.
- Definir le catalogue de donnees comme facette transverse et non comme simple annuaire.
- Definir le catalogue d'API avec auth, scopes, schemas, consumers et policies.
- Definir la version actionnable du catalogue MCP avec garde-fous.
- Choisir le premier vertical PaaS: `GCS + PostgreSQL + Jupyter/OpenRefine + Superset/Metabase` ou `Iceberg + Jupyter + Trino/Superset`.
- Repositionner `matchID`, `deces.matchid.io`, `data.gouv.fr` et `api.gouv.fr` comme consommateurs du modele transverse.
- Preparer l'integration avancee de Sentropic chat une fois le modele etabli.

### Attendus

- Decision utilisateur sur la forme de v1 du plugin: metadata/reporting seul ou hooks de provisioning controles.
- Decision utilisateur sur la premiere cible dataviz: `Superset` ou `Metabase`.
- Decision utilisateur sur le premier vertical d'integration transverse.

## Repartition recommandee

### Ajoutable maintenant

- GKE / DNS / TLS / auth
- Theme Sentropic
- GCS / STS
- Iceberg / Polaris
- MCP catalog read/report
- Sentropic chat en mode simple

### Dependant du plugin inter-PaaS

- Catalogue contributeur runtime
- Catalogue de donnees transverse
- Catalogue d'API transverse
- MCP catalog actionnable
- DB / Dataviz / Dataprep / Datascience connectes
- matchID backend/front
- deces.matchid.io
- data.gouv.fr
- api.gouv.fr
- Sentropic chat en mode avance

## Sources

- [PLAN.md](/home/antoinefa/src/onyxia/.claude/PLAN.md)
- [Rules](/home/antoinefa/src/onyxia/.claude/RULES.md)
- [Agent operating mode](/tmp/work-gcs-deploy/docs/conductor/2026-05-18-agent-operating-mode.md)
- [PLAN crosswalk](/tmp/work-gcs-deploy/docs/conductor/2026-05-18-plan-crosswalk.md)
- [Conductor multi-track](/tmp/work-gcs-deploy/docs/conductor/2026-05-17-onyxia-contributor-catalog-conductor.md)
- [Inter-PaaS proposal](/tmp/work-inter-paas-management/docs/proposals/2026-05-18-inter-paas-management-priority.md)
