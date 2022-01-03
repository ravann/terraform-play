terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.70"
    }
  }

  required_version = ">= 0.14.9"
}

locals {
  name   = "aurora-cdc"
  region = "ap-southeast-1"
  tags = {
    Owner       = "Ravan"
    Environment = "poc"
  }
}

provider "aws" {
  region = local.region
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.11"

  name = local.name
  cidr = "10.99.0.0/18"

  azs              = ["${local.region}a", "${local.region}b", "${local.region}c"]
  public_subnets   = ["10.99.0.0/24", "10.99.1.0/24", "10.99.2.0/24"]
  private_subnets  = ["10.99.3.0/24", "10.99.4.0/24", "10.99.5.0/24"]
  database_subnets = ["10.99.7.0/24", "10.99.8.0/24", "10.99.9.0/24"]

  create_database_subnet_group = true

  tags = local.tags
}

resource "aws_db_subnet_group" "aurora_subnet_group" {
    name       = "${local.name}-sg"
    subnet_ids = module.vpc.database_subnets

    tags = local.tags
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4"

  name        = local.name
  description = "Aurora security group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "Aurora access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

  tags = local.tags
}

resource "time_sleep" "wait_60_seconds_destroy" {
  depends_on = [module.security_group]

  destroy_duration = "60s"
}

resource "aws_rds_cluster_parameter_group" "aurora-poc" {
  depends_on = [time_sleep.wait_60_seconds_destroy]

  name        = "${local.name}-pg"
  family      = "aurora-postgresql12"
  description = "RDS cluster parameter group"

  parameter {
    apply_method = "pending-reboot"
    name = "rds.logical_replication"
    value = 1
  }

  parameter {
    apply_method = "pending-reboot"
    name = "max_replication_slots"
    value = 5
  }

  parameter {
    apply_method = "pending-reboot"
    name = "max_wal_senders"
    value = 5
  }

  parameter {
    apply_method = "pending-reboot"
    name = "max_logical_replication_workers"
    value = 5
  }
}

output "vpc" {
  value = module.vpc.vpc_id
}

output "security_group" {
  value = module.security_group.security_group_id
}

output "subnets" {
  value = module.vpc.database_subnets
}

resource "time_sleep" "wait_60_seconds_create" {
  depends_on = [aws_rds_cluster_parameter_group.aurora-poc]

  create_duration = "60s"
}

module "cluster" {
  depends_on = [time_sleep.wait_60_seconds_create]

  source  = "terraform-aws-modules/rds-aurora/aws"

  name           = local.name
  engine         = "aurora-postgresql"
  engine_version = "12.7"
  instance_class = "db.r6g.large"
  instances = {
    poc = {}
  }

  vpc_id  = module.vpc.vpc_id
  vpc_security_group_ids = [module.security_group.security_group_id]
  subnets = module.vpc.database_subnets
  db_subnet_group_name = aws_db_subnet_group.aurora_subnet_group.name
  create_db_subnet_group = false

  # allowed_security_groups = [module.security_group.security_group_id]

  storage_encrypted   = true
  apply_immediately   = true
  monitoring_interval = 10

  # db_parameter_group_name         = "default"
  db_cluster_parameter_group_name = "${local.name}-pg"

  enabled_cloudwatch_logs_exports = ["postgresql"]
  

  tags = local.tags
}
