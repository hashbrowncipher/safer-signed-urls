variable "region" {
  type = string
}

variable "domain_name" {
  type = string
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.22"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "acm"
  region = "us-east-1"
}


