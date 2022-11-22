# AWS details
variable "aws_region" {
  description = "AWS target region"
  type        = string
  default     = "us-east-2"
}

# EKS cluster name
variable "cluster_name" {
  description = "Cluster name"
  type        = string
  default     = "splunk-sysdig-integration-cluster"
}

# Sysdig Access Key
variable "sysdig_accesskey" {
  type      = string
  default   = "674bf134-f7e1-426a-a799-1756b76f081f"
  sensitive = true
}

# Sysdig Collector endpoint url
variable "sysdig_collector_endpoint" {
  type    = string
  default = "ingest-us2.app.sysdig.com"
}

# Sysdig NodeAnalyzer endpoint url
variable "sysdig_nodeanalyzer_api_endpoint" {
  type    = string
  default = "us2.app.sysdig.com"
}
