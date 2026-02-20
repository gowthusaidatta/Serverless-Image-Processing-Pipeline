"""
Cloud Function: upload-image
Type: HTTP-triggered (2nd Gen)

Receives an image via multipart/form-data POST request,
uploads it to the -uploads GCS bucket, publishes a message
to the image-processing-requests Pub/Sub topic, and returns
202 Accepted with a unique upload_id.
"""

import os
import uuid
import json
import logging
from datetime import datetime

import functions_framework
from flask import Request, jsonify
from google.cloud import storage, pubsub_v1

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Environment variables injected via Terraform
UPLOADS_BUCKET = os.environ["UPLOADS_BUCKET"]
PUBSUB_TOPIC   = os.environ["PUBSUB_TOPIC"]
PROJECT_ID     = os.environ["PROJECT_ID"]

# Initialize GCP clients once (module-level = reused across warm invocations)
_storage_client = storage.Client()
_publisher      = pubsub_v1.PublisherClient()

ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff"}


@functions_framework.http
def upload_image(request: Request):
    """Entry point: POST /v1/images/upload"""

    # Handle CORS preflight
    if request.method == "OPTIONS":
        return ("", 204, {
            "Access-Control-Allow-Origin":  "*",
            "Access-Control-Allow-Methods": "POST",
            "Access-Control-Allow-Headers": "Content-Type, x-api-key",
        })

    if request.method != "POST":
        return jsonify({"error": "Method not allowed. Use POST."}), 405

    # Validate file presence
    if "image" not in request.files:
        return jsonify({
            "error": "Missing file. Send a multipart/form-data request with field name 'image'."
        }), 400

    file = request.files["image"]

    if not file or not file.filename:
        return jsonify({"error": "Empty file or filename."}), 400

    # Validate extension
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        return jsonify({
            "error": f"Unsupported file type '{ext}'. Allowed: {sorted(ALLOWED_EXTENSIONS)}"
        }), 400

    # Build unique GCS object name
    upload_id   = str(uuid.uuid4())
    timestamp   = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    object_name = f"{timestamp}_{upload_id}{ext}"

    # Upload raw image to GCS
    try:
        bucket = _storage_client.bucket(UPLOADS_BUCKET)
        blob   = bucket.blob(object_name)
        file.stream.seek(0)   # ensure stream is at start before upload
        blob.upload_from_file(
            file.stream,
            content_type=file.content_type or "image/jpeg",
        )
        logger.info("Uploaded %s to gs://%s", object_name, UPLOADS_BUCKET)
    except Exception:
        logger.exception("GCS upload failed for upload_id=%s", upload_id)
        return jsonify({"error": "Failed to store image. Please retry."}), 500

    # Publish Pub/Sub message to trigger processing
    message_data = {
        "upload_id":         upload_id,
        "bucket":            UPLOADS_BUCKET,
        "object_name":       object_name,
        "original_filename": file.filename,
        "content_type":      file.content_type or "image/jpeg",
        "timestamp":         timestamp,
    }

    try:
        future    = _publisher.publish(
            PUBSUB_TOPIC,
            data=json.dumps(message_data).encode("utf-8"),
            upload_id=upload_id,
        )
        pubsub_id = future.result(timeout=10)
        logger.info("Published message %s for upload_id=%s", pubsub_id, upload_id)
    except Exception:
        logger.exception("Pub/Sub publish failed for upload_id=%s", upload_id)
        return jsonify({"error": "Image stored but failed to queue for processing."}), 500

    return jsonify({
        "upload_id":   upload_id,
        "object_name": object_name,
        "message":     "Image accepted and queued for processing.",
        "status":      "PROCESSING",
    }), 202
