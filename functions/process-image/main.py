"""
Cloud Function: process-image
Type: Pub/Sub-triggered (2nd Gen)

Triggered by messages on image-processing-requests topic.
Downloads the raw image from the -uploads bucket, converts it to
grayscale using Pillow, uploads the result to the -processed bucket,
then publishes a completion message to image-processing-results.

Idempotent: processed object name is keyed by upload_id so
re-processing the same message produces the same output object.
"""

import os
import io
import json
import base64
import logging
from datetime import datetime, timezone

import functions_framework
from cloudevents.http import CloudEvent
from google.cloud import storage, pubsub_v1
from PIL import Image

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

UPLOADS_BUCKET   = os.environ["UPLOADS_BUCKET"]
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]
RESULTS_TOPIC    = os.environ["RESULTS_TOPIC"]
PROJECT_ID       = os.environ["PROJECT_ID"]

_storage_client = storage.Client()
_publisher      = pubsub_v1.PublisherClient()


def _decode_pubsub_message(cloud_event: CloudEvent) -> dict:
    """Decode base64-encoded JSON data from a Pub/Sub CloudEvent."""
    raw = cloud_event.data.get("message", {}).get("data", "")
    if not raw:
        raise ValueError("Pub/Sub message has no data payload.")
    return json.loads(base64.b64decode(raw).decode("utf-8"))


@functions_framework.cloud_event
def process_image(cloud_event: CloudEvent):
    """Entry point: triggered by image-processing-requests Pub/Sub topic."""

    # ── 1. Decode message ────────────────────────────────────
    try:
        payload = _decode_pubsub_message(cloud_event)
    except (ValueError, json.JSONDecodeError) as exc:
        logger.error("Invalid Pub/Sub message — skipping: %s", exc)
        return  # Do NOT raise — we don't want infinite retries for bad messages

    upload_id    = payload.get("upload_id", "unknown")
    src_bucket   = payload.get("bucket", UPLOADS_BUCKET)
    object_name  = payload.get("object_name", "")
    content_type = payload.get("content_type", "image/jpeg")

    if not object_name:
        logger.error("Missing object_name in payload for upload_id=%s", upload_id)
        return

    logger.info("Processing gs://%s/%s  (upload_id=%s)", src_bucket, object_name, upload_id)

    # ── 2. Download from GCS into memory ────────────────────
    try:
        src_blob    = _storage_client.bucket(src_bucket).blob(object_name)
        image_bytes = src_blob.download_as_bytes()
        logger.info("Downloaded %d bytes for %s", len(image_bytes), object_name)
    except Exception:
        logger.exception("Failed to download gs://%s/%s", src_bucket, object_name)
        raise  # Raise → Pub/Sub retries → dead-letter after 5 attempts

    # ── 3. Convert to grayscale ──────────────────────────────
    try:
        original_image = Image.open(io.BytesIO(image_bytes))
        original_fmt   = original_image.format or "JPEG"
        grayscale      = original_image.convert("L")

        output_buf = io.BytesIO()
        grayscale.save(output_buf, format="JPEG", quality=90)
        output_buf.seek(0)
        logger.info("Converted to grayscale (original format: %s)", original_fmt)
    except Exception:
        logger.exception("Image conversion failed for upload_id=%s", upload_id)
        raise

    # ── 4. Upload processed image (idempotent name) ──────────
    # Always .jpg — output is always saved as JPEG regardless of input format
    processed_name = f"grayscale_{upload_id}.jpg"      # stable, keyed by upload_id

    try:
        dest_blob = _storage_client.bucket(PROCESSED_BUCKET).blob(processed_name)
        dest_blob.upload_from_file(output_buf, content_type="image/jpeg")
        logger.info("Uploaded processed image to gs://%s/%s", PROCESSED_BUCKET, processed_name)
    except Exception:
        logger.exception("Failed to upload processed image for upload_id=%s", upload_id)
        raise

    # ── 5. Publish completion message ────────────────────────
    result_payload = {
        "upload_id":         upload_id,
        "status":            "SUCCESS",
        "original_bucket":   src_bucket,
        "original_object":   object_name,
        "original_filename": payload.get("original_filename", object_name),
        "processed_bucket":  PROCESSED_BUCKET,
        "processed_object":  processed_name,
        "processed_at":      datetime.now(timezone.utc).isoformat(),
    }

    try:
        future    = _publisher.publish(
            RESULTS_TOPIC,
            data=json.dumps(result_payload).encode("utf-8"),
            upload_id=upload_id,
            status="SUCCESS",
        )
        pubsub_id = future.result(timeout=10)
        logger.info("Published completion message %s for upload_id=%s", pubsub_id, upload_id)
    except Exception:
        logger.exception("Failed to publish result message for upload_id=%s", upload_id)
        raise
