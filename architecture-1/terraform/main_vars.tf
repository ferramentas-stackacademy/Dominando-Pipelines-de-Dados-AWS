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

variable "master_username" {
    type = string
    default = "admin"
}

variable "master_password" {
    type = string
    sensitive = true
    default = "07ce69721a45e73fE"
}

variable "subnet_public_a" {
  type = string
  default = "subnet-07ce69721a45e73fe"
}

variable "subnet_public_b" {
  type = string
  default = "subnet-0906328f4516b208e"
}

variable "default_security_group" {
  type = string
  default = "sg-0a8f6d1f585c16afd"
}