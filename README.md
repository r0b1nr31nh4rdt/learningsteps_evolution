# LearningSteps Evolution — Kubernetes on Azure, fully as Code

The **LearningSteps API** (a FastAPI + PostgreSQL learning journal) redeployed
as a container on **Azure Kubernetes Service (AKS)**, with the complete Azure
infrastructure declared in **Terraform** and the workload declared in
**Kubernetes manifests**.

This is the second iteration of the project. The first one
([learningsteps-azure-infra](https://github.com/r0b1nr31nh4rdt/learningsteps-azure-infra))
ran the app on two VMs provisioned with Azure CLI commands.

> **Status: work in progress.** The Terraform configuration is written and
> has been destroyed and re-applied successfully, the app runs on AKS with
> its database schema, and all CRUD operations work. The CI/CD pipeline is
> written and checked locally; its first run on GitHub is pending.

---

## What changed compared to the first iteration

| | Iteration 1 | Iteration 2 (this repo) |
|---|---|---|
| Repositories | infrastructure and app in separate repos | one repo: app, Dockerfile, Terraform, manifests, pipelines |
| Provisioning | imperative `az` commands, run step by step | declarative Terraform, one `terraform apply` |
| App runtime | systemd service on a VM | container on AKS, 2 nodes |
| Database | PostgreSQL installed on a VM | Azure Database for PostgreSQL **Flexible Server** (managed) |
| Entry point | public IP of the API VM | Ingress (managed NGINX) behind an Azure Load Balancer |
| Secret retrieval | VM reads Key Vault via IMDS | pod reads Key Vault via **Workload Identity** + CSI driver |
| Image registry | none (code cloned onto the VM) | Azure Container Registry |

The security idea stays the same: the database is not reachable from the
internet, and the password lives only in Key Vault.

---

## Architecture

``` mermaid
graph TB
    User([Internet / Browser])

    subgraph RG["Resource Group: rg-learningsteps-dev (westeurope)"]
        ACR["Container Registry<br/>admin user disabled"]
        Vault["Key Vault (RBAC)<br/>secret: database-url"]
        AppId["Managed Identity id-app<br/>Key Vault Secrets User<br/>on this one secret"]

        subgraph VNet["VNet 10.10.0.0/16"]
            subgraph AksSub["Subnet snet-aks 10.10.0.0/24"]
                Ingress["Ingress<br/>(App Routing / NGINX)"]
                Pods["API pods<br/>ServiceAccount learningsteps-app"]
            end
            subgraph PgSub["Subnet snet-postgres 10.10.1.0/24<br/>(delegated)"]
                DB["PostgreSQL Flexible Server 16<br/>no public access"]
            end
        end
        DNS["Private DNS zone<br/>*.private.postgres.database.azure.com"]
    end

    User -->|HTTP| LB["Azure Load Balancer<br/>(created by AKS)"]
    LB --> Ingress
    Ingress --> Pods
    Pods -->|5432, TLS| DB
    Pods -.->|name lookup| DNS
    Pods -.->|federated token| AppId
    AppId -.->|read secret| Vault
    Pods -.->|AcrPull via kubelet identity| ACR
```

### Components

| Component | Terraform file | Purpose |
|---|---|---|
| Resource group `rg-learningsteps-dev` | `main.tf` | Container for all resources |
| VNet `10.10.0.0/16` with two subnets | `network.tf` | Private network for cluster and database |
| Private DNS zone + VNet link | `network.tf` | Resolves the database hostname to its private IP inside the VNet |
| AKS cluster, 2–3 × `Standard_D2s_v6` (cluster autoscaler) | `aks.tf` | Runs the API containers; Azure CNI Overlay networking |
| App Routing add-on | `aks.tf` | Managed NGINX ingress controller |
| Key Vault Secrets Provider add-on | `aks.tf` | CSI driver that brings Key Vault secrets into pods |
| PostgreSQL Flexible Server 16, `B_Standard_B1ms` | `postgres.tf` | Managed database, private access only |
| Key Vault + secret `database-url` | `keyvault.tf` | Holds the complete connection string |
| App identity + federated credential | `keyvault.tf` | Lets exactly one Kubernetes ServiceAccount act as an Azure identity |
| Container Registry (Basic) | `acr.tf` | Stores the API image; the cluster pulls with `AcrPull` |

**Resource groups:** Terraform creates `rg-learningsteps-dev`. AKS creates
and owns a second group, `MC_rg-learningsteps-dev_aks-learningsteps-dev_westeurope`
(the *node resource group*), for the infrastructure it manages itself: the VM
scale set with the nodes, the Azure Load Balancer `kubernetes` and its public
IPs, the NSG of the nodes and the identities of kubelet and add-ons. It is
created and deleted together with the cluster and is not changed by hand.

**Boundary between Terraform and Kubernetes:** Terraform builds everything up
to and including the cluster. The Kubernetes manifests describe what runs
inside the cluster. The values the manifests need (client ID, tenant ID, vault
name) come from Terraform outputs.

### ConfigMap for the app's settings

`app-config` in `app.yaml` holds the non-secret settings the app reads as
environment variables (`envFrom`): `LOG_LEVEL` and `DB_POOL_MAX_SIZE`. Code
(image), configuration (ConfigMap) and secrets (Key Vault) are kept apart, so
the same image can run with different settings.

Pods read environment variables only at start, so a changed ConfigMap alone
would not reach running pods. `deploy.sh` therefore writes a hash of the
ConfigMap into an annotation of the pod template (`checksum/app-config`): a
changed ConfigMap changes the hash, which changes the pod template and makes
Kubernetes roll out new pods. Tested: setting `LOG_LEVEL` to `DEBUG` rolled
out new pods that logged at debug level, without a new image; applying again
without changes left everything `unchanged`.

The values are coupled across three places: at most 6 pods (HPA) × 5
connections (`DB_POOL_MAX_SIZE`) must stay below the roughly 40 connections
the database size allows (Terraform).

### Demo data after a rebuild

`scripts/seed_demo_data.py` fills an **empty** database with 5 entries picked
at random from a pool of 15. It works through the public API instead of the
database, because the database is only reachable inside the VNet while the
API is reachable from a CI runner too; the entries also pass the app's normal
validation. If entries exist, it does nothing, so it can run after every
deployment (`./k8s-manifests/deploy.sh --seed`, which also waits for the
ingress IP). Tested locally (first run seeded 5, second run skipped) and
against the cluster (skipped, 6 entries present).

### Database schema: a one-off Kubernetes Job

The database is only reachable from inside the VNet, so the schema cannot be
applied from a laptop. `k8s-manifests/db-init.yaml` holds the SQL in a
ConfigMap and runs `psql` once in a Job, under the app's ServiceAccount, so it
gets `DATABASE_URL` from Key Vault the same way the app does. All statements
use `IF NOT EXISTS`, so the job can be re-run safely. It lives in its own file
because it has a different lifecycle than the app and should not run on every
deployment (`./k8s-manifests/deploy.sh --db-init`).

### Pods spread across nodes

Two replicas on the same VM would not survive the loss of that VM. A
`topologySpreadConstraint` on `kubernetes.io/hostname` keeps the pods on
different nodes. All nodes are in zone 3 (the only zone with capacity for this
VM size), so a zone outage would still take down both.

### Horizontal Pod Autoscaler

The HPA keeps between 2 and 6 API pods and adds pods when the average CPU use
exceeds 70 % of the CPU request (100m). The Deployment no longer sets
`replicas`, otherwise every `kubectl apply` would reset the number the HPA
chose. It waits 5 minutes of low load before removing pods again.

**Load test** (4 minutes, 50 parallel requests to `/health` from outside,
`ab -r -k -t 240 -c 50`): about 340,000 requests at 1,400 requests/s, 0.2 %
connection resets under saturation. The HPA went from 2 to 3 pods at 86 %
CPU, then asked for 6 at over 400 %. **Only 3 could start**; 3 stayed
`Pending`:

```
0/2 nodes are available: 1 Insufficient cpu,
1 node(s) didn't match pod topology spread constraints.
```

The reason is capacity, not the HPA: the managed NGINX ingress controller
reserves 2 × 500m CPU and placed both of its pods on the same node, leaving
almost no room there. The strict spreading rule then forbids putting a third
pod on the other node. Pod scaling needs node capacity behind it. That is the
job of the **cluster autoscaler**, now enabled on the node pool (2 to 3 nodes):
when pods are `Pending` for lack of room, Azure adds a VM, and removes it after
about 10 idle minutes. Three nodes of 2 vCPUs plus one temporary upgrade node
stay within the subscription's quota of 10 vCPUs.

**Load test with the cluster autoscaler** (8 minutes, same parameters, about
480,000 requests):

| Time | Avg. CPU | HPA wants | Nodes | API pods |
|---|---|---|---|---|
| 0 s | 2 % | 2 | 2 | 2 running |
| 42 s | 213 % | 6 | 2 | 3 running, 3 `Pending` → `TriggeredScaleUp: vmss 2->3` |
| 83 s | | | 3rd node joins (`NotReady`) | |
| 104 s | 406 % | 6 | 3 `Ready` | |
| 188 s | 382 % | 6 | 3 | **5 running**, 1 `Pending` |

Both scaling levels worked together: the HPA added pods, the pending pods made
the cluster autoscaler add a VM, and the pods started on it about three
minutes after the load began. One pod stayed `Pending` with
`max node group size reached`: with 2/1/2 pods on three nodes, the strict
spreading rule only allows the sixth pod on the node that the NGINX controller
already fills. This is the configured upper limit, not an error.

**Spreading and rollouts: finding a combination that holds.** One node is
almost full, because the managed NGINX controller put both of its pods
(500m CPU each) there; it has room for exactly one API pod. Three attempts:

| Rollout strategy | Spreading rule | Result |
|---|---|---|
| default (new pod first) | `DoNotSchedule` (strict) | rollout **stuck**: the new pod needed the place the old pod held, and the old pod only goes once the new one is ready |
| default (new pod first) | `ScheduleAnyway` (soft) | never stuck, but both pods **ended up on the same node** because the full node was skipped |
| `maxSurge: 0, maxUnavailable: 1` (old pod first) | `DoNotSchedule` (strict) | **works**: the new pod waits a few seconds until the old one has freed its place; three rollouts in a row, each time one pod per node |

The cost of the final combination is that during a rollout one pod fewer is
serving (1 instead of 2).

**A spreading bug found on the way.** Before the test, both API pods were on
the same node although the spreading rule was in place. The rule is only
checked when a pod is scheduled, and during a rolling update it also counted
the old pods that were about to be removed. Adding
`matchLabelKeys: [pod-template-hash]` makes it count only pods of the same
version; after the next rollout the pods were on two different nodes again.

**Another fix in `deploy.sh`:** it used `v1` as the default image tag, so a
plain `./deploy.sh` after deploying `v2` would have rolled the app back. It
now keeps the tag that is currently running unless `IMAGE_TAG` is given.

### Ingress instead of a Service of type LoadBalancer per app

The brief lists "Service (LoadBalancer)". The Azure Load Balancer is used, but
in front of the ingress controller rather than in front of the app:

```
Internet → Azure Load Balancer → NGINX ingress controller → Service (ClusterIP) → pods
```

The managed NGINX controller is exposed through its own Service of type
`LoadBalancer`, for which AKS configures the Azure Load Balancer and a public
IP. This matches the architecture diagram of the brief and adds HTTP routing
and a single place to terminate HTTPS later, with one public IP for all apps
instead of one per app. Switching the app's Service to `type: LoadBalancer`
would be a one-line change.

The load balancer itself does not scale anything; it spreads traffic across
the nodes that exist. Scaling happens through the HorizontalPodAutoscaler
(pods) and optionally the cluster autoscaler (nodes).

---

## Changes to the application

The API code comes from the original LearningSteps repository. Two changes
were made:

- **`GET /health`** for the Kubernetes probes. It does not check the database
  on purpose: restarting pods would not fix a database outage.
- **`PATCH /entries/{id}` now updates only the fields that are sent.** The
  original endpoint validated the body with the create model, so all three
  fields were required and it acted like `PUT`. A new `EntryUpdate` model
  makes every field optional; the router passes on only the fields the client
  actually sent (`exclude_unset`, explicit `null`s are ignored), and the
  service merges them over the stored entry before saving. An empty body
  returns `400`. Tested locally against PostgreSQL in Docker: single field,
  two fields, empty body, `null`, too long (`422`), unknown ID (`404`) and a
  full body.
- **One database connection pool per pod instead of one per request.** The
  original code created a new asyncpg pool (10 connections by default) for
  every request and closed it afterwards. The pool is now created once at
  startup (FastAPI *lifespan*) with at most 5 connections
  (`DB_POOL_MAX_SIZE`). With up to 6 pods that is 30 connections, below the
  roughly 40 the smallest Azure PostgreSQL size leaves for applications (50
  minus 10 reserved). `min_size=0` lets the app start even while the database
  is unreachable, so the pods do not crash-loop when the database is still
  stopped in the morning.

  Load test `ab -c 20` against `GET /entries` from outside, same parameters
  before and after:

  | | Requests/s | Failed | Database connections (max) |
  |---|---|---|---|
  | Pool per request (`v2`) | 22 | **99 %** (`TooManyConnectionsError`) | 47 of 50 |
  | One pool per pod (`v3`) | 184 | 0 | about 8 |

  With HTTP keep-alive (`ab -k`) `v3` reached 586 requests/s; without it
  the load generator opens a new TCP connection per request, which limits the
  rate.

---

## CI/CD Pipeline

One workflow, `.github/workflows/pipeline.yml`, checks everything once and
deploys only if every check passed:

```
secrets ──┐
lint-test ├──> build-scan-push ──> deploy
iac-scan ─┘
```

| Job | What | Runs on |
|---|---|---|
| `secrets` | gitleaks over the whole Git history | PRs and `main` |
| `lint-test` | ruff; pytest (15 tests) against a PostgreSQL service container | PRs and `main` |
| `iac-scan` | `trivy config` on Terraform, Kubernetes manifests and Dockerfile; `trivy fs` on the Python dependencies | PRs and `main` |
| `build-scan-push` | build the image, `trivy image` **before** pushing, push to ACR tagged with the commit SHA | build and scan on PRs, push only on `main` |
| `deploy` | `deploy.sh`, wait for the rollout, schema job, demo data, smoke test from outside | `main` only |

Every scan fails the run on **High** or **Critical**. Pull requests never get
Azure access.

**Passwordless Azure sign-in (OIDC).** GitHub issues a signed token per run;
Entra ID exchanges it for the pipeline identity only if it was issued for this
repository and the `main` branch (federated credential). No client secret is
stored in GitHub; the three values the workflow needs (client, tenant and
subscription ID) are not sensitive and are stored as repository *variables*.

**The pipeline identity survives a rebuild.** It lives in a separate Terraform
configuration, `infra-bootstrap/` (own state, own resource group, never
destroyed); otherwise every `terraform destroy`/`apply` would give it a new
client ID and the GitHub settings would have to change each time. Its
permissions are granted by the main stack (`infra-terraform/github.tf`),
because they point to resources that are rebuilt.

**Least privilege for the pipeline:** `AcrPush` on the registry, *Azure
Kubernetes Service Cluster User Role* on the cluster, `Reader` on the resource
group (to look up names instead of reading Terraform state). No Owner or
Contributor role, no access to the Terraform state, and Terraform is **not**
applied by the pipeline, only scanned: applying it would require the most
powerful identity in the project (it assigns roles) and access to the state,
which contains the database password. Infrastructure changes therefore go
through the pipeline as a gate (the scan must pass) and are then applied by
hand.

A manual approval step in the pipeline would not remove that privilege: it
controls *when* the job runs, not *what* its identity may do. The production
pattern would be `terraform plan` in the pull request and `apply` after
approval, with remote state in Azure Storage, the federated credential bound
to a protected GitHub *environment* instead of the branch, and the right to
assign roles constrained by an Azure RBAC condition to the few roles this
stack needs. For this project the simpler manual apply was chosen
deliberately.

*Limitation:* the cluster uses local accounts, so the credentials from
`az aks get-credentials` give full rights inside the cluster. Entra ID
integration with Azure RBAC for Kubernetes would allow limiting the pipeline
to the `learningsteps` namespace.

**Actions pinned to commit SHAs** (`actions/checkout@3d3c42e… # v7.0.1`). A
tag can be moved to other code; a commit SHA cannot. A compromised release of
an action therefore does not run here unnoticed.

**Values without Terraform state.** `deploy.sh` reads names and IDs from
`terraform output` on a laptop and directly from Azure in the pipeline
(`VALUES_FROM=azure`). Both paths were compared and produce identical
manifests.

---

## Security Decisions

### The database is private by design

The Flexible Server is created with **private access** in its own delegated
subnet and `public_network_access_enabled = false`. It has no public endpoint,
so no firewall rule for the cluster's outbound IP is needed. This mode cannot
be changed after creation, so it was decided before the first deployment.

### No human ever sees the database password

Terraform generates the password (`random_password`), builds the complete
`DATABASE_URL` and writes it straight into Key Vault. The password is not in
any file in the repository, not in the image and not in the manifests.
Compared to iteration 1 (password generated with `openssl rand` and stored by
hand), there is no manual step left in which it could leak.

### Passwordless access from the pod to Key Vault (Workload Identity)

A pod has no VM of its own, so the IMDS approach from iteration 1 does not
apply. Instead:

1. AKS issues a signed token to the pod for its **ServiceAccount**.
2. Microsoft Entra ID trusts this token through a **federated identity
   credential**, but only if it was issued for exactly
   `system:serviceaccount:learningsteps:learningsteps-app`.
3. Entra ID returns a short-lived token for the app identity.
4. With it, the CSI driver reads the secret and hands it to the container as
   the environment variable `DATABASE_URL`.

No client secret or password is stored anywhere to make this work. The app
code is unchanged; it still just reads `DATABASE_URL`.

### Trade-off: a second copy of the secret inside the cluster

The CSI driver can hand the secret to the container as a file only, or
additionally copy it into a Kubernetes Secret that becomes the environment
variable `DATABASE_URL`. The second way was chosen so the application code
stays unchanged. The cost is a copy of the value in the cluster: Kubernetes
Secrets are only base64-encoded, so anyone allowed to read Secrets in the
`learningsteps` namespace can read the connection string. Only cluster admins
have that right here. Reading the mounted file directly in the app would
remove this copy.

### Hardened containers

- The image runs as an unprivileged user (UID `10001`) instead of root.
- The Deployment enforces this with `runAsNonRoot: true`, so Kubernetes refuses
  to start the container if the image ever runs as root again.
- Read-only root filesystem, all Linux capabilities dropped, no privilege
  escalation, and the runtime's default seccomp profile (blocks rarely needed
  system calls).
- CPU and memory limits, so one misbehaving pod cannot starve the node.

Tested locally with the same restrictions (`docker run --read-only
--cap-drop ALL --security-opt no-new-privileges`) before deploying.

### Least privilege

- The app identity has **Key Vault Secrets User** (read-only) on the single
  secret `database-url`, not on the whole vault. Secrets added later are not
  readable by the app.
- Terraform's own identity gets **Key Vault Secrets Officer** only on this
  vault, to write the secret.
- The cluster nodes get **AcrPull** only (no push) on the registry.
- The cluster identity gets **Network Contributor** only on its own subnet.
- *(planned with the manifests)* The app runs under its own ServiceAccount
  instead of `default`, with no Kubernetes RBAC roles, and
  `automountServiceAccountToken: false` on both ServiceAccounts in the
  namespace. The app never talks to the Kubernetes API, so a compromised
  container should not find an API token to explore the cluster with.

### No shared credentials for the registry

The ACR admin user is disabled (`admin_enabled = false`). Pulls happen through
the cluster's managed identity, so there is no registry password to store in
the cluster.

### Key Vault uses RBAC instead of access policies

Access is managed with Azure role assignments, the same model as every other
resource, so permissions are visible and auditable in one place.

### Cluster: Kubernetes RBAC and a network policy engine

- `role_based_access_control_enabled = true`: on by default in AKS, stated
  explicitly so it cannot be turned off by accident and scanners can verify it.
- **Cilium** as data plane and network policy engine. Without a policy engine
  in the cluster, Kubernetes `NetworkPolicy` objects are accepted but silently
  have no effect. Cilium is Microsoft's recommended data plane for new AKS
  clusters. The policies themselves are described in the next section.

Both settings were added after `trivy config` reported them as High.

### NetworkPolicies: default deny inside the cluster

Without policies every pod may talk to every other pod and to the internet.
The namespace `learningsteps` now starts from **deny all** in both directions,
and three policies in `app.yaml` allow only what is needed:

| Policy | Allows |
|---|---|
| `default-deny-all` | nothing (baseline for all pods in the namespace) |
| `api-allow-from-ingress` | incoming traffic to the API pods on port 8000, only from the NGINX ingress controller |
| `allow-dns-and-postgres` | outgoing traffic from the API and the schema job, only to CoreDNS (53) and the database subnet (5432) |

This blocks in particular the node's **IMDS endpoint** (`169.254.169.254`).
Before the policies, a pod could reach it and could have requested a token of
the node's (kubelet) identity. It also blocks the internet, which the app never
needs; a compromised container can no longer download tools or send data out.

Tested before and after (see Verification). One limitation: the database
subnet `10.10.1.0/24` is written into the policy by hand and has to match
`postgres_subnet_prefix` in Terraform.

### Tags as asset inventory

Every resource that supports tags carries the same set, defined once as
`local.common_tags` in `main.tf`:

| Tag | Value | Purpose |
|---|---|---|
| `project` | `learningsteps` | what the resource belongs to |
| `environment` | `dev` | stage; basis for rules such as "never auto-stop prod" |
| `owner` | `robin-reinhardt` | who is accountable |
| `managed-by` | `terraform` | do not change by hand, or it will drift |
| `repository` | link to this repo | where the code for the resource lives |
| `data-classification` | `internal` | how sensitive the data is |
| `cost-center` | `cybersteps-modul-3` | cost allocation in Azure Cost Management |

`owner` and `data-classification` map directly to ISO/IEC 27001:2022
Annex A 5.9 (inventory of assets with an owner) and A 5.12 (classification of
information): every new resource is in the inventory with an owner and a
classification from the moment it is created. Tags contain no secrets, since
anyone who can read a resource can read its tags.

### Scanning and accepted risks

- **Secrets:** `gitleaks` as a pre-commit hook and in the pipeline (whole
  history). Before the first commit of this iteration, gitleaks checked
  exactly the 56 files that would be committed: no findings.
- **Image:** 0 fixable High/Critical vulnerabilities. 44 more are in packages
  of the Debian base image without an available fix; `--ignore-unfixed` keeps
  those from failing the pipeline, since nothing can be done about them.
- **Dependencies:** versions in `requirements.txt` are pinned, which is also
  what lets Trivy match them against known vulnerabilities: 0 findings.
- **Configuration:** `trivy config` reported four High/Critical findings. Two
  were fixed (explicit RBAC, network policy engine). Two are **accepted risks**
  in `.trivyignore.yaml`, each with a statement (why, which mitigations, what
  the proper fix would be) and an **expiry date** (2026-12-31); after that
  date the findings count again and the pipeline fails, forcing a review:

  | Finding | Why not fixed |
  |---|---|
  | AKS API server not limited to authorized IP ranges | GitHub-hosted runners change IP on every run; an allow list would lock out the pipeline. Proper fix: private cluster with a self-hosted runner. |
  | Key Vault without network ACL | Terraform writes the secret from a laptop with a changing IP. Proper fix: private endpoint, Terraform running inside the network. |

- **Error messages:** the create endpoint returned the text of internal
  exceptions (for example database errors) to the client (CWE-209). Details
  now go to the log only.

### Known risk: the Terraform state contains secrets

The generated password (and therefore the `DATABASE_URL`) is stored in plain
text in `terraform.tfstate`. The state is excluded from Git, but for now it
lives locally. The state has to be treated like a secret. Moving it to a
remote backend in Azure Storage (encrypted, access controlled by RBAC) is
planned, at the latest when Terraform runs in a pipeline.

---

## Challenges

- **PostgreSQL Flexible Server blocked in `germanywestcentral`.** The
  subscription returned *"Provisioning is restricted in this region"* for the
  service, independent of the size. AKS would have worked there. Because
  cluster and database are connected through a private VNet, they have to be
  in the same region, so everything moved to **`westeurope`** after checking
  that every resource type is available there.

- **VM size restricted per availability zone.** `Standard_D2s_v6` is only
  available in **zone 3** in `westeurope` for this subscription (zones 1 and 2
  restricted). Both nodes and the database are pinned to zone 3. The nodes
  therefore do not spread across zones, which is acceptable for this project.

- **Address overlap with AKS.** AKS uses `10.0.0.0/16` internally for service
  addresses by default. The VNet was therefore placed at `10.10.0.0/16`,
  otherwise cluster creation would fail.

- **No health endpoint.** Kubernetes needs a URL to check whether a pod is
  alive and ready. The app had none, so `GET /health` was added. It
  deliberately does not check the database: if the database is down,
  restarting the pods would not fix it, it would only add restarts on top.

- **Hidden dependencies in Terraform.** Terraform orders resources by their
  references. Three dependencies have no reference and needed an explicit
  `depends_on`: the subnet role before the cluster, the DNS zone link before
  the database, and the Key Vault role before writing the secret.

- **Role assignments take time to apply.** Azure can take a few minutes to
  apply a new role assignment. On the first `terraform apply`, writing the
  secret may fail with `403`. Running `terraform apply` again resolves it.

- **Cluster and database stopped every night by the course tenant.** The
  first `kubectl apply` failed with `no such host` for the API server. The
  cause was not DNS: an automation account of the course administrators
  (`admin-automation-account`) stops the AKS cluster and the PostgreSQL server
  in the evening to save cost. A stopped cluster has no API server address.
  `deploy.sh` now checks the power state first and prints the `az aks start`
  command instead of the misleading DNS error.

- **`terraform destroy` fails on a stopped database.** Before deleting,
  Terraform reads the current state of every resource. A stopped PostgreSQL
  server rejects that (`ServerStoppedError`), so the destroy stops before
  deleting anything. The server has to be started first.

- **Drift from outside Terraform.** After the first apply, every resource
  carried a `created-on` tag that Terraform never set, most likely added by a
  policy or automation of the course tenant. Terraform then wants to remove it
  on every run. Drift like this is exactly what `terraform plan` makes visible.
  Setting the tag in code is not an option (its value is the creation time,
  unknown in advance). Instead Terraform ignores exactly this one tag with
  `lifecycle { ignore_changes = [tags["created-on"]] }`. The AKS node pool's
  `upgrade_settings`, which Azure fills with default values, are now written
  out explicitly for the same reason.
  After the first rebuild, `terraform plan` showed one more drift: Azure had
  added the service endpoint `Microsoft.Storage` to the PostgreSQL subnet (the
  server uses it for backups). It is now declared in `network.tf` instead of
  being removed. Since then `terraform plan` right after `apply` reports
  *No changes*.

- **vCPU quota.** VMs from iteration 1 still counted against the vCPU quota
  in `germanywestcentral`. This no longer matters after the move to
  `westeurope`, but they should be deallocated or deleted to save cost.

---

## Next Steps

- Set up the pipeline (bootstrap, roles, GitHub variables) and run it
- Prove the security gates: an intentionally vulnerable package and an
  insecure Terraform rule must fail the pipeline (success criterion)
- Resolve or justify the two remaining Critical findings of `trivy config`
  (API server authorized IP ranges, Key Vault network ACL) together with the
  pipeline, since the pipeline must fail on High/Critical
- *(optional)* Monitoring, decided: Prometheus and Grafana **inside the
  cluster** (as the brief asks), `prometheus_client` in the app serving
  `/metrics` on a separate port that the ingress does not expose, dashboard for
  request volume, latency and database health
- Initialize the database schema from inside the cluster (the database is not
  reachable from outside)
- Remote Terraform state in Azure Storage (needed only if Terraform should
  ever run in the pipeline)
- **App:** create one connection pool at startup instead of one per request,
  otherwise several pods quickly exhaust the database's connection limit

### Hardening (out of scope for now)

- HTTPS on the ingress (DNS zone + certificate). Until then the API is served
  over plain HTTP on the ingress IP, like in iteration 1.
- Network Security Groups between the subnets
- `prevent_destroy` on the database once it holds real data
- Private endpoint for Key Vault
- Purge protection on Key Vault (disabled so the environment can be destroyed
  and rebuilt quickly)

---

## Repository Structure

```
.
├── app/                      FastAPI application
├── Dockerfile                Container image of the API (non-root)
├── db/schema.sql             Database schema (schema job and tests)
├── tests/                    pytest suite (API, validation, seed script)
├── scripts/
│   └── seed_demo_data.py     Adds 5 demo entries if the database is empty
├── infra-bootstrap/          Pipeline identity with OIDC trust (never destroyed)
├── infra-terraform/          Azure infrastructure (one Terraform state)
│   ├── providers.tf          Provider versions and configuration
│   ├── variables.tf          Inputs with defaults
│   ├── main.tf               Resource group, common tags
│   ├── network.tf            VNet, subnets, private DNS
│   ├── aks.tf                Cluster, identity, add-ons, autoscaler
│   ├── postgres.tf           Flexible Server and database
│   ├── keyvault.tf           Vault, secret, app identity, federation
│   ├── acr.tf                Container registry and pull permission
│   ├── github.tf             Permissions of the pipeline identity
│   └── outputs.tf            Values for the Kubernetes manifests
├── k8s-manifests/
│   ├── app.yaml              Namespace, ServiceAccounts, SecretProviderClass,
│   │                         ConfigMap, Deployment, HPA, Service, Ingress,
│   │                         NetworkPolicies (with placeholders)
│   ├── db-init.yaml          One-off Job that creates the database schema
│   └── deploy.sh             Fills the placeholders and applies to the cluster
├── .github/workflows/
│   └── pipeline.yml          Build - Scan - Deploy
├── .trivyignore.yaml         Accepted risks with reason and expiry date
├── ruff.toml                 Lint rules
└── requirements-dev.txt      Test and lint tools (pinned)
```

---

## Deployment (infrastructure)

Prerequisites: an Azure subscription where you can assign roles (Owner or
User Access Administrator), the Azure CLI and Terraform ≥ 1.6.

0. **Once:** create the pipeline identity in `infra-bootstrap/`
   (`terraform init && terraform apply`), and store its outputs
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as repository
   variables in GitHub (Settings → Secrets and variables → Actions →
   Variables). The main stack below reads this identity, so it has to exist
   first.
1. Log in: `az login`
2. Create `infra-terraform/terraform.tfvars` (git-ignored):
   ```hcl
   subscription_id = "<your-subscription-id>"
   ```
3. In `infra-terraform/`:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```
4. If the secret fails with `403` on the first run, run `terraform apply` again.
5. Show the values for the next steps and connect `kubectl` to the cluster:
   ```bash
   terraform output
   az aks get-credentials \
     --resource-group "$(terraform output -raw resource_group_name)" \
     --name "$(terraform output -raw aks_cluster_name)"
   ```

| Output | Used for |
|---|---|
| `resource_group_name`, `aks_cluster_name` | `az aks get-credentials` |
| `acr_login_server` | image name for `docker push` and the Deployment |
| `app_identity_client_id` | ServiceAccount annotation, SecretProviderClass |
| `tenant_id`, `key_vault_name` | SecretProviderClass |
| `k8s_namespace`, `k8s_service_account` | must match the manifests exactly |

None of the outputs is a secret. The `DATABASE_URL` is deliberately not an
output; it only exists in Key Vault (and in the state).

Tear down everything with `terraform destroy`. This also deletes the database
and its data.

---

## Deployment (workload)

Some Terraform outputs change on every rebuild: the app identity gets a new
client ID from Azure, and Key Vault and registry get a new random name suffix.
The manifests therefore contain placeholders such as `${APP_IDENTITY_CLIENT_ID}`
instead of fixed values.

`k8s-manifests/deploy.sh` reads the current values with `terraform output`,
fills them in with `envsubst` and pipes the result straight into
`kubectl apply`. The filled-in manifest is never written to disk, so it cannot
go stale or end up in Git by accident.

```bash
./k8s-manifests/deploy.sh --dry-run   # print the filled-in manifest only
./k8s-manifests/deploy.sh             # connect kubectl to the cluster and apply
./k8s-manifests/deploy.sh --db-init   # once after every rebuild: create the schema
./k8s-manifests/deploy.sh --seed      # demo entries, only if the database is empty
```

After `terraform apply` the database is empty, so the schema job has to run
once after the app has been deployed (it needs the ServiceAccount and the
SecretProviderClass from `app.yaml`).

With the pipeline set up, a push to `main` (or a manual run of the workflow
after a rebuild) does all of this: build, scan, push, deploy, schema job and
demo data.

---

## Verification

First deployment on 2026-09-27, checked from the cluster and from the internet:

| Check | Command | Result |
|---|---|---|
| Both pods running and ready | `kubectl get pods -n learningsteps` | `2/2 Running`, 0 restarts |
| Secret synced from Key Vault | `kubectl get secret db-credentials -n learningsteps` | exists with key `DATABASE_URL` |
| Workload identity injected | `env` in the pod | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` set |
| Runs as non-root | `id` in the pod | `uid=10001(appuser)` |
| No Kubernetes API token in the pod | `ls /var/run/secrets/kubernetes.io/serviceaccount` | does not exist |
| `default` ServiceAccount has no real rights | `kubectl auth can-i --list --as=system:serviceaccount:learningsteps:default` | only discovery endpoints (`/api`, `/healthz`, ...) |
| App ServiceAccount cannot read Secrets | `kubectl auth can-i get secrets --as=...:learningsteps-app` | `no` |
| Reachable from the internet | `curl http://<ingress-ip>/health`, `/docs` | `200` |
| Database connection before schema init | `curl http://<ingress-ip>/entries` | `500`: `relation "entries" does not exist` |
| Schema initialized | `./k8s-manifests/deploy.sh --db-init` | table `entries` with 3 indexes, printed in the job log |
| Pods on different nodes | `kubectl get pods -o wide` | one pod each on `vmss000000` and `vmss000001` |
| Pod reaches IMDS / internet, before NetworkPolicies | Python socket test in the pod | IMDS answered (`vmSize=Standard_D2s_v6`), `1.1.1.1:443` open |
| Same test after NetworkPolicies | same | IMDS and internet **blocked**, DNS and PostgreSQL still work |
| Pod in another namespace calls the API Service | `kubectl run ... wget http://learningsteps-api.learningsteps.svc/health` | timed out (blocked) |
| API from the internet after NetworkPolicies | `curl /health`, CRUD | `200`, probes keep pods ready |
| Schema job after NetworkPolicies | `deploy.sh --db-init` | completes; second run only reports `already exists, skipping` |

The database line before the schema init was the expected result: the app
reached the private database over TLS with the password from Key Vault, only
the table was missing.

### CRUD walkthrough (after schema init)

| Operation | Request | Result |
|---|---|---|
| Create | `POST /entries` | `200`, entry with generated UUID |
| Create, missing fields | `POST /entries` with only `work` | `422` |
| Read all | `GET /entries` | `200`, list with count |
| Read one | `GET /entries/{id}` | `200` |
| Read unknown | `GET /entries/does-not-exist` | `404` |
| Update | `PATCH /entries/{id}` | `200` (at that time the original app required all three fields; fixed since, see *Changes to the application*) |
| Delete | `DELETE /entries/{id}` | `200 Entry deleted` |

The readiness probe failed once per pod right after start (`connection
refused`) because uvicorn was not listening yet. This is expected; the Service
only sends traffic once the probe succeeds.
