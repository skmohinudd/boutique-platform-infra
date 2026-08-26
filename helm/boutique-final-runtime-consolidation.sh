#!/usr/bin/env bash
#
# Boutique final consolidation before per-repository CI/CD
# ========================================================
#
# Run from ANY directory in Git Bash:
#   bash boutique-final-runtime-consolidation.sh
#
# Permanent-state rule:
#   Kubernetes objects  -> Helm code in boutique-platform-infra/helm
#   AWS Pod Identity    -> code files in boutique-platform-infra/aws/pod-identity
#   Application source  -> each microservice repository
#
# kubectl is used only for discovery, validation, temporary diagnostic/bootstrap
# Pods, and one-time Helm ownership migration. Permanent application objects are
# deployed through Helm.
#
# This script DOES NOT exit when one service fails. It continues, diagnoses,
# applies known safe repairs, retries, and writes complete logs.
#
# Known problems handled:
# - wrong Helm root
# - wrong Helm release names
# - kubectl-client-side-apply field conflicts
# - Helm ownership metadata conflicts
# - Product Catalog's shared SecretProviderClass ownership
# - stale static RDS passwords in Helm
# - missing DB_URL after removing old Kubernetes Secret
# - Pod Identity association propagation race
# - AWS CLI file:// path conversion under Git Bash/MSYS
# - service-specific PostgreSQL databases
# - missing Recommendation deployment/image
# - failed Helm upgrade with healthy old Pods hiding a failed new rollout
#
# Current DB design confirmed from application.yml:
#   productcatalogservice -> product_catalog_db
#   inventoryservice      -> inventory_db
#   userservice           -> user_db
#   orderservice          -> order_db
#   paymentservice        -> payment_db
#   shippingservice       -> shipping_db
#
# Non-DB:
#   cartservice, checkoutservice, notificationservice, recommendationservice
#

set +e
set +u
set +o pipefail 2>/dev/null || true

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-663130434910}"
CLUSTER="${CLUSTER:-boutique-dev-eks}"
NAMESPACE="${NAMESPACE:-boutique}"
RDS_INSTANCE="${RDS_INSTANCE:-boutique-dev-postgres}"

POD_ROLE_NAME="${POD_ROLE_NAME:-BoutiqueMicroservicesSecretsAccess}"
POD_ROLE_POLICY_NAME="${POD_ROLE_POLICY_NAME:-BoutiqueMicroservicesSecretsAccessPolicy}"

SPC_NAME="${SPC_NAME:-boutique-rds-secrets}"
SYNCED_SECRET_NAME="${SYNCED_SECRET_NAME:-boutique-rds-credentials}"

HELM_TIMEOUT="${HELM_TIMEOUT:-8m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
POD_IDENTITY_RETRIES="${POD_IDENTITY_RETRIES:-6}"
POD_IDENTITY_RETRY_DELAY="${POD_IDENTITY_RETRY_DELAY:-15}"

# Deploy Recommendation too. If its ECR image is absent, build/push from source.
ENSURE_ALL_SERVICES="${ENSURE_ALL_SERVICES:-true}"
AUTO_BUILD_MISSING_IMAGE="${AUTO_BUILD_MISSING_IMAGE:-true}"

# chart|deployment|release|serviceAccount|database|sourceDir|ecrRepository
SERVICES=(
  "productcatalogservice|productcatalogservice|productcatalog-dev|productcatalogservice-sa|product_catalog_db|boutique-productcatalogservice|boutique-productcatalogservice"
  "inventoryservice|inventoryservice|inventoryservice|inventoryservice-sa|inventory_db|boutique-inventoryservice|boutique-inventoryservice"
  "userservice|userservice|user-dev|userservice-sa|user_db|boutique-userservice|boutique-userservice"
  "cartservice|cartservice|cartservice-dev|cartservice-sa|-|boutique-cartservice|boutique-cartservice"
  "orderservice|orderservice|orderservice-dev|orderservice-sa|order_db|boutique-orderservice|boutique-orderservice"
  "paymentservice|paymentservice|paymentservice-dev|paymentservice-sa|payment_db|boutique-paymentservice-java|boutique-paymentservice"
  "checkoutservice|checkoutservice|checkoutservice-dev|checkoutservice-sa|-|boutique-checkoutservice-java|boutique-checkoutservice"
  "shippingservice|shippingservice|shippingservice-dev|shippingservice-sa|shipping_db|boutique-shippingservice-java|boutique-shippingservice"
  "notificationservice|notificationservice|notificationservice-dev|notificationservice-sa|-|boutique-notificationservice|boutique-notificationservice"
  "recommendationservice|recommendationservice|recommendationservice-dev|recommendationservice-sa|-|boutique-recommendationservice-java|boutique-recommendationservice"
)

ERRORS=0
WARNINGS=0
FIXED=0
DEPLOYED=0
RUNTIME_HEALTHY=0
IDENTITY_PASS=0
IDENTITY_FAIL=0
BUILT_IMAGES=0

section() {
  printf '\n================================================================\n%s\n================================================================\n' "$1"
}

ok() {
  echo "OK: $*"
}

warn() {
  echo "WARNING: $*"
  WARNINGS=$((WARNINGS + 1))
}

err() {
  echo "ERROR: $*"
  ERRORS=$((ERRORS + 1))
}

have() {
  command -v "$1" >/dev/null 2>&1
}

is_db_service() {
  [[ "$1" != "-" ]]
}

contains_alias() {
  local current="$1"
  shift
  local alias
  for alias in "$@"; do
    [[ "$current" == "$alias" ]] && return 0
  done
  return 1
}

find_project_root() {
  local candidate

  for candidate in \
    "/c/boutique-project/Projects" \
    "$(pwd)" \
    "$(pwd)/Projects" \
    "$(pwd)/.."; do

    if [[ -f "$candidate/boutique-platform-infra/helm/productcatalogservice/Chart.yaml" ]]; then
      (cd "$candidate" 2>/dev/null && pwd)
      return
    fi
  done

  local hit
  hit="$(find "$(pwd)" -maxdepth 5 \
    -path '*/boutique-platform-infra/helm/productcatalogservice/Chart.yaml' \
    -print -quit 2>/dev/null)"

  if [[ -n "$hit" ]]; then
    dirname "$(dirname "$(dirname "$(dirname "$hit")")")"
  fi
}

PROJECT_ROOT="$(find_project_root)"

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "ERROR: boutique-platform-infra/helm could not be located."
  echo "Git Bash remains open."
  return 0 2>/dev/null || true
fi

PLATFORM_ROOT="$PROJECT_ROOT/boutique-platform-infra"
HELM_ROOT="$PLATFORM_ROOT/helm"
AWS_CODE_ROOT="$PLATFORM_ROOT/aws/pod-identity"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ROOT="$PLATFORM_ROOT/ops-runtime-consolidation/$STAMP"
LOG_ROOT="$RUN_ROOT/logs"
BACKUP_ROOT="$RUN_ROOT/helm-backup"
SUMMARY="$RUN_ROOT/summary.txt"
DB_MAP="$RUN_ROOT/database-map.txt"
HEALTH_MAP="$RUN_ROOT/health-map.txt"

mkdir -p "$LOG_ROOT" "$BACKUP_ROOT" "$AWS_CODE_ROOT"
exec > >(tee -a "$LOG_ROOT/master.log") 2>&1

svc_dir() {
  mkdir -p "$LOG_ROOT/$1"
  echo "$LOG_ROOT/$1"
}

discover_rds_endpoint() {
  aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text 2>/dev/null
}

discover_rds_secret() {
  local arn

  arn="$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].MasterUserSecret.SecretArn' \
    --output text 2>/dev/null)"

  if [[ -n "$arn" && "$arn" != "None" ]]; then
    echo "$arn"
    return
  fi

  aws secretsmanager list-secrets \
    --region "$AWS_REGION" \
    --query "SecretList[?contains(Description, \`${RDS_INSTANCE}\`)].ARN | [0]" \
    --output text 2>/dev/null
}

verify_secret_shape() {
  local arn="$1"

  local keys
  keys="$(aws secretsmanager get-secret-value \
    --secret-id "$arn" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text 2>/dev/null \
    | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  try {
    const j=JSON.parse(s);
    console.log(Object.keys(j).sort().join(","));
  } catch(e) {
    process.exit(2);
  }
});' 2>/dev/null)"

  if [[ ",$keys," == *",username,"* && ",$keys," == *",password,"* ]]; then
    ok "RDS-managed secret contains username/password."
  else
    err "RDS secret has unexpected JSON keys: ${keys:-unreadable}"
  fi
}

backup_platform_code() {
  section "BACKUP HELM CODE"

  cp -a "$HELM_ROOT/." "$BACKUP_ROOT/" 2>"$LOG_ROOT/backup.err"

  if [[ $? -eq 0 ]]; then
    ok "Backup saved: $BACKUP_ROOT"
  else
    err "Helm backup did not complete cleanly."
  fi
}

verify_existing_cluster_components() {
  section "VERIFY EXISTING CLUSTER COMPONENTS"

  kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io \
    > "$LOG_ROOT/secretproviderclass-crd.txt" 2>&1
  [[ $? -eq 0 ]] && ok "SecretProviderClass CRD exists." \
    || err "SecretProviderClass CRD missing."

  kubectl get csidriver secrets-store.csi.k8s.io \
    > "$LOG_ROOT/secrets-store-csidriver.txt" 2>&1
  [[ $? -eq 0 ]] && ok "Secrets Store CSI driver exists." \
    || err "Secrets Store CSI driver missing."

  kubectl get pods -n kube-system -o wide \
    > "$LOG_ROOT/kube-system-pods.txt" 2>&1

  if grep -Eqi 'secrets-store.*provider.*aws|provider-aws' "$LOG_ROOT/kube-system-pods.txt"; then
    ok "AWS Secrets Store provider detected."
  else
    warn "AWS Secrets Store provider name not detected automatically; nothing duplicate will be installed."
  fi

  aws eks describe-addon \
    --cluster-name "$CLUSTER" \
    --addon-name eks-pod-identity-agent \
    --region "$AWS_REGION" \
    > "$LOG_ROOT/pod-identity-agent.json" 2>&1

  [[ $? -eq 0 ]] && ok "EKS Pod Identity Agent add-on exists." \
    || err "EKS Pod Identity Agent add-on could not be verified."
}

write_aws_source_of_truth() {
  local secret_arn="$1"

  section "WRITE AWS POD IDENTITY SOURCE OF TRUTH"

  cat > "$AWS_CODE_ROOT/trust-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EksPodIdentity",
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

  cat > "$AWS_CODE_ROOT/secrets-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadBoutiqueRDSManagedSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ],
      "Resource": "${secret_arn}"
    },
    {
      "Sid": "CustomerManagedKMSViaSecretsManager",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "secretsmanager.${AWS_REGION}.amazonaws.com"
        }
      }
    }
  ]
}
EOF

  cat > "$AWS_CODE_ROOT/associations.tsv" <<EOF
cluster	namespace	serviceAccount	role
${CLUSTER}	${NAMESPACE}	productcatalogservice-sa	${POD_ROLE_NAME}
${CLUSTER}	${NAMESPACE}	inventoryservice-sa	${POD_ROLE_NAME}
${CLUSTER}	${NAMESPACE}	userservice-sa	${POD_ROLE_NAME}
${CLUSTER}	${NAMESPACE}	orderservice-sa	${POD_ROLE_NAME}
${CLUSTER}	${NAMESPACE}	paymentservice-sa	${POD_ROLE_NAME}
${CLUSTER}	${NAMESPACE}	shippingservice-sa	${POD_ROLE_NAME}
EOF

  cat > "$AWS_CODE_ROOT/README.md" <<EOF
# Boutique EKS Pod Identity

This directory is the code record for the Boutique database workload AWS identity.

- IAM role: \`${POD_ROLE_NAME}\`
- EKS cluster: \`${CLUSTER}\`
- namespace: \`${NAMESPACE}\`
- RDS-managed Secrets Manager secret: \`${secret_arn}\`

Kubernetes ServiceAccounts are created by their Helm charts. EKS Pod Identity
associates only DB workloads with the IAM role. No IRSA role annotation is used.

The JSON policy files are applied by \`boutique-final-runtime-consolidation.sh\`.
EOF

  ok "AWS desired-state files written under $AWS_CODE_ROOT"
}

apply_iam_code() {
  section "APPLY IAM CODE"

  ROLE_ARN="$(aws iam get-role \
    --role-name "$POD_ROLE_NAME" \
    --query Role.Arn \
    --output text 2>/dev/null)"

  if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
    err "Expected IAM role does not exist: $POD_ROLE_NAME"
    ROLE_ARN=""
    return
  fi

  # IMPORTANT: pass JSON content directly. Do not use file:// here because
  # Git Bash/MSYS previously rewrote the path and AWS CLI could not find it.
  aws iam update-assume-role-policy \
    --role-name "$POD_ROLE_NAME" \
    --policy-document "$(cat "$AWS_CODE_ROOT/trust-policy.json")" \
    > "$LOG_ROOT/iam-trust-apply.log" 2>&1

  [[ $? -eq 0 ]] && {
    ok "IAM trust policy applied."
    FIXED=$((FIXED + 1))
  } || err "IAM trust policy apply failed."

  aws iam put-role-policy \
    --role-name "$POD_ROLE_NAME" \
    --policy-name "$POD_ROLE_POLICY_NAME" \
    --policy-document "$(cat "$AWS_CODE_ROOT/secrets-policy.json")" \
    > "$LOG_ROOT/iam-permissions-apply.log" 2>&1

  [[ $? -eq 0 ]] && {
    ok "IAM Secrets Manager/KMS policy applied."
    FIXED=$((FIXED + 1))
  } || err "IAM permissions policy apply failed."
}

ensure_pod_identity_association() {
  local service="$1"
  local sa="$2"
  local dir
  dir="$(svc_dir "$service")"

  [[ -n "$ROLE_ARN" ]] || {
    err "$service: IAM role ARN unavailable."
    return
  }

  local id current_role
  id="$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER" \
    --region "$AWS_REGION" \
    --query "associations[?namespace=='${NAMESPACE}' && serviceAccount=='${sa}'].associationId | [0]" \
    --output text 2>/dev/null)"

  if [[ -z "$id" || "$id" == "None" ]]; then
    aws eks create-pod-identity-association \
      --cluster-name "$CLUSTER" \
      --namespace "$NAMESPACE" \
      --service-account "$sa" \
      --role-arn "$ROLE_ARN" \
      --region "$AWS_REGION" \
      > "$dir/pod-identity-create.json" 2>&1

    [[ $? -eq 0 ]] && {
      ok "$service: Pod Identity association created."
      FIXED=$((FIXED + 1))
    } || err "$service: Pod Identity association creation failed."
    return
  fi

  current_role="$(aws eks describe-pod-identity-association \
    --cluster-name "$CLUSTER" \
    --association-id "$id" \
    --region "$AWS_REGION" \
    --query association.roleArn \
    --output text 2>/dev/null)"

  if [[ "$current_role" == "$ROLE_ARN" ]]; then
    ok "$service: Pod Identity association already correct."
    return
  fi

  aws eks update-pod-identity-association \
    --cluster-name "$CLUSTER" \
    --association-id "$id" \
    --role-arn "$ROLE_ARN" \
    --region "$AWS_REGION" \
    > "$dir/pod-identity-update.json" 2>&1

  [[ $? -eq 0 ]] && {
    ok "$service: Pod Identity association updated."
    FIXED=$((FIXED + 1))
  } || err "$service: Pod Identity association update failed."
}

test_pod_identity_with_retry() {
  local service="$1"
  local sa="$2"
  local secret_arn="$3"
  local dir
  dir="$(svc_dir "$service")"

  local attempt pod phase sts_arn secret_rc

  for attempt in $(seq 1 "$POD_IDENTITY_RETRIES"); do
    pod="identity-${service}-${attempt}"
    pod="${pod:0:63}"

    kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

    kubectl run "$pod" \
      -n "$NAMESPACE" \
      --image=amazon/aws-cli:2.17.52 \
      --restart=Never \
      --overrides="{\"spec\":{\"serviceAccountName\":\"${sa}\"}}" \
      --command -- sleep 180 \
      > "$dir/identity-${attempt}-create.log" 2>&1

    if [[ $? -ne 0 ]]; then
      sleep "$POD_IDENTITY_RETRY_DELAY"
      continue
    fi

    phase=""
    for _ in {1..45}; do
      phase="$(kubectl get pod "$pod" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)"
      [[ "$phase" == "Running" ]] && break
      sleep 2
    done

    if [[ "$phase" != "Running" ]]; then
      kubectl describe pod "$pod" -n "$NAMESPACE" \
        > "$dir/identity-${attempt}-describe.log" 2>&1
      kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
      sleep "$POD_IDENTITY_RETRY_DELAY"
      continue
    fi

    sts_arn="$(kubectl exec "$pod" -n "$NAMESPACE" -- \
      aws sts get-caller-identity \
      --query Arn --output text 2>/dev/null)"

    echo "$sts_arn" > "$dir/identity-${attempt}-sts.txt"

    kubectl exec "$pod" -n "$NAMESPACE" -- \
      aws secretsmanager get-secret-value \
      --secret-id "$secret_arn" \
      --region "$AWS_REGION" \
      --query VersionId \
      --output text \
      > "$dir/identity-${attempt}-secret.txt" 2>&1
    secret_rc=$?

    kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

    if [[ "$sts_arn" == *"assumed-role/${POD_ROLE_NAME}/"* && $secret_rc -eq 0 ]]; then
      ok "$service: Pod Identity -> IAM -> Secrets Manager verified."
      IDENTITY_PASS=$((IDENTITY_PASS + 1))
      return
    fi

    echo "$service: waiting for Pod Identity propagation before retry $((attempt + 1))."
    sleep "$POD_IDENTITY_RETRY_DELAY"
  done

  IDENTITY_FAIL=$((IDENTITY_FAIL + 1))
  err "$service: Pod Identity verification failed after retries."
}

ensure_productcatalog_owns_spc() {
  local secret_arn="$1"
  local chart="$HELM_ROOT/productcatalogservice"
  local values="$chart/values.yaml"
  local template="$chart/templates/secretproviderclass.yaml"

  section "NORMALIZE SHARED SECRETPROVIDERCLASS SOURCE"

  # For stability we intentionally keep this resource in productcatalog-dev.
  # Moving it to another Helm release caused the previous ownership conflict.
  cat > "$template" <<'EOF'
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: {{ .Values.awsSecrets.secretProviderClassName }}
  namespace: {{ .Release.Namespace }}
spec:
  provider: aws
  parameters:
    region: {{ .Values.awsSecrets.region | quote }}
    usePodIdentity: "true"
    objects: |
      - objectName: {{ .Values.awsSecrets.secretArn | quote }}
        objectType: "secretsmanager"
        objectVersionLabel: "AWSCURRENT"
        jmesPath:
          - path: "username"
            objectAlias: "DB_USERNAME"
          - path: "password"
            objectAlias: "DB_PASSWORD"
  secretObjects:
    - secretName: {{ .Values.database.kubernetesSecretName }}
      type: Opaque
      data:
        - objectName: "DB_USERNAME"
          key: "DB_USERNAME"
        - objectName: "DB_PASSWORD"
          key: "DB_PASSWORD"
EOF

  node - "$values" "$secret_arn" "$AWS_REGION" "$SPC_NAME" "$SYNCED_SECRET_NAME" <<'NODE'
const fs=require("fs");
const [file,arn,region,spc,secret]=process.argv.slice(2);
let s=fs.readFileSync(file,"utf8").replace(/\r\n/g,"\n");

function replaceBlock(name, block) {
  const re=new RegExp("^"+name+":\\n(?:(?:[ \\t]+.*)\\n)*","m");
  if (re.test(s)) s=s.replace(re,block+"\n");
  else s=s.replace(/\s*$/,"\n\n")+block+"\n";
}

const currentUrl=(s.match(/^database:\n(?:[ \t]+.*\n)*?[ \t]+url:[ \t]*["']?([^"'\n]+)["']?/m)||[])[1] || "";

replaceBlock("database",
`database:
  url: "${currentUrl}"
  kubernetesSecretName: ${secret}`);

replaceBlock("awsSecrets",
`awsSecrets:
  enabled: true
  region: ${region}
  secretProviderClassName: ${spc}
  secretArn: "${arn}"
  mountPath: /mnt/secrets-store`);

fs.writeFileSync(file,s);
NODE

  ok "Shared SecretProviderClass remains code-owned by productcatalog-dev."
}

patch_db_chart() {
  local chart="$1"
  local sa="$2"
  local database="$3"
  local endpoint="$4"
  local chart_root="$HELM_ROOT/$chart"
  local values="$chart_root/values.yaml"
  local deploy="$chart_root/templates/deployment.yaml"
  local jdbc="jdbc:postgresql://${endpoint}:5432/${database}"

  if [[ ! -f "$values" || ! -f "$deploy" ]]; then
    err "$chart: required Helm files missing."
    return
  fi

  # All DB service deployments are normalized to the same explicit pattern.
  # Existing probes/resources/security/other env vars are preserved.
  node - "$values" "$deploy" "$sa" "$jdbc" "$SYNCED_SECRET_NAME" "$SPC_NAME" <<'NODE'
const fs=require("fs");
const [valuesFile,deployFile,sa,jdbc,k8sSecret,spcName]=process.argv.slice(2);

function replaceTopBlock(text,name,block) {
  const re=new RegExp("^"+name+":\\n(?:(?:[ \\t]+.*)\\n)*","m");
  if (re.test(text)) return text.replace(re,block+"\n");
  return text.replace(/\s*$/,"\n\n")+block+"\n";
}

let v=fs.readFileSync(valuesFile,"utf8").replace(/\r\n/g,"\n");

v=replaceTopBlock(v,"database",
`database:
  url: "${jdbc}"
  kubernetesSecretName: ${k8sSecret}`);

let existingAws="";
if (/^awsSecrets:/m.test(v)) {
  existingAws="present";
}

if (!existingAws) {
  v=v.replace(/\s*$/,"\n\n")+
`awsSecrets:
  enabled: true
  secretProviderClassName: ${spcName}
  mountPath: /mnt/secrets-store
`;
} else {
  // Product Catalog keeps region + ARN. Other service charts only reference the shared SPC.
  if (!v.includes("secretProviderClassName:")) {
    v=v.replace(/^awsSecrets:\n/m,
`awsSecrets:
  enabled: true
  secretProviderClassName: ${spcName}
  mountPath: /mnt/secrets-store
`);
  }
}

v=v.replace(
  /(serviceAccount:\n(?:(?:[ \t]+.*)\n)*?[ \t]+name:)[^\n]*/,
  `$1 ${sa}`
);

fs.writeFileSync(valuesFile,v);

let lines=fs.readFileSync(deployFile,"utf8").replace(/\r\n/g,"\n").split("\n");

// 1) Remove old database secretRef from envFrom.
for (let i=0;i<lines.length;i++) {
  if (lines[i].trim()==="- secretRef:" &&
      lines[i+1] && lines[i+1].includes(".Values.database.")) {
    lines.splice(i,2);
    i--;
  }
}

// 2) Remove any previously generated DB env entries (idempotent reruns).
for (let i=0;i<lines.length;i++) {
  const match=lines[i].match(/^(\s*)-\s+name:\s+(DB_URL|DB_USERNAME|DB_PASSWORD)\s*$/);
  if (!match) continue;

  const indent=match[1].length;
  let j=i+1;
  while (j<lines.length) {
    const line=lines[j];
    if (line.trim()==="") { j++; continue; }
    const nextIndent=(line.match(/^(\s*)/)||["",""])[1].length;
    if (nextIndent<=indent) break;
    j++;
  }
  lines.splice(i,j-i);
  i--;
}

const dbEnv=[
"            # Service-specific PostgreSQL JDBC URL from Helm values.",
"            - name: DB_URL",
"              value: {{ .Values.database.url | quote }}",
"            # Current RDS credentials synchronized from AWS Secrets Manager.",
"            - name: DB_USERNAME",
"              valueFrom:",
"                secretKeyRef:",
"                  name: {{ .Values.database.kubernetesSecretName }}",
"                  key: DB_USERNAME",
"            - name: DB_PASSWORD",
"              valueFrom:",
"                secretKeyRef:",
"                  name: {{ .Values.database.kubernetesSecretName }}",
"                  key: DB_PASSWORD"
];

// 3) Preserve existing RabbitMQ/etc env entries; prepend DB env to existing env.
let envIndex=lines.findIndex(x=>x==="          env:");

if (envIndex>=0) {
  lines.splice(envIndex+1,0,...dbEnv);
} else {
  const envFromIndex=lines.findIndex(x=>x==="          envFrom:");
  if (envFromIndex<0) throw new Error("container envFrom block not found");

  let insert=envFromIndex+1;
  while (insert<lines.length) {
    if (lines[insert].trim()==="") { insert++; continue; }
    const indent=(lines[insert].match(/^(\s*)/)||["",""])[1].length;
    if (indent<=10) break;
    insert++;
  }

  lines.splice(insert,0,"          env:",...dbEnv);
}

// 4) Add one CSI volumeMount only.
if (!lines.some(x=>x.includes("mountPath: {{ .Values.awsSecrets.mountPath }}"))) {
  const resourcesIndex=lines.findIndex(x=>x==="          resources:");
  if (resourcesIndex<0) throw new Error("resources block not found");

  lines.splice(resourcesIndex,0,
    "          # Mount Secrets Manager values with the existing Secrets Store CSI driver.",
    "          volumeMounts:",
    "            - name: aws-secrets-store",
    "              mountPath: {{ .Values.awsSecrets.mountPath }}",
    "              readOnly: true"
  );
}

// 5) Add one Pod-level CSI volume only.
if (!lines.some(x=>x.includes("driver: secrets-store.csi.k8s.io"))) {
  while (lines.length && lines[lines.length-1].trim()==="") lines.pop();

  lines.push(
    "",
    "      # Reuse the shared SecretProviderClass owned by productcatalog-dev.",
    "      volumes:",
    "        - name: aws-secrets-store",
    "          csi:",
    "            driver: secrets-store.csi.k8s.io",
    "            readOnly: true",
    "            volumeAttributes:",
    "              secretProviderClass: {{ .Values.awsSecrets.secretProviderClassName }}"
  );
}

fs.writeFileSync(deployFile,lines.join("\n")+"\n");
NODE

  if [[ $? -ne 0 ]]; then
    err "$chart: Helm patch failed."
    return
  fi

  # Static credentials are no longer a Helm resource.
  if [[ -f "$chart_root/templates/secret.yaml" ]]; then
    rm -f "$chart_root/templates/secret.yaml"
    ok "$chart: static DB Secret template removed."
  fi

  echo "$chart|$database|$jdbc|$sa" >> "$DB_MAP"
  ok "$chart: DB configuration normalized."
  FIXED=$((FIXED + 1))
}

validate_chart() {
  local chart="$1"
  local release="$2"
  local sa="$3"
  local database="$4"
  local dir
  dir="$(svc_dir "$chart")"

  helm lint "$HELM_ROOT/$chart" > "$dir/helm-lint.log" 2>&1
  if [[ $? -eq 0 ]]; then
    ok "$chart: helm lint."
  else
    err "$chart: helm lint failed."
    return
  fi

  helm template "$release" "$HELM_ROOT/$chart" \
    --namespace "$NAMESPACE" \
    > "$dir/rendered.yaml" 2> "$dir/helm-template.err"

  if [[ $? -ne 0 ]]; then
    err "$chart: helm template failed."
    return
  fi

  grep -q "serviceAccountName: ${sa}" "$dir/rendered.yaml" \
    && ok "$chart: ServiceAccount rendered correctly." \
    || err "$chart: wrong rendered ServiceAccount."

  if is_db_service "$database"; then
    grep -q 'name: DB_URL' "$dir/rendered.yaml" \
      || err "$chart: DB_URL is missing from rendered Deployment."
    grep -q 'name: DB_USERNAME' "$dir/rendered.yaml" \
      || err "$chart: DB_USERNAME is missing."
    grep -q 'name: DB_PASSWORD' "$dir/rendered.yaml" \
      || err "$chart: DB_PASSWORD is missing."
    grep -q 'driver: secrets-store.csi.k8s.io' "$dir/rendered.yaml" \
      || err "$chart: CSI volume missing."
    grep -q 'port: 5432' "$dir/rendered.yaml" \
      || warn "$chart: NetworkPolicy does not render PostgreSQL port 5432."
  fi
}

render_resource_names() {
  helm template "$1" "$2" --namespace "$NAMESPACE" 2>/dev/null \
    | kubectl apply --dry-run=client -f - -o name 2>/dev/null \
    | sort -u
}

repair_helm_ownership() {
  local chart="$1"
  local release="$2"
  local resources resource owner managed ns

  resources="$(render_resource_names "$release" "$HELM_ROOT/$chart")"

  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue

    case "$resource" in
      namespace/*|customresourcedefinition.*/*|clusterrole.*/*|clusterrolebinding.*/*)
        continue
        ;;
    esac

    kubectl get "$resource" -n "$NAMESPACE" >/dev/null 2>&1 || continue

    owner="$(kubectl get "$resource" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)"
    managed="$(kubectl get "$resource" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
    ns="$(kubectl get "$resource" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null)"

    local aliases=("$release" "$chart" "${chart}-dev")
    [[ "$chart" == "productcatalogservice" ]] && aliases+=("productcatalog-dev")
    [[ "$chart" == "userservice" ]] && aliases+=("user-dev")

    if [[ -n "$owner" ]] && ! contains_alias "$owner" "${aliases[@]}"; then
      err "$chart: refusing to steal $resource from unrelated release '$owner'."
      continue
    fi

    if [[ "$owner" == "$release" && "$managed" == "Helm" && "$ns" == "$NAMESPACE" ]]; then
      continue
    fi

    kubectl label "$resource" -n "$NAMESPACE" \
      app.kubernetes.io/managed-by=Helm \
      --overwrite >/dev/null 2>&1
    local a=$?

    kubectl annotate "$resource" -n "$NAMESPACE" \
      meta.helm.sh/release-name="$release" \
      meta.helm.sh/release-namespace="$NAMESPACE" \
      --overwrite >/dev/null 2>&1
    local b=$?

    if [[ $a -eq 0 && $b -eq 0 ]]; then
      FIXED=$((FIXED + 1))
      ok "$chart: Helm ownership normalized for $resource"
    else
      err "$chart: Helm ownership repair failed for $resource"
    fi
  done <<< "$resources"
}

ensure_databases() {
  local endpoint="$1"
  local pod="boutique-db-bootstrap"
  local yaml="$LOG_ROOT/db-bootstrap-pod.yaml"

  section "ENSURE SERVICE DATABASES"

  cat > "$yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  serviceAccountName: productcatalogservice-sa
  containers:
    - name: psql
      image: postgres:16-alpine
      command:
        - /bin/sh
        - -c
        - |
          set +e
          export PGHOST="${endpoint}"
          export PGPORT="5432"
          export PGUSER="\$(cat /mnt/secrets-store/DB_USERNAME)"
          export PGPASSWORD="\$(cat /mnt/secrets-store/DB_PASSWORD)"

          for db in product_catalog_db inventory_db user_db order_db payment_db shipping_db; do
            echo "===== \$db ====="
            exists="\$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='\$db';" 2>&1)"

            if echo "\$exists" | grep -qx "1"; then
              echo "EXISTS: \$db"
            else
              echo "CREATE: \$db"
              psql -d postgres -v ON_ERROR_STOP=1 \
                -c "CREATE DATABASE \\"\$db\\" OWNER \\"\$PGUSER\\";" || true
            fi

            psql -d postgres \
              -c "GRANT ALL PRIVILEGES ON DATABASE \\"\$db\\" TO \\"\$PGUSER\\";" || true

            psql -d "\$db" \
              -c "GRANT ALL ON SCHEMA public TO \\"\$PGUSER\\";" || true
          done
      volumeMounts:
        - name: aws-secrets-store
          mountPath: /mnt/secrets-store
          readOnly: true
  volumes:
    - name: aws-secrets-store
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: ${SPC_NAME}
EOF

  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl create -f "$yaml" > "$LOG_ROOT/db-bootstrap-create.log" 2>&1

  if [[ $? -ne 0 ]]; then
    err "DB bootstrap pod could not be created."
    return
  fi

  local phase=""
  for _ in {1..100}; do
    phase="$(kubectl get pod "$pod" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
  done

  kubectl logs "$pod" -n "$NAMESPACE" > "$LOG_ROOT/db-bootstrap.log" 2>&1
  kubectl describe pod "$pod" -n "$NAMESPACE" > "$LOG_ROOT/db-bootstrap-describe.txt" 2>&1

  if grep -Eqi 'FATAL:|permission denied|AccessDenied|FailedMount|could not connect' "$LOG_ROOT/db-bootstrap.log"; then
    err "Database bootstrap contains errors."
  else
    ok "All dedicated databases exist and grants were checked."
  fi

  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
}

current_image() {
  kubectl get deployment "$1" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

ecr_image_exists() {
  aws ecr describe-images \
    --repository-name "$1" \
    --image-ids "imageTag=$2" \
    --region "$AWS_REGION" >/dev/null 2>&1
}

ensure_image_for_missing_service() {
  local chart="$1"
  local source_dir="$2"
  local ecr_repo="$3"
  local values="$HELM_ROOT/$chart/values.yaml"

  local repository tag
  repository="$(awk '/^[[:space:]]*repository:/ {print $2; exit}' "$values" | tr -d '"')"
  tag="$(awk '/^[[:space:]]*tag:/ {print $2; exit}' "$values" | tr -d '"')"

  if ecr_image_exists "$ecr_repo" "$tag"; then
    echo "${repository}:${tag}"
    return
  fi

  if [[ "$AUTO_BUILD_MISSING_IMAGE" != "true" ]]; then
    echo ""
    return
  fi

  if ! have docker || [[ ! -f "$PROJECT_ROOT/$source_dir/Dockerfile" ]]; then
    echo ""
    return
  fi

  section "BUILD MISSING IMAGE: $chart"

  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login \
      --username AWS \
      --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" \
      > "$LOG_ROOT/$chart/ecr-login.log" 2>&1

  if [[ ${PIPESTATUS[0]} -ne 0 && ${PIPESTATUS[1]} -ne 0 ]]; then
    err "$chart: ECR login failed."
    echo ""
    return
  fi

  docker build \
    -t "${repository}:${tag}" \
    "$PROJECT_ROOT/$source_dir" \
    > "$LOG_ROOT/$chart/docker-build.log" 2>&1

  if [[ $? -ne 0 ]]; then
    err "$chart: Docker build failed."
    echo ""
    return
  fi

  docker push "${repository}:${tag}" \
    > "$LOG_ROOT/$chart/docker-push.log" 2>&1

  if [[ $? -ne 0 ]]; then
    err "$chart: Docker push failed."
    echo ""
    return
  fi

  BUILT_IMAGES=$((BUILT_IMAGES + 1))
  ok "$chart: missing image built and pushed."
  echo "${repository}:${tag}"
}

capture_pod_diagnostics() {
  local chart="$1"
  local deployment="$2"
  local dir
  dir="$(svc_dir "$chart")"

  kubectl get deployment "$deployment" -n "$NAMESPACE" -o yaml \
    > "$dir/deployment.yaml" 2>&1

  kubectl get pods -n "$NAMESPACE" -l "app=${deployment}" -o wide \
    > "$dir/pods.txt" 2>&1

  kubectl get rs -n "$NAMESPACE" -l "app=${deployment}" -o wide \
    > "$dir/replicasets.txt" 2>&1

  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
    > "$dir/events.txt" 2>&1

  local pod
  pod="$(kubectl get pods -n "$NAMESPACE" \
    -l "app=${deployment}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"

  [[ -n "$pod" ]] || return

  kubectl describe pod "$pod" -n "$NAMESPACE" \
    > "$dir/newest-pod-describe.txt" 2>&1
  kubectl logs "$pod" -n "$NAMESPACE" --all-containers --tail=400 \
    > "$dir/newest-pod.log" 2>&1
  kubectl logs "$pod" -n "$NAMESPACE" --all-containers --previous --tail=400 \
    > "$dir/newest-pod-previous.log" 2>&1
}

classify_and_repair_after_helm_failure() {
  local chart="$1"
  local deployment="$2"
  local release="$3"
  local log="$4"

  if grep -Eqi 'invalid ownership metadata|cannot be imported into the current release' "$log"; then
    echo "$chart: detected Helm ownership failure; repairing and retrying."
    repair_helm_ownership "$chart" "$release"
    return 0
  fi

  if grep -Eqi 'conflict with "kubectl-client-side-apply"|Apply failed with .* conflict' "$log"; then
    echo "$chart: detected old kubectl field-manager conflict; server-side force-conflicts will be retried."
    return 0
  fi

  capture_pod_diagnostics "$chart" "$deployment"
  local podlog="$LOG_ROOT/$chart/newest-pod.log"

  if [[ -f "$podlog" ]] && grep -Eqi 'password authentication failed|Unable to obtain connection from database' "$podlog"; then
    echo "$chart: detected stale DB credential path; restarting after Secrets Manager sync."
    kubectl rollout restart "deployment/$deployment" -n "$NAMESPACE" \
      > "$LOG_ROOT/$chart/rollout-restart.log" 2>&1
    return 0
  fi

  if [[ -f "$podlog" ]] && grep -Eqi 'DB_URL.*(not|missing)|Could not resolve placeholder.*DB_URL' "$podlog"; then
    echo "$chart: detected missing DB_URL; Helm code already contains the explicit DB_URL repair."
    return 0
  fi

  if grep -Eqi 'context deadline exceeded|timed out waiting|not ready' "$log"; then
    echo "$chart: detected readiness timeout; collecting diagnostics and retrying once."
    return 0
  fi

  return 1
}

deploy_service_with_self_heal() {
  local chart="$1"
  local deployment="$2"
  local release="$3"
  local source_dir="$4"
  local ecr_repo="$5"
  local dir
  dir="$(svc_dir "$chart")"

  local image repo tag
  image="$(current_image "$deployment")"

  if [[ -z "$image" ]]; then
    if [[ "$ENSURE_ALL_SERVICES" != "true" ]]; then
      warn "$chart: not currently deployed."
      return
    fi

    image="$(ensure_image_for_missing_service "$chart" "$source_dir" "$ecr_repo")"

    if [[ -z "$image" ]]; then
      err "$chart: no current Deployment and no deployable ECR image."
      return
    fi
  fi

  repo="${image%:*}"
  tag="${image##*:}"

  echo "$chart: desired image $image"

  local attempt
  for attempt in 1 2; do
    helm upgrade --install "$release" "$HELM_ROOT/$chart" \
      --namespace "$NAMESPACE" \
      --set image.repository="$repo" \
      --set image.tag="$tag" \
      --server-side=true \
      --force-conflicts \
      --wait \
      --timeout "$HELM_TIMEOUT" \
      > "$dir/helm-upgrade-attempt-${attempt}.log" 2>&1

    local rc=$?

    if [[ $rc -eq 0 ]]; then
      kubectl rollout status "deployment/$deployment" \
        -n "$NAMESPACE" \
        --timeout="$ROLLOUT_TIMEOUT" \
        > "$dir/rollout.log" 2>&1

      if [[ $? -eq 0 ]]; then
        DEPLOYED=$((DEPLOYED + 1))
        ok "$chart: Helm release and Kubernetes rollout healthy."
        capture_pod_diagnostics "$chart" "$deployment"
        return
      fi
    fi

    err "$chart: Helm/rollout attempt $attempt failed."
    capture_pod_diagnostics "$chart" "$deployment"

    if [[ $attempt -eq 1 ]]; then
      classify_and_repair_after_helm_failure \
        "$chart" "$deployment" "$release" "$dir/helm-upgrade-attempt-${attempt}.log"
      sleep 10
    fi
  done

  # Do not claim success only because old replicas are still Ready.
  err "$chart: desired Helm release could not be made healthy after repair/retry."
}

verify_final_runtime() {
  local chart="$1"
  local deployment="$2"
  local sa="$3"
  local database="$4"
  local dir
  dir="$(svc_dir "$chart")"

  local desired ready updated available pod actual_sa
  desired="$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  ready="$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  updated="$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
    -o jsonpath='{.status.updatedReplicas}' 2>/dev/null)"
  available="$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"

  if [[ -z "$desired" ]]; then
    err "$chart: Deployment missing."
    echo "$chart|MISSING" >> "$HEALTH_MAP"
    return
  fi

  if [[ "${ready:-0}" == "$desired" &&
        "${updated:-0}" == "$desired" &&
        "${available:-0}" == "$desired" ]]; then
    ok "$chart: Deployment $ready/$desired Ready, Updated and Available."
  else
    err "$chart: Deployment not fully converged (ready=${ready:-0}, updated=${updated:-0}, available=${available:-0}, desired=$desired)."
    echo "$chart|NOT_CONVERGED" >> "$HEALTH_MAP"
    return
  fi

  pod="$(kubectl get pods -n "$NAMESPACE" \
    -l "app=${deployment}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"

  actual_sa="$(kubectl get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)"

  [[ "$actual_sa" == "$sa" ]] \
    && ok "$chart: runtime ServiceAccount correct." \
    || err "$chart: runtime ServiceAccount '$actual_sa' != '$sa'"

  kubectl logs "$pod" -n "$NAMESPACE" --tail=300 \
    > "$dir/final-pod.log" 2>&1

  if grep -Eqi 'CrashLoopBackOff|password authentication failed|AccessDeniedException|FailedMount|Unable to obtain connection from database' "$dir/final-pod.log"; then
    err "$chart: application log contains known fatal runtime error."
    echo "$chart|LOG_ERROR" >> "$HEALTH_MAP"
    return
  fi

  if is_db_service "$database"; then
    kubectl exec "$pod" -n "$NAMESPACE" -- \
      sh -c 'test -d /mnt/secrets-store' \
      > "$dir/final-csi-mount.txt" 2>&1

    [[ $? -eq 0 ]] && ok "$chart: CSI mount exists." \
      || err "$chart: CSI mount missing."
  fi

  RUNTIME_HEALTHY=$((RUNTIME_HEALTHY + 1))
  echo "$chart|HEALTHY" >> "$HEALTH_MAP"
}

###############################################################################
# MAIN
###############################################################################

section "BOUTIQUE FINAL CONSOLIDATION"

echo "Project root : $PROJECT_ROOT"
echo "Platform repo: $PLATFORM_ROOT"
echo "Helm root    : $HELM_ROOT"
echo "Logs         : $RUN_ROOT"
echo "Cluster      : $CLUSTER"
echo "Namespace    : $NAMESPACE"

section "PREFLIGHT"

for cmd in kubectl helm aws node grep awk sed; do
  have "$cmd" && ok "$cmd available." || err "$cmd missing."
done

context="$(kubectl config current-context 2>/dev/null)"
[[ "$context" == *"$CLUSTER"* ]] \
  && ok "Correct Kubernetes context." \
  || err "Wrong Kubernetes context: ${context:-none}"

kubectl get namespace "$NAMESPACE" > "$LOG_ROOT/namespace.txt" 2>&1
[[ $? -eq 0 ]] && ok "Namespace accessible." || err "Namespace inaccessible."

verify_existing_cluster_components
backup_platform_code

RDS_ENDPOINT="$(discover_rds_endpoint)"
RDS_SECRET_ARN="$(discover_rds_secret)"

[[ -n "$RDS_ENDPOINT" && "$RDS_ENDPOINT" != "None" ]] \
  && ok "RDS endpoint: $RDS_ENDPOINT" \
  || err "RDS endpoint discovery failed."

[[ -n "$RDS_SECRET_ARN" && "$RDS_SECRET_ARN" != "None" ]] \
  && {
    ok "RDS-managed secret discovered."
    verify_secret_shape "$RDS_SECRET_ARN"
  } \
  || err "RDS-managed secret discovery failed."

if [[ -n "$RDS_SECRET_ARN" && "$RDS_SECRET_ARN" != "None" ]]; then
  write_aws_source_of_truth "$RDS_SECRET_ARN"
  apply_iam_code
  ensure_productcatalog_owns_spc "$RDS_SECRET_ARN"
fi

section "DATABASE / SERVICE MAP"

: > "$DB_MAP"
: > "$HEALTH_MAP"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database source_dir ecr_repo <<< "$entry"

  if is_db_service "$database"; then
    echo "$chart|$database|jdbc:postgresql://${RDS_ENDPOINT}:5432/${database}|$sa" | tee -a "$DB_MAP"
  else
    echo "$chart|NO_DATABASE|-|$sa" | tee -a "$DB_MAP"
  fi
done

section "POD IDENTITY"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database source_dir ecr_repo <<< "$entry"

  is_db_service "$database" || continue

  ensure_pod_identity_association "$chart" "$sa"

  if [[ -n "$RDS_SECRET_ARN" && "$RDS_SECRET_ARN" != "None" ]]; then
    test_pod_identity_with_retry "$chart" "$sa" "$RDS_SECRET_ARN"
  fi
done

section "NORMALIZE HELM CODE"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database source_dir ecr_repo <<< "$entry"

  [[ -f "$HELM_ROOT/$chart/Chart.yaml" ]] || {
    err "$chart: Helm chart missing."
    continue
  }

  if is_db_service "$database"; then
    patch_db_chart "$chart" "$sa" "$database" "$RDS_ENDPOINT"
  fi

  validate_chart "$chart" "$release" "$sa" "$database"
  repair_helm_ownership "$chart" "$release"
done

section "DEPLOY PRODUCT CATALOG / SHARED SECRET PROVIDER"

deploy_service_with_self_heal \
  "productcatalogservice" \
  "productcatalogservice" \
  "productcatalog-dev" \
  "boutique-productcatalogservice" \
  "boutique-productcatalogservice"

if kubectl get secretproviderclass "$SPC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  ok "Shared SecretProviderClass available."
else
  err "Shared SecretProviderClass unavailable after Product Catalog deploy."
fi

ensure_databases "$RDS_ENDPOINT"

section "DEPLOY EVERY REMAINING MICROSERVICE"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database source_dir ecr_repo <<< "$entry"

  [[ "$chart" == "productcatalogservice" ]] && continue

  deploy_service_with_self_heal \
    "$chart" "$deployment" "$release" "$source_dir" "$ecr_repo"
done

section "FINAL RUNTIME VERIFICATION"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database source_dir ecr_repo <<< "$entry"
  verify_final_runtime "$chart" "$deployment" "$sa" "$database"
done

section "FINAL SNAPSHOT"

helm list -n "$NAMESPACE" > "$LOG_ROOT/helm-list.txt" 2>&1
kubectl get deployments -n "$NAMESPACE" -o wide > "$LOG_ROOT/deployments.txt" 2>&1
kubectl get pods -n "$NAMESPACE" -o wide > "$LOG_ROOT/pods.txt" 2>&1
kubectl get serviceaccounts -n "$NAMESPACE" > "$LOG_ROOT/serviceaccounts.txt" 2>&1
kubectl get secretproviderclass -n "$NAMESPACE" > "$LOG_ROOT/secretproviderclasses.txt" 2>&1

aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER" \
  --region "$AWS_REGION" \
  > "$LOG_ROOT/pod-identity-associations.json" 2>&1

cat "$LOG_ROOT/deployments.txt"

cat > "$SUMMARY" <<EOF
Boutique final consolidation summary
====================================

Timestamp                : $STAMP
Project root             : $PROJECT_ROOT
Platform source of truth : $PLATFORM_ROOT
Helm root                : $HELM_ROOT
AWS identity code        : $AWS_CODE_ROOT

Cluster                  : $CLUSTER
Namespace                : $NAMESPACE
RDS instance             : $RDS_INSTANCE
RDS endpoint             : $RDS_ENDPOINT
RDS managed secret       : $RDS_SECRET_ARN
IAM role                 : $ROLE_ARN
SecretProviderClass      : $SPC_NAME
Synced Kubernetes Secret : $SYNCED_SECRET_NAME

Pod Identity passed      : $IDENTITY_PASS
Pod Identity failed      : $IDENTITY_FAIL
Helm rollouts succeeded  : $DEPLOYED
Final healthy services   : $RUNTIME_HEALTHY / ${#SERVICES[@]}
Images built locally     : $BUILT_IMAGES
Known repairs/configured : $FIXED
Warnings                 : $WARNINGS
Errors observed          : $ERRORS

Database map:
$(cat "$DB_MAP")

Health map:
$(cat "$HEALTH_MAP")

Logs:
$RUN_ROOT

Helm backup:
$BACKUP_ROOT
EOF

section "SUMMARY"
cat "$SUMMARY"

echo
echo "The full pass is complete; individual errors never terminated the script."
echo "Permanent Kubernetes configuration is in Helm."
echo "AWS Pod Identity policy/mapping code is in $AWS_CODE_ROOT."
echo "Git Bash remains open."
echo
echo "CI/CD readiness rule:"
echo "  Final healthy services must be ${#SERVICES[@]} / ${#SERVICES[@]}"
echo "  Pod Identity failed must be 0"
echo "  No service may be MISSING / NOT_CONVERGED / LOG_ERROR in health-map.txt"
echo
echo "Diagnostics:"
echo "  $RUN_ROOT"
