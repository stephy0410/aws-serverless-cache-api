terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state in a pre-existing S3 bucket (create it once: aws s3 mb s3://stephanie-borrego-sd-lab04).
  # Native S3 locking (use_lockfile) instead of a DynamoDB table.
  backend "s3" {
    bucket       = "stephanie-borrego-sd-lab04"
    key          = "lab04/terraform.tfstate"
    region       = "us-east-1"
    profile      = "academy"
    encrypt      = true
    use_lockfile = true
  }
}
