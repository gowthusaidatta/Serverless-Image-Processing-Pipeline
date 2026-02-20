# Main AWS resources for serverless pipeline

resource "aws_s3_bucket" "uploads" {
  bucket = "gpp-pipeline-uploads-${random_id.suffix.hex}"
  force_destroy = true
}

resource "random_id" "suffix" {
  byte_length = 4
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}
