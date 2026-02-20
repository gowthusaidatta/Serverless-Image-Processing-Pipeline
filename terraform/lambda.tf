resource "aws_iam_role" "lambda_exec" {
  name = "gpp-pipeline-lambda-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "process_image" {
  function_name = "process-image"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "main.handler"
  runtime       = "python3.11"
  filename      = "../functions/process-image/lambda.zip"
  source_code_hash = filebase64sha256("../functions/process-image/lambda.zip")
  environment {
    variables = {
      UPLOADS_BUCKET = aws_s3_bucket.uploads.bucket
    }
  }
}

resource "aws_lambda_function" "log_notification" {
  function_name = "log-notification"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "main.handler"
  runtime       = "python3.11"
  filename      = "../functions/log-notification/lambda.zip"
  source_code_hash = filebase64sha256("../functions/log-notification/lambda.zip")
}

resource "aws_lambda_function" "upload_image" {
  function_name = "upload-image"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "main.handler"
  runtime       = "python3.11"
  filename      = "../functions/upload-image/lambda.zip"
  source_code_hash = filebase64sha256("../functions/upload-image/lambda.zip")
}
