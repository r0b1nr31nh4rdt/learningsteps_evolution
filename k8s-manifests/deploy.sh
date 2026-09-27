#!/usr/bin/env bash
# Fills the placeholders in app.yaml with the current values of the Azure
# resources and applies the result to the cluster. The filled-in manifest is
# never written to disk.
#
# Usage (from anywhere):
#   ./k8s-manifests/deploy.sh             connect to the cluster and apply app.yaml
#   ./k8s-manifests/deploy.sh --dry-run   only print the filled-in manifest
#   ./k8s-manifests/deploy.sh --db-init   run the one-off schema job (db-init.yaml)
#   ./k8s-manifests/deploy.sh --seed      add 5 demo entries if the database is empty
#
# Where the values come from:
#   - with Terraform state (your laptop): terraform output
#   - without it (GitHub pipeline): read directly from Azure (needs Reader on
#     the resource group, see infra-terraform/github.tf)
#   VALUES_FROM=azure forces the second way, e.g. to test it on a laptop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../infra-terraform"

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null
}

if [[ "${VALUES_FROM:-}" != "azure" ]] && command -v terraform >/dev/null \
   && tf_output resource_group_name >/dev/null; then
  RESOURCE_GROUP="$(tf_output resource_group_name)"
  CLUSTER_NAME="$(tf_output aks_cluster_name)"
  APP_IDENTITY_CLIENT_ID="$(tf_output app_identity_client_id)"
  KEY_VAULT_NAME="$(tf_output key_vault_name)"
  TENANT_ID="$(tf_output tenant_id)"
  ACR_LOGIN_SERVER="$(tf_output acr_login_server)"
else
  # Names with a random suffix are found by type; there is one of each.
  RESOURCE_GROUP="${RESOURCE_GROUP:-rg-learningsteps-dev}"
  CLUSTER_NAME="$(az aks list -g "$RESOURCE_GROUP" --query '[0].name' -o tsv)"
  APP_IDENTITY_CLIENT_ID="$(az identity list -g "$RESOURCE_GROUP" \
    --query "[?starts_with(name, 'id-app-')].clientId | [0]" -o tsv)"
  KEY_VAULT_NAME="$(az keyvault list -g "$RESOURCE_GROUP" --query '[0].name' -o tsv)"
  TENANT_ID="$(az account show --query tenantId -o tsv)"
  ACR_LOGIN_SERVER="$(az acr list -g "$RESOURCE_GROUP" --query '[0].loginServer' -o tsv)"
fi
export APP_IDENTITY_CLIENT_ID KEY_VAULT_NAME TENANT_ID ACR_LOGIN_SERVER

for value in RESOURCE_GROUP CLUSTER_NAME APP_IDENTITY_CLIENT_ID KEY_VAULT_NAME TENANT_ID ACR_LOGIN_SERVER; do
  [[ -n "${!value}" ]] || { echo "Could not determine $value." >&2; exit 1; }
done

# Image version to deploy, e.g. IMAGE_TAG=v3 ./deploy.sh. Without it, the
# version currently running in the cluster is kept (v1 on a fresh cluster),
# so a plain ./deploy.sh never rolls the app back by accident.
if [[ -z "${IMAGE_TAG:-}" ]]; then
  CURRENT_IMAGE="$(kubectl get deployment learningsteps-api -n learningsteps \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  IMAGE_TAG="${CURRENT_IMAGE##*:}"
  IMAGE_TAG="${IMAGE_TAG:-v1}"
fi
export IMAGE_TAG

# Hash of the app-config ConfigMap (see the annotation in the Deployment).
export CONFIG_HASH="$(python3 - "$SCRIPT_DIR/app.yaml" <<'PY'
import hashlib, sys
docs = open(sys.argv[1]).read().split("\n---\n")
config = [d for d in docs if "kind: ConfigMap" in d and "name: app-config" in d]
print(hashlib.sha256(config[0].encode()).hexdigest()[:16])
PY
)"

# Only these variables are replaced. Any other "$" in the YAML stays as it is.
PLACEHOLDERS='${APP_IDENTITY_CLIENT_ID} ${KEY_VAULT_NAME} ${TENANT_ID} ${ACR_LOGIN_SERVER} ${IMAGE_TAG} ${CONFIG_HASH}'

if [[ "${1:-}" == "--dry-run" ]]; then
  envsubst "$PLACEHOLDERS" < "$SCRIPT_DIR/app.yaml"
  exit 0
fi

# A stopped cluster has no API server address, and kubectl only reports
# "no such host". Check first and say what to do.
POWER_STATE="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query powerState.code -o tsv)"
if [[ "$POWER_STATE" != "Running" ]]; then
  echo "Cluster $CLUSTER_NAME is $POWER_STATE. Start it first (takes a few minutes):" >&2
  echo "  az aks start -g $RESOURCE_GROUP -n $CLUSTER_NAME" >&2
  exit 1
fi

# Point kubectl at this cluster (safe to repeat, overwrites the old entry).
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

if [[ "${1:-}" == "--db-init" ]]; then
  # The SQL lives in db/schema.sql (also used by the tests); the job reads it
  # from this ConfigMap.
  kubectl create configmap db-schema -n learningsteps \
    --from-file=schema.sql="$SCRIPT_DIR/../db/schema.sql" \
    --dry-run=client -o yaml | kubectl apply -f -
  # A Job cannot be changed once created, so remove a previous run first.
  kubectl delete job db-init -n learningsteps --ignore-not-found
  kubectl apply -f "$SCRIPT_DIR/db-init.yaml"
  echo "Waiting for the job to finish ..."
  if ! kubectl wait --for=condition=complete job/db-init -n learningsteps --timeout=180s; then
    echo "Job did not complete. Its log:" >&2
    kubectl logs job/db-init -n learningsteps >&2 || true
    exit 1
  fi
  kubectl logs job/db-init -n learningsteps
  exit 0
fi

if [[ "${1:-}" == "--seed" ]]; then
  # The public IP of the ingress can take a moment to appear after a rebuild.
  INGRESS_IP=""
  for _ in $(seq 36); do
    INGRESS_IP="$(kubectl get ingress learningsteps-api -n learningsteps \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$INGRESS_IP" ]] && break
    echo "Waiting for the ingress IP ..."
    sleep 5
  done
  [[ -n "$INGRESS_IP" ]] || { echo "Ingress has no IP yet." >&2; exit 1; }
  python3 "$SCRIPT_DIR/../scripts/seed_demo_data.py" "http://$INGRESS_IP"
  exit 0
fi

envsubst "$PLACEHOLDERS" < "$SCRIPT_DIR/app.yaml" | kubectl apply -f -
