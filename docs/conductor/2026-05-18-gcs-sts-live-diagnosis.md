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

## A faire

- Appliquer en live le role IAM manquant:
  - `roles/storage.hmacKeyAdmin` sur
    `serviceAccount:onyxia-sts-bridge@sent-tech.iam.gserviceaccount.com`
- Recharger le launcher `metabase` puis `superset`.
- Verifier que le `POST https://sts.onyxia.sent-tech.ca/` passe en `200`.
- Verifier que le formulaire launcher se rend a nouveau.
- Ensuite seulement, reprendre les bugs propres aux charts `metabase/superset`
  releves en analyse statique.

## Attendus

- Accord utilisateur explicite pour la mutation IAM live ci-dessus.

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

Conclusion: a cette heure, le blocage principal de `metabase/superset` est
amont et transverse (`GCS/STS`), pas chart-specifique.
