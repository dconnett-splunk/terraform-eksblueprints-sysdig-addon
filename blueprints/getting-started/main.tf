provider "aws" {
  region = local.region
}

resource "random_string" "random_suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  name         = coalesce(var.cluster_name, "${basename(path.cwd)}-${random_string.random_suffix.result}")
  cluster_name = local.name
  region       = var.aws_region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_blueprints.eks_cluster_id
}

data "aws_availability_zones" "available" {}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }

  tags = local.tags
}

module "storage" {
  source = "./storage"
}

resource "kubernetes_namespace" "stackrox_ns" {
  metadata {
    name = "stackrox"
    labels = {
      name = "stackrox"
    }
  }
}
resource "aws_security_group" "stackrox_efs_sg" {
  name        = "stackrox_ef_sg"
  description = "StackRox EFS Security Group"
  vpc_id      = module.vpc.vpc_id


}

resource "kubernetes_persistent_volume_claim" "stackrox_pvc" {
  metadata {
    annotations = {
      "email"                          = "support@stackrox.com"
      "helm.sh/hook"                   = "pre-install,pre-upgrade"
      "helm.sh/hook-delete-policy"     = "never"
      "helm.sh/resource-policy"        = "keep"
      "meta.helm.sh/release-name"      = "stackrox-central-services"
      "meta.helm.sh/release-namespace" = "stackrox"
      "owner"                          = "stackrox"
    }
    labels = {
      "app.kubernetes.io/component"  = "central"
      "app.kubernetes.io/instance"   = "stackrox-central-services"
      "app.kubernetes.io/managed-by" = "Helm"
      "app.kubernetes.io/name"       = "stackrox"
      "app.kubernetes.io/part-of"    = "stackrox-central-services"
      "app.kubernetes.io/version"    = "3.73.1"
      "helm.sh/chart"                = "stackrox-central-services-73.1.0"
    }
    name      = "stackrox-db"
    namespace = "stackrox"
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "gp2"
    volume_name        = "pv-sr-0"

    resources {
      requests = {
        storage = "100Gi"
      }
    }
  }
}



# resource "kubernetes_persistent_volume" "stackrox_pv" {
#   metadata {
#     name = "stackrox-pv"
#   }
#   spec {
#     capacity = {
#       storage = "150Gi"
#     }

#     storage_class_name = "gp2"
#     access_modes       = ["ReadWriteOnce"]
#     # persistent_volume_source {
#     #   aws_elastic_block_store {
#     #     volume_id = module.storage.aws_ebs_volume_id
#     #     fs_type   = "ext4"
#     #   }
#     # }
#     persistent_volume_source {
#       csi {
#         driver        = "ebs.csi.aws.com"
#         volume_handle = module.storage.aws_ebs_volume_id
#       }
#     }
#     persistent_volume_reclaim_policy = "Retain"
#   }
# }

# This was from ChatGPT, it's not working
# resource "kubernetes_persistent_volume" "pv" {
#   metadata {
#     name = "pv-sr-0"
#   }
#   spec {
#     capacity = {
#       storage = "150Gi"
#     }
#     volume_mode                      = "Filesystem"
#     access_modes                     = ["ReadWriteOnce"]
#     persistent_volume_reclaim_policy = "Retain"
#     claim_ref = {
#       namespace = "stackrox"
#       name      = "stackrox-db"
#     }
#     storage_class_name = "stackrox-db"
#     local = {
#       path = "/mnt"
#     }
#     node_affinity {
#       required {
#         node_selector_term {
#           match_expressions {
#             key      = "topology.kubernetes.io/zone"
#             operator = "In"
#             values   = ["us-east-1c"]
#           }
#         }
#       }
#     }
#   }
#   kubernetes = {
#     context   = var.cluster_name
#     namespace = "stackrox"
#   }
# }


#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------

module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints"

  cluster_name    = local.cluster_name
  cluster_version = "1.23"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  managed_node_groups = {
    mg_5 = {
      node_group_name = "managed-ondemand"

      instance_types = ["m5.4xlarge"]
      capacity_type  = "ON_DEMAND"
      disk_size      = 150

      desired_size    = 3
      max_size        = 3
      min_size        = 2
      max_unavailable = 1

      subnet_ids = module.vpc.private_subnets
    }
  }


  # Add self-managed node groups
  # self_managed_node_groups = {
  #  self_mg_5 = {
  #    node_group_name    = "self-managed-ondemand"
  #    instance_type      = "m5.large"
  #    launch_template_os = "amazonlinux2eks"   # amazonlinux2eks  or bottlerocket or windows
  #    custom_ami_id      = data.aws_ami.eks.id # Bring your own custom AMI generated by Packer/ImageBuilder/Puppet etc.
  #    subnet_ids         = module.vpc.private_subnets
  #  }

  tags = local.tags
  # additional_iam_policies = [] # Attach additional IAM policies to the IAM role attached to this worker group
  # # SSH ACCESS Optional - Recommended to use SSM Session manager
  # remote_access         = false
  # ec2_ssh_key           = ""
  # ssh_security_group_id = ""

}

module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.21.0//modules/kubernetes-addons"

  eks_cluster_id       = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_version  = module.eks_blueprints.eks_cluster_version

  # EKS Managed Add-ons
  # enable_amazon_eks_vpc_cni            = true
  # enable_amazon_eks_coredns            = true
  # enable_amazon_eks_kube_proxy         = true

  # Add-ons
  # enable_metrics_server               = true
  # enable_cluster_autoscaler           = true
  # enable_aws_load_balancer_controller = true

  # Sysdig addon
  enable_sysdig_agent = true

  sysdig_agent_helm_config = {

    namespace = "sysdig-agent"

    values = [templatefile("${path.module}/values-sysdig.yaml", {
      sysdigAccessKey   = sensitive(var.sysdig_accesskey)
      sysdigRegion      = var.sysdig_region
      sysdigClusterName = local.cluster_name
    })]
  }

  tags = local.tags
}


# resource "aws_ebs_volume" "stackrox" {
#   availability_zone = format("%s%s", var.aws_region, "a")
#   size              = 50

#   tags = {
#     Name = "StackRox"
#   }
# }

# resource "aws_ebs_volume" "stackrox" {
#   availability_zone = data.aws_availability_zones.available.names[0]
#   size              = 50
#   type              = "gp2"
#   tags = {
#     Name = "stackrox-db"
#   }
# }


# resource "aws_efs_mount_target" "stackrox_efs_mt" {
#   count          = length(module.vpc.private_subnets)
#   file_system_id = module.storage.efs_id
#   subnet_id      = module.vpc.private_subnets[count.index]
#   # VPC Default Security Group
#   security_groups = [module.vpc.default_security_group_id]


# }


# resource "kubernetes_persistent_volume" "stackrox_pv" {
#   metadata {
#     name = "stackrox-pv"
#   }
#   spec {
#     capacity = {
#       storage = "100Gi"
#     }
#     storage_class_name = "gp2"
#     access_modes       = ["ReadWriteOnce"]
#     persistent_volume_source {
#       csi {
#         driver        = "efs.csi.aws.com"
#         volume_handle = module.storage.efs_id
#       }
#     }
#     # persistent_volume_source {

#     #   aws_elastic_block_store {
#     #     volume_id = module.storage.aws_ebs_volume_id
#     #   }
#     persistent_volume_reclaim_policy = "Delete"
#   }
# }



# resource "kubernetes_persistent_volume_claim" "stackrox_pvc" {
#   # wait_until_bound = false
#   metadata {
#     name      = "stackrox-db"
#     namespace = "stackrox"
#   }
#   spec {
#     access_modes = ["ReadWriteOnce"]
#     resources {
#       requests = {
#         storage = "150Gi"
#       }
#     }
#     volume_name        = "stackrox-pv"
#     storage_class_name = "gp2"

#   }
# }

# locals {
#   central_services_values = templatefile("central-services.yaml", {})

# }

# locals {
#   secured_cluster_values = templatefile("secured-cluster-services.yaml", {})
# }

# resource "helm_release" "stackrox_central_services" {
#   name       = "stackrox-central-services"
#   repository = "https://raw.githubusercontent.com/stackrox/helm-charts/main/opensource/"
#   chart      = "stackrox-central-services"
#   namespace  = "stackrox"
#   values     = [local.central_services_values]
# }

# resource "helm_release" "stackrox_secured_cluster_services" {
#   name       = "stackrox-secured-cluster-services"
#   repository = "https://raw.githubusercontent.com/stackrox/helm-charts/main/opensource/"
#   chart      = "stackrox-secured-cluster-services"
#   namespace  = "stackrox"
#   values     = [local.secured_cluster_values]
# }
