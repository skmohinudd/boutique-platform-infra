#!/usr/bin/env bash

# Boutique Helm ownership repair and validation.
# Run this script from the boutique-platform-infra/helm directory.
# It preserves the real release names already used by the cluster,
# repairs only safe same-service ownership mismatches, validates
# NetworkPolicy presence, and never deletes Kubernetes resources.

set -uo pipefail

NAMESPACE="boutique"
EXPECTED_CLUSTER="boutique-dev-eks"

# chart|canonical-release|accepted-old-release-aliases
SERVICE_MAP=(
  "productcatalogservice|productcatalog-dev|productcatalog-dev,productcatalogservice"
  "inventoryservice|inventoryservice|inventoryservice,inventoryservice-dev"
  "userservice|user-dev|user-dev,userservice,userservice-dev"
  "cartservice|cartservice-dev|cartservice-dev,cartservice"
  "orderservice|orderservice-dev|orderservice-dev,orderservice"
  "paymentservice|paymentservice-dev|paymentservice-dev,paymentservice"
  "checkoutservice|checkoutservice-dev|checkoutservice-dev,checkoutservice"
  "shippingservice|shippingservice-dev|shippingservice-dev,shippingservice"
  "notificationservice|notificationservice-dev|notificationservice-dev,notificationservice"
  "recommendationservice|recommendationservice-dev|recommendationservice-dev,recommendationservice"
)

ADOPTED=0
ALREADY_OK=0
NEW_RESOURCES=0
CONFLICTS=0
WARNINGS=0
CHART_ERRORS=0

banner() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

contains_alias() {
  local value="$1"
  local aliases="$2"
  local item

  IFS=',' read -r -a _aliases <<< "$aliases"

  for item in "${_aliases[@]}"; do
    [[ "$value" == "$item" ]] && return 0
  done

  return 1
}

get_metadata() {
  local resource="$1"
  local jsonpath="$2"

  kubectl get "$resource" \
    -n "$NAMESPACE" \
    -o "jsonpath=${jsonpath}" \
    2>/dev/null || true
}

discover_resources() {
  local release="$1"
  local chart="$2"

  helm template "$release" "$chart" \
    --namespace "$NAMESPACE" 2>/dev/null \
    | kubectl apply \
        --dry-run=client \
        -f - \
        -o name 2>/dev/null \
    | sort -u
}

validate_networkpolicy() {
  local release="$1"
  local chart="$2"
  local rendered

  rendered="$(helm template "$release" "$chart" --namespace "$NAMESPACE" 2>/dev/null || true)"

  if ! grep -q '^kind: NetworkPolicy$' <<< "$rendered"; then
    echo "WARNING: No NetworkPolicy rendered by $chart"
    WARNINGS=$((WARNINGS + 1))
    return
  fi

  if ! grep -q 'Ingress' <<< "$rendered"; then
    echo "WARNING: NetworkPolicy does not declare Ingress policy type"
    WARNINGS=$((WARNINGS + 1))
  fi

  if ! grep -q 'Egress' <<< "$rendered"; then
    echo "WARNING: NetworkPolicy does not declare Egress policy type"
    WARNINGS=$((WARNINGS + 1))
  fi

  echo "NetworkPolicy validation: OK"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

banner "Boutique Helm Ownership Repair"

echo "Helm directory : $SCRIPT_DIR"
echo "Namespace      : $NAMESPACE"
echo "Expected EKS   : $EXPECTED_CLUSTER"

# Pre-flight checks. The script reports failures but does not close Git Bash.
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is not installed."
  echo "Script stopped safely. Git Bash remains open."
  return 0 2>/dev/null || true
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm is not installed."
  echo "Script stopped safely. Git Bash remains open."
  return 0 2>/dev/null || true
fi

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"

if [[ "$CURRENT_CONTEXT" != *"$EXPECTED_CLUSTER"* ]]; then
  echo "ERROR: Wrong Kubernetes context."
  echo "Current : ${CURRENT_CONTEXT:-none}"
  echo "Expected: $EXPECTED_CLUSTER"
  echo "Script stopped safely. Git Bash remains open."
  return 0 2>/dev/null || true
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Namespace '$NAMESPACE' does not exist."
  echo "Script stopped safely. Git Bash remains open."
  return 0 2>/dev/null || true
fi

for entry in "${SERVICE_MAP[@]}"; do
  IFS='|' read -r CHART_NAME RELEASE ALIASES <<< "$entry"
  CHART="${SCRIPT_DIR}/${CHART_NAME}"

  banner "$CHART_NAME -> $RELEASE"

  if [[ ! -f "${CHART}/Chart.yaml" ]]; then
    echo "SKIP: Chart not found: $CHART"
    WARNINGS=$((WARNINGS + 1))
    continue
  fi

  if ! helm lint "$CHART" >/dev/null 2>&1; then
    echo "ERROR: helm lint failed for $CHART_NAME"
    CHART_ERRORS=$((CHART_ERRORS + 1))
    continue
  fi

  echo "Helm lint: OK"
  validate_networkpolicy "$RELEASE" "$CHART"

  RESOURCES_OUTPUT="$(discover_resources "$RELEASE" "$CHART")"

  if [[ -z "$RESOURCES_OUTPUT" ]]; then
    echo "ERROR: No Kubernetes resources could be rendered."
    CHART_ERRORS=$((CHART_ERRORS + 1))
    continue
  fi

  mapfile -t RESOURCES <<< "$RESOURCES_OUTPUT"

  for RESOURCE in "${RESOURCES[@]}"; do
    # Do not touch cluster-scoped resources in a per-service migration.
    case "$RESOURCE" in
      namespace/*|\
      customresourcedefinition.*/*|\
      clusterrole.*/*|\
      clusterrolebinding.*/*)
        echo "SKIP cluster-scoped: $RESOURCE"
        continue
        ;;
    esac

    if ! kubectl get "$RESOURCE" -n "$NAMESPACE" >/dev/null 2>&1; then
      echo "NEW : $RESOURCE"
      NEW_RESOURCES=$((NEW_RESOURCES + 1))
      continue
    fi

    MANAGED_BY="$(get_metadata "$RESOURCE" '{.metadata.labels.app\.kubernetes\.io/managed-by}')"
    CURRENT_RELEASE="$(get_metadata "$RESOURCE" '{.metadata.annotations.meta\.helm\.sh/release-name}')"
    CURRENT_NAMESPACE="$(get_metadata "$RESOURCE" '{.metadata.annotations.meta\.helm\.sh/release-namespace}')"

    # Correct ownership: leave the resource untouched.
    if [[ "$MANAGED_BY" == "Helm" &&
          "$CURRENT_RELEASE" == "$RELEASE" &&
          "$CURRENT_NAMESPACE" == "$NAMESPACE" ]]; then
      echo "OK  : $RESOURCE"
      ALREADY_OK=$((ALREADY_OK + 1))
      continue
    fi

    # Never steal a resource owned by an unrelated Helm release.
    if [[ -n "$CURRENT_RELEASE" ]] && ! contains_alias "$CURRENT_RELEASE" "$ALIASES"; then
      echo "CONFLICT: $RESOURCE"
      echo "  Current release : $CURRENT_RELEASE"
      echo "  Expected release: $RELEASE"
      echo "  Action          : NOT MODIFIED"
      CONFLICTS=$((CONFLICTS + 1))
      continue
    fi

    # Safe repair: resource is unmanaged or belongs to an accepted old alias
    # of the same service.
    echo "FIX : $RESOURCE"
    echo "  old release: ${CURRENT_RELEASE:-unmanaged}"
    echo "  new release: $RELEASE"

    if ! kubectl label "$RESOURCE" \
      -n "$NAMESPACE" \
      app.kubernetes.io/managed-by=Helm \
      --overwrite >/dev/null 2>&1; then
      echo "ERROR: Could not set Helm label on $RESOURCE"
      CONFLICTS=$((CONFLICTS + 1))
      continue
    fi

    if ! kubectl annotate "$RESOURCE" \
      -n "$NAMESPACE" \
      meta.helm.sh/release-name="$RELEASE" \
      meta.helm.sh/release-namespace="$NAMESPACE" \
      --overwrite >/dev/null 2>&1; then
      echo "ERROR: Could not set Helm annotations on $RESOURCE"
      CONFLICTS=$((CONFLICTS + 1))
      continue
    fi

    # Verify immediately after the repair.
    VERIFY_MANAGED="$(get_metadata "$RESOURCE" '{.metadata.labels.app\.kubernetes\.io/managed-by}')"
    VERIFY_RELEASE="$(get_metadata "$RESOURCE" '{.metadata.annotations.meta\.helm\.sh/release-name}')"
    VERIFY_NAMESPACE="$(get_metadata "$RESOURCE" '{.metadata.annotations.meta\.helm\.sh/release-namespace}')"

    if [[ "$VERIFY_MANAGED" == "Helm" &&
          "$VERIFY_RELEASE" == "$RELEASE" &&
          "$VERIFY_NAMESPACE" == "$NAMESPACE" ]]; then
      echo "DONE: $RESOURCE"
      ADOPTED=$((ADOPTED + 1))
    else
      echo "ERROR: Verification failed for $RESOURCE"
      CONFLICTS=$((CONFLICTS + 1))
    fi
  done

  # Show whether the canonical release already has Helm release state.
  if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    STATUS="$(helm status "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null \
      | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    echo "Helm release state: ${STATUS:-present}"
  else
    echo "Helm release state: not installed yet"
  fi
done

banner "Final Verification"

for entry in "${SERVICE_MAP[@]}"; do
  IFS='|' read -r CHART_NAME RELEASE ALIASES <<< "$entry"
  CHART="${SCRIPT_DIR}/${CHART_NAME}"

  [[ -f "${CHART}/Chart.yaml" ]] || continue

  RESOURCES_OUTPUT="$(discover_resources "$RELEASE" "$CHART")"
  [[ -n "$RESOURCES_OUTPUT" ]] || continue

  mapfile -t RESOURCES <<< "$RESOURCES_OUTPUT"

  for RESOURCE in "${RESOURCES[@]}"; do
    case "$RESOURCE" in
      namespace/*|\
      customresourcedefinition.*/*|\
      clusterrole.*/*|\
      clusterrolebinding.*/*)
        continue
        ;;
    esac

    kubectl get "$RESOURCE" -n "$NAMESPACE" >/dev/null 2>&1 || continue

    MANAGED_BY="$(get_metadata "$RESOURCE" '{.metadata.labels.app\.kubernetes\.io/managed-by}')"
    CURRENT_RELEASE="$(get_metadata "$RESOURCE" '{.metadata.annotations.meta\.helm\.sh/release-name}')"
    CURRENT_NAMESPACE="$(get_metadata "$RESOURCE" '{.metadata.annotations.meta\.helm\.sh/release-namespace}')"

    if [[ "$MANAGED_BY" != "Helm" ||
          "$CURRENT_RELEASE" != "$RELEASE" ||
          "$CURRENT_NAMESPACE" != "$NAMESPACE" ]]; then
      echo "VERIFY FAILED: $RESOURCE"
      echo "  expected: Helm | $RELEASE | $NAMESPACE"
      echo "  actual  : ${MANAGED_BY:-none} | ${CURRENT_RELEASE:-none} | ${CURRENT_NAMESPACE:-none}"
      CONFLICTS=$((CONFLICTS + 1))
    fi
  done
done

banner "Summary"

echo "Repaired ownership        : $ADOPTED"
echo "Already correct           : $ALREADY_OK"
echo "Not deployed yet          : $NEW_RESOURCES"
echo "Chart/render errors        : $CHART_ERRORS"
echo "Unrelated ownership issues : $CONFLICTS"
echo "Warnings                  : $WARNINGS"

echo
echo "Canonical release names:"
echo "  productcatalogservice  -> productcatalog-dev"
echo "  inventoryservice       -> inventoryservice"
echo "  userservice            -> user-dev"
echo "  cartservice            -> cartservice-dev"
echo "  orderservice           -> orderservice-dev"
echo "  paymentservice         -> paymentservice-dev"
echo "  checkoutservice        -> checkoutservice-dev"
echo "  shippingservice        -> shippingservice-dev"
echo "  notificationservice    -> notificationservice-dev"
echo "  recommendationservice  -> recommendationservice-dev"

echo
if (( CONFLICTS == 0 && CHART_ERRORS == 0 )); then
  echo "SUCCESS: Helm ownership is consistent for all existing service resources."
else
  echo "ATTENTION: Review only the CONFLICT/ERROR lines above."
  echo "The script intentionally did not steal unrelated resources."
fi

echo
echo "No resources were deleted."
echo "NetworkPolicy rules were not modified."
echo "Git Bash remains open."
