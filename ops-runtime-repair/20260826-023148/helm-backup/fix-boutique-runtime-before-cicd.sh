#!/usr/bin/env bash
#
# Boutique EKS final runtime repair
# ==================================
# Designed from the current full Boutique project archive + the runtime logs.
#
# Run from ANY directory in Git Bash:
#   bash fix-boutique-runtime-before-cicd.sh
#
# What this script fixes:
# - Finds the real Helm root automatically (no more "Helm chart not found" issue).
# - Keeps the REAL existing Helm release names.
# - Reuses every service's EXISTING Helm ServiceAccount.
# - Creates/repairs EKS Pod Identity associations for DB services.
# - Waits/retries Pod Identity propagation (fixes the Shipping test race).
# - Reuses the EXISTING Secrets Store CSI driver/provider; installs nothing duplicate.
# - Keeps boutique-rds-secrets owned by productcatalog-dev (no ownership transfer conflict).
# - Dynamically discovers the RDS endpoint and the RDS-managed Secrets Manager secret ARN.
# - Removes static DB passwords from all DB Helm charts.
# - Uses dedicated DB names/JDBC URLs per DB service.
# - Ensures those databases exist and grants the RDS master user access.
# - Adds DB_URL + rotating DB_USERNAME/DB_PASSWORD to the workloads.
# - Adds the CSI mount to every DB workload.
# - Safely repairs known same-service Helm ownership metadata.
# - Uses Helm server-side apply + force-conflicts for the old kubectl field-manager migration.
# - Preserves the image CURRENTLY running in EKS instead of reverting to an old values.yaml tag.
# - Continues after individual errors and stores full diagnostics outside helm/.
#
# It DOES NOT:
# - create GitHub Actions workflows
# - create GitHub repo secrets
# - configure Nexus/Sonar
# - install another CSI driver/provider
# - move boutique-rds-secrets to another Helm release
# - delete application Deployments/Services/HPAs/PDBs/NetworkPolicies/ServiceAccounts
#
# DB architecture used by the actual source code + Helm charts:
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

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-663130434910}"
CLUSTER="${CLUSTER:-boutique-dev-eks}"
NAMESPACE="${NAMESPACE:-boutique}"
RDS_INSTANCE="${RDS_INSTANCE:-boutique-dev-postgres}"

POD_ROLE_NAME="${POD_ROLE_NAME:-BoutiqueMicroservicesSecretsAccess}"
POD_ROLE_POLICY_NAME="${POD_ROLE_POLICY_NAME:-BoutiqueMicroservicesSecretsAccessPolicy}"

SPC_NAME="${SPC_NAME:-boutique-rds-secrets}"
SYNCED_SECRET_NAME="${SYNCED_SECRET_NAME:-boutique-rds-credentials}"

HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-240s}"
POD_IDENTITY_RETRIES="${POD_IDENTITY_RETRIES:-5}"
POD_IDENTITY_RETRY_DELAY="${POD_IDENTITY_RETRY_DELAY:-15}"

# chart|deployment|release|serviceAccount|database
SERVICES=(
  "productcatalogservice|productcatalogservice|productcatalog-dev|productcatalogservice-sa|product_catalog_db"
  "inventoryservice|inventoryservice|inventoryservice|inventoryservice-sa|inventory_db"
  "userservice|userservice|user-dev|userservice-sa|user_db"
  "cartservice|cartservice|cartservice-dev|cartservice-sa|-"
  "orderservice|orderservice|orderservice-dev|orderservice-sa|order_db"
  "paymentservice|paymentservice|paymentservice-dev|paymentservice-sa|payment_db"
  "checkoutservice|checkoutservice|checkoutservice-dev|checkoutservice-sa|-"
  "shippingservice|shippingservice|shippingservice-dev|shippingservice-sa|shipping_db"
  "notificationservice|notificationservice|notificationservice-dev|notificationservice-sa|-"
  "recommendationservice|recommendationservice|recommendationservice-dev|recommendationservice-sa|-"
)

ERRORS=0
WARNINGS=0
FIXED=0
DEPLOYED=0
SKIPPED=0
IDENTITY_PASS=0
IDENTITY_FAIL=0

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

is_db_service() {
  [[ "$1" != "-" ]]
}

have() {
  command -v "$1" >/dev/null 2>&1
}

contains_alias() {
  local current="$1"
  shift
  local a
  for a in "$@"; do
    [[ "$current" == "$a" ]] && return 0
  done
  return 1
}

find_project_root() {
  local candidates=(
    "/c/boutique-project/Projects"
    "$(pwd)"
    "$(pwd)/Projects"
  )

  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c/boutique-platform-infra/helm/productcatalogservice/Chart.yaml" ]]; then
      echo "$c"
      return 0
    fi
  done

  # Last-resort shallow discovery around current location.
  local found
  found="$(find "$(pwd)" -maxdepth 4 \
    -path '*/boutique-platform-infra/helm/productcatalogservice/Chart.yaml' \
    -print -quit 2>/dev/null)"

  if [[ -n "$found" ]]; then
    dirname "$(dirname "$(dirname "$(dirname "$found")")")"
    return 0
  fi

  return 1
}

PROJECT_ROOT="$(find_project_root)"
if [[ -z "$PROJECT_ROOT" ]]; then
  echo "ERROR: Could not locate boutique-platform-infra/helm."
  echo "Expected project root similar to /c/boutique-project/Projects"
  echo "Git Bash remains open."
  return 0 2>/dev/null || true
fi

PLATFORM_ROOT="$PROJECT_ROOT/boutique-platform-infra"
HELM_ROOT="$PLATFORM_ROOT/helm"
STAMP="$(date +%Y%m%d-%H%M%S)"
OPS_ROOT="$PLATFORM_ROOT/ops-runtime-repair/$STAMP"
LOG_ROOT="$OPS_ROOT/logs"
BACKUP_ROOT="$OPS_ROOT/helm-backup"
MASTER_LOG="$LOG_ROOT/master.log"
SUMMARY="$OPS_ROOT/summary.txt"
DB_MAP="$OPS_ROOT/database-map.txt"

mkdir -p "$LOG_ROOT" "$BACKUP_ROOT"
exec > >(tee -a "$MASTER_LOG") 2>&1

service_log_dir() {
  local svc="$1"
  mkdir -p "$LOG_ROOT/$svc"
  echo "$LOG_ROOT/$svc"
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

  if ! have node; then
    warn "Node.js not found; JSON key verification skipped."
    return
  fi

  local keys
  keys="$(aws secretsmanager get-secret-value \
    --secret-id "$arn" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text 2>/dev/null \
    | node -e '
let s="";
process.stdin.on("data", d => s += d);
process.stdin.on("end", () => {
  try {
    const j=JSON.parse(s);
    console.log(Object.keys(j).sort().join(","));
  } catch(e) {
    process.exit(2);
  }
});' 2>/dev/null)"

  if [[ ",$keys," == *",username,"* && ",$keys," == *",password,"* ]]; then
    ok "RDS Secrets Manager secret contains username/password."
  else
    err "RDS secret JSON does not contain expected username/password keys. Keys: ${keys:-unknown}"
  fi
}

verify_existing_csi() {
  section "VERIFY EXISTING SECRETS INFRASTRUCTURE"

  kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io \
    > "$LOG_ROOT/secretproviderclass-crd.txt" 2>&1
  [[ $? -eq 0 ]] && ok "SecretProviderClass CRD exists." \
    || err "SecretProviderClass CRD missing."

  kubectl get csidriver secrets-store.csi.k8s.io \
    > "$LOG_ROOT/secrets-store-csi-driver.txt" 2>&1
  [[ $? -eq 0 ]] && ok "Secrets Store CSI driver exists." \
    || err "Secrets Store CSI driver missing."

  kubectl get pods -n kube-system -o wide \
    > "$LOG_ROOT/kube-system-pods.txt" 2>&1

  if grep -Eqi 'secrets-store.*provider.*aws|provider-aws|secrets-store-csi-driver' \
    "$LOG_ROOT/kube-system-pods.txt"; then
    ok "Existing Secrets Store components detected; nothing will be reinstalled."
  else
    warn "Could not identify Secrets Store provider pod by name. No duplicate installation will be attempted."
  fi

  aws eks describe-addon \
    --cluster-name "$CLUSTER" \
    --addon-name eks-pod-identity-agent \
    --region "$AWS_REGION" \
    > "$LOG_ROOT/pod-identity-addon.json" 2>&1

  [[ $? -eq 0 ]] && ok "EKS Pod Identity Agent add-on exists." \
    || warn "Could not verify EKS Pod Identity Agent add-on through AWS CLI."
}

configure_iam_role() {
  local secret_arn="$1"
  local trust="$LOG_ROOT/pod-identity-trust.json"
  local policy="$LOG_ROOT/pod-identity-secrets-policy.json"

  section "VERIFY / NORMALIZE POD IAM ROLE"

  ROLE_ARN="$(aws iam get-role \
    --role-name "$POD_ROLE_NAME" \
    --query Role.Arn \
    --output text 2>/dev/null)"

  if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
    err "IAM role $POD_ROLE_NAME does not exist."
    ROLE_ARN=""
    return
  fi

  ok "IAM role found: $ROLE_ARN"

  cat > "$trust" <<'EOF'
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

  cat > "$policy" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadRDSManagedSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ],
      "Resource": "${secret_arn}"
    },
    {
      "Sid": "FutureCustomerManagedKMSViaSecretsManager",
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

  aws iam update-assume-role-policy \
    --role-name "$POD_ROLE_NAME" \
    --policy-document "file://$trust" \
    > "$LOG_ROOT/iam-trust-update.log" 2>&1
  [[ $? -eq 0 ]] && {
    ok "Pod Identity trust policy correct."
    FIXED=$((FIXED + 1))
  } || err "Failed to update IAM trust policy."

  aws iam put-role-policy \
    --role-name "$POD_ROLE_NAME" \
    --policy-name "$POD_ROLE_POLICY_NAME" \
    --policy-document "file://$policy" \
    > "$LOG_ROOT/iam-policy-update.log" 2>&1
  [[ $? -eq 0 ]] && {
    ok "Secrets Manager/KMS inline policy correct."
    FIXED=$((FIXED + 1))
  } || err "Failed to update IAM inline policy."
}

backup_helm() {
  section "BACKUP CURRENT HELM"

  cp -a "$HELM_ROOT/." "$BACKUP_ROOT/" 2>"$LOG_ROOT/backup.err"
  [[ $? -eq 0 ]] && ok "Helm backup stored at $BACKUP_ROOT" \
    || err "Could not fully backup Helm directory."
}

normalize_product_secret_provider() {
  local secret_arn="$1"
  local values="$HELM_ROOT/productcatalogservice/values.yaml"
  local spc="$HELM_ROOT/productcatalogservice/templates/secretproviderclass.yaml"

  section "KEEP EXISTING SHARED SECRETPROVIDERCLASS OWNERSHIP"

  # IMPORTANT: productcatalog-dev already owns boutique-rds-secrets.
  # We KEEP that ownership to avoid the exact conflict from the previous run.
  if [[ ! -f "$spc" ]]; then
    cat > "$spc" <<'EOF'
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
    FIXED=$((FIXED + 1))
  fi

  node - "$values" "$secret_arn" "$AWS_REGION" "$SPC_NAME" "$SYNCED_SECRET_NAME" <<'NODE'
const fs=require("fs");
const [file,arn,region,spc,secret]=process.argv.slice(2);
let s=fs.readFileSync(file,"utf8").replace(/\r\n/g,"\n");

function replaceBlock(name, block) {
  const re=new RegExp("^"+name+":\\n(?:(?:[ \\t]+.*)\\n)*","m");
  if (re.test(s)) s=s.replace(re,block+"\n");
  else s=s.replace(/\s*$/,"\n\n")+block+"\n";
}

const url=(s.match(/^[ \t]*url:[ \t]*["']?([^"'\n]+)["']?/m)||[])[1] || "";

replaceBlock("database",
`database:
  url: "${url}"
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

  [[ $? -eq 0 ]] && ok "Product Catalog keeps ownership of $SPC_NAME with current RDS secret ARN." \
    || err "Could not normalize Product Catalog secret-provider values."
}

ensure_association() {
  local service="$1"
  local sa="$2"
  local dir
  dir="$(service_log_dir "$service")"

  if [[ -z "$ROLE_ARN" ]]; then
    err "$service: IAM role unavailable; Pod Identity association skipped."
    return
  fi

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
      ok "$service: Pod Identity association created for $sa."
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

test_association_with_retry() {
  local service="$1"
  local sa="$2"
  local secret_arn="$3"
  local dir
  dir="$(service_log_dir "$service")"

  local attempt pod sts_arn rc_secret
  for attempt in $(seq 1 "$POD_IDENTITY_RETRIES"); do
    pod="identity-${service}-${attempt}"
    pod="${pod:0:63}"

    echo "$service: Pod Identity test attempt $attempt/$POD_IDENTITY_RETRIES"

    kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found \
      >/dev/null 2>&1

    kubectl run "$pod" \
      -n "$NAMESPACE" \
      --image=amazon/aws-cli:2.17.52 \
      --restart=Never \
      --overrides="{\"spec\":{\"serviceAccountName\":\"${sa}\"}}" \
      --command -- sleep 180 \
      > "$dir/identity-attempt-${attempt}-create.log" 2>&1

    if [[ $? -ne 0 ]]; then
      sleep "$POD_IDENTITY_RETRY_DELAY"
      continue
    fi

    local phase=""
    for _ in {1..45}; do
      phase="$(kubectl get pod "$pod" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)"
      [[ "$phase" == "Running" ]] && break
      sleep 2
    done

    if [[ "$phase" != "Running" ]]; then
      kubectl describe pod "$pod" -n "$NAMESPACE" \
        > "$dir/identity-attempt-${attempt}-describe.log" 2>&1
      kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found \
        >/dev/null 2>&1
      sleep "$POD_IDENTITY_RETRY_DELAY"
      continue
    fi

    sts_arn="$(kubectl exec "$pod" -n "$NAMESPACE" -- \
      aws sts get-caller-identity --query Arn --output text 2>/dev/null)"

    echo "$sts_arn" > "$dir/identity-attempt-${attempt}-sts.txt"

    kubectl exec "$pod" -n "$NAMESPACE" -- \
      aws secretsmanager get-secret-value \
        --secret-id "$secret_arn" \
        --region "$AWS_REGION" \
        --query VersionId \
        --output text \
      > "$dir/identity-attempt-${attempt}-secret.txt" 2>&1
    rc_secret=$?

    kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found \
      >/dev/null 2>&1

    if [[ "$sts_arn" == *"assumed-role/${POD_ROLE_NAME}/"* && $rc_secret -eq 0 ]]; then
      ok "$service: ServiceAccount -> Pod Identity -> IAM -> Secrets Manager verified."
      IDENTITY_PASS=$((IDENTITY_PASS + 1))
      return
    fi

    # This specifically handles the Shipping failure seen in the old logs:
    # association existed, but the first temporary pod still received the node role.
    echo "$service: association not propagated yet; retrying after ${POD_IDENTITY_RETRY_DELAY}s."
    sleep "$POD_IDENTITY_RETRY_DELAY"
  done

  err "$service: Pod Identity did not verify after $POD_IDENTITY_RETRIES attempts."
  IDENTITY_FAIL=$((IDENTITY_FAIL + 1))
}

patch_db_chart() {
  local chart="$1"
  local sa="$2"
  local database="$3"
  local endpoint="$4"
  local values="$HELM_ROOT/$chart/values.yaml"
  local deployment="$HELM_ROOT/$chart/templates/deployment.yaml"
  local static_secret="$HELM_ROOT/$chart/templates/secret.yaml"
  local jdbc="jdbc:postgresql://${endpoint}:5432/${database}"

  local dir
  dir="$(service_log_dir "$chart")"

  if [[ ! -f "$values" || ! -f "$deployment" ]]; then
    err "$chart: Helm values/deployment missing."
    return
  fi

  node - "$values" "$deployment" "$sa" "$jdbc" "$SYNCED_SECRET_NAME" "$SPC_NAME" <<'NODE'
const fs=require("fs");
const [valuesFile,deployFile,sa,jdbc,k8sSecret,spcName]=process.argv.slice(2);

function blockReplace(text,name,block) {
  const re=new RegExp("^"+name+":\\n(?:(?:[ \\t]+.*)\\n)*","m");
  if (re.test(text)) return text.replace(re,block+"\n");
  return text.replace(/\s*$/,"\n\n")+block+"\n";
}

let v=fs.readFileSync(valuesFile,"utf8").replace(/\r\n/g,"\n");

// Preserve all non-DB values. Replace only the database and awsSecrets blocks.
v=blockReplace(v,"database",
`database:
  url: "${jdbc}"
  kubernetesSecretName: ${k8sSecret}`);

v=blockReplace(v,"awsSecrets",
`awsSecrets:
  enabled: true
  secretProviderClassName: ${spcName}
  mountPath: /mnt/secrets-store`);

// Keep the chart's existing ServiceAccount identity.
v=v.replace(
  /(serviceAccount:\n(?:(?:[ \t]+.*)\n)*?[ \t]+name:)[^\n]*/,
  `$1 ${sa}`
);

fs.writeFileSync(valuesFile,v);

let lines=fs.readFileSync(deployFile,"utf8").replace(/\r\n/g,"\n").split("\n");

// Remove old database secretRef from envFrom.
for (let i=0;i<lines.length;i++) {
  if (lines[i].trim()==="- secretRef:" &&
      lines[i+1] && lines[i+1].includes(".Values.database.")) {
    lines.splice(i,2);
    i--;
  }
}

// Remove previously generated DB_URL / DB_USERNAME / DB_PASSWORD entries.
const dbNames=new Set(["DB_URL","DB_USERNAME","DB_PASSWORD"]);
for (let i=0;i<lines.length;i++) {
  const m=lines[i].match(/^(\s*)-\s+name:\s+(DB_URL|DB_USERNAME|DB_PASSWORD)\s*$/);
  if (!m) continue;

  const indent=m[1].length;
  let j=i+1;
  while (j<lines.length) {
    const next=lines[j];
    if (next.trim()==="") { j++; continue; }
    const nextIndent=(next.match(/^(\s*)/)||["",""])[1].length;
    if (nextIndent<=indent) break;
    j++;
  }
  lines.splice(i,j-i);
  i--;
}

const dbEnv=[
"            # Service-specific JDBC URL; not a secret.",
"            - name: DB_URL",
"              value: {{ .Values.database.url | quote }}",
"            # Rotating RDS credentials synchronized from AWS Secrets Manager.",
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

// Find or create container-level env:.
let envIndex=lines.findIndex(x => x==="          env:");
if (envIndex>=0) {
  lines.splice(envIndex+1,0,...dbEnv);
} else {
  // Insert after complete envFrom block.
  const envFrom=lines.findIndex(x => x==="          envFrom:");
  if (envFrom<0) throw new Error("container envFrom block not found");

  let j=envFrom+1;
  while (j<lines.length) {
    if (lines[j].trim()==="") { j++; continue; }
    const indent=(lines[j].match(/^(\s*)/)||["",""])[1].length;
    if (indent<=10) break;
    j++;
  }

  lines.splice(j,0,"          env:",...dbEnv);
}

// Add CSI container mount if absent.
if (!lines.some(x => x.includes("mountPath: {{ .Values.awsSecrets.mountPath }}"))) {
  const resources=lines.findIndex(x => x==="          resources:");
  if (resources<0) throw new Error("container resources block not found");

  lines.splice(resources,0,
    "          # Mount AWS Secrets Manager values through the existing CSI driver.",
    "          volumeMounts:",
    "            - name: aws-secrets-store",
    "              mountPath: {{ .Values.awsSecrets.mountPath }}",
    "              readOnly: true"
  );
}

// Add Pod-level CSI volume if absent.
if (!lines.some(x => x.includes("driver: secrets-store.csi.k8s.io"))) {
  while (lines.length && lines[lines.length-1].trim()==="") lines.pop();

  lines.push(
    "",
    "      # Namespace-wide SecretProviderClass is reused by all DB workloads.",
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
    err "$chart: failed to patch DB Helm configuration."
    return
  fi

  # Product Catalog already has no static secret.yaml. Remove stale password
  # templates from the other DB charts.
  if [[ -f "$static_secret" ]]; then
    rm -f "$static_secret"
    ok "$chart: removed static DB password Secret template."
  fi

  echo "$chart|$database|$jdbc|$sa" >> "$DB_MAP"
  ok "$chart: JDBC = $jdbc"
  FIXED=$((FIXED + 1))
}

validate_chart() {
  local chart="$1"
  local release="$2"
  local sa="$3"
  local database="$4"
  local dir
  dir="$(service_log_dir "$chart")"

  helm lint "$HELM_ROOT/$chart" > "$dir/helm-lint.log" 2>&1
  if [[ $? -eq 0 ]]; then
    ok "$chart: helm lint."
  else
    err "$chart: helm lint failed. See $dir/helm-lint.log"
  fi

  helm template "$release" "$HELM_ROOT/$chart" \
    --namespace "$NAMESPACE" \
    > "$dir/rendered.yaml" 2> "$dir/helm-template.err"

  if [[ $? -ne 0 ]]; then
    err "$chart: helm template failed."
    return
  fi

  grep -q "serviceAccountName: ${sa}" "$dir/rendered.yaml"
  [[ $? -eq 0 ]] && ok "$chart: rendered ServiceAccount = $sa" \
    || err "$chart: rendered ServiceAccount does not match $sa"

  if is_db_service "$database"; then
    grep -q 'name: DB_URL' "$dir/rendered.yaml" \
      || err "$chart: rendered Deployment missing DB_URL"

    grep -q 'name: DB_USERNAME' "$dir/rendered.yaml" \
      || err "$chart: rendered Deployment missing DB_USERNAME"

    grep -q 'name: DB_PASSWORD' "$dir/rendered.yaml" \
      || err "$chart: rendered Deployment missing DB_PASSWORD"

    grep -q 'driver: secrets-store.csi.k8s.io' "$dir/rendered.yaml" \
      || err "$chart: rendered Deployment missing Secrets Store CSI volume"

    grep -q 'port: 5432' "$dir/rendered.yaml" \
      || warn "$chart: NetworkPolicy render does not show PostgreSQL TCP/5432"
  fi
}

repair_helm_ownership() {
  local chart="$1"
  local release="$2"
  local dir
  dir="$(service_log_dir "$chart")"

  local resources resource owner managed ns
  resources="$(helm template "$release" "$HELM_ROOT/$chart" \
    --namespace "$NAMESPACE" 2>/dev/null \
    | kubectl apply --dry-run=client -f - -o name 2>/dev/null \
    | sort -u)"

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
      # The shared SecretProviderClass intentionally remains productcatalog-dev-owned.
      if [[ "$resource" == "secretproviderclass.secrets-store.csi.x-k8s.io/${SPC_NAME}" &&
            "$chart" == "productcatalogservice" &&
            "$owner" == "productcatalog-dev" ]]; then
        continue
      fi

      err "$chart: refusing to steal $resource from unrelated release '$owner'."
      continue
    fi

    if [[ "$owner" == "$release" && "$managed" == "Helm" && "$ns" == "$NAMESPACE" ]]; then
      continue
    fi

    kubectl label "$resource" -n "$NAMESPACE" \
      app.kubernetes.io/managed-by=Helm --overwrite \
      > "$dir/ownership-label.log" 2>&1
    local a=$?

    kubectl annotate "$resource" -n "$NAMESPACE" \
      meta.helm.sh/release-name="$release" \
      meta.helm.sh/release-namespace="$NAMESPACE" \
      --overwrite \
      > "$dir/ownership-annotate.log" 2>&1
    local b=$?

    if [[ $a -eq 0 && $b -eq 0 ]]; then
      FIXED=$((FIXED + 1))
      ok "$chart: Helm ownership corrected for $resource"
    else
      err "$chart: Helm ownership correction failed for $resource"
    fi
  done <<< "$resources"
}

current_image() {
  local deployment="$1"
  kubectl get deployment "$deployment" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

capture_runtime() {
  local chart="$1"
  local deployment="$2"
  local dir
  dir="$(service_log_dir "$chart")"

  kubectl get deployment "$deployment" -n "$NAMESPACE" -o yaml \
    > "$dir/deployment-current.yaml" 2>&1

  kubectl get pods -n "$NAMESPACE" -l "app=${deployment}" -o wide \
    > "$dir/pods-current.txt" 2>&1

  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
    > "$dir/events.txt" 2>&1
}

capture_bad_pod() {
  local chart="$1"
  local deployment="$2"
  local dir
  dir="$(service_log_dir "$chart")"

  local pod
  pod="$(kubectl get pods -n "$NAMESPACE" \
    -l "app=${deployment}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"

  [[ -n "$pod" ]] || return

  kubectl describe pod "$pod" -n "$NAMESPACE" \
    > "$dir/newest-pod-describe.txt" 2>&1

  kubectl logs "$pod" -n "$NAMESPACE" --all-containers --tail=300 \
    > "$dir/newest-pod.log" 2>&1

  kubectl logs "$pod" -n "$NAMESPACE" --all-containers --previous --tail=300 \
    > "$dir/newest-pod-previous.log" 2>&1
}

deploy_existing_chart() {
  local chart="$1"
  local deployment="$2"
  local release="$3"
  local dir
  dir="$(service_log_dir "$chart")"

  capture_runtime "$chart" "$deployment"

  local image repo tag
  image="$(current_image "$deployment")"

  if [[ -z "$image" ]]; then
    warn "$chart: Deployment does not currently exist; skipped to avoid unexpectedly deploying an optional service."
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  repo="${image%:*}"
  tag="${image##*:}"

  echo "$chart: preserving current image $image"

  helm upgrade --install "$release" "$HELM_ROOT/$chart" \
    --namespace "$NAMESPACE" \
    --set image.repository="$repo" \
    --set image.tag="$tag" \
    --server-side=true \
    --force-conflicts \
    --wait \
    --timeout "$HELM_TIMEOUT" \
    > "$dir/helm-upgrade.log" 2>&1

  if [[ $? -ne 0 ]]; then
    err "$chart: Helm deployment failed."
    capture_bad_pod "$chart" "$deployment"
    return
  fi

  kubectl rollout status "deployment/$deployment" \
    -n "$NAMESPACE" \
    --timeout="$ROLLOUT_TIMEOUT" \
    > "$dir/rollout.log" 2>&1

  if [[ $? -ne 0 ]]; then
    err "$chart: rollout failed."
    capture_bad_pod "$chart" "$deployment"
    return
  fi

  DEPLOYED=$((DEPLOYED + 1))
  ok "$chart: deployment successfully rolled out."

  capture_runtime "$chart" "$deployment"
  capture_bad_pod "$chart" "$deployment"
}

verify_db_runtime() {
  local chart="$1"
  local deployment="$2"
  local expected_sa="$3"
  local database="$4"
  local dir
  dir="$(service_log_dir "$chart")"

  local pod actual_sa
  pod="$(kubectl get pods -n "$NAMESPACE" \
    -l "app=${deployment}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"

  [[ -n "$pod" ]] || {
    warn "$chart: no pod found for final DB runtime verification."
    return
  }

  actual_sa="$(kubectl get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)"

  [[ "$actual_sa" == "$expected_sa" ]] \
    && ok "$chart: runtime ServiceAccount correct." \
    || err "$chart: runtime ServiceAccount '$actual_sa' != '$expected_sa'"

  kubectl exec "$pod" -n "$NAMESPACE" -- \
    sh -c 'test -d /mnt/secrets-store' \
    > "$dir/csi-mount-test.log" 2>&1

  [[ $? -eq 0 ]] && ok "$chart: CSI mount exists." \
    || err "$chart: CSI mount missing."

  kubectl logs "$pod" -n "$NAMESPACE" --tail=250 \
    > "$dir/final-pod.log" 2>&1

  if grep -Eqi \
    'password authentication failed|AccessDeniedException|FailedMount|Unable to obtain connection from database' \
    "$dir/final-pod.log"; then
    err "$chart: final logs still contain DB/secret failure."
  else
    ok "$chart: no DB password/Secrets Manager failure detected."
  fi
}

ensure_databases() {
  local endpoint="$1"
  local bootstrap_sa="productcatalogservice-sa"
  local pod="boutique-db-bootstrap"
  local yaml="$LOG_ROOT/db-bootstrap-pod.yaml"

  section "ENSURE DEDICATED DATABASES"

  if ! kubectl get serviceaccount "$bootstrap_sa" -n "$NAMESPACE" >/dev/null 2>&1; then
    err "Bootstrap ServiceAccount $bootstrap_sa missing."
    return
  fi

  if ! kubectl get secretproviderclass "$SPC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    err "SecretProviderClass $SPC_NAME missing; database bootstrap skipped."
    return
  fi

  cat > "$yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  serviceAccountName: ${bootstrap_sa}
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
              echo "EXISTS \$db"
            else
              echo "CREATING \$db"
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

  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found \
    >/dev/null 2>&1

  kubectl create -f "$yaml" > "$LOG_ROOT/db-bootstrap-create.log" 2>&1

  if [[ $? -ne 0 ]]; then
    err "Could not create temporary DB bootstrap pod."
    return
  fi

  local phase=""
  for _ in {1..90}; do
    phase="$(kubectl get pod "$pod" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
  done

  kubectl logs "$pod" -n "$NAMESPACE" \
    > "$LOG_ROOT/db-bootstrap.log" 2>&1

  kubectl describe pod "$pod" -n "$NAMESPACE" \
    > "$LOG_ROOT/db-bootstrap-describe.txt" 2>&1

  if grep -Eqi 'FATAL:|permission denied|AccessDenied|FailedMount|could not connect' \
    "$LOG_ROOT/db-bootstrap.log"; then
    err "Database bootstrap reported errors. See $LOG_ROOT/db-bootstrap.log"
  else
    ok "Dedicated databases verified/created."
  fi

  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found \
    >/dev/null 2>&1
}

###############################################################################
# MAIN
###############################################################################

section "BOUTIQUE FINAL RUNTIME REPAIR"

echo "Project root : $PROJECT_ROOT"
echo "Helm root    : $HELM_ROOT"
echo "Cluster      : $CLUSTER"
echo "Namespace    : $NAMESPACE"
echo "Logs         : $OPS_ROOT"

section "PREFLIGHT"

for cmd in kubectl helm aws node grep sed awk; do
  if have "$cmd"; then
    ok "$cmd available."
  else
    err "$cmd is missing."
  fi
done

context="$(kubectl config current-context 2>/dev/null)"
[[ "$context" == *"$CLUSTER"* ]] \
  && ok "Correct Kubernetes context." \
  || err "Wrong Kubernetes context: ${context:-none}"

kubectl get namespace "$NAMESPACE" > "$LOG_ROOT/namespace.txt" 2>&1
[[ $? -eq 0 ]] && ok "Namespace accessible." \
  || err "Namespace $NAMESPACE is not accessible."

verify_existing_csi

RDS_ENDPOINT="$(discover_rds_endpoint)"
RDS_SECRET_ARN="$(discover_rds_secret)"

if [[ -n "$RDS_ENDPOINT" && "$RDS_ENDPOINT" != "None" ]]; then
  ok "RDS endpoint discovered: $RDS_ENDPOINT"
else
  err "Could not discover RDS endpoint."
fi

if [[ -n "$RDS_SECRET_ARN" && "$RDS_SECRET_ARN" != "None" ]]; then
  ok "RDS-managed secret discovered: $RDS_SECRET_ARN"
  verify_secret_shape "$RDS_SECRET_ARN"
else
  err "Could not discover RDS-managed Secrets Manager secret."
fi

backup_helm

if [[ -n "$RDS_SECRET_ARN" && "$RDS_SECRET_ARN" != "None" ]]; then
  configure_iam_role "$RDS_SECRET_ARN"
  normalize_product_secret_provider "$RDS_SECRET_ARN"
fi

section "DATABASE MAP"

: > "$DB_MAP"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database <<< "$entry"

  if is_db_service "$database"; then
    jdbc="jdbc:postgresql://${RDS_ENDPOINT}:5432/${database}"
    echo "$chart|$database|$jdbc|$sa" | tee -a "$DB_MAP"
  else
    echo "$chart|NO_DATABASE|-|$sa" | tee -a "$DB_MAP"
  fi
done

section "POD IDENTITY FOR DB SERVICES"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database <<< "$entry"

  is_db_service "$database" || continue

  ensure_association "$chart" "$sa"

  if [[ -n "$RDS_SECRET_ARN" && "$RDS_SECRET_ARN" != "None" ]]; then
    test_association_with_retry "$chart" "$sa" "$RDS_SECRET_ARN"
  fi
done

section "PATCH DB HELM CHARTS"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database <<< "$entry"

  if is_db_service "$database"; then
    patch_db_chart "$chart" "$sa" "$database" "$RDS_ENDPOINT"
  fi
done

section "VALIDATE ALL HELM CHARTS"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database <<< "$entry"

  if [[ ! -f "$HELM_ROOT/$chart/Chart.yaml" ]]; then
    warn "$chart chart missing."
    continue
  fi

  validate_chart "$chart" "$release" "$sa" "$database"
  repair_helm_ownership "$chart" "$release"
done

# Product Catalog is already the proven owner of the shared SecretProviderClass.
# Deploy it first so the SPC/synced secret remain healthy before other DB services.
section "DEPLOY PRODUCT CATALOG FIRST"

deploy_existing_chart "productcatalogservice" "productcatalogservice" "productcatalog-dev"
verify_db_runtime "productcatalogservice" "productcatalogservice" \
  "productcatalogservice-sa" "product_catalog_db"

ensure_databases "$RDS_ENDPOINT"

section "DEPLOY REMAINING EXISTING SERVICES"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r chart deployment release sa database <<< "$entry"

  [[ "$chart" == "productcatalogservice" ]] && continue

  deploy_existing_chart "$chart" "$deployment" "$release"

  if is_db_service "$database"; then
    verify_db_runtime "$chart" "$deployment" "$sa" "$database"
  fi
done

section "FINAL SNAPSHOT"

helm list -n "$NAMESPACE" > "$LOG_ROOT/helm-list-final.txt" 2>&1
kubectl get deployments -n "$NAMESPACE" -o wide > "$LOG_ROOT/deployments-final.txt" 2>&1
kubectl get pods -n "$NAMESPACE" -o wide > "$LOG_ROOT/pods-final.txt" 2>&1
kubectl get serviceaccounts -n "$NAMESPACE" > "$LOG_ROOT/serviceaccounts-final.txt" 2>&1
kubectl get secretproviderclass -n "$NAMESPACE" > "$LOG_ROOT/secretproviderclasses-final.txt" 2>&1
kubectl get secret "$SYNCED_SECRET_NAME" -n "$NAMESPACE" > "$LOG_ROOT/synced-secret-final.txt" 2>&1

aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER" \
  --region "$AWS_REGION" \
  > "$LOG_ROOT/pod-identity-associations-final.json" 2>&1

cat "$LOG_ROOT/deployments-final.txt"

cat > "$SUMMARY" <<EOF
Boutique final runtime repair
=============================

Timestamp                  : $STAMP
Project root               : $PROJECT_ROOT
Helm root                  : $HELM_ROOT
EKS cluster                : $CLUSTER
Namespace                  : $NAMESPACE
RDS instance               : $RDS_INSTANCE
RDS endpoint               : $RDS_ENDPOINT
RDS managed secret         : $RDS_SECRET_ARN
Pod IAM role               : $ROLE_ARN
SecretProviderClass        : $SPC_NAME
Synced Kubernetes Secret   : $SYNCED_SECRET_NAME

Pod Identity tests passed  : $IDENTITY_PASS
Pod Identity tests failed  : $IDENTITY_FAIL
Successful Helm rollouts   : $DEPLOYED
Skipped optional/missing   : $SKIPPED
Fixed/configured items     : $FIXED
Warnings                   : $WARNINGS
Errors                     : $ERRORS

Database map:
$(cat "$DB_MAP")

All logs:
$OPS_ROOT

Helm backup:
$BACKUP_ROOT
EOF

section "SUMMARY"
cat "$SUMMARY"

echo
echo "Full script pass completed."
echo "Individual failures did NOT stop the remaining services."
echo "Git Bash remains open."
echo "For debugging, use:"
echo "  $OPS_ROOT"
