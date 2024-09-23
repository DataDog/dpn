module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.30.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.23"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  node_security_group_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = null
  }

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

    # we are going to use the ARM-based Graviton2 processors
    # ami_type = "AL2_ARM_64"

    #create_cluster_primary_security_group_tags = false
    
    attach_cluster_primary_security_group = true
    
    # Disabling and using externally provided security groups
    create_security_group = false
  }


  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]
      # we are going to use the ARM-based Graviton2 instance types
      # instance_types = ["m6g.medium"]

      min_size     = 1
      max_size     = 3
      desired_size = 2

      pre_bootstrap_user_data = <<-EOT
      echo 'dd demo'
      EOT

      vpc_security_group_ids = [
        aws_security_group.node_group_one.id
      ]
    }

    two = {
      name = "node-group-2"

      instance_types = ["t3.medium"]
      # we are going to use the ARM-based Graviton2 instance types
      # instance_types = ["m6g.large"]

      min_size     = 1
      max_size     = 2
      desired_size = 1

      pre_bootstrap_user_data = <<-EOT
      echo 'dd demo'
      EOT

      vpc_security_group_ids = [
        aws_security_group.node_group_two.id
      ]
    }
    
  }
}
