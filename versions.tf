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

  # Remote state in the same pre-existing S3 bucket used by the previous labs, under its own key.
  # Native S3 locking (use_lockfile) instead of a DynamoDB table.
  # Path-style addressing avoids TLS issues with the dot in the bucket name.
  backend "s3" {
    bucket         = "stephanie.borrego"
    key            = "lab04/terraform.tfstate"
    region         = "us-east-1"
    profile        = "academy"
    encrypt        = true
    use_lockfile   = true
    use_path_style = true
  }
}
