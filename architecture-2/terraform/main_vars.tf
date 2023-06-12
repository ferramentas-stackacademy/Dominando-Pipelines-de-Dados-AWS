variable "credentials" {
  type = object({
    credentials_file = string
    region           = string
  })
  sensitive = true
  default = {
    credentials_file = "~/.aws/credentials_stack"
    region           = "us-east-1"
  }
}

variable "vpc_id" {
  type = string
  default = "vpc-02ea86da064b87b44"
}

variable "private_subnet" {
  type = object({
    cidr_block = string
    availability_zone = string
  })
    default = {
      cidr_block        = "172.31.96.0/20"
      availability_zone = "us-east-1a"
    }
}

variable "eks_cluster_name" {
    type = string
    default = "stack-cluster"
}

variable "subnet_public_b" {
  type = string
  default = "subnet-0906328f4516b208e"
}