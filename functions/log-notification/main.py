"""
Cloud Function: log-notification
Type: Pub/Sub-triggered (2nd Gen)

Triggered by messages on image-processing-results topic.
Writes a structured JSON log entry to Cloud Logging confirming
successful end-to-end processing of an image through the pipeline.
"""

import base64
import json
import logging
from datetime import datetime, timezone

import functions_framework
from cloudevents.http import CloudEvent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _decode_pubsub_message(cloud_event: CloudEvent) -> dict:
    """Decode base64-encoded JSON from a Pub/Sub CloudEvent."""
    raw = cloud_event.data.get("message", {}).get("data", "")
    if not raw:
        raise ValueError("Pub/Sub message has no data payload.")
    return json.loads(base64.b64decode(raw).decode("utf-8"))


@functions_framework.cloud_event
def log_notification(cloud_event: CloudEvent):
    """Entry point: triggered by image-processing-results Pub/Sub topic."""

    try:
        payload = _decode_pubsub_message(cloud_event)
    except (ValueError, json.JSONDecodeError) as exc:
        logger.error("Failed to decode Pub/Sub message: %s", exc)
        return  # Bad message — skip without retrying

    upload_id  = payload.get("upload_id", "unknown")
    status     = payload.get("status", "UNKNOWN")

    # Build structured log entry (Cloud Logging picks up JSON printed to stdout)
    log_entry = {
        "severity":         "INFO",
        "message":          f"Image pipeline completed for upload_id={upload_id}",
        "event_type":       "IMAGE_PROCESSING_COMPLETE",
        "upload_id":        upload_id,
        "status":           status,
        "original": {
            "bucket": payload.get("original_bucket", ""),
            "object": payload.get("original_object", ""),
            "filename": payload.get("original_filename", ""),
        },
        "processed": {
            "bucket": payload.get("processed_bucket", ""),
            "object": payload.get("processed_object", ""),
        },
        "pipeline_completed_at": datetime.now(timezone.utc).isoformat(),
        "processed_at":          payload.get("processed_at", ""),
        "cloud_event_id":        cloud_event.get("id", ""),
    }

    # Print as JSON — GCP Cloud Logging automatically parses structured JSON stdout
    print(json.dumps(log_entry))

    logger.info(
        "Logged completion: upload_id=%s status=%s processed_object=%s",
        upload_id,
        status,
        payload.get("processed_object", ""),
    )
