# Onyxia Sent-Tech Conductor

Date: 2026-05-17

Ce fichier est le registre de suivi pour les tracks Onyxia/Sent-Tech. Il capture les intentions, le statut courant et les attendus sous le format `Fait / A faire / Attendus`.

## Mode de reporting

Chaque point de suivi doit conserver les champs suivants:

- Statut: `brainstorm`, `spec`, `plan`, `implementation`, `UAT`, `blocked`, `done`.
- Fait: preuves, commits, fichiers, ressources live ou decisions deja prises.
- A faire: prochaines actions concretes, testables et ordonnees.
- Attendus: decisions utilisateur, actions manuelles, credentials, validation UAT ou arbitrage produit.
- Sources: spec, plan, worktree, branche ou verification runtime.

Cadence proposee:

1. Stabiliser le runtime en cours avant les nouveaux brainstorms.
2. Tenir `gcs` et `iceberg` en priorite UAT.
3. Garder les tracks catalog/API/MCP/data.gouv/matchID en `brainstorm` tant que le meta-catalogue contributeur n'est pas cadre.
4. En fin de session, mettre a jour les sections `Fait / A faire / Attendus`.

## Vue worktrees

- `/home/antoinefa/src/onyxia`: branche `feat/example-gke-ephemeral`; sources spec/plan et traces Claude.
- `/tmp/work-gcs-deploy`: branche `brainstorm/gcs-deploy`; worktree actif pour GCS, STS bridge, theme Sentropic et deploiement GKE.
- `/home/antoinefa/src/onyxia/.claude/worktrees/agent-a5993dab10614fce4`: worktree Claude verrouille, branche `worktree-agent-a5993dab10614fce4`, propre au moment du relevé agent.

## Priorites immediates

1. Theme Sentropic: maintenir la page sans erreur console.
2. GCS: construire et executer la matrice UAT exhaustive Onyxia.
3. Iceberg: demarrer l'UAT Polaris apres validation GCS.
4. Catalog contributeur: cadrer l'objet produit avant implementation des tracks data/API/MCP.

## Track theme Sentropic

Statut: `UAT`

Fait:

- Theme Sentropic reactive sur le deploiement GKE.
- Correction runtime MUI: les couleurs `oklch(...)` sont converties avant injection dans `PALETTE_OVERRIDE_LIGHT/DARK`.
- `FONT` reste desactive par defaut via `SENTROPIC_INJECT_FONT=false` tant que les fonts ne sont pas hebergees proprement.
- `HEADER_LOGO` et `FAVICON` sont temporairement bascules vers `/logo.svg`, car les URLs jsdelivr/cdn Sent-Tech ne sont pas disponibles.
- Verification Playwright 2026-05-17: nouvelle navigation sans erreur console.
- Verification Playwright complementaire 2026-05-17: shell public non authentifie, bouton `Connexion`, `0` erreur console.

A faire:

- Choisir ou publier un asset logo/favion Sent-Tech stable et publiquement resoluble.
- Repasser `SENTROPIC_HEADER_LOGO_URL` et `SENTROPIC_FAVICON_URL` sur cet asset quand il existe.
- Garder un test visuel rapide desktop/mobile apres chaque changement de theme.

Attendus:

- Decision utilisateur: accepter temporairement `/logo.svg` ou fournir une URL Sent-Tech stable.

Sources:

- `helm-chart/examples/gke-ephemeral/theme/`
- `docs/superpowers/specs/2026-05-16-onyxia-sentropic-theme-design.md`
- `docs/superpowers/plans/2026-05-16-onyxia-sentropic-theme-plan.md`

## Track GCS

Statut: `UAT`

Fait:

- Stockage Onyxia configure sur GCS via compatibilite S3.
- Bucket data: `sent-tech-onyxia-data`.
- Bucket warehouse Polaris: `sent-tech-onyxia-warehouse`.
- STS bridge expose sur `https://sts.onyxia.sent-tech.ca/`.
- Workload Identity, service account bridge, ingress STS et rotation HMAC presents dans le worktree GCS.
- Deploiement GKE courant applique sans creation/destruction d'infra lors du dernier apply.
- Matrice de tracabilite UAT GCS creee dans `docs/conductor/2026-05-17-gcs-uat-traceability.md`.
- Suite STS bridge: 24 tests passent.
- Runtime Kubernetes `onyxia`: API, web et STS bridge a `1/1`; aucun event warning recent observe.
- Endpoint STS `/healthz` OK et config publique Onyxia expose bien `data.S3`.

A faire:

- Tester depuis Onyxia UI: login, affichage du storage, list/upload/download/delete, creation de dossiers, prefixes utilisateur et projet.
- Tester depuis services lances: Jupyter, RStudio, VS Code si disponible, variables d'environnement S3/AWS, boto3/s3fs/aws-cli, lecture/ecriture/suppression, gros fichier, chemins avec caracteres usuels.
- Tester isolation: utilisateur A vs utilisateur B, projet vs user namespace, absence d'acces hors prefixe attendu.
- Tester integration services/data: charts `databases`, `dataviz`, `automation` quand ils exposent ou consomment du stockage.
- Tester exploitation: rotation HMAC, logs STS, quotas IAM/service accounts, comportement expiration token, checksum AWS SDK.
- Stabiliser le worktree et choisir un tag image immuable pour le bridge.

Attendus:

- Action utilisateur: executer ou autoriser les parcours UAT avec un compte Onyxia reel.
- Decision utilisateur: valider le niveau d'isolation attendu entre prefixes `user-` et `project-`.

Sources:

- `docs/superpowers/specs/2026-05-16-onyxia-gcs-storage-design.md`
- `docs/superpowers/plans/2026-05-16-onyxia-gcs-storage-plan.md`
- `docs/conductor/2026-05-17-gcs-uat-traceability.md`
- `/tmp/work-gcs-deploy/helm-chart/examples/gke-ephemeral/`

## Track Iceberg / Polaris

Statut: `UAT a preparer`

Fait:

- Decision v1: Apache Polaris plutot que Lakekeeper.
- Bucket warehouse et GSA Polaris provisionnes cote GCS.
- Plan local pour namespace, Postgres, deployment/service/ingress Polaris et initialisation.
- Tests offline des scripts Polaris/Keycloak: `tests/scripts/test_polaris_init.sh` -> `PASS`; `tests/scripts/test_keycloak_init_polaris.sh` -> `PASS`.

A faire:

- Brancher Polaris sur le warehouse GCS et ses credentials.
- Activer `ENABLE_POLARIS` uniquement quand la configuration storage est stabilisee.
- Tester REST catalog avec PyIceberg.
- Tester integration Trino/Spark si retenue dans le scope UAT.
- Verifier creation warehouse/table par utilisateur ou projet.

Attendus:

- Decision utilisateur: valider que Polaris reste le premier catalogue Iceberg.
- Prerequis: UAT GCS suffisamment positif pour utiliser le bucket warehouse.

Sources:

- `docs/superpowers/specs/2026-05-16-iceberg-lakehouse-catalog-design.md`
- `docs/superpowers/plans/2026-05-16-iceberg-polaris-plan.md`

## Track catalog de donnees

Statut: `brainstorm`

Intention:

- Creer un meta-catalogue qui decrit et connecte les plateformes disponibles: analytique, dataprep, sources de donnees, warehouses, APIs et composants actionnables.
- Favoriser le dispatch fluide de bout en bout dans Onyxia, au-dela du catalogue Helm de services.

Fait:

- Hypothese courante: Onyxia possede deja des catalogues de services Helm, mais pas encore un meta-catalogue donnees/API/MCP generaliste couvrant sources, destinations, politiques, connecteurs et actions.
- Note de recherche creee: `docs/conductor/2026-05-17-contributor-catalog-research-note.md`.
- Draft GitOps du catalogue contributeur cree dans `docs/contributor-catalog/`.
- Validation locale du catalogue draft: `node docs/contributor-catalog/validate.mjs` -> `validated 9 catalog items`.

A faire:

- Auditer les concepts existants Onyxia: catalogues Helm, regions, `api.catalogs`, services, onboarding et eventuelles metadata applicatives.
- Distinguer trois niveaux: catalogue de services, catalogue de donnees, catalogue de connecteurs/actions.
- Proposer un modele minimal: fiche source, fiche plateforme, fiche connecteur, policies, owners, secrets requis, UAT hooks.
- Decider si le meta-catalogue vit dans Onyxia, dans un chart contributeur, ou dans un service externe reference par Onyxia.

Attendus:

- Decision utilisateur: scope v1 du meta-catalogue contributeur et niveau d'integration UI attendu.

Sources:

- Track utilisateur 2026-05-17.
- Config `api.catalogs` dans l'exemple GKE.
- `docs/conductor/2026-05-17-contributor-catalog-research-note.md`
- `docs/contributor-catalog/`

## Track data.gouv.fr

Statut: `brainstorm`, repris sous le futur catalogue contributeur

Fait:

- Le track data.gouv avait ete abandonne comme implementation immediate.
- Intention reactivee: data.gouv doit devenir un element inscrit au meta-catalogue donnees, connectable aux bases et dataprep Onyxia.
- Trace locale: branche `brainstorm/datagouv-airflow` et plan `2026-05-16-datagouv-airflow-connector-plan.md`, non present dans le worktree actif.
- Fiche draft creee: `docs/contributor-catalog/items/data-gouv.json`.

A faire:

- Ne pas reprendre l'ancien connecteur Airflow tel quel avant cadrage du meta-catalogue.
- Definir comment data.gouv expose datasets, schemas, refresh, licences, qualite et destinations Onyxia.
- Identifier un premier flux UAT: selection dataset, materialisation GCS, exposition a un service dataprep/DB.

Attendus:

- Decision utilisateur: datasets v1 et destination cible prioritaire.

Sources:

- Track utilisateur 2026-05-17.
- Branche locale mentionnee par l'agent: `brainstorm/datagouv-airflow`.

## Track catalog d'API

Statut: `brainstorm`

Intention:

- Ajouter un catalogue d'API pour fluidifier les connexions internes Onyxia et les sources externes, notamment Kafka et les modeles type api.gouv.fr.

Fait:

- Aucune trace locale forte de spec/branche dediee.
- Fiche draft creee: `docs/contributor-catalog/items/api-catalog.json`.

A faire:

- Definir les objets: API, topic/event stream, auth, scopes, endpoints, schemas, rate limits, owners, environments.
- Voir comment Kafka doit apparaitre: service deployable, source catalogable, ou connecteur actionnable.
- Aligner avec le meta-catalogue donnees pour eviter deux inventaires incoherents.

Attendus:

- Decision utilisateur: catalog API separe ou facette du meta-catalogue contributeur.

Sources:

- Track utilisateur 2026-05-17.

## Track api.gouv.fr

Statut: `brainstorm`

Intention:

- Traiter api.gouv.fr comme composant contributeur inscrit au catalogue d'API et raccordable aux autres composants Onyxia.

Fait:

- Aucune trace locale forte de spec/branche dediee.
- Fiche draft creee: `docs/contributor-catalog/items/api-gouv.json`.

A faire:

- Identifier les APIs prioritaires et leurs contraintes auth.
- Decrire le parcours: decouverte API, test, generation secret/config, consommation dans service Onyxia.
- Prevoir le lien avec data.gouv quand une API complete un dataset.

Attendus:

- Decision utilisateur: premiere API cible pour UAT.

Sources:

- Track utilisateur 2026-05-17.

## Track catalog MCP

Statut: `brainstorm`

Intention:

- Rendre des composants Onyxia actionnables par MCP et ajouter un outil agentique pour les gerer.
- Premier candidat utilisateur: Sentec/Sent-Tech.

Fait:

- Aucune spec locale dediee trouvee. Traces MCP locales limitees a l'usage Playwright et fichiers de session.
- Fiches draft creees: `docs/contributor-catalog/items/mcp-catalog.json` et `docs/contributor-catalog/items/sent-tech-mcp.json`.

A faire:

- Definir les actions MCP autorisees: lire catalogues, lancer service, lister storage, creer connecteur, verifier UAT, consulter logs.
- Definir securite: OIDC, delegation, audit, limites par projet/utilisateur.
- Decider si le MCP server est un service Onyxia, un sidecar, ou un composant externe connecte au meta-catalogue.
- Preparer un PoC Sent-Tech limite et auditable.

Attendus:

- Decision utilisateur: perimetre des actions MCP v1 et niveau de privilege acceptable.

Sources:

- Track utilisateur 2026-05-17.

## Track matchID

Statut: `brainstorm`

Intention:

- Ajouter deux composants a la marketplace Onyxia: backend matchID (`datapep-backend` + front) et `deces.matchid.io`.

Fait:

- Aucune trace locale forte dans ce repo Onyxia.
- Contexte navigateur ouvert sur une PR matchID, a verifier dans le repo matchID si le track demarre.
- Fiches draft creees: `docs/contributor-catalog/items/matchid-backend.json` et `docs/contributor-catalog/items/matchid-deces.json`.

A faire:

- Identifier charts/images existants pour `datapep-backend`, le front et `deces.matchid.io`.
- Choisir packaging: catalog Helm Onyxia existant, chart Sent-Tech contributeur, ou meta-catalogue contributeur.
- Definir env/secrets, DB, stockage, ingress et UAT.

Attendus:

- Action utilisateur: fournir ou confirmer le repo/source des images matchID et les contraintes de deploiement.
- Decision utilisateur: deux fiches marketplace separees ou un bundle.

Sources:

- Track utilisateur 2026-05-17.

## Track catalog contributeur

Statut: `brainstorm`

Intention:

- Faire converger data.gouv, api.gouv.fr, catalog API, catalog MCP, matchID et autres composants dans un catalogue contributeur gere par l'utilisateur.

Fait:

- Besoin produit explicite capture.
- Les catalogues Helm Onyxia existants peuvent servir de precedent UX/ops, mais ne suffisent probablement pas pour cataloguer donnees, APIs, actions MCP et dispatch dataprep.
- Catalogue contributeur draft cree avec schema, validateur et 9 items initiaux.
- Validation locale du draft effectuee avec succes.

A faire:

- Faire relire le draft par l'utilisateur avant de le promouvoir en spec.
- Ecrire une spec courte du concept `contributor catalog` apres validation du cadrage.
- Definir les fiches de catalogue: `service`, `data_source`, `api`, `mcp_tool`, `connector`, `workflow`.
- Definir le cycle de vie: proposer, valider, publier, UAT, deprecier.
- Definir les hooks d'execution: helm chart, job import, DAG, MCP action, documentation UAT.
- Choisir un premier vertical complet: par exemple `data.gouv -> GCS -> dataprep`, ou `api.gouv -> service Onyxia -> MCP action`.

Attendus:

- Decision utilisateur: premier vertical a specifier apres GCS/Iceberg.

Sources:

- Track utilisateur 2026-05-17.

## Track DNS / cluster

Statut: `note`

Fait:

- Pas d'indice de nouveau cluster dans le travail courant.
- Le changement DNS concerne le pointage des hostnames vers l'IP d'ingress nginx du cluster GKE existant, pas la creation d'un nouveau cluster.
- IP d'ingress observee dans les outputs recents: `34.135.88.193`.

A faire:

- Garder les instructions DNS datees, car `.claude/PLAN.md` contient une ancienne action utilisateur avec une IP differente.
- Toujours verifier l'output `services_ingress_nginx_ip` avant de demander une modification Cloudflare.

Attendus:

- Action utilisateur seulement si l'IP d'ingress change ou si un hostname ne resout pas vers l'IP courante.

Sources:

- Output OpenTofu recent.
- `.claude/PLAN.md` pour les traces historiques.
