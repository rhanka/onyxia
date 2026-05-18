# GCS UAT Traceability

Date: 2026-05-17

Objectif: verifier que le stockage GCS via compatibilite S3 couvre toutes les surfaces Onyxia qui manipulent du stockage, avant de demarrer l'UAT Iceberg/Polaris.

## Baseline live

Fait:

- OpenTofu plan avec `STS_BRIDGE_IMAGE=gcr.io/sent-tech/onyxia-gcs-sts-bridge:gcs-deploy-20260516-2`: no changes.
- Tests unitaires STS bridge: `UV_CACHE_DIR=/tmp/uv-cache uv run --extra test pytest -q` -> `24 passed`.
- Helm live `onyxia` contient:
  - `S3.URL=https://storage.googleapis.com`
  - `S3.region=auto`
  - `S3.pathStyleAccess=true`
  - `S3.sts.URL=https://sts.onyxia.sent-tech.ca/`
  - `S3.workingDirectory.bucketName=sent-tech-onyxia-data`
  - `S3.workingDirectory.prefix=user-`
  - `S3.workingDirectory.prefixGroup=project-`
- DNS public via Cloudflare DoH:
  - `onyxia.sent-tech.ca A 34.135.88.193`
  - `sts.onyxia.sent-tech.ca A 34.135.88.193`
- L'ingress STS repond en TLS sur `34.135.88.193`; `GET /` retourne `405 Allow: POST`, attendu pour un endpoint AWS STS.
- `https://sts.onyxia.sent-tech.ca/healthz` retourne `{"status":"ok"}`.
- Kubernetes namespace `onyxia`: `onyxia-api`, `onyxia-web` et `onyxia-sts-bridge` sont `1/1 Running`; aucun warning event recent dans le namespace pendant le relevé.
- Configuration publique Onyxia lue via `GET /api/public/configuration`: `data.S3` expose GCS, STS, bucket et prefixes attendus.
- Playwright non authentifie: shell Onyxia charge avec bouton `Connexion` et `0` erreur console.

Points d'attention:

- Le resolver local du shell a ete intermittent sur `sts.onyxia.sent-tech.ca`; le DNS public Cloudflare est correct.
- L'UAT applicative doit etre faite avec un vrai login Onyxia, car le flux STS depend du token OIDC Keycloak.

## Carte des surfaces Onyxia

| Surface | Code source | Fonction GCS a couvrir |
| --- | --- | --- |
| Configuration region S3 | `web/src/core/ports/OnyxiaApi/DeploymentRegion.ts` | STS, bucket shared/multi, prefixes user/project, bookmarks |
| X-Onyxia services | `web/src/core/ports/OnyxiaApi/XOnyxia.ts` | Injection `AWS_*`, endpoint, bucket, working directory |
| Client S3 navigateur | `web/src/core/adapters/s3Client/s3Client.ts` | STS token, list, upload multipart, delete, presigned URL, policy |
| Gestion configs S3 | `web/src/core/usecases/s3ConfigManagement/` | Config region + configs projet/custom, defaults explorer/X-Onyxia |
| Test connexion S3 custom | `web/src/core/usecases/s3ConfigConnectionTest/` | `listObjects` sur config non-STS |
| Explorateur fichiers | `web/src/core/usecases/fileExplorer/` et `web/src/ui/pages/fileExplorer/` | browse, upload, directory `.keep`, delete recursive, download, share |
| Entrees explorateur | `web/src/ui/pages/fileExplorerEntry/S3Entries/` | entree personnelle, projet, bookmarks admin |
| Snippets credentials | `web/src/core/usecases/s3CodeSnippets/` | export credentials temporaires pour SDK/CLI |
| Catalogues services | `helm-chart/examples/gke-ephemeral/onyxia-private-values.local.yaml.tmpl` | services lances avec config S3 disponible |

## Matrice UAT

| ID | Statut | Surface | Test attendu | Preuve a collecter |
| --- | --- | --- | --- | --- |
| GCS-00 | Fait | Infra | Plan OpenTofu sans changement avec image STS immuable | sortie `No changes` |
| GCS-01 | Fait | DNS | `onyxia` et `sts` pointent vers l'IP ingress courante | DoH Cloudflare `34.135.88.193` |
| GCS-02 | Fait partiel | STS ingress | Endpoint STS accessible en HTTPS et refuse GET avec `405 Allow: POST` | `curl --resolve ...` |
| GCS-03 | Fait | Config Onyxia | Helm live expose la config `region.data.S3` GCS | `helm get values` |
| GCS-04 | Fait | Public config API | `/api/public/configuration` expose `data.S3` GCS | JSON public Onyxia |
| GCS-05 | Fait | STS bridge unit | Suite Python STS bridge | `24 passed` |
| GCS-06 | Fait | Kubernetes runtime | Deployments/pods/services/ingress sains | `kubectl get deploy,svc,ingress,pods` |
| GCS-07 | Fait | STS health | `/healthz` retourne `{"status":"ok"}` | `curl https://sts.../healthz` |
| GCS-08 | Fait | Shell public | Page Onyxia non authentifiee charge sans erreur console | Playwright console errors=0 |
| GCS-10 | A faire | Login/UI | Login Onyxia puis page fichiers sans erreur console | capture Playwright + console errors=0 |
| GCS-11 | A faire | STS browser | Le navigateur obtient un token STS via Keycloak OIDC | requete STS 200, credentials temporaires presents |
| GCS-12 | A faire | Explorer list | Entrer dans le working directory personnel et lister | objets visibles sous `sent-tech-onyxia-data/user-<sub>` |
| GCS-13 | A faire | Explorer upload | Uploader petit fichier texte, fichier >5 MiB et fichier avec espaces | objets crees, progres upload, contenu lisible |
| GCS-14 | A faire | Explorer directory | Creer dossier vide | objet `.keep` cree et dossier visible |
| GCS-15 | A faire | Explorer download | Telecharger un fichier et un dossier zip | contenu identique, zip valide |
| GCS-16 | A faire | Explorer delete | Supprimer fichier puis dossier recursif | objets absents dans UI et GCS |
| GCS-17 | A faire risque | Share signed URL | Generer une URL signee et l'ouvrir sans session | URL fonctionne jusqu'a expiration |
| GCS-18 | A faire risque | Policy public/private | Basculer public/private si l'UI l'autorise | verifier support GCS S3 bucket policy; sinon desactiver/masquer |
| GCS-20 | A faire | Project settings | Ajouter une config S3 custom non-STS et tester connexion | test success/failure lisible, pas de regression region default |
| GCS-21 | A faire | Defaults | Choisir config explorer et config X-Onyxia par defaut | persistence projet OK apres reload |
| GCS-22 | A faire | Snippets | Generer snippets/credentials temporaires | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, endpoint GCS |
| GCS-23 | A faire | Token lifecycle | Forcer renouvellement token et reload navigateur | nouveau token, cache session propre |
| GCS-30 | A faire | IDE Jupyter | Lancer Jupyter et lire/ecrire via `boto3` ou `s3fs` | create/read/delete dans prefixe attendu |
| GCS-31 | A faire | IDE RStudio | Lancer RStudio et acceder a GCS via env AWS/S3 | create/read/delete dans prefixe attendu |
| GCS-32 | A faire | IDE VS Code | Lancer VS Code et acceder a GCS via CLI/SDK | env presentes, operations OK |
| GCS-33 | A faire | Databases catalog | Lancer un service representatif et verifier absence de regression + env si chart compatible | pod running, env S3 si exposee |
| GCS-34 | A faire | Dataviz catalog | Lancer Superset ou Metabase et verifier integration minimale | service running, stockage/config non cassee |
| GCS-35 | A faire | Automation catalog | Lancer Airflow ou MLflow et verifier acces GCS si pertinent | artifact/DAG lit ou ecrit GCS |
| GCS-40 | A faire | Isolation utilisateur | Utilisateur A ne lit/ecrit pas le prefixe utilisateur B | 403/absence d'objets hors prefixe |
| GCS-41 | A faire | Isolation projet | Projet/groupe utilise `project-<group>` et pas `user-<sub>` | paths et permissions conformes |
| GCS-42 | A faire | Bookmarks admin | Si bookmarks configures, affichage et navigation OK | cartes bookmark + listObjects OK |
| GCS-50 | A faire | Rotation HMAC | CronJob rotation conserve l'acces et remplace les credentials | logs rotation + token post-rotation OK |
| GCS-51 | A faire | Logs/audit | STS bridge journalise provisionnement et erreurs sans secret | logs propres, pas de secret en clair |
| GCS-52 | A faire | Quotas IAM | Creation SA/HMAC reste sous quotas et gere les erreurs | comportement documente |
| GCS-60 | A faire | Iceberg prereq | Bucket warehouse et GSA Polaris utilisables apres GCS UAT | `sent-tech-onyxia-warehouse` pret pour Polaris |

## Commandes de preuve utiles

```bash
ENABLE_GCS_STORAGE=true \
STS_BRIDGE_IMAGE=gcr.io/sent-tech/onyxia-gcs-sts-bridge:gcs-deploy-20260516-2 \
./scripts/_tofu.sh app plan -detailed-exitcode -input=false -no-color
```

```bash
curl -sS -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=sts.onyxia.sent-tech.ca&type=A'
```

```bash
curl -sSI --resolve sts.onyxia.sent-tech.ca:443:34.135.88.193 \
  https://sts.onyxia.sent-tech.ca/
```

## Definition de done GCS

GCS est pret pour Iceberg quand:

- GCS-00 a GCS-18 sont passes ou explicitement classes "non supporte v1" avec mitigation.
- Au moins un IDE lance depuis Onyxia lit/ecrit/supprime dans GCS via les env injectees.
- L'isolation utilisateur/projet est prouvee.
- La rotation HMAC ne casse pas une session existante apres renouvellement token.
- Le bucket warehouse Polaris est confirme pret pour l'UAT Iceberg.
