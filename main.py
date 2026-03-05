import os
import json
import logging
import requests

log = logging.getLogger(__name__)

def _respond(body_dict, status_code=200):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body_dict),
    }

def main(params):
    log.info("--- begin invocation ---")

    # --- Extract COS notification from various payload formats ---
    notification = {}

    # Format 1: IBM Event Notifications webhook envelope
    # { "notification": { "data": { "notification": { "object_name": ... } } } }
    en_data = (params.get("notification", {})
                     .get("data", {})
                     .get("notification", {}))
    if en_data.get("object_name"):
        notification = en_data
        log.info("Detected Format 1: Event Notifications webhook envelope")

    # Format 2: Direct / manual test format
    # { "data": { "notification": { "object_name": ... } } }
    if not notification.get("object_name"):
        notification = params.get("data", {}).get("notification", {})
        if notification.get("object_name"):
            log.info("Detected Format 2: Direct test format")

    # Format 3: Alternative EN format
    # { "data": { "object_name": ... } }
    if not notification.get("object_name"):
        data = params.get("data", {})
        if data.get("object_name"):
            notification = data
            log.info("Detected Format 3: Alternative EN format")

    # Format 4: IBM Code Engine native COS subscription
    # { "bucket": "...", "key": "path/to/file.pdf", "operation": "write" }
    if not notification.get("object_name"):
        if params.get("key"):
            notification = {
                "object_name": params["key"],
                "bucket_name": params.get("bucket", ""),
            }
            log.info("Detected Format 4: Code Engine COS subscription")

    # Format 5: Top-level notification
    # { "object_name": ... }
    if not notification.get("object_name"):
        if params.get("object_name"):
            notification = params
            log.info("Detected Format 5: Top-level format")

    object_key = notification.get("object_name", "")
    bucket     = notification.get("bucket_name", "")

    if not object_key:
        log.error("Could not extract object_name — payload keys: %s", list(params.keys()))
        return _respond({
            "status": "error",
            "reason": "Could not extract object_name from payload",
            "payload_keys": list(params.keys())
        }, 400)

    log.info("object_key=%s  bucket=%s", object_key, bucket)

    if object_key.endswith("/"):
        log.info("Skipping directory marker: %s", object_key)
        return _respond({"status": "skipped", "reason": "directory marker"})

    langflow_url     = os.environ.get("LANGFLOW_URL")
    langflow_api_key = os.environ.get("LANGFLOW_API_KEY")
    component_id     = os.environ.get("COS_COMPONENT_ID", "IBMCOSFile")

    if not langflow_url or not langflow_api_key:
        log.error("Missing LANGFLOW_URL or LANGFLOW_API_KEY environment variables")
        return _respond({
            "status": "error",
            "reason": "Missing required environment variables"
        }, 500)

    log.info("Calling Langflow  url=%s  component=%s", langflow_url, component_id)

    payload = {
        "input_value": f"New file uploaded: {object_key}",
        "tweaks": {
            component_id: {
                "cos_object_key": object_key
            }
        }
    }

    try:
        resp = requests.post(
            langflow_url,
            json=payload,
            headers={
                "x-api-key": langflow_api_key,
                "Content-Type": "application/json"
            },
            timeout=30
        )

        log.info("Langflow responded  status=%s", resp.status_code)
        if resp.status_code != 200:
            log.warning("Langflow error body: %s", resp.text[:500])

        return _respond({
            "status": "triggered",
            "object_key": object_key,
            "bucket": bucket,
            "langflow_status": resp.status_code,
            "langflow_response": resp.text[:200]
        })

    except Exception as e:
        log.exception("Failed to call Langflow: %s", e)
        return _respond({
            "status": "error",
            "reason": f"Failed to call Langflow: {e}",
            "object_key": object_key,
            "bucket": bucket
        }, 500)

# Made with Bob
