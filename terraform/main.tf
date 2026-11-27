terraform {
  required_version = ">= 1.10"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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
    cluster_name    = local.cluster_name
    kubeconfig_path = local.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      k3d cluster create ${local.cluster_name} \
        --servers 1 \
        --k3s-arg "--disable=traefik@server:0" \
        -p "8080:80@loadbalancer" \
        --volume /sys/kernel/debug:/sys/kernel/debug \
        --volume /sys/kernel/tracing:/sys/kernel/tracing \
        --wait \
        --timeout 180s
      k3d kubeconfig write ${local.cluster_name} --output ${local.kubeconfig_path}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.triggers.cluster_name} && rm -f ${self.triggers.kubeconfig_path}"
  }
}

# 2. Tell Helm provider how to talk to the new cluster
#
# NOTE: because k3d isn't a native Terraform resource (no provider exposes cluster
# endpoint/certs as computed attributes), run:
#   terraform apply -target=null_resource.k3d_cluster
# once to create the cluster and kubeconfig file, then a plain `terraform apply`
# to install all charts and apply the GitOps bootstrap manifests.
provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

# 3. Install ArgoCD automatically via Helm
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "10.18.3"

  depends_on = [null_resource.k3d_cluster]
}

# 4. Install Sealed Secrets controller via Helm (kube-system)
resource "helm_release" "sealed_secrets" {
  name       = "sealed-secrets-controller"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "sealed-secrets"
  namespace  = "kube-system"
  version    = "2.22.0"

  depends_on = [null_resource.k3d_cluster]
}

# 5. Install Tetragon (eBPF Security) automatically via Helm
#
# Pinned at 1.8.0 for newer kernel/BTF compatibility (1.1.0's precompiled
# multi-kprobe BPF object failed the in-kernel verifier on modern kernels).
resource "helm_release" "tetragon" {
  name       = "tetragon"
  repository = "https://helm.cilium.io"
  chart      = "tetragon"
  namespace  = "kube-system"
  version    = "1.8.0"

  # Re-expose the node's debugfs/tracefs (bind-mounted from the host at cluster
  # creation, see null_resource.k3d_cluster) into the tetragon pod itself.
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

# 6. Install Envoy Gateway Controller (Automatically installs Gateway API CRDs)
#
# Pinned at v1.8.3: recent k3s ships a Traefik CRD bundle where TLSRoute/TCPRoute/
# UDPRoute have moved past the v1alpha2 API that envoy-gateway v1.1.0 hard-coded.
resource "helm_release" "envoy_gateway" {
  name             = "eg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  namespace        = "envoy-gateway-system"
  create_namespace = true
  version          = "v1.8.3"

  depends_on = [null_resource.k3d_cluster]
}

# 7. Install Kyverno Admission Controller (Cosign Signature & SBOM Enforcement)
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  version          = "3.10.0"

  # Single-node k3d overrides (disable HA anti-affinity so pods schedule on 1 server node)
  values = [
    yamlencode({
      admissionController = {
        replicas = 1
        antiAffinity = {
          enabled = false
        }
      }
      backgroundController = {
        replicas = 1
      }
      cleanupController = {
        replicas = 1
      }
      reportsController = {
        replicas = 1
      }
      upgrade = {
        legacyPolicyCheck = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [null_resource.k3d_cluster]
}

# 8. Hand over cluster GatewayClass, Kyverno supply-chain policy, and root ArgoCD Application (zero manual kubectl)
resource "null_resource" "bootstrap_gitops" {
  triggers = {
    gatewayclass_sha         = filesha256("${path.module}/../k8s/cluster/gatewayclass.yaml")
    verify_images_policy_sha = filesha256("${path.module}/../k8s/cluster/verify-images-policy.yaml")
    argocd_app_sha           = filesha256("${path.module}/../k8s/argocd-app.yaml")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      KUBECONFIG=${local.kubeconfig_path} kubectl apply -f ${path.module}/../k8s/cluster/gatewayclass.yaml
      KUBECONFIG=${local.kubeconfig_path} kubectl apply -f ${path.module}/../k8s/cluster/verify-images-policy.yaml
      KUBECONFIG=${local.kubeconfig_path} kubectl apply -f ${path.module}/../k8s/argocd-app.yaml
    EOT
  }

  depends_on = [
    helm_release.argocd,
    helm_release.envoy_gateway,
    helm_release.kyverno,
    helm_release.sealed_secrets,
    helm_release.tetragon,
  ]
}
