module "consul_server_dc1" {
  source = "../../../modules/consul_server"

  name  = var.name
  owner = var.owner
  vpc_id = module.vpc.vpc_id
  region = var.region

  private_subnets = module.vpc.private_subnets

  consul_server_key   = data.local_file.consul_server_key.content
  consul_server_cert  = data.local_file.consul_server_cert.content
  consul_agent_ca     = data.local_file.consul_agent_ca.content
  
  consul_encryption_key = var.consul_encryption_key
  
  consul_license = var.consul_license
  consul_binary  = var.consul_binary 

  target_groups = [aws_lb_target_group.consul.arn]
}

module "nomad_server_dc1" {
  source = "../../../modules/nomad_server"

  name  = var.name
  owner = var.owner
  vpc_id = module.vpc.vpc_id
  region = var.region
  datacenter = "dc1"

  public_subnets  = module.vpc.public_subnets
  private_subnets = module.vpc.private_subnets

  consul_ca_file = data.local_file.consul_agent_ca.content
  consul_binary  = var.consul_binary

  key_file  = data.local_file.consul_server_key.content
  cert_file = data.local_file.consul_server_cert.content
  ca_file   = data.local_file.consul_agent_ca.content

  target_groups = [aws_lb_target_group.nomad.arn]
}

module "nomad_client_dc1" {
  source = "../../../modules/nomad_client"

  name  = var.name
  owner = var.owner
  vpc_id = module.vpc.vpc_id
  region = var.region
  datacenter = "dc1"

  public_subnets  = module.vpc.public_subnets
  private_subnets = module.vpc.private_subnets

  consul_ca_file = data.local_file.consul_agent_ca.content
  consul_binary  = var.consul_binary

  key_file  = data.local_file.consul_server_key.content
  cert_file = data.local_file.consul_server_cert.content
  ca_file   = data.local_file.consul_agent_ca.content

  nomad_client_count = 1
  target_groups = [aws_lb_target_group.application.arn, aws_lb_target_group.traefik.arn]
}

# module "nomad_windows_client_dc1" {
#   source = "../../modules/windows_nomad_client"

#   name  = var.name
#   owner = var.owner
#   vpc_id = module.vpc.vpc_id
#   region = var.region

#   public_subnets  = module.vpc.public_subnets
#   private_subnets = module.vpc.private_subnets

#   # key_file  = data.local_file.consul_server_key.content
#   # cert_file = data.local_file.consul_server_cert.content
#   consul_ca_file = data.local_file.consul_agent_ca.content
# }