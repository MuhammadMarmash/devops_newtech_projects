# Terraform Infrastructure

Infrastructure-as-Code for the **Todo API** project. This Terraform configuration
provisions a complete public-facing environment on AWS: a VPC with networking, a
locked-down security group, and a single EC2 instance that runs the Flask app as a
Docker container. State is stored remotely in S3 with native locking.

---

## Architecture

```
                          Internet
                              │
                              ▼
                    ┌───────────────────┐
                    │ Internet Gateway  │
                    └─────────┬─────────┘
                              │  (route 0.0.0.0/0)
        VPC 10.0.0.0/16       │
        ┌─────────────────────┼──────────────────────────────┐
        │   Public subnet 10.0.1.0/24                         │
        │   ┌───────────────────────────────────────────┐    │
        │   │ EC2 (t3.micro, Ubuntu 22.04)              │    │
        │   │   • Docker container: todo-api :5000      │◀───┼── Elastic IP
        │   │   • SSM Agent (outbound 443, no SSH)      │    │   (stable public IP)
        │   │   • IAM instance profile → SSM Core       │    │
        │   └───────────────────────────────────────────┘    │
        │        ▲ Security Group: inbound 80/443/5000        │
        └────────┼───────────────────────────────────────────┘
                 │
        GitHub Actions ──(OIDC, no static keys)──▶ assume IAM role
                 └──────────(SSM Run Command)──────▶ deploy to instance
```

**Why no SSH?** Access and deployments go through **AWS Systems Manager (SSM)**.
The SSM Agent on the instance dials *out* over 443, so there is no need to open
inbound port 22. The security group only allows the app/web ports.

---

## Module layout

| Module | Path | Creates |
|--------|------|---------|
| **vpc** | `modules/vpc/` | VPC (`10.0.0.0/16`), Internet Gateway, public subnet (`10.0.1.0/24`), route table + association |
| **security_group** | `modules/security_group/` | Security group; inbound `80/443/5000` from `0.0.0.0/0`, all outbound |
| **ec2** | `modules/ec2/` | EC2 instance, auto-generated SSH key pair, IAM role + instance profile for SSM, Elastic IP + association, Docker provisioning via `user_data` |

`main.tf` wires the three modules together and passes outputs between them
(VPC → subnet/SG IDs → EC2). The AWS provider region defaults to `eu-north-1`.

---

## Prerequisites

- **Terraform** ≥ 1.10 (S3-native state locking via `use_lockfile` requires it; this repo is tested on 1.15)
- **AWS CLI** configured with credentials that can manage VPC/EC2/IAM/S3
- An **S3 bucket** for remote state (see below) — must exist before `init`

---

## Remote state

State lives in S3 with **native locking** (no DynamoDB table needed):

```hcl
backend "s3" {
  bucket       = "mini-project1-tfstate-284483510847"
  key          = "mini-project1/terraform.tfstate"
  region       = "eu-north-1"
  encrypt      = true
  use_lockfile = true   # S3 conditional-write lock; replaces the old DynamoDB lock
}
```

The state bucket is **not** created by this configuration (chicken-and-egg: the
backend must exist before Terraform initializes). It was bootstrapped once with
versioning, encryption, and public-access-block enabled:

```bash
aws s3api create-bucket --bucket mini-project1-tfstate-284483510847 \
  --region eu-north-1 --create-bucket-configuration LocationConstraint=eu-north-1
aws s3api put-bucket-versioning --bucket mini-project1-tfstate-284483510847 \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket mini-project1-tfstate-284483510847 \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket mini-project1-tfstate-284483510847 \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

---

## Configuration

Two variables are **required** (no defaults); set them in `terraform.tfvars`:

```hcl
project_name = "mini-project1"
environment  = "dev"
```

`terraform.tfvars` is gitignored (it is environment-specific); copy
`terraform.tfvars.example` and fill in your values.

### Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `project_name` | — (required) | Name prefix for all resources/tags |
| `environment` | — (required) | Environment name (`dev`/`staging`/`prod`), used in tags |
| `region` | `eu-north-1` | AWS region |
| `instance_type` | `t3.micro` | EC2 size (free-tier eligible) |
| `size` | `8` | Root volume size (GB) |
| `repo_url` | this repo | Git repo cloned onto the instance at boot |
| `repo_branch` | `main` | Branch the instance deploys |
| `app_home` | `/opt/todo-api` | Where the repo is cloned (Compose file lives here) |
| `app_port` | `5000` | Port the app listens on |

The AMI is **not** a variable — the ec2 module looks up the latest Canonical
Ubuntu 22.04 image dynamically via an `aws_ami` data source.

---

## Usage

```bash
# From the terraform/ directory:

terraform init        # downloads providers, configures the S3 backend
terraform plan        # preview changes
terraform apply       # create/update infrastructure  (type "yes")

terraform output      # show outputs (public IP, elastic IP, instance id, role ARN)

terraform destroy     # tear everything down
```

> **Note:** changing the `user_data` script forces the instance to be **replaced**
> (`user_data_replace_on_change = true`). The Elastic IP re-attaches to the new
> instance, so the public IP stays the same and `EC2_HOST` does not need updating.

---

## Multiple environments

The same configuration serves `dev`, `staging`, and `prod` via **Terraform workspaces**
plus one variable file per environment. Because every resource is named/tagged
`${project_name}-${environment}-...`, the environments are fully isolated — separate
VPCs, instances, and Elastic IPs — with zero code duplication.

Workspaces also isolate **state** automatically: with the S3 backend, non-default
workspaces are stored under an `env:/<workspace>/` prefix in the same bucket.

| Environment | Workspace | Var file |
|-------------|-----------|----------------|
| dev | `default` | `dev.tfvars` |
| staging | `staging` | `staging.tfvars` |
| prod | `prod` | `prod.tfvars` |

```bash
# one-time: create the workspaces
terraform workspace new staging
terraform workspace new prod
terraform workspace list

# work on a specific environment
terraform workspace select staging
terraform apply   -var-file=staging.tfvars
terraform destroy -var-file=staging.tfvars   # tear down when done

terraform workspace select prod
terraform apply   -var-file=prod.tfvars
```

Environment-specific overrides (e.g. a larger `instance_type` for prod) go in that
environment's `*.tfvars` file.

> **CI note:** the deploy workflow finds its target by `tag:Project`. If more than one
> environment runs at once, add a `tag:Environment` filter to the lookup so deploys
> target the intended instance.

---

## Outputs

| Output | Description |
|--------|-------------|
| `ec2_public_ip` | Instance public IP (equals the Elastic IP once attached) |
| `ec2_elastic_ip` | Stable Elastic IP — use this for the `EC2_HOST` CI secret |
| `ec2_instance_id` | Instance ID |
| `github_deploy_role_arn` | IAM role ARN that GitHub Actions assumes via OIDC |

---

## How the application gets deployed

1. **At first boot** — the instance's `user_data` installs Docker, clones the repo,
   and runs `docker compose up -d --build`, starting the app as a container on port 5000.
2. **On every push to `main`** — GitHub Actions authenticates to AWS with **OIDC**
   (short-lived credentials, no stored AWS keys), looks up the running instance by
   its `Project` tag, and uses an **SSM Run Command** to pull the latest code and
   restart the container. A post-deploy health check curls `:5000/health`.

The OIDC provider and the `github-deploy-role` (trust scoped to this repo's `main`
branch) are defined in `github_oidc.tf`.

---

## Security notes

- **No inbound SSH** — port 22 is closed; access is via SSM Session Manager.
- **Keyless CI** — GitHub Actions uses OIDC; no long-lived AWS keys in secrets.
- **Least-privilege SG** — only 80/443/5000 are open inbound.
- **State protection** — the S3 backend is encrypted, versioned, and blocks public access.
- **Never commit** `terraform.tfvars`, `*.tfstate`, or `*.pem` (all gitignored).
```
