#!/bin/bash
set -e  # Exit on any error

# ============================================================================
# COS → Langflow Auto-Trigger Setup Script
# ============================================================================
# This script automates the complete setup of the event-driven pipeline:
# COS bucket → Event Notifications → Code Engine Function → Langflow
# ============================================================================

echo "=========================================="
echo "COS → Langflow Auto-Trigger Setup"
echo "=========================================="
echo ""

# ============================================================================
# LOAD CONFIGURATION FROM .env FILE
# ============================================================================

if [ ! -f ".env" ]; then
    echo "ERROR: .env file not found"
    echo ""
    echo "Please create a .env file with your configuration:"
    echo "  cp .env.example .env"
    echo "  # Edit .env with your actual values"
    echo ""
    exit 1
fi

echo "Loading configuration from .env..."
set -a  # automatically export all variables
source .env
set +a
echo "✓ Configuration loaded"
echo ""

# Validate required variables
REQUIRED_VARS=(
    "LANGFLOW_URL"
    "LANGFLOW_API_KEY"
    "COS_BUCKET_NAME"
    "EN_INSTANCE_NAME"
    "CE_PROJECT_NAME"
    "CE_FUNCTION_NAME"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "ERROR: Required variable $var is not set in .env"
        exit 1
    fi
done

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================

echo "Checking prerequisites..."

# Check if ibmcloud CLI is installed
if ! command -v ibmcloud &> /dev/null; then
    echo "ERROR: ibmcloud CLI is not installed"
    echo "Install from: https://cloud.ibm.com/docs/cli?topic=cli-install-ibmcloud-cli"
    exit 1
fi

# Check if python3 is installed
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is not installed"
    exit 1
fi

# Check if logged in
if ! ibmcloud target &> /dev/null; then
    echo "ERROR: Not logged in to IBM Cloud"
    echo "Run: ibmcloud login"
    exit 1
fi

echo "✓ Prerequisites OK"
echo ""

# ============================================================================
# STEP 1: Install Required Plugins
# ============================================================================

echo "Step 1: Installing IBM Cloud plugins..."

# Install Code Engine plugin
if ! ibmcloud plugin list | grep -q "code-engine"; then
    echo "Installing code-engine plugin..."
    ibmcloud plugin install code-engine -f
else
    echo "✓ code-engine plugin already installed"
fi

# Install COS plugin
if ! ibmcloud plugin list | grep -q "cloud-object-storage"; then
    echo "Installing cloud-object-storage plugin..."
    ibmcloud plugin install cloud-object-storage -f
else
    echo "✓ cloud-object-storage plugin already installed"
fi

# Install Event Notifications plugin
if ! ibmcloud plugin list | grep -q "event-notifications"; then
    echo "Installing event-notifications plugin..."
    ibmcloud plugin install event-notifications -f
else
    echo "✓ event-notifications plugin already installed"
fi

echo ""

# ============================================================================
# STEP 2: Create Event Notifications Instance
# ============================================================================

echo "Step 2: Creating Event Notifications instance..."

# Check if instance already exists
EN_EXISTS=$(ibmcloud resource service-instances --service-name event-notifications --output json \
    | python3 -c "import sys,json; instances=[i for i in json.load(sys.stdin) if i['name']=='$EN_INSTANCE_NAME']; print('yes' if instances else 'no')")

if [ "$EN_EXISTS" = "yes" ]; then
    echo "✓ Event Notifications instance '$EN_INSTANCE_NAME' already exists"
else
    echo "Creating Event Notifications instance '$EN_INSTANCE_NAME'..."
    ibmcloud resource service-instance-create "$EN_INSTANCE_NAME" \
        event-notifications "$EN_PLAN" "$EN_REGION"
    echo "✓ Event Notifications instance created"
fi

# Get EN instance details
EN_INFO=$(ibmcloud resource service-instances --service-name event-notifications --output json \
    | python3 -c "
import sys, json
instances = [i for i in json.load(sys.stdin) if i['name'] == '$EN_INSTANCE_NAME']
if not instances:
    print('ERROR: Could not find EN instance', file=sys.stderr)
    sys.exit(1)
i = instances[0]
print(f\"EN_INSTANCE_ID={i['guid']}\")
print(f\"EN_CRN={i['crn']}\")
")
eval "$EN_INFO"

echo "  Instance ID: $EN_INSTANCE_ID"
echo ""

# ============================================================================
# STEP 3: Enable Activity Tracking on COS Bucket
# ============================================================================

echo "Step 3: Enabling activity tracking on COS bucket '$COS_BUCKET_NAME'..."

IAM_TOKEN=$(ibmcloud iam oauth-tokens | grep "IAM token" | awk '{print $4}')

# Configure activity tracking
curl -s -X PATCH \
    "https://config.cloud-object-storage.cloud.ibm.com/v1/b/${COS_BUCKET_NAME}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"activity_tracking\": {
            \"activity_tracker_crn\": \"${EN_CRN}\",
            \"write_data_events\": true,
            \"management_events\": true
        }
    }" > /dev/null

# Verify configuration
TRACKING_STATUS=$(curl -s \
    "https://config.cloud-object-storage.cloud.ibm.com/v1/b/${COS_BUCKET_NAME}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('enabled' if 'activity_tracking' in d and d['activity_tracking'].get('activity_tracker_crn') else 'disabled')")

if [ "$TRACKING_STATUS" = "enabled" ]; then
    echo "✓ Activity tracking enabled on bucket '$COS_BUCKET_NAME'"
else
    echo "ERROR: Failed to enable activity tracking"
    exit 1
fi

# Get bucket CRN
COS_BUCKET_CRN=$(curl -s \
    "https://config.cloud-object-storage.cloud.ibm.com/v1/b/${COS_BUCKET_NAME}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['crn'])")

echo "  Bucket CRN: $COS_BUCKET_CRN"
echo ""

# ============================================================================
# STEP 4: Create Code Engine Function
# ============================================================================

echo "Step 4: Creating Code Engine function..."

# Create or select project
CE_PROJECT_EXISTS=$(ibmcloud ce project list --output json 2>/dev/null \
    | python3 -c "import sys,json; projects=[p for p in json.load(sys.stdin) if p['name']=='$CE_PROJECT_NAME']; print('yes' if projects else 'no')" 2>/dev/null || echo "no")

if [ "$CE_PROJECT_EXISTS" = "yes" ]; then
    echo "✓ Code Engine project '$CE_PROJECT_NAME' already exists"
    ibmcloud ce project select --name "$CE_PROJECT_NAME"
else
    echo "Creating Code Engine project '$CE_PROJECT_NAME'..."
    ibmcloud ce project create --name "$CE_PROJECT_NAME"
fi

# Verify main.py exists (shipped with the repo)
if [ ! -f "main.py" ]; then
    echo "ERROR: main.py not found in the current directory"
    echo "This file is required and should be part of the repository."
    exit 1
fi
echo "✓ main.py found"

# Check if function already exists
CE_FN_EXISTS=$(ibmcloud ce fn list --output json 2>/dev/null \
    | python3 -c "import sys,json; fns=[f for f in json.load(sys.stdin).get('functions',[]) if f['name']=='$CE_FUNCTION_NAME']; print('yes' if fns else 'no')" 2>/dev/null || echo "no")

if [ "$CE_FN_EXISTS" = "yes" ]; then
    echo "✓ Code Engine function '$CE_FUNCTION_NAME' already exists"
    # Get existing function URL
    CE_FUNCTION_URL=$(ibmcloud ce fn get --name "$CE_FUNCTION_NAME" --output json \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['endpoint'])")
else
    echo "Creating Code Engine function '$CE_FUNCTION_NAME'..."
    ibmcloud ce fn create \
        --name "$CE_FUNCTION_NAME" \
        --runtime python-3.11 \
        --build-source . \
        --env LANGFLOW_URL="$LANGFLOW_URL" \
        --env LANGFLOW_API_KEY="$LANGFLOW_API_KEY" \
        --env COS_COMPONENT_ID="$COS_COMPONENT_ID"
    
    # Get function URL
    CE_FUNCTION_URL=$(ibmcloud ce fn get --name "$CE_FUNCTION_NAME" --output json \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['endpoint'])")
    
    echo "✓ Code Engine function created"
fi

echo "  Function URL: $CE_FUNCTION_URL"
echo ""

# ============================================================================
# STEP 5: Configure Event Notifications
# ============================================================================

echo "Step 5: Configuring Event Notifications..."

# Initialize EN CLI
ibmcloud event-notifications init --instance-id "$EN_INSTANCE_ID" > /dev/null

# Get account ID from EN CRN
ACCOUNT_ID=$(echo "$EN_CRN" | python3 -c "import sys,re; print(re.search(r':a/([^:]+):', sys.stdin.read()).group(1))")
RLE_SOURCE_ID="crn:v1:bluemix:public:resource-lifecycle-events:global:a/${ACCOUNT_ID}:${EN_INSTANCE_ID}::"

# Enable Resource Lifecycle Events source
echo "Enabling Resource Lifecycle Events source..."
ibmcloud event-notifications source-update \
    --instance-id "$EN_INSTANCE_ID" \
    --id "$RLE_SOURCE_ID" \
    --enabled=true > /dev/null
echo "✓ Resource Lifecycle Events source enabled"

# Create or update topic
TOPIC_ID=$(ibmcloud event-notifications topics --instance-id "$EN_INSTANCE_ID" --output json \
    | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin)['topics'] if x['name']=='$TOPIC_NAME']; print(t[0]['id'] if t else '')")

SOURCES_JSON="[{
    \"id\": \"${RLE_SOURCE_ID}\",
    \"rules\": [{
        \"enabled\": true,
        \"event_type_filter\": \"\$.notification_event_info.event_type == 'cloud-object-storage.object.create'\",
        \"notification_filter\": \"\$.notification.resources[0].crn == '${COS_BUCKET_CRN}'\"
    }]
}]"

if [ -z "$TOPIC_ID" ]; then
    echo "Creating topic '$TOPIC_NAME'..."
    TOPIC_RESULT=$(ibmcloud event-notifications topic-create \
        --instance-id "$EN_INSTANCE_ID" \
        --name "$TOPIC_NAME" \
        --description "Triggers on new object uploads to COS bucket" \
        --sources "$SOURCES_JSON" \
        --output json)
    TOPIC_ID=$(echo "$TOPIC_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    echo "✓ Topic created"
else
    echo "Updating existing topic '$TOPIC_NAME'..."
    ibmcloud event-notifications topic-replace \
        --instance-id "$EN_INSTANCE_ID" \
        --id "$TOPIC_ID" \
        --name "$TOPIC_NAME" \
        --description "Triggers on new object uploads to COS bucket" \
        --sources "$SOURCES_JSON" > /dev/null
    echo "✓ Topic updated"
fi

echo "  Topic ID: $TOPIC_ID"

# Create or get webhook destination
DESTINATION_ID=$(ibmcloud event-notifications destinations --instance-id "$EN_INSTANCE_ID" --output json \
    | python3 -c "import sys,json; d=[x for x in json.load(sys.stdin)['destinations'] if x['name']=='$DESTINATION_NAME']; print(d[0]['id'] if d else '')")

if [ -z "$DESTINATION_ID" ]; then
    echo "Creating webhook destination '$DESTINATION_NAME'..."
    DEST_RESULT=$(ibmcloud event-notifications destination-create \
        --instance-id "$EN_INSTANCE_ID" \
        --name "$DESTINATION_NAME" \
        --type webhook \
        --config "{
            \"params\": {
                \"url\": \"${CE_FUNCTION_URL}\",
                \"verb\": \"post\",
                \"custom_headers\": {\"Content-Type\": \"application/json\"},
                \"sensitive_headers\": []
            }
        }" \
        --output json)
    DESTINATION_ID=$(echo "$DEST_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    echo "✓ Webhook destination created"
else
    echo "✓ Webhook destination '$DESTINATION_NAME' already exists"
fi

echo "  Destination ID: $DESTINATION_ID"

# Create subscription
SUBSCRIPTION_ID=$(ibmcloud event-notifications subscriptions --instance-id "$EN_INSTANCE_ID" --output json \
    | python3 -c "import sys,json; s=[x for x in json.load(sys.stdin)['subscriptions'] if x['name']=='$SUBSCRIPTION_NAME']; print(s[0]['id'] if s else '')")

if [ -z "$SUBSCRIPTION_ID" ]; then
    echo "Creating subscription '$SUBSCRIPTION_NAME'..."
    SUB_RESULT=$(ibmcloud event-notifications subscription-create \
        --instance-id "$EN_INSTANCE_ID" \
        --name "$SUBSCRIPTION_NAME" \
        --topic-id "$TOPIC_ID" \
        --destination-id "$DESTINATION_ID" \
        --output json)
    SUBSCRIPTION_ID=$(echo "$SUB_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    echo "✓ Subscription created"
else
    echo "✓ Subscription '$SUBSCRIPTION_NAME' already exists"
fi

echo "  Subscription ID: $SUBSCRIPTION_ID"
echo ""

# ============================================================================
# SETUP COMPLETE
# ============================================================================

echo "=========================================="
echo "✓ Setup Complete!"
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "  COS Bucket:        $COS_BUCKET_NAME"
echo "  EN Instance:       $EN_INSTANCE_NAME ($EN_INSTANCE_ID)"
echo "  Topic:             $TOPIC_NAME ($TOPIC_ID)"
echo "  Destination:       $DESTINATION_NAME ($DESTINATION_ID)"
echo "  Subscription:      $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "  CE Function:       $CE_FUNCTION_NAME"
echo "  Function URL:      $CE_FUNCTION_URL"
echo ""
echo "Next Steps:"
echo "  1. Test the pipeline by uploading a file to the bucket:"
echo "     ibmcloud cos object-put --bucket $COS_BUCKET_NAME --key test/sample.pdf --body ./sample.pdf --region us-south"
echo ""
echo "  2. Verify the function was triggered:"
echo "     ibmcloud ce function get --name $CE_FUNCTION_NAME"
echo ""
echo "  3. Or test the function directly:"
echo "     curl -X POST $CE_FUNCTION_URL -H 'Content-Type: application/json' -d '{\"data\":{\"notification\":{\"object_name\":\"test/sample.pdf\",\"bucket_name\":\"$COS_BUCKET_NAME\"}}}'"
echo ""
echo "  4. To teardown everything, run: ./teardown.sh"
echo ""

# Made with Bob
