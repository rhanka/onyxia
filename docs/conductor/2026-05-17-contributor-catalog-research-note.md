# Contributor Catalog Research Note

Date: 2026-05-17

Statut: cadrage autonome, pas encore une spec approuvee.

## Question

Comment integrer data.gouv.fr, api.gouv.fr, les APIs internes, Kafka, MCP, matchID et les futures plateformes Sent-Tech dans Onyxia sans confondre ce besoin avec le catalogue Helm existant ?

## Ce qui existe deja dans Onyxia

### 1. Catalogue de services Helm

Onyxia expose deja `api.catalogs` pour declarer des catalogues de charts Helm:

- `id`, `name`, `location`, `maintainer`, `status`, `type=helm`
- exemples locaux: `ide`, `databases`, `dataviz`, `automation`
- usage: decouverte et lancement de services Kubernetes.

Limite: ce catalogue decrit des services deployables, pas des sources de donnees, contrats API, actions MCP, workflows d'import, lineage ou politiques de dispatch.

Sources:

- `helm-chart/values.yaml`
- `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml`
- `web/src/core/ports/OnyxiaApi/OnyxiaApi.ts`

### 2. Contexte X-Onyxia

Les charts peuvent declarer des champs `x-onyxia` pour recevoir du contexte au lancement:

- utilisateur et tokens OIDC
- projet
- git
- vault
- S3: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_S3_ENDPOINT`, `AWS_BUCKET_NAME`, `workingDirectoryPath`
- region Kafka: `url`, `topicName`

Limite: excellent mecanisme d'injection au moment du lancement, mais ce n'est pas un inventaire metier ni un systeme de gouvernance.

Source:

- `web/src/core/ports/OnyxiaApi/XOnyxia.ts`

### 3. Region data / S3 / Kafka

La configuration de region connait les primitives techniques:

- `s3Configs`
- `s3ConfigCreationFormDefaults`
- `kafka`
- `vault`
- `kubernetes`
- injections CA/proxy/packages

Limite: ce sont des capacites de runtime, pas une carte navigable des actifs data/API/MCP.

Source:

- `web/src/core/ports/OnyxiaApi/DeploymentRegion.ts`

### 4. User profile et schemas

Le chart Onyxia permet de pousser des schemas de profil utilisateur et des schemas additionnels.

Limite: utile pour parametrer les formulaires et les profils, pas suffisant pour publier des composants contributeurs avec lifecycle/UAT.

Source:

- `helm-chart/values.yaml`

## Conclusion de cadrage

Il ne faut pas remplacer `api.catalogs`. Il faut ajouter un **catalogue contributeur** au-dessus ou a cote:

- `api.catalogs` reste le registre des services deployables.
- `X-Onyxia` reste le mecanisme d'injection runtime.
- Le nouveau catalogue contributeur devient le registre des actifs et connecteurs: donnees, API, MCP tools, workflows, services marketplace, UAT et ownership.

## Modele minimal recommande

### Entity: `catalog_item`

Champs communs:

- `id`
- `kind`: `service`, `data_source`, `api`, `mcp_tool`, `connector`, `workflow`, `iceberg_catalog`
- `title`
- `owner`
- `status`: `brainstorm`, `spec`, `plan`, `uat`, `prod`, `deprecated`
- `description`
- `links`: docs, repo, chart, endpoint, dashboard
- `security`: auth type, scopes, secret refs, data sensitivity
- `runtime_hooks`: helm chart, DAG, job, MCP action, API probe
- `uat`: checklist IDs, last evidence, blockers
- `dependencies`: other `catalog_item.id`

### Facettes par type

- `data_source`: dataset refs, schema, licence, refresh, landing zone, quality checks.
- `api`: base URL, OpenAPI/schema, auth, rate limits, sample calls, consumers.
- `mcp_tool`: tools exposed, auth boundary, audit, allowed actions.
- `service`: Onyxia catalog/chart references, env injection, ingress, DB/storage needs.
- `connector`: source, destination, transform, schedule, replay/idempotence.
- `workflow`: orchestrator, inputs, outputs, runbook.
- `iceberg_catalog`: REST URI, warehouse, namespace policy, engine compatibility.

## Tracks utilisateur mappes

| Track | Kind principal | Premiere integration utile |
| --- | --- | --- |
| GCS | `connector` + `data_source` | cataloguer bucket data, prefixes, STS, UAT |
| Iceberg/Polaris | `iceberg_catalog` | cataloguer REST catalog + warehouse GCS |
| data.gouv.fr | `data_source` + `connector` | dataset -> GCS -> dataprep/DB |
| api.gouv.fr | `api` + `connector` | API -> service Onyxia ou workflow |
| catalog API | `api` | registry interne + externe, Kafka inclus |
| catalog MCP | `mcp_tool` | actions Onyxia et Sent-Tech exposees avec audit |
| matchID | `service` + `workflow` | deux fiches marketplace: backend/front, deces.matchid.io |
| Sent-Tech/Sentec | `service` + `mcp_tool` | premier vertical MCP/agentique limite |

## Approches possibles

### A. Fichier GitOps YAML dans un repo contributeur

Recommandation pour v1.

Avantages:

- simple a auditer et versionner
- compatible avec PR/review
- peut alimenter docs, UAT et plus tard UI/API
- ne demande pas de modifier Onyxia core au depart

Limites:

- pas de recherche/UI riche au debut
- validation schema a ajouter

### B. Service catalogue dedie dans Onyxia

Avantages:

- API et UI natives
- meilleur pour workflows dynamiques, permissions et recherche

Limites:

- plus couteux
- demande une vraie spec produit et probablement changements core/API

### C. Extension du catalogue Helm existant

Avantages:

- reutilise l'UI marketplace existante
- rapide pour matchID et services deployables

Limites:

- mauvais modele pour datasets, API, MCP tools et workflows non-Helm
- risque de melanger "actif catalogable" et "service deployable"

## Recommandation

Demarrer par A: un **catalogue contributeur GitOps** avec schema JSON/YAML, validation CI et rendu docs. Le relier aux catalogues Helm existants par references, sans forcer toutes les entites a devenir des charts.

Le premier vertical devrait etre GCS/Iceberg, car il donne une base de stockage et de gouvernance pour data.gouv.fr, api.gouv.fr et matchID.

## Prochaines actions sans decision utilisateur

- Ecrire un schema de brouillon pour `catalog_item`.
- Ajouter des fiches `draft` non executables pour GCS, Iceberg, data.gouv.fr, api.gouv.fr, MCP et matchID.
- Ajouter une validation locale minimale du schema.

## Decisions utilisateur attendues

- Confirmer que v1 peut etre GitOps YAML avant UI native.
- Choisir le premier vertical fonctionnel apres GCS: `Iceberg`, `data.gouv -> GCS`, `api.gouv`, `MCP Sent-Tech`, ou `matchID`.
- Confirmer le niveau de gouvernance souhaite: simple inventaire, registre UAT, ou catalogue pilotant des actions.
