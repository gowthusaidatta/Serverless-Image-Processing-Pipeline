output "api_gateway_url" {
  description = "Invoke URL for the deployed AWS API Gateway."
  value       = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/prod"
}

output "upload_endpoint" {
  description = "Full POST endpoint for image upload."
  value       = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/prod/v1/images/upload"
}

output "api_key" {
  description = "API key for authenticating requests."
  value       = aws_api_gateway_api_key.main.value
  sensitive   = true
}
