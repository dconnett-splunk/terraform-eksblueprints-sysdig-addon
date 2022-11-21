provider "aws" {
  region = local.region
}

resource "random_string" "random_suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  name = coalesce(var.cluster_name, "${basename(path.cwd)}-${random_string.random_suffix.result}")
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

      instance_types = ["m5.large"]
      capacity_type  = "ON_DEMAND"
      disk_size      = 50

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
}

module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/kubernetes-addons"

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

    values = [templatefile("${path.module}/values.yaml", {
      sysdigAccessKey         = sensitive(var.sysdig_accesskey)
      sysdigRegion            = var.sysdig_region
      sysdigClusterName       = local.cluster_name
    })]
  }

  tags = local.tags
}
