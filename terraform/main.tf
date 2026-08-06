terraform {
  required_providers {
    kind = {
      source = "tehcyx/kind"
      version = "~> 0.2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

provider "kind" {}

# 1. Spin up Local Kubernetes Cluster (Cost: $0)
resource "kind_cluster" "default" {
  name           = "gitops-cluster"
  wait_for_ready = true
}

# 2. Tell Helm and K8s providers how to talk to new cluster
provider "helm" {
  kubernetes {
    host                   = kind_cluster.default.endpoint
    client_certificate     = kind_cluster.default.client_certificate
    client_key             = kind_cluster.default.client_key
    cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = kind_cluster.default.endpoint
  client_certificate     = kind_cluster.default.client_certificate
  client_key             = kind_cluster.default.client_key
  cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
}

# 3. Install ArgoCD automatically via Helm
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "5.46.0" # Stable version

  depends_on = [kind_cluster.default]
}

# 4. Install Tetragon (eBPF Security) automatically via Helm
resource "helm_release" "tetragon" {
  name             = "tetragon"
  repository       = "https://helm.cilium.io"
  chart            = "tetragon"
  namespace        = "kube-system"
  version          = "1.1.0"

  depends_on = [kind_cluster.default]
}
