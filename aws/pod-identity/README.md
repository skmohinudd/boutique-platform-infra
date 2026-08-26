# Boutique EKS Pod Identity

This directory is the code record for the Boutique database workload AWS identity.

- IAM role: `BoutiqueMicroservicesSecretsAccess`
- EKS cluster: `boutique-dev-eks`
- namespace: `boutique`
- RDS-managed Secrets Manager secret: `arn:aws:secretsmanager:us-east-1:663130434910:secret:rds!db-7e157237-f45d-49ca-b15e-69564c0a712c-nDs6Xi`

Kubernetes ServiceAccounts are created by their Helm charts. EKS Pod Identity
associates only DB workloads with the IAM role. No IRSA role annotation is used.

The JSON policy files are applied by `boutique-final-runtime-consolidation.sh`.
