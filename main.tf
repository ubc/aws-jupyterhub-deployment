terraform {
  required_version = ">= 0.12.0"
}

provider "aws" {
    version = ">= 2.43.0"
    region  = var.region
    profile = var.profile
}

provider "random" {
  version = "~> 2.2"
}

provider "local" {
  version = "~> 1.2"
}

provider "null" {
  version = "~> 2.1"
}

provider "template" {
  version = "~> 2.1"
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  version                = "~> 1.11"
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

data "aws_availability_zones" "available" {
}

locals {
  cluster_name = "ubc-eks-${random_string.suffix.result}"
  k8s_service_account_namespace = "kube-system"
  k8s_service_account_name      = "cluster-autoscaler-aws-cluster-autoscaler-chart"
}

resource "random_string" "suffix" {
  length = 8
  special = false
}

resource "aws_security_group" "worker_group_mgmt_one" {
  name_prefix = "worker_group_mgmt_one"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8"
    ]
  }
}

resource "aws_security_group" "all_worker_mgmt" {
  name_prefix = "all_worker_management"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16",
    ]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.21.0"

  name                 = "eks-vpc"
  cidr                 = "10.1.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = ["10.1.1.0/24", "10.1.2.0/24"]
  public_subnets       = ["10.1.101.0/24", "10.1.102.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "project" = "jupyterhub"
  
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
    "project"                                      = "jupyterhub"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
    "project"                                     = "jupyterhub"
  }
}

module "eks" {
  source       = "terraform-aws-modules/eks/aws"
  version      = "12.2.0"
  cluster_version = "1.17"

  cluster_name = local.cluster_name

  kubeconfig_aws_authenticator_env_variables = {
    AWS_PROFILE = var.profile
  }
  subnets      = module.vpc.private_subnets

  tags = {
    Environment = "ubc"
    GithubRepo  = "terraform-aws-eks"
    GithubOrg   = "terraform-aws-modules"
    project     = "jupyterhub"
  }

  vpc_id = module.vpc.vpc_id

  enable_irsa   = true

  worker_groups = [
    {
      name                          = "worker-group-1"
      instance_type                 = "t2.medium"
      asg_desired_capacity          = 2
      additional_security_group_ids = [aws_security_group.worker_group_mgmt_one.id]
    },
    {
      name                          = "user-group-1"
      instance_type                 = var.worker_group_user_node_type
      asg_desired_capacity          = var.worker_group_user_asg_desired_capacity
      asg_min_size                  = var.worker_group_user_asg_min_size
      asg_max_size                  = var.worker_group_user_asg_max_size
      kubelet_extra_args            = "--node-labels=hub.jupyter.org/node-purpose=user --register-with-taints=hub.jupyter.org/dedicated=user:NoSchedule"
      additional_security_group_ids = [aws_security_group.worker_group_mgmt_one.id]
      tags = [
        {
          "key"                     = "k8s.io/cluster-autoscaler/enabled"
          "propagate_at_launch"     = "false"
          "value"                   = "true"
          "project"                 = "jupyterhub"
        },
        {
          "key"                     = "k8s.io/cluster-autoscaler/${local.cluster_name}"
          "propagate_at_launch"     = "false"
          "value"                   = "true"
          "application"             = "true"
        }
      ]
    }
  ]

  worker_additional_security_group_ids = [aws_security_group.all_worker_mgmt.id]
  map_roles                            = var.map_roles
  map_users                            = var.map_users
  map_accounts                         = var.map_accounts
}

resource "aws_efs_file_system" "home" {
}

resource "aws_efs_mount_target" "home_mount" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.home.id
  subnet_id       = element(module.vpc.private_subnets, count.index)
  security_groups = [aws_security_group.efs_mt_sg.id]
}

resource "aws_security_group" "efs_mt_sg" {
  name_prefix = "efs_mt_sg"
  description = "Allow NFSv4 traffic"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  ingress {
    from_port = 2049
    to_port   = 2049
    protocol  = "tcp"

    cidr_blocks = [
      "10.1.0.0/16"
    ]
  }
}