terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

locals {
  cluster_name    = "gitops-cluster"
  kubeconfig_path = "${path.module}/kubeconfig-${local.cluster_name}.yaml"
}

# 1. Spin up Local Kubernetes Cluster (Cost: $0)
#
# We use k3d instead of kind. k3d's node containers run `--privileged` by default;
# kind's do not. Tetragon (Phase 8) needs CAP_SYS_ADMIN plus a live debugfs/tracefs
# to attach kprobes -- under kind this silently fails ("neither debugfs nor tracefs
# are mounted"), because the node container itself is unprivileged and never mounts
# them. Under k3d we additionally bind-mount the host's own debugfs/tracefs into the
# node at cluster-create time, which the privileged node container is then allowed
# to re-expose to pods via a hostPath volume (see the tetragon helm_release below).
resource "null_resource" "k3d_cluster" {
  triggers = {
    cluster_name = local.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      k3d cluster create ${local.cluster_name} \
        --servers 1 \
        --volume /sys/kernel/debug:/sys/kernel/debug \
        --volume /sys/kernel/tracing:/sys/kernel/tracing \
        --wait \
        --timeout 180s
      k3d kubeconfig write ${local.cluster_name} --output ${local.kubeconfig_path}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.triggers.cluster_name}"
  }
}

# 2. Tell Helm and K8s providers how to talk to the new cluster
#
# NOTE: because k3d isn't a native Terraform resource (no provider exposes cluster
# endpoint/certs as computed attributes the way tehcyx/kind did), these providers
# can't graph-depend on null_resource.k3d_cluster the way they depended on
# kind_cluster.default before. Run `terraform apply -target=null_resource.k3d_cluster`
# once to create the cluster and kubeconfig file, then a plain `terraform apply` to
# install everything onto it. See terraform-notes.md for the full explanation.
provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = local.kubeconfig_path
}

# 3. Install ArgoCD automatically via Helm
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "5.46.0" # Stable version

  depends_on = [null_resource.k3d_cluster]
}

# 4. Install Tetragon (eBPF Security) automatically via Helm
#
# Pinned above 1.1.0 (this project's original pin): on a recent host kernel, 1.1.0's
# precompiled multi-kprobe BPF object fails the in-kernel verifier ("load program:
# invalid argument") and the TracingPolicy never actually attaches. 1.7.0 is the
# latest stable chart/app version and loads cleanly. Its values schema changed too
# (e.g. tetragon.processAncestors.enabled is now required), so if you bump this
# again, don't just `helm upgrade --reuse-values` across a major version jump.
resource "helm_release" "tetragon" {
  name       = "tetragon"
  repository = "https://helm.cilium.io"
  chart      = "tetragon"
  namespace  = "kube-system"
  version    = "1.7.0"

  # Re-expose the node's debugfs/tracefs (bind-mounted from the host at cluster
  # creation, see null_resource.k3d_cluster) into the tetragon pod itself. Without
  # this the agent crash-loops with "neither debugfs nor tracefs are mounted".
  # extraHostPathMounts alone is enough: the chart's tetragon container template
  # already ranges over it to add matching volumeMounts, so setting
  # tetragon.extraVolumeMounts too would duplicate the mount paths.
  values = [
    yamlencode({
      extraHostPathMounts = [
        { name = "debugfs", mountPath = "/sys/kernel/debug", readOnly = false },
        { name = "tracefs", mountPath = "/sys/kernel/tracing", readOnly = false },
      ]
    })
  ]

  depends_on = [null_resource.k3d_cluster]
}

# 5. Install Envoy Gateway Controller (Automatically installs Gateway API CRDs)
#
# Pinned above v1.1.0 (this project's original pin): recent k3s ships a Traefik CRD
# bundle where TLSRoute/TCPRoute/UDPRoute have moved past the v1alpha2 API that
# envoy-gateway v1.1.0 hard-codes, so it crash-loops with
# "no matches for kind TLSRoute in version gateway.networking.k8s.io/v1alpha2".
# v1.8.3 is the latest stable release and targets the current Gateway API versions.
resource "helm_release" "envoy_gateway" {
  name             = "eg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  namespace        = "envoy-gateway-system"
  create_namespace = true
  version          = "v1.8.3"

  depends_on = [null_resource.k3d_cluster]
}
