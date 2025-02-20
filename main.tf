locals {
  source_db_account = {
    profile = "source"
    id      = "11111111111111"
    region  = "us-west-2"
  }
  target_db_account = {
    profile = "target"
    id      = "22222222222222"
    region  = "us-west-2"
  }
  name = "${var.target_rds_instance}-db-copy"
  tags = {
    "ManagedBy" = "terraform"
  }
}

provider "aws" {
  alias               = "source"
  region              = local.source_db_account.region
  profile             = local.source_db_account.profile
  allowed_account_ids = [local.source_db_account.id]

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias               = "target"
  region              = local.target_db_account.region
  profile             = local.target_db_account.profile
  allowed_account_ids = [local.target_db_account.id]

  default_tags {
    tags = local.tags
  }
}

###################
# Common Variables
###################
resource "random_pet" "name" {
  length = 1
}

resource "time_static" "time" {}

# 1. create kms key and share with target account
resource "aws_kms_key" "shared_kms_key" {
  provider = aws.source
}

resource "aws_kms_alias" "shared_kms_key" {
  provider      = aws.source
  name          = "alias/source-to-target-share" # TODO: make a more meaningful name
  target_key_id = aws_kms_key.shared_kms_key.key_id
}

resource "aws_kms_key_policy" "shared_kms_key" {
  provider = aws.source
  key_id   = aws_kms_key.shared_kms_key.key_id
  policy = jsonencode({
    Id = "SharedKMSKeyPolicy"
    Statement = [
      {
        Action = "kms:*"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::11111111111111:root",
            "arn:aws:iam::22222222222222:root",
          ]
        }

        Resource = "*"
        Sid      = "Enable IAM User Permissions"
      },
    ]
    Version = "2012-10-17"
  })
}

# 2. create source db manual snapshot
data "aws_db_instance" "source_db_instance" {
  provider               = aws.source
  db_instance_identifier = var.source_rds_instance
}

resource "aws_db_snapshot" "source_db_snapshot" {
  provider               = aws.source
  db_instance_identifier = data.aws_db_instance.source_db_instance.db_instance_identifier
  db_snapshot_identifier = "${local.name}-${time_static.time.unix}"

  timeouts {
    create = "60m"
  }
}

resource "aws_db_snapshot_copy" "copy_db_snapshot" {
  provider                      = aws.source
  source_db_snapshot_identifier = aws_db_snapshot.source_db_snapshot.db_snapshot_arn
  target_db_snapshot_identifier = "${local.name}-${time_static.time.unix}-shared"
  kms_key_id                    = aws_kms_key.shared_kms_key.arn
  destination_region            = local.target_db_account.region
  shared_accounts               = [local.target_db_account.id]

  timeouts {
    create = "60m"
  }
}

# 2. create target db from snapshot in target account
data "aws_kms_key" "target_kms_key" {
  provider = aws.target
  key_id   = "alias/aws/rds"
}

resource "aws_db_snapshot_copy" "target_copy_db_snapshot" {
  provider                      = aws.target
  source_db_snapshot_identifier = aws_db_snapshot_copy.copy_db_snapshot.db_snapshot_arn
  target_db_snapshot_identifier = "${local.name}-${time_static.time.unix}-shared"
  destination_region            = local.target_db_account.region
  kms_key_id                    = data.aws_kms_key.target_kms_key.arn

  timeouts {
    create = "60m"
  }
}

# TODO: Make this more dynamic
resource "random_password" "random_password" {
  length  = 16
  special = false
}

data "aws_db_instance" "database" {
  provider               = aws.target
  db_instance_identifier = var.target_rds_instance
}

module "database" {
  providers = {
    aws = aws.target
  }

  source  = "terraform-aws-modules/rds/aws"
  version = "v6.10.0"

  apply_immediately                   = true
  snapshot_identifier                 = aws_db_snapshot_copy.target_copy_db_snapshot.db_snapshot_arn
  identifier                          = "${local.name}-${time_static.time.unix}"
  engine                              = aws_db_snapshot_copy.target_copy_db_snapshot.engine
  engine_version                      = aws_db_snapshot_copy.target_copy_db_snapshot.engine_version
  family                              = "mysql8.0"
  major_engine_version                = "8.0"
  instance_class                      = data.aws_db_instance.database.db_instance_class
  allocated_storage                   = aws_db_snapshot_copy.target_copy_db_snapshot.allocated_storage
  skip_final_snapshot                 = true
  manage_master_user_password         = false
  password                            = random_password.random_password.result
  iam_database_authentication_enabled = true
  port                                = aws_db_snapshot_copy.target_copy_db_snapshot.port
  create_db_subnet_group              = false
  db_subnet_group_use_name_prefix     = false
  db_subnet_group_name                = data.aws_db_instance.database.db_subnet_group
  vpc_security_group_ids              = data.aws_db_instance.database.vpc_security_groups
  storage_encrypted                   = true
  publicly_accessible                 = false
}

