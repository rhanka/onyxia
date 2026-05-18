# PLAN.md Crosswalk

Date: 2026-05-18

Objectif: recroiser le `PLAN.md` historique Claude avec les tracks actifs pour eviter d'oublier les sujets hors plugin inter-PaaS.

## Regle de pilotage

- `/.claude/PLAN.md` reste une source historique et une trace de l'intention upstream initiale.
- Les fichiers `docs/conductor/*` deviennent la source de pilotage active multi-track.
- Toute proposition avec arbitrage doit maintenant avoir:
  - une page HTML de dossier de decision dans le companion UI;
  - un releve Markdown telechargeable;
  - contexte, options, impacts, questions et statut `Fait / A faire / Attendus`.

## Attention: elements stale dans PLAN.md

Le `PLAN.md` reste utile, mais il contient au moins deux zones depassees:

- DNS: il demande une ancienne bascule vers `35.192.81.132`; l'IP ingress courante observee est `34.135.88.193`.
- Auth: il documente le blocage oauth2-proxy/Dex et l'identite mock; le deploiement courant utilise Keycloak/OIDC comme cible de login.

Donc `PLAN.md` ne doit pas etre execute aveuglement. Il doit etre interprete comme backlog/contexte.

## Crosswalk multi-track

| Track | Source PLAN.md / docs | Statut actif | Prochain pilotage |
| --- | --- | --- | --- |
| Socle GKE / upstream | `.claude/PLAN.md` | A reconciler | Verifier ce qui reste upstreamable apres GCS/Keycloak/Sentropic |
| DNS / TLS | `.claude/PLAN.md`, outputs OpenTofu | Stable actuellement | Ne demander action DNS que si IP ingress change |
| Auth / Keycloak | PLAN.md post-mortem Dex + etat live | En service, UAT login requis | Valider session utilisateur reelle et projet personnel/groupe |
| Theme Sentropic | spec/plan theme + conductor | UAT visuelle | Logo/favion definitifs a fournir ou accepter `/logo.svg` |
| GCS / STS | spec/plan GCS + UAT matrix | UAT technique en cours | UAT authentifiee UI/IDE/isolation |
| Iceberg / Polaris | spec/plan Polaris | UAT a preparer | Attendre baseline GCS puis activer/tester Polaris |
| Inter-PaaS plugin | proposition nouvelle | P1 | Designer le module transverse avant services dependants |
| Catalog MCP | contributor catalog draft | P1/P2 | Read/report first, mutations plus tard |
| DB / Dataviz / Dataprep | catalogues Onyxia `databases`, `dataviz`, `ide`, `automation` | P2 | Premier vertical PaaS: DB + Jupyter/OpenRefine + Superset/Metabase |
| matchID backend/front | intention utilisateur | P2/P3 | Attendre modele inter-PaaS + sources images/charts |
| deces.matchid.io | intention utilisateur | P2/P3 | Traiter comme service marketplace distinct |
| data.gouv.fr | ancien brainstorm datagouv + intention utilisateur | P3, postponed | Garder comme source SaaS externe, pas integration directe |
| api.gouv.fr | intention utilisateur | P3, postponed | Garder comme source API externe, pas integration directe |
| Catalog contributeur | contributor catalog draft | Cadrage actif | Garder comme registre de decisions/UAT, pas runtime tant que non valide |

## Priorite corrigee

### P0 - Fondations deja en cours

- GKE/DNS/TLS/auth: maintenir et reconciler avec `PLAN.md`.
- GCS/ST​S: finir UAT.
- Iceberg/Polaris: demarrer apres baseline GCS.
- Theme Sentropic: garder sans regression console, finaliser assets.

### P1 - Module inter-PaaS

- Designer l'objet transverse qui manque: services, ressources, connections, policies, hooks, UAT.
- Ne pas basculer trop vite vers data.gouv/api.gouv avant ce modele.

### P2 - Services PaaS connectables

- DB, dataviz, dataprep/datascience, MCP, matchID.
- Cadrage parallele possible, mais implementation apres le modele inter-PaaS.

### P3 - SaaS externes

- data.gouv.fr et api.gouv.fr restent au backlog comme sources externes.
- Ils redeviendront prioritaires quand le plugin saura ingester/source->destination->droits->UAT.

## Questions de decision ouvertes

1. Source of truth: garder `docs/conductor/*` comme source active et `PLAN.md` comme historique ?
2. Premier vertical inter-PaaS: `GCS + DB + Jupyter/OpenRefine + Superset/Metabase` ou `Iceberg + Jupyter + Trino/Superset` ?
3. Premiere app dataviz: Superset ou Metabase ?
4. V1 du plugin: metadata/read/report seulement, ou provisioning mutating sous garde-fous ?
5. Faut-il ouvrir un PR upstream GKE avant ou apres integration des changements GCS/Keycloak/Sentropic ?

## Attendus utilisateur

- Valider la regle: chaque question importante passe par un dossier de decision HTML + releve telechargeable.
- Valider que `PLAN.md` est historique et que le conductor est actif.
- Choisir le premier vertical inter-PaaS quand le contexte sera suffisant.
