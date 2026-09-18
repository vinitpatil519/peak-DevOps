# Remote state in S3 with native S3 locking (Terraform >= 1.10, no DynamoDB table needed).
# Create the bucket first with infra-terraform/bootstrap, then:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key          = "cloudforge/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
