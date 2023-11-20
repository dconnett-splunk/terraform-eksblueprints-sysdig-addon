# Helm addon
module "helm_addon" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.32.1//modules/kubernetes-addons/helm-addon"

  addon_context = var.addon_context
  set_values    = local.set_values
  helm_config   = local.helm_config
}
