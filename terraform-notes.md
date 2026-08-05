# Terraform Architecture & Notes

This document serves as a senior-level reference for how Terraform manages infrastructure, state, and drift in a GitOps environment.

## 1. What Our Terraform Does
Instead of clicking through UIs or running manual `kubectl` commands, our `main.tf` automates the bootstrap phase:
1. Spins up a free local Kubernetes cluster.
2. Configures the Helm and K8s providers to talk to it.
3. Installs ArgoCD natively using Helm charts (version-locked and clean).
4. Applies `argocd-app.yaml` to hand over control to GitOps.

## 2. Managing Configuration Drift
Drift happens when the real world differs from your code (e.g., someone manually edits a server in the AWS console).
- **The Memory**: Terraform tracks everything it builds in a database file called `terraform.tfstate`.
- **The Scan (`terraform plan`)**: Terraform compares the actual real-world infrastructure against your `main.tf` code.
- **The Fix (`terraform apply`)**: If Terraform detects drift, it will overwrite the manual changes and force the real world back into alignment with the code. Code is Law.

*In this project, we have two layers of drift protection: Terraform protects the Infrastructure (Cluster/ArgoCD), and ArgoCD protects the Software (Podinfo/Secrets).*

## 3. Remote State & Team Syncing
By default, the `terraform.tfstate` file lives locally on your laptop. **It must never be pushed to GitHub** because it contains plain-text secrets and infrastructure IP addresses. In an enterprise team, this file must be moved to a secure Cloud Locker.

### Step-by-Step S3 Migration Workflow:
1. **AWS Authentication**: 
   - Install `aws-cli` and run `aws configure`.
   - Your secret badge is saved to `~/.aws/credentials`. 
   - Terraform automatically hunts for this file. You **never** hardcode AWS passwords into `main.tf`.
2. **Build the Locker**: 
   - Create an AWS S3 Bucket (the storage) and a DynamoDB table (the lock mechanism, so two developers don't build at the exact same second and corrupt the file).
3. **Write the Code**: 
   - Add the `backend` block to the top of `main.tf`:
   ```hcl
   terraform {
     backend "s3" {
       bucket         = "my-team-locker"
       key            = "production.tfstate"
       dynamodb_table = "terraform-lock"
     }
   }
   ```
4. **The Transfer**: 
   - Run `terraform init`. 
   - Terraform will notice the new backend and ask: *"Do you want to copy your local state to S3?"* Type `yes`.
5. **Clean Up**: 
   - Terraform securely uploads the file to AWS and deletes the local copy off your laptop. From that day forward, your laptop has no memory file—`terraform plan` and `apply` talk directly to the cloud locker.

## 4. Dynamic Secret Injection (Enterprise Best Practice)
In a real-world corporate environment, you never hardcode GitHub Personal Access Tokens (PATs) or passwords into `main.tf`, nor do you run manual `kubectl create secret` commands. Instead, Terraform fetches them dynamically from a vault like AWS Secrets Manager.

### How it works:
1. **The Safe**: An Admin securely stores the GitHub PAT in AWS Secrets Manager under the name `github-pat`.
2. **The Fetch**: Terraform is instructed to read this safe during its run:
   ```hcl
   data "aws_secretsmanager_secret_version" "github_token" {
     secret_id = "github-pat"
   }
   ```
3. **The Inject**: Terraform builds the Kubernetes Secret, passing the sensitive data strictly in memory:
   ```hcl
   resource "kubernetes_secret" "argocd_git_access" {
     metadata {
       name      = "my-private-repo"
       namespace = "argocd"
       labels = {
         "argocd.argoproj.io/secret-type" = "repository"
       }
     }
     data = {
       url      = "https://github.com/my-org/my-repo.git"
       username = "deploy-bot"
       password = data.aws_secretsmanager_secret_version.github_token.secret_string
     }
   }
   ```

**Why this is genius:**
The `main.tf` code contains zero passwords, so it is 100% safe to commit to GitHub. When Terraform runs, it pulls the password into memory, injects it straight into the K8s cluster, and wipes its memory. If the token expires, the Admin updates AWS Secrets Manager, and running `terraform apply` will automatically patch the cluster with zero human intervention.
