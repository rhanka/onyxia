# Ephemeral GKE Test Deployment

Deploy Onyxia on a short-lived GKE Autopilot cluster while keeping the Onyxia
Helm chart fully provider-agnostic.

The example layers a small amount of cloud-specific glue (OpenTofu/Terraform)
on top of the standard chart. The Kubernetes/Helm contract is untouched.

The lifecycle is split into three OpenTofu roots, from durable to disposable:

- `terraform/base`: durable, low-cost resources (backup bucket).
- `terraform/cluster`: the disposable GKE Autopilot cluster and VPC.
- `terraform/app`: the disposable Onyxia Helm release plus ingress-nginx +
  cert-manager (Let's Encrypt) on that cluster.

The expected hibernation pattern is to destroy `terraform/app` and
`terraform/cluster`, keeping only `terraform/base`. Resume by applying both
roots again.

## Cost Profile

While `terraform/app` and `terraform/cluster` are up, expect:

| Item                                       | ~$ / day                              |
|--------------------------------------------|---------------------------------------|
| GKE Autopilot control plane                | $2.40 (often $0 under GCP free tier)  |
| 1 regional network LB (ingress-nginx)      | $0.60                                 |
| Onyxia + ingress-nginx + cert-manager pods | $0.70                                 |
| One running user service (e.g. Jupyter)    | $1–2                                  |

Idle target ≈ **$3–4 / day**. Shut down user services in the Onyxia UI when you
stop working; they are by far the biggest driver of variable cost.

After destroying the `app` and `cluster` roots, only the backup bucket from
`base` remains, at well under $1 / month.

For a stricter cap, create a GCP budget alert (you should anyway):

```bash
gcloud services enable billingbudgets.googleapis.com cloudbilling.googleapis.com --project=PROJECT_ID
gcloud billing budgets create \
  --billing-account=$(gcloud beta billing projects describe PROJECT_ID --format='value(billingAccountName)' | sed 's|billingAccounts/||') \
  --display-name="onyxia-gke-25usd" \
  --budget-amount=25 \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --filter-projects=projects/PROJECT_ID
```

## Prerequisites

Run from any workstation with `gcloud`, `kubectl`, `helm`, `curl`, `tar` and
`sudo` available. The bootstrap script installs the rest:

```bash
cd helm-chart/examples/gke-ephemeral
./scripts/bootstrap.sh
```

The script is idempotent. It installs:

- `tofu` (OpenTofu) under `~/.local/bin/` — no sudo.
- `gke-gcloud-auth-plugin` via Google's apt repo — sudo, once.

If you prefer to install those yourself, that works too; the script just skips
what is already on PATH.

## Quickstart

All personal values (project, hostnames, OAuth client, passwords) live in a
single gitignored file `.env.local`. Nothing personal lives in any tracked
file — the helper scripts load `.env.local` and export the right `TF_VAR_*`
+ helm-template substitutions automatically.

```bash
cd helm-chart/examples/gke-ephemeral
cp .env.local.example .env.local
$EDITOR .env.local        # fill in PROJECT_ID, hostnames, OAuth, …
./scripts/up.sh
```

Day-to-day:

```bash
./scripts/status.sh         # what's running, indicative cost
./scripts/down.sh           # destroy app layer only
./scripts/down.sh --full    # destroy app + cluster + VPC
```

The sections below explain each layer if you want to drive `tofu` directly
(`source scripts/_load_env.sh` first to get the `TF_VAR_*` exported).

## CI on GitHub Actions

A workflow at `.github/workflows/onyxia-gke-ephemeral.yml` drives the example
end-to-end from your fork without ever exposing personal values in the repo.
Everything personal lives in GitHub repo **variables** (non-secret) and
**secrets** (sensitive); the workflow file references them by name only.

### One-time setup

```bash
# .env.local already populated with the non-secret values
./scripts/gh-setup.sh
```

`gh-setup.sh` pushes the following to your fork:

| Kind   | Name                          | Source                  |
|--------|-------------------------------|-------------------------|
| var    | GCP_PROJECT_ID                | `.env.local`            |
| var    | GCP_REGION                    | `.env.local`            |
| var    | GCP_CLUSTER_NAME              | `.env.local`            |
| var    | PUBLIC_HOSTNAME               | `.env.local`            |
| var    | KEYCLOAK_HOSTNAME             | `.env.local`            |
| var    | LETSENCRYPT_EMAIL             | `.env.local`            |
| var    | GOOGLE_OAUTH_CLIENT_ID        | `.env.local`            |
| var    | GOOGLE_OAUTH_ALLOWED_EMAILS   | `.env.local`            |
| secret | GOOGLE_OAUTH_CLIENT_SECRET    | prompt (or env)         |
| secret | GOOGLE_OAUTH_COOKIE_SECRET    | prompt (or env)         |
| secret | KEYCLOAK_ADMIN_PASSWORD       | prompt (or env)         |
| secret | GCP_SA_KEY                    | path or paste (JSON)    |

The deployer service account needs at least `roles/container.admin`,
`roles/compute.networkAdmin`, `roles/iam.serviceAccountUser` on the project.

### Run

```bash
gh workflow run onyxia-gke-ephemeral.yml -f mode=init       # full cold start
gh workflow run onyxia-gke-ephemeral.yml -f mode=resume     # apply app + reconfigure Keycloak realm
gh workflow run onyxia-gke-ephemeral.yml -f mode=down       # destroy app layer (keeps the cluster)
gh workflow run onyxia-gke-ephemeral.yml -f mode=down_full  # destroy everything down to the VPC
```

`init` runs the three Terraform layers in order and bootstraps the Kubernetes
Secrets (`onyxia-oauth2-proxy`, `keycloak-bootstrap-admin`). `resume` is the
fast path after a hibernation: it only touches the `app` layer and re-applies
the Keycloak realm (the H2 in-memory store loses its state every restart).

## Manual `tofu` workflow (advanced)

If you'd rather drive `tofu` directly (without the helper scripts), source the
loader once to export the `TF_VAR_*` variables from `.env.local`:

```bash
source scripts/_load_env.sh
cd terraform/app && tofu init && tofu apply
```

The legacy per-layer `terraform.tfvars` workflow (one `tfvars` file per root)
is still supported as an alternative — see the `*.tfvars.example` files. Pick
one approach; do not mix.

## Configure Durable Base

```bash
cd helm-chart/examples/gke-ephemeral/terraform/base
cp terraform.tfvars.example terraform.tfvars
```

Edit:

```hcl
project_id         = "my-gcp-project"
region             = "us-central1"
bucket_location    = "US-CENTRAL1"
backup_bucket_name = "my-gcp-project-onyxia-test-backup"
```

Apply once:

```bash
tofu init
tofu apply
```

## Create The Cluster

```bash
cd ../cluster
cp terraform.tfvars.example terraform.tfvars
```

Edit:

```hcl
project_id   = "my-gcp-project"
region       = "us-central1"
cluster_name = "onyxia-test"
```

Create the disposable cluster:

```bash
tofu init
tofu apply
gcloud container clusters get-credentials onyxia-test \
  --project my-gcp-project --location us-central1
```

## Deploy Onyxia (Local-Only Mode)

The default `terraform/app` apply installs Onyxia behind no public endpoint —
useful for a private smoke test through `kubectl port-forward`.

```bash
cd ../app
cp terraform.tfvars.example terraform.tfvars
tofu init
tofu apply
```

Then start the two port-forwards and the local proxy in three terminals
(commands also exposed as outputs):

```bash
kubectl -n onyxia port-forward --address 127.0.0.1 svc/onyxia-web 18082:80
kubectl -n onyxia port-forward --address 127.0.0.1 svc/onyxia-api 18083:80
ONYXIA_PROXY_PORT=18080 ONYXIA_WEB_PORT=18082 ONYXIA_API_PORT=18083 \
  node ../../scripts/onyxia-local-proxy.mjs
```

Open <http://127.0.0.1:18080>.

The proxy keeps the same browser-visible shape as the chart Ingress template:
`/api` to the API service, `/` to the web service.

## Public Mode — ingress-nginx + cert-manager (Let's Encrypt)

The example also supports a fully public deployment behind a **single regional
network LB**, served by `ingress-nginx`, with HTTPS certificates issued
automatically by `cert-manager` against Let's Encrypt production. This is the
recommended public mode: provider-agnostic, one LB only, fast cert issuance.

### Pieces installed by `terraform/app`

- `ingress-nginx` Helm release in namespace `ingress-nginx` — creates the
  single regional network LB.
- `cert-manager` Helm release in namespace `cert-manager`.
- A `ClusterIssuer` named `letsencrypt-prod`, registered with your email.
- An Onyxia auth-gateway `Ingress` (created by Terraform) with class `nginx`
  and the `cert-manager.io/cluster-issuer` annotation, fronting the
  `oauth2-proxy` gateway.
- Onyxia's region config (`api.regions[].services.expose.certManager`) so that
  **every service users launch** (Jupyter, RStudio, etc.) gets its own
  Let's Encrypt certificate without further configuration.

### Google OAuth client

Create a Google OAuth 2.0 Web client for your hostname (e.g. `onyxia.example.com`):

- Authorized JavaScript origin: `https://onyxia.example.com`
- Authorized redirect URI: `https://onyxia.example.com/oauth2/callback`

The browser-side OAuth runs through the oauth2-proxy gateway, so Onyxia's
in-browser OpenID Connect mode is not needed and `authentication.mode: none`
is set in `onyxia-gke-oauth2-proxy-values.yaml`.

### Configure values

Create the local overlay (gitignored):

```bash
cd helm-chart/examples/gke-ephemeral
touch onyxia-private-values.local.yaml
```

Edit `onyxia-private-values.local.yaml`:

```yaml
ingress:
  hosts:
    - host: onyxia.example.com

api:
  env:
    security.cors.allowed_origins: "https://onyxia.example.com"
  regions:
    - id: gke
      services:
        expose:
          domain: services.onyxia.example.com
          certManager:
            useCertManager: true
            certManagerClusterIssuer: letsencrypt-prod
```

The OAuth client secret and cookie secret are passed via a Kubernetes Secret
referenced by `oauth2_proxy_secret_name`. Create it out of band so secrets do
not enter Terraform state:

```bash
kubectl -n onyxia create secret generic onyxia-oauth2-proxy \
  --from-file=client-secret=/path/to/client-secret \
  --from-file=cookie-secret=/path/to/cookie-secret
```

### Enable public mode in tfvars

In `terraform/app/terraform.tfvars`:

```hcl
public_hostname                  = "onyxia.example.com"
extra_values_files = [
  "../../onyxia-gke-public-values.yaml",
  "../../onyxia-gke-oauth2-proxy-values.yaml",
  "../../onyxia-private-values.local.yaml",
]

enable_oauth2_proxy_gateway = true
oauth2_proxy_client_id      = "000000000000-example.apps.googleusercontent.com"
oauth2_proxy_allowed_emails = ["me@example.com"]
oauth2_proxy_secret_name    = "onyxia-oauth2-proxy"
oauth2_proxy_cookie_domain  = ".onyxia.example.com"
oauth2_proxy_whitelist_domains = [".onyxia.example.com"]

enable_services_ingress_nginx      = true
services_ingress_class_name        = "nginx"
services_ingress_nginx_oauth2_auth = true

enable_cert_manager              = true
cert_manager_letsencrypt_email   = "me@example.com"
cert_manager_cluster_issuer_name = "letsencrypt-prod"

# Legacy GCE/ManagedCertificate path. Leave false — kept only for users who
# can't use cert-manager / Let's Encrypt and want Google-managed certificates.
create_gke_public_ingress_support = false
```

### Apply and point DNS

```bash
cd terraform/app
tofu apply
```

Take the load balancer IP from the apply outputs:

```bash
tofu output -raw services_ingress_nginx_ip
```

Create two DNS records at your provider (Cloudflare, OVH, Route53, etc.):

```
A   onyxia.example.com               <services_ingress_nginx_ip>
A   *.services.onyxia.example.com    <services_ingress_nginx_ip>
```

Use a short TTL (300s) while iterating.

Once the records resolve to the LB, cert-manager will satisfy the HTTP-01
challenge in under a minute. Check progress:

```bash
kubectl -n onyxia get certificate,order,challenge
```

When the certificate is `Ready=True`, open `https://onyxia.example.com`.

### Validate end-to-end

A quick smoke test of the cert-manager / ingress-nginx pipeline, without going
through Onyxia, uses any host in the services wildcard:

```bash
kubectl create namespace cert-smoketest
kubectl -n cert-smoketest apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
  - hosts: [cert-smoketest.services.onyxia.example.com]
    secretName: cert-smoketest-tls
  rules:
  - host: cert-smoketest.services.onyxia.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes  # any service; auth will block the response anyway
            port:
              number: 443
EOF
kubectl -n cert-smoketest get certificate -w
kubectl delete namespace cert-smoketest
```

On a healthy setup the certificate becomes `Ready=True` in 10–30 seconds.

## Real Google Identity — Keycloak IdP (recommended)

The default `oauth2-proxy` gateway above only **gates** access to Onyxia; the
platform itself runs in `authentication.mode: none` and sees every user as the
mock account `default` / `John`. For multi-user usage with real Gmail identities
propagated inside Onyxia (per-user projects, vault dirs, namespaces), enable
the optional in-cluster Keycloak with a Google identity provider.

This mirrors the SSP Cloud / INSEE production pattern (Onyxia → Keycloak →
Google) and works out of the box.

### Enable via `.env.local`

Set in `.env.local`:

```bash
KEYCLOAK_HOSTNAME=auth.onyxia.example.com   # must resolve to the same LB
ENABLE_KEYCLOAK=true                        # default is already true when using ./scripts/up.sh
```

### Create the Keycloak admin password as a Kubernetes Secret (out of band)

The admin password is never stored in any file in this repo (not even
gitignored ones) or in Terraform state. Create it directly in the cluster:

```bash
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl -n keycloak create secret generic keycloak-bootstrap-admin \
  --from-literal=password='<your strong password>'
```

DNS: add an `A` record `auth.onyxia.example.com → <services_ingress_nginx_ip>`.

### Add the Keycloak callback to Google OAuth

In Google Cloud Console → APIs & Services → Credentials → your OAuth 2.0 Web
client, add the redirect URI:

```
https://auth.onyxia.example.com/realms/onyxia/broker/google/endpoint
```

### Apply + configure the realm

```bash
./scripts/up.sh

# Configure the realm (idempotent, also re-run after each Keycloak restart
# since the chart ships H2 in-memory by default). The admin password is read
# back from the Kubernetes Secret you created above.
source ./scripts/_load_env.sh
KC_ADMIN_PASSWORD="$(kubectl -n keycloak get secret keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)" \
GOOGLE_CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID}" \
ONYXIA_HOSTNAME="${PUBLIC_HOSTNAME}" \
KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME}" \
  ./scripts/keycloak-init.sh
```

`keycloak-init.sh` is idempotent. It creates the `onyxia` realm, a public PKCE
client called `onyxia`, and a Google identity provider — exactly what Onyxia
expects. Re-run after every Keycloak restart (the chart ships an H2 in-memory
database by default; for persistence wire an external Postgres via
`database.*` in the Helm release).

### Switch Onyxia to OIDC against Keycloak

In `onyxia-gke-public-values.yaml` (already wired when `enable_keycloak=true`):

- `ingress.enabled: true` with `class: nginx` + `cert-manager` annotation.
- `nginx.ingress.kubernetes.io/configuration-snippet` overrides the strict
  default `frame-src` CSP so oidc-spa can iframe Keycloak's login.
- `api.env.authentication.mode: openidconnect`
- `api.env.oidc.issuer-uri: "https://auth.<your hostname>/realms/onyxia"`
- `api.env.oidc.clientID: "onyxia"`
- **`api.env.oidc.username-claim: sub`** — must produce an RFC1123-compliant
  token (no dots/@). The Keycloak `sub` UUID is always safe. Using `email`
  breaks because Onyxia API filters non-RFC1123 namespaces and the user-project
  is dropped.
- `web.env.OIDC_DISABLE_DPOP: "true"` — Keycloak doesn't accept the `DPoP`
  header on the token endpoint by default.

`./scripts/up.sh` already sets `enable_oauth2_proxy_gateway=false` and
`services_ingress_nginx_oauth2_auth=false` when `ENABLE_KEYCLOAK=true`, so the
oauth2-proxy gateway is not deployed in this mode.

### Result

`https://onyxia.<your hostname>` → "Connexion" → Keycloak login screen → click
**Google** → Google consent → return to Onyxia logged in as **the real Gmail
user**. The Account page shows the actual `<your-account>@gmail.com` email and
a per-user project namespace `user-<keycloak-uuid>`.

## GKE Autopilot Gotchas

GKE Autopilot is a great fit for ephemeral test clusters, but enforces a few
Pod Security / namespace constraints that bite generic Helm charts. The
example's `terraform/app/main.tf` already works around the following:

- **`kube-system` is read-only for workloads.** cert-manager's controller and
  cainjector default to leader-election leases in `kube-system`. The example
  pins `global.leaderElection.namespace=<cert-manager namespace>`.
- **`cert-manager-startupapicheck` job is flaky on Autopilot.** It's a
  post-install health check, not a runtime dependency. The example disables it
  via `startupapicheck.enabled=false`.
- **cert-manager 1.16+ ships `crds.enabled`.** The deprecated `installCRDs`
  flag conflicts with it. The example only sets `crds.enabled=true`.
- **No write access to the `gce-pd` storage class metadata.** Standard PVCs
  still work; just don't try to mutate the default storage class.

## Brand it (optional)

This example can reskin Onyxia at deploy time using the [`@sentropic/design-system-themes`](https://www.npmjs.com/package/@sentropic/design-system-themes) tokens — colors, fonts, logo, header strings. Zero fork of `onyxia-web`.

### Enable the sentropic theme

In `.env.local`:

```
ENABLE_SENTROPIC_THEME=true
SENTROPIC_HEADER_LOGO_URL=https://cdn.sent-tech.ca/onyxia-logo.svg
SENTROPIC_HEADER_TEXT_BOLD=sent-tech
SENTROPIC_HEADER_TEXT_FOCUS=Datalab
```

Run `./scripts/up.sh` (or the GHA workflow with `mode=resume`). The deploy will:

1. `npm ci` inside `theme/` (cached after the first run).
2. Run `theme/sentropic-to-onyxia.mjs`, which produces a `BEGIN SENTROPIC THEME` block.
3. Splice the block under `web.env:` in `onyxia-private-values.local.yaml`.
4. `tofu apply` upgrades the helm release — Onyxia restarts with the new env, which `onyxia-web` consumes at boot.

### Pin a specific sentropic version

Edit `theme/package.json`:

```json
"dependencies": {
  "@sentropic/design-system-themes": "0.5.0"
}
```

Then `cd theme && npm install --package-lock-only && git commit -am "chore: bump sentropic to <version>"`.

Optionally also set `SENTROPIC_THEME_VERSION=v0.6.0` in `.env.local` so the jsdelivr font URLs match the version you installed.

### Swap to a different design system

The generator is intentionally thin (~80 LOC). Copy `theme/sentropic-to-onyxia.mjs` to e.g. `theme/mydsl-to-onyxia.mjs`, change the `import` and the mapping in `lib/mapping.mjs` to your tokens, and point `_load_env.sh` at the new entry point. The Onyxia palette contract is documented at `onyxia-ui/src/lib/color.urgent.ts` (upstream) and re-stated in `lib/mapping.mjs` comments.

### Scope

V1 ships colors + fonts + logo + header strings. Component **shape** (button radius, drawer geometry) is not covered — that needs a fork of `onyxia-ui` and is deliberately deferred.

## Pause And Resume

Destroy the disposable layers:

```bash
PROJECT_ID=my-gcp-project ./scripts/down.sh         # app only
PROJECT_ID=my-gcp-project ./scripts/down.sh --full  # app + cluster + VPC
```

The backup bucket from `terraform/base` remains.

Resume by re-running `./scripts/up.sh` (the script will re-apply
`terraform/cluster` and `terraform/app` in order if needed).

Sanity-check that no LBs, forwarding rules, or reserved IPs are left behind:

```bash
gcloud compute forwarding-rules list --project my-gcp-project
gcloud compute addresses list        --project my-gcp-project
gcloud compute target-https-proxies list --project my-gcp-project
gcloud container clusters list       --project my-gcp-project
```

## Layout

```
helm-chart/examples/gke-ephemeral/
├── README.md
├── onyxia-values.yaml                       # minimal local-only values
├── onyxia-gke-public-values.yaml            # public mode values (committed)
├── onyxia-gke-oauth2-proxy-values.yaml      # oauth2-proxy gateway values (committed)
├── onyxia-private-values.local.yaml         # gitignored, your specifics
├── scripts/
│   ├── bootstrap.sh                          # install prerequisites (idempotent)
│   ├── up.sh / down.sh / status.sh           # day-to-day lifecycle
│   ├── common.sh                             # shared helpers
│   └── onyxia-local-proxy.mjs                # /api routing for local mode
└── terraform/
    ├── base/      # backup bucket
    ├── cluster/   # GKE Autopilot + VPC
    └── app/       # Onyxia + ingress-nginx + cert-manager
```
