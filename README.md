# Secure K8s Deployment Pipeline

This project demonstrates a production-grade, secure CI/CD pipeline and K8s deployment for a Go microservice.

## Phase 1: The Application & Dockerization

**The Base Application**
We use `stefanprodan/podinfo` (raw source only). It is an industry-standard Cloud Native application that exposes Prometheus metrics, health probes, and structured logging.

**The Multi-Stage Docker Build**
Instead of using a standard base image which is large and vulnerable, we use a multi-stage approach:
1. **Builder Stage**: `golang:alpine` compiles Go code into a single statically-linked binary.
2. **Production Stage**: `scratch` (empty container). We copy only the binary and UI assets.
**Result**: ~10MB image, virtually zero OS attack surface.

## Phase 2: Enterprise SecOps CI Pipeline

**Tool Choice: GitHub Actions vs Jenkins**
We chose GitHub Actions over Jenkins because it is a fully managed SaaS (zero server maintenance or plugin hell), uses clean declarative YAML instead of Groovy scripts, and offers seamless integration with the repository.

Our GitHub Action (`.github/workflows/ci.yml`) implements "Shift-Left" security. It blocks bad code from ever reaching the registry.

**Pipeline Stages:**
1. **Linting**: `golangci-lint` enforces clean code.
2. **Unit Tests**: Verifies logic.
3. **SAST (Static Application Security Testing)**: We use `gosec` to scan the raw Go code for hardcoded credentials, SQL injections, and bad cryptography.
   - *Why gosec?* It is purpose-built and highly optimized specifically for Go.
   - *Alternatives*: We could use **Semgrep** or **SonarQube** for this phase. Semgrep is excellent for multi-language repositories, but for a pure Go microservice, `gosec` is lighter and faster.
4. **Build**: Executes multi-stage Docker build.
5. **SCA (Software Composition Analysis)**: `Trivy` scans the final Docker image. Fails the build if `CRITICAL` or `HIGH` vulnerabilities exist.
6. **Publish**: Pushes verified image to GHCR if merged to `main`.

## Phase 3: Kubernetes Deployment

We provide production-ready K8s manifests in the `k8s/` directory.
- **Security Context**: Enforces `runAsNonRoot` to prevent privilege escalation if container is compromised.
- **Resource Quotas**: Defines CPU/Memory limits to prevent "noisy neighbor" crashes.
- **Health Probes**: Uses `/healthz` and `/readyz` endpoints. K8s will only send traffic when app is fully ready. Zero-downtime rolling updates.

## Phase 4: GitOps Secrets Management

**Tool Choice: Bitnami Sealed Secrets**
In a true GitOps workflow, *everything* must live in Git—including secrets. However, standard K8s `Secret` objects are merely base64 encoded and unsafe for Git repositories.

We solve this using **Sealed Secrets**:
- **Asymmetric Encryption**: We use the `kubeseal` CLI to encrypt secrets locally using a public key.
- **Safe Storage**: The resulting `SealedSecret` is fully encrypted and 100% safe to commit to Git. Hackers cannot read it.
- **Secure Decryption**: Only the controller inside our specific K8s cluster holds the private key to decrypt it back into a normal K8s Secret at runtime.

## Phase 5: Continuous Deployment (GitOps)

**Tool Choice: ArgoCD**
To achieve true GitOps, we do not run `kubectl apply` manually, nor do we let GitHub Actions push changes to the cluster. Instead, we use a pull-based model with ArgoCD.

- **ArgoCD Application**: The `k8s/argocd-app.yaml` manifest tells ArgoCD to constantly monitor this Git repository.
- **Auto-Sync**: When a new change is merged to `main`, ArgoCD detects the drift and automatically synchronizes the K8s cluster state to match Git.
- **Self-Healing**: If someone manually edits a K8s resource via CLI, ArgoCD will overwrite their changes to ensure Git remains the single source of truth.

## Phase 6: Next-Gen Routing (Gateway API)

Instead of using legacy `Ingress`, we use the modern Kubernetes **Gateway API** (`HTTPRoute`).
- **Decoupled Architecture**: Cluster admins manage the `Gateway` infrastructure, while developers independently manage the `HTTPRoute` application logic.
- **Advanced Traffic Management**: Natively supports canary deployments, weight-based traffic splitting, and header matching without relying on ugly vendor-specific annotations.

## Phase 7: Kustomize (The Glue)

We use `kustomization.yaml` to group all Kubernetes manifests.
- **Why?** It allows us to apply `commonLabels` to all resources simultaneously and dynamically override Docker image tags per environment (Dev vs Prod) without duplicating raw YAML files. ArgoCD natively detects and builds Kustomize.

## Future Enhancements
While this pipeline is production-grade, a massive enterprise scale-out would add:
- **Horizontal Pod Autoscaler (HPA)**: Auto-scale pod replicas from 2 to 50 dynamically based on CPU/Memory usage.
- **Cloud Provider IaC (Terraform)**: Expand our local `kind` Terraform module to provision a real AWS EKS cluster and VPC network.
- **ServiceMonitor (Prometheus)**: Automatically tell Prometheus to scrape the `/metrics` endpoint built into our Go app.

## How to Deploy (Run it Yourself)

To see this pipeline in action, follow these exact steps:

1. **GitHub Setup**: 
   - Create a new GitHub repository.
   - Run `git init`, commit this folder, and `git push`.
2. **Registry Setup**: 
   - We push images to **GHCR (GitHub Container Registry)** instead of DockerHub. 
   - *Why?* GHCR integrates natively with GitHub Actions. It automatically authenticates using the ephemeral, built-in `GITHUB_TOKEN`. You do not need to create third-party accounts, generate passwords, or manage secrets manually. It is significantly more secure and requires zero setup.
3. **Infrastructure as Code (Terraform)**: 
   - Edit `k8s/argocd-app.yaml` and change `repoURL` to point to your new GitHub repo.
   - Navigate to the `terraform/` directory.
   - Run `terraform init` and `terraform apply -auto-approve`.
   - *What happens?* Terraform automatically spins up a free Kubernetes cluster (using `kind`), installs ArgoCD via Helm, and automatically applies the root `argocd-app.yaml` handover file. Zero manual `kubectl` commands required.
4. **Watch the Magic**: 
   - ArgoCD wakes up, connects to your Git repo, reads `kustomization.yaml`, and automatically deploys the Gateway, Service, Deployment, and Secrets.

## Enterprise Note: Private Repositories
In a real-world corporate environment, the GitHub repository will be **Private**. This introduces two authentication hurdles that this portfolio architecture bypasses for simplicity:
1. **ArgoCD Git Access**: ArgoCD requires a GitHub Personal Access Token (PAT) or SSH Deploy Key stored as a Kubernetes `Secret` to read the private YAML manifests.
2. **K8s Image Pull**: The Kubernetes `Deployment` requires an `imagePullSecrets` configuration to authenticate with the private GHCR registry and pull the Docker image.

## Phase 8: Observability & Monitoring (VPS 2)
In an enterprise architecture, monitoring is decoupled from the application cluster. We use a dedicated server (VPS 2) running Docker Compose.

### The Architecture (Zero Trust Networking)
- **VPS 1 (App Cluster)**: Runs K3s, ArgoCD, and the application. Connected to the Tailscale VPN mesh.
- **VPS 2 (Monitoring)**: Runs Docker Compose (Prometheus + Grafana). Connected to the Tailscale VPN mesh.
- **The Connection**: Prometheus securely scrapes metrics from VPS 1 over the encrypted Tailscale network. Zero public ports are opened on VPS 1.

### Deployment Steps (VPS 2)
1. Install Docker and Tailscale on VPS 2.
2. Copy the `monitoring/` directory from this repository to VPS 2.
3. **CRITICAL CHANGE**: Edit `monitoring/prometheus.yml`. Change the `targets: ['100.x.x.x:8080']` IP to match the private Tailscale IP of your K8s cluster/service on VPS 1.
4. Run `docker compose up -d`.
5. Access Grafana at `http://<VPS_2_PUBLIC_IP>:3000` (Default login: `admin`/`admin`).
6. Add Prometheus as a Data Source (`http://prometheus:9090`) and import the official K8s Dashboard (ID: `315`).
