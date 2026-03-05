import os
import requests

def main(params):
    notification = params.get("data", {}).get("notification", {})
    object_key   = notification.get("object_name", "")
    bucket       = notification.get("bucket_name", "")

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