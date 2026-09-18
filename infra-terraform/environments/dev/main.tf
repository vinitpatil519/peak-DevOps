###############################################################################
# CloudForge — AWS dev environment (EKS path).
# Cost warning: EKS control plane (~$0.10/h), NAT gateway and nodes are NOT free.
# Destroy when the demo is over:  terraform destroy
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = local.name
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "cloudforge-platform/infra-terraform"
  })
}

module "vpc" {
  source             = "../../modules/vpc"
  name               = local.name
  cluster_name       = local.cluster_name
  region             = var.region
  cidr               = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  tags               = local.tags
}

module "security_groups" {
  source       = "../../modules/security-groups"
  name         = local.name
  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = module.vpc.vpc_cidr
  tags         = local.tags
}

module "ecr" {
  source       = "../../modules/ecr"
  prefix       = var.project
  force_delete = var.demo_mode
  tags         = local.tags
}

module "s3" {
  source        = "../../modules/s3"
  prefix        = "${local.name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.demo_mode
  buckets = {
    loki    = { purpose = "loki-log-chunks", expire_days = 30, versioning = false }
    backups = { purpose = "postgres-backups", expire_days = 35 }
  }
  tags = local.tags
}

module "route53" {
  source        = "../../modules/route53"
  domain        = var.domain
  environment   = var.environment
  create_zone   = var.create_dns_zone
  force_destroy = var.demo_mode
  tags          = local.tags
}

module "iam" {
  source              = "../../modules/iam"
  name                = local.name
  cluster_name        = local.cluster_name
  region              = var.region
  route53_zone_ids    = [module.route53.zone_id]
  secrets_prefix      = "${var.project}/${var.environment}"
  loki_bucket_arn     = module.s3.bucket_arns["loki"]
  ecr_repository_arns = module.ecr.repository_arns
  tags                = local.tags
}

module "eks" {
  source                       = "../../modules/eks"
  cluster_name                 = local.cluster_name
  kubernetes_version           = var.kubernetes_version
  cluster_role_arn             = module.iam.cluster_role_arn
  node_role_arn                = module.iam.node_role_arn
  private_subnet_ids           = module.vpc.private_subnet_ids
  cluster_security_group_id    = module.security_groups.cluster_security_group_id
  node_security_group_id       = module.security_groups.node_security_group_id
  endpoint_public_access_cidrs = var.api_allowed_cidrs
  admin_principal_arns         = var.admin_principal_arns
  developer_principal_arns     = var.developer_principal_arns
  pod_identity_roles           = module.iam.pod_identity_roles
  node_groups = {
    # System pool: add-ons, ingress, monitoring
    system = {
      instance_types = var.system_instance_types
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
    # App pool: CloudForge workloads (charts select cloudforge.dev/pool=apps on EKS)
    apps = {
      instance_types = var.app_instance_types
      capacity_type  = var.app_capacity_type
      min_size       = 2
      max_size       = 6
      desired_size   = 2
    }
  }
  tags = local.tags
}

# ---------------- application secrets (synced into the cluster by External Secrets) ----------------
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/${var.environment}/app"
  description             = "CloudForge application credentials (Postgres, Redis)"
  recovery_window_in_days = var.demo_mode ? 0 : 7
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    db_password    = random_password.db.result
    redis_password = random_password.redis.result
  })
}
