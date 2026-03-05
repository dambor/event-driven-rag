import os
import json
import requests

def main(params):
    # Log the raw incoming payload for debugging
    print("=== Incoming params ===")
    print(json.dumps(params, indent=2, default=str))

    # --- Extract COS notification from various payload formats ---
    notification = {}

    # Format 1: IBM Event Notifications webhook envelope
    # EN sends: { "notification": { "data": { "notification": { "object_name": ... } } } }
    en_data = (params.get("notification", {})
                     .get("data", {})
                     .get("notification", {}))
    if en_data.get("object_name"):
        notification = en_data

    # Format 2: Direct / manual test format
    # curl sends: { "data": { "notification": { "object_name": ... } } }
    if not notification.get("object_name"):
        notification = params.get("data", {}).get("notification", {})

    object_key = notification.get("object_name", "")
    bucket     = notification.get("bucket_name", "")

    print(f"Extracted object_key={object_key}, bucket={bucket}")

    if not object_key or object_key.endswith("/"):
        return {"status": "skipped", "reason": "directory marker or empty key"}

    langflow_url     = os.environ["LANGFLOW_URL"]
    langflow_api_key = os.environ["LANGFLOW_API_KEY"]
    component_id     = os.environ.get("COS_COMPONENT_ID", "IBMCOSFile")

    payload = {
        "input_value": f"New file uploaded: {object_key}",
        "tweaks": {
            component_id: {
                "cos_object_key": object_key
            }
        }
    }

    resp = requests.post(
        langflow_url,
        json=payload,
        headers={
            "x-api-key": langflow_api_key,
            "Content-Type": "application/json"
        },
        timeout=30
    )

    return {
        "status": "triggered",
        "object_key": object_key,
        "bucket": bucket,
        "langflow_status": resp.status_code,
        "langflow_response": resp.text
    }