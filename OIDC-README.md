# 🔐 GitHub Actions → AWS OIDC Federation

## Eliminating Static Credentials from CI/CD Pipelines

---

## Overview

This document details the implementation of OpenID Connect (OIDC) federation between GitHub Actions and AWS IAM for this portfolio's CI/CD pipeline. The same pattern has been implemented in enterprise production environments for clients requiring zero long-lived credential exposure in their pipelines.

**Before:** Long-lived AWS access keys stored as GitHub Secrets
**After:** Short-lived tokens issued at runtime via OIDC — no stored credentials anywhere

---

## The Problem with Static Credentials

The original pipeline authenticated to AWS using `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` stored as GitHub Secrets:

```yaml
# ❌ Old approach — static keys
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: us-east-1
```

**Risks of this approach:**
- Keys never expire — a leaked key gives permanent AWS access until manually rotated
- Keys stored at rest in GitHub's secret store — an additional attack surface
- If the GitHub account is compromised, AWS access is compromised
- Key rotation is a manual operational burden
- No guarantee keys are scoped correctly over time

---

## The Solution — OIDC Federation

GitHub Actions and AWS establish a trust relationship using OpenID Connect. When a workflow runs, GitHub's OIDC provider issues a signed JWT token that AWS verifies directly. No credentials are stored anywhere.

```
┌─────────────────────────────────────────────────────────────┐
│                      OIDC Flow                              │
│                                                             │
│  GitHub Actions                                             │
│       │                                                     │
│       │  1. Request OIDC token from GitHub                  │
│       ▼                                                     │
│  GitHub OIDC Provider                                       │
│  token.actions.githubusercontent.com                        │
│       │                                                     │
│       │  2. Issues signed JWT containing:                   │
│       │     - repo: rerkted/aws-server                      │
│       │     - ref: refs/heads/main                          │
│       │     - environment: production                       │
│       ▼                                                     │
│  AWS STS (AssumeRoleWithWebIdentity)                        │
│       │                                                     │
│       │  3. Validates JWT signature against                 │
│       │     trusted OIDC provider thumbprint                │
│       │                                                     │
│       │  4. Checks trust policy conditions:                 │
│       │     - aud == sts.amazonaws.com ✓                    │
│       │     - sub matches repo + branch ✓                   │
│       │                                                     │
│       │  5. Issues temporary credentials (~1 hour)          │
│       ▼                                                     │
│  GitHub Actions receives:                                   │
│     AWS_ACCESS_KEY_ID     (temporary, expires in 1hr)       │
│     AWS_SECRET_ACCESS_KEY (temporary, expires in 1hr)       │
│     AWS_SESSION_TOKEN     (temporary, expires in 1hr)       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation

### 1. AWS OIDC Identity Provider

Tells AWS to trust tokens issued by GitHub's OIDC endpoint:

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

### 2. IAM Role with Scoped Trust Policy

The trust policy enforces that **only this specific repo and branch** can assume the role:

```hcl
resource "aws_iam_role" "github_actions_oidc" {
  name = "github-actions-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Only main branch and production environment can assume this role
          "token.actions.githubusercontent.com:sub" = [
            "repo:rerkted/aws-server:ref:refs/heads/main",
            "repo:rerkted/aws-server:environment:production"
          ]
        }
      }
    }]
  })
}
```

**Why `StringLike` on the sub claim matters:**
A misconfigured trust policy using only `StringEquals` on `aud` would allow ANY GitHub repo to assume the role. The `sub` condition locks it to this specific repo and branch — a critical security control.

### 3. Least Privilege Permissions

The role only has the permissions the pipeline actually needs:

```hcl
resource "aws_iam_role_policy" "github_actions_deploy" {
  policy = jsonencode({
    Statement = [
      {
        Sid      = "ECRAuth"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Action = ["ecr:BatchGetImage", "ecr:PutImage", ...]
        Resource = "arn:aws:ecr:us-east-1:427956996655:repository/portfolio"
        # Scoped to this specific ECR repo only
      },
      {
        Sid    = "SSMDeploy"
        Action = ["ssm:SendCommand", "ssm:GetCommandInvocation", ...]
        Resource = "*"
      }
    ]
  })
}
```

### 4. GitHub Actions Workflow

```yaml
jobs:
  build:
    permissions:
      id-token: write   # Required — allows requesting OIDC token
      contents: read

    steps:
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_OIDC_ROLE_ARN }}
          aws-region: us-east-1
          # No aws-access-key-id or aws-secret-access-key
```

---

## Security Comparison

| Property | Static Keys | OIDC Federation |
|---|---|---|
| Credential lifetime | Never expires | ~1 hour |
| Stored at rest | Yes (GitHub Secrets) | No |
| Rotation required | Manual, periodic | Automatic every run |
| Blast radius if leaked | Full AWS access until rotated | Expired before attacker can use it |
| Repo scoping | None | Enforced via trust policy |
| Branch scoping | None | Enforced via trust policy |
| Audit trail | Key-level only | Full STS AssumeRole in CloudTrail |

---

## Verification

After deployment, every pipeline run will show in **AWS CloudTrail**:

```
Event: AssumeRoleWithWebIdentity
Principal: token.actions.githubusercontent.com
Role: arn:aws:iam::427956996655:role/github-actions-oidc-role
Source: GitHub Actions
```

You can also verify the OIDC provider in the AWS Console:
- **IAM → Identity Providers** → `token.actions.githubusercontent.com`
- **IAM → Roles → github-actions-oidc-role** → Trust relationships tab

---

## Enterprise Context

This pattern is the AWS-recommended standard for CI/CD authentication and is widely adopted in enterprise environments. Key considerations when implementing for clients:

- **Multi-account setups:** The OIDC provider must exist in each account, but a single GitHub repo can be granted access to assume roles across multiple accounts via cross-account trust policies
- **Environment separation:** Separate IAM roles per environment (dev/staging/prod) with branch-scoped trust conditions prevent a dev branch from deploying to production
- **Compliance:** Eliminates the "long-lived credentials" finding that appears in CIS AWS Foundations Benchmark and AWS Security Hub checks
- **Auditability:** Every pipeline authentication appears as a discrete STS event in CloudTrail with full context

---

## Files

| File | Purpose |
|---|---|
| `terraform/oidc.tf` | OIDC provider, IAM role, trust policy, permissions |
| `terraform/variables.tf` | `github_org` and `github_repo` variables |
| `.github/workflows/deploy.yml` | Updated to use `role-to-assume` instead of static keys |

---

## References

- [AWS — Configuring OpenID Connect in Amazon Web Services](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [AWS — IAM OIDC identity providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [GitHub — About security hardening with OpenID Connect](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
