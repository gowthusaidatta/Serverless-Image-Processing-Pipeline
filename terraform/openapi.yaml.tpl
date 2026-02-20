swagger: "2.0"
info:
  title: Image Processing Pipeline API
  description: Serverless image processing pipeline on GCP
  version: "1.0.0"
host: "image-pipeline-api.apigateway.${project_id}.cloud.goog"
schemes:
  - https
produces:
  - application/json
consumes:
  - multipart/form-data

# Backend: all requests route to the upload-image Cloud Function
x-google-backend:
  address: ${upload_function_url}
  protocol: h2

# Rate limiting: 20 requests per minute per project
x-google-management:
  metrics:
    - name: "upload-requests"
      displayName: "Image Upload Requests"
      valueType: INT64
      metricKind: DELTA
  quota:
    limits:
      - name: "upload-requests-limit"
        metric: "upload-requests"
        unit: "1/min/{project}"
        values:
          STANDARD: 20

securityDefinitions:
  api_key:
    type: apiKey
    name: x-api-key
    in: header

paths:
  /v1/images/upload:
    post:
      summary: Upload an image for asynchronous processing
      operationId: uploadImage
      consumes:
        - multipart/form-data
      parameters:
        - name: image
          in: formData
          required: true
          type: file
          description: The image file to upload (JPEG, PNG, GIF, BMP, WEBP)
      responses:
        "202":
          description: Accepted — image queued for processing
          schema:
            type: object
            properties:
              upload_id:
                type: string
                description: Unique identifier for this upload
              object_name:
                type: string
                description: GCS object name of the uploaded file
              message:
                type: string
              status:
                type: string
        "400":
          description: Bad request — missing or invalid file
        "401":
          description: Unauthorized — missing or invalid API key
        "429":
          description: Too many requests — rate limit exceeded
        "500":
          description: Internal server error
      security:
        - api_key: []
      x-google-quota:
        metricCosts:
          upload-requests: 1
