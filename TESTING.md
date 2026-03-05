# Testing and Monitoring Guide

## Quick Test Commands

### 1. Test the Code Engine Function Directly

```bash
# Load environment variables
source .env

# Get the function URL
CE_FUNCTION_URL=$(ibmcloud ce function get --name "$CE_FUNCTION_NAME" --output json \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['endpoint'])")

# Test with a sample payload
curl -v -X POST "$CE_FUNCTION_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"data\": {
      \"notification\": {
        \"object_name\": \"test/sample.txt\",
        \"bucket_name\": \"$COS_BUCKET_NAME\"
      }
    }
  }"
```

**Expected Response:**
- HTTP 200 OK
- JSON response with `status: "triggered"` and `langflow_status: 200`

**Common Issues:**
- **HTTP 422** — Function executed but encountered an error (check Langflow URL/API key)
- **HTTP 500** — Internal function error (check function code)
- **Connection timeout** — Function may be cold-starting (wait and retry)

---

### 2. Test End-to-End by Uploading a File

```bash
source .env

# Upload a test file to trigger the pipeline
ibmcloud cos object-put \
  --bucket "$COS_BUCKET_NAME" \
  --key "test/sample-$(date +%s).txt" \
  --body README.md \
  --region "$COS_REGION"
```

**What happens:**
1. File is uploaded to COS bucket
2. COS emits `object.create` event to Event Notifications
3. Event Notifications matches the topic filter
4. Webhook sends POST to Code Engine function
5. Function extracts object key and calls Langflow API
6. Langflow downloads the file from COS and processes it

---

### 3. Check Langflow API Directly

```bash
source .env

# Test Langflow API with a direct call
curl -v -X POST "$LANGFLOW_URL" \
  -H "x-api-key: $LANGFLOW_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"input_value\": \"Test file uploaded\",
    \"tweaks\": {
      \"$COS_COMPONENT_ID\": {
        \"cos_object_key\": \"test/sample.txt\"
      }
    }
  }"
```

**Expected Response:**
- HTTP 200 OK
- JSON response with flow execution results

**Common Issues:**
- **HTTP 401** — Invalid API key
- **HTTP 404** — Invalid flow ID in URL
- **Connection refused** — Langflow server not accessible

---

## Monitoring

### Check Code Engine Function Status

```bash
source .env

# Get function details
ibmcloud ce function get --name "$CE_FUNCTION_NAME"

# Check recent function invocations (via activation ID in response headers)
# Note: Detailed logs require IBM Cloud Logging setup
```

### Check Event Notifications Status

```bash
source .env

# Get EN instance ID
EN_INSTANCE_ID=$(ibmcloud resource service-instances --service-name event-notifications --output json \
  | python3 -c "import sys,json; instances=[i for i in json.load(sys.stdin) if i['name']=='$EN_INSTANCE_NAME']; print(instances[0]['guid'] if instances else '')")

# List topics
ibmcloud event-notifications topics --instance-id "$EN_INSTANCE_ID"

# List destinations
ibmcloud event-notifications destinations --instance-id "$EN_INSTANCE_ID"

# List subscriptions
ibmcloud event-notifications subscriptions --instance-id "$EN_INSTANCE_ID"
```

### Check COS Activity Tracking

```bash
source .env

# Get bucket configuration
IAM_TOKEN=$(ibmcloud iam oauth-tokens | grep "IAM token" | awk '{print $4}')
curl -s "https://config.cloud-object-storage.cloud.ibm.com/v1/b/$COS_BUCKET_NAME" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  | python3 -m json.tool | grep -A 10 "activity_tracking"
```

**Expected Output:**
```json
"activity_tracking": {
    "read_data_events": false,
    "write_data_events": true,
    "activity_tracker_crn": "crn:v1:bluemix:public:event-notifications:...",
    "management_events": true
}
```

---

## Troubleshooting

### Function Returns HTTP 422

**Cause:** Function executed but encountered an error calling Langflow.

**Debug Steps:**
1. Verify Langflow URL is accessible:
   ```bash
   source .env
   curl -I "$LANGFLOW_URL"
   ```

2. Verify Langflow API key is valid:
   ```bash
   source .env
   curl -X POST "$LANGFLOW_URL" \
     -H "x-api-key: $LANGFLOW_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"input_value": "test"}'
   ```

3. Check if the COS component ID matches your Langflow flow:
   - Open your flow in Langflow
   - Find the IBM COS File component
   - Verify its ID matches `COS_COMPONENT_ID` in `.env`

### No Events Received

**Cause:** Event Notifications not routing events to the webhook.

**Debug Steps:**
1. Verify activity tracking is enabled on the bucket (see above)

2. Check if the Resource Lifecycle Events source is enabled:
   ```bash
   source .env
   EN_INSTANCE_ID=$(ibmcloud resource service-instances --service-name event-notifications --output json \
     | python3 -c "import sys,json; instances=[i for i in json.load(sys.stdin) if i['name']=='$EN_INSTANCE_NAME']; print(instances[0]['guid'] if instances else '')")
   
   ibmcloud event-notifications sources --instance-id "$EN_INSTANCE_ID" --output json \
     | python3 -c "import sys,json; [print(f\"{s['name']}: enabled={s['enabled']}\") for s in json.load(sys.stdin)['sources']]"
   ```

3. Verify the topic filter matches your bucket:
   ```bash
   ibmcloud event-notifications topic get \
     --instance-id "$EN_INSTANCE_ID" \
     --id "<topic-id-from-setup-output>"
   ```

### Langflow Not Processing Files

**Cause:** Langflow receives the trigger but fails to download/process the file.

**Debug Steps:**
1. Check Langflow logs in the Langflow UI

2. Verify the IBM COS File component has correct credentials:
   - Bucket name
   - IBM Cloud API key with COS access
   - Correct region/endpoint

3. Test file download manually:
   ```bash
   source .env
   ibmcloud cos object-get \
     --bucket "$COS_BUCKET_NAME" \
     --key "test/sample.txt" \
     --region "$COS_REGION"
   ```

---

## Advanced: Enable IBM Cloud Logging

For detailed Code Engine function logs:

1. Go to IBM Cloud Console → Observability → Logging
2. Create a logging instance in the same region as your Code Engine project
3. Go to Code Engine → Your Project → Logging
4. Connect the logging instance
5. View logs in the IBM Cloud Logging dashboard

---

## Test Checklist

- [ ] Langflow API responds to direct curl test
- [ ] Code Engine function responds to direct curl test
- [ ] File upload to COS bucket succeeds
- [ ] Activity tracking is enabled on bucket
- [ ] Resource Lifecycle Events source is enabled
- [ ] Topic exists with correct filter
- [ ] Webhook destination points to function URL
- [ ] Subscription links topic to destination
- [ ] End-to-end test: upload file → Langflow processes it