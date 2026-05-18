# GCS / STS Live Diagnosis

Date: 2026-05-18

## Fait

- Reproduction live dans le navigateur sur:
  - `https://onyxia.sent-tech.ca/launcher/dataviz/metabase`
  - `https://onyxia.sent-tech.ca/launcher/dataviz/superset`
- Constat initial:
  - le `main` du launcher restait vide;
  - le front appelait `POST https://sts.onyxia.sent-tech.ca/`;
  - reponse `401 {"detail":"invalid token: Invalid audience"}`.
- Cause racine #1 confirmee:
  - le token utilisateur Keycloak ne portait pas `aud: onyxia`;
  - le bridge STS attend `OIDC_AUDIENCE=onyxia`.
- Correctif live applique dans Keycloak:
  - ajout du protocol mapper `onyxia-self-audience` sur le client `onyxia`.
- Resultat apres ce correctif:
  - le `401` a disparu;
  - le bridge STS est alle plus loin puis a retourne `500`.
- Cause racine #2 confirmee dans les logs `onyxia-sts-bridge`:
  - `403 storage.hmacKeys.create`;
  - le service account `onyxia-sts-bridge@sent-tech.iam.gserviceaccount.com`
    n'a pas le role IAM permettant de creer les HMAC GCS.
- Correctif repo prepare:
  - branche `fix/gcs-sts-onyxia-audience`
  - commit `d41ea0d5`
  - PR `#4`: `fix(gcs-sts): restore Onyxia audience and HMAC role`
- Correctif live applique ensuite:
  - ajout du role `roles/storage.hmacKeyAdmin` au service account
    `onyxia-sts-bridge@sent-tech.iam.gserviceaccount.com`.
- Resultat apres ce correctif IAM:
  - le `POST https://sts.onyxia.sent-tech.ca/` est passe en `200`;
  - mais le front affichait encore `Invalid STS response when assuming role with web identity`.
- Cause racine #3 confirmee:
  - le runtime web live (`inseefrlab/onyxia-web` `4.58.6`) attend encore un
    `SessionToken` non vide dans la reponse STS;
  - le bridge GCS renvoyait `AccessKeyId`, `SecretAccessKey`, `Expiration`,
    mais omettait `SessionToken`.
- Correctif repo + live applique:
  - commit `a3af0ea0` sur le bridge STS;
  - image redeployee:
    `gcr.io/sent-tech/onyxia-gcs-sts-bridge:fix-a3af0ea0`;
  - Deployment et CronJob `onyxia-sts-bridge(-rotate)` mis a jour vers ce tag.
- Validation live:
  - `POST https://sts.onyxia.sent-tech.ca/` retourne maintenant `200` avec
    `SessionToken=unused-by-gcs`;
  - les launchers `metabase` et `superset` rendent de nouveau leur formulaire.

## A faire

- Pousser les commits `d41ea0d5` + `a3af0ea0` sur `main`.
- Mettre a jour le mecanisme de build/deploy pour que l'image STS bridge
  versionnee en registry reste coherente avec le repo sans patch live manuel.
- Reprendre ensuite les bugs propres aux charts `metabase/superset`
  releves en analyse statique.

## Attendus

- Aucun blocage immediat pour le bridge STS.
- Arbitrage ulterieur sur le traitement des erreurs restantes de theme
  (`sent-tech-logo.svg` 404) qui ne bloquent pas le lancement.

## Notes chart-level

Les analyses paralleles ont aussi releve des risques secondaires, a traiter
apres la remise en etat du bridge STS:

- `metabase`:
  - Postgres embarque probablement non compatible GKE Autopilot par defaut
    (`resourcesPreset: nano`, `podAntiAffinityPreset: soft`);
  - probes Metabase probablement trop agressives au premier boot.
- `superset`:
  - ingress custom sans annotations cert-manager;
  - bootstrap runtime `pip install ...` lourd;
  - ressources non explicites sur web/worker/init.

Conclusion: le blocage principal observe sur `metabase/superset` etait bien
amont et transverse (`GCS/STS`). L'IAM en faisait partie, mais pas seule:
il fallait aussi realigner le contrat STS entre le bridge GCS et le runtime
web effectivement deploye.
