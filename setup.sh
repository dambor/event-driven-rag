#!/bin/bash
set -euo pipefail  # Exit on error, unset vars, and pipe failures

# ============================================================================
# COS → Langflow Auto-Trigger Setup Script
# ============================================================================
# This script automates the complete setup of the event-driven pipeline:
# COS bucket → Code Engine subscription → Code Engine App → Langflow
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

# Safe .env parser — reads only KEY=VALUE lines, does not execute shell code
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        else
            value=$(echo "$value" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')
        fi
        export "$key=$value"
    fi
done < .env

echo "✓ Configuration loaded"
echo ""

# Validate required variables
REQUIRED_VARS=(
    "LANGFLOW_URL"
    "LANGFLOW_API_KEY"
    "COS_BUCKET_NAME"
    "COS_COMPONENT_ID"
    "COS_REGION"
    "CE_PROJECT_NAME"
    "CE_APP_NAME"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable $var is not set in .env"
        exit 1
    fi
done

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================

echo "Checking prerequisites..."

if ! command -v ibmcloud &> /dev/null; then
    echo "ERROR: ibmcloud CLI is not installed"
    echo "Install from: https://cloud.ibm.com/docs/cli?topic=cli-install-ibmcloud-cli"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is not installed"
    exit 1
fi

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

if ! ibmcloud plugin list | grep -q "code-engine"; then
    echo "Installing code-engine plugin..."
    ibmcloud plugin install code-engine -f
else
    echo "✓ code-engine plugin already installed"
fi

if ! ibmcloud plugin list | grep -q "cloud-object-storage"; then
    echo "Installing cloud-object-storage plugin..."
    ibmcloud plugin install cloud-object-storage -f
else
    echo "✓ cloud-object-storage plugin already installed"
fi

echo ""

# ============================================================================
# STEP 2: Target Region and Create Code Engine Project
# ============================================================================

echo "Step 2: Setting up Code Engine project..."

# CE project must be in the same region as the COS bucket for subscriptions to work
echo "Targeting region '$COS_REGION' (must match bucket region)..."
ibmcloud target -r "$COS_REGION" > /dev/null
echo "✓ Region set to '$COS_REGION'"

# Use project select as the existence check — it fails naturally if the project
# doesn't exist in the currently targeted region, avoiding JSON field ambiguity.
if ibmcloud ce project select --name "$CE_PROJECT_NAME" &>/dev/null; then
    echo "✓ Code Engine project '$CE_PROJECT_NAME' already exists"
else
    echo "Creating Code Engine project '$CE_PROJECT_NAME'..."
    ibmcloud ce project create --name "$CE_PROJECT_NAME"
fi

# Use project get to extract the ID — reliable immediately after create/select
CE_PROJECT_ID=$(ibmcloud ce project get --name "$CE_PROJECT_NAME" \
    | awk '/^ID:/{print $NF}')

if [ -z "$CE_PROJECT_ID" ]; then
    echo "ERROR: Could not retrieve CE project ID"
    exit 1
fi

echo "  Project ID: $CE_PROJECT_ID"
echo ""

# ============================================================================
# STEP 3: Deploy Code Engine App
# ============================================================================

echo "Step 3: Deploying Code Engine app '$CE_APP_NAME'..."

# Verify required source files exist
for f in main.py app.py requirements.txt; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found in the current directory"
        exit 1
    fi
done
echo "✓ Source files found (main.py, app.py, requirements.txt)"

if ibmcloud ce app get --name "$CE_APP_NAME" &>/dev/null; then
    echo "Updating existing app '$CE_APP_NAME'..."
    ibmcloud ce app update \
        --name "$CE_APP_NAME" \
        --build-source . \
        --env LANGFLOW_URL="$LANGFLOW_URL" \
        --env LANGFLOW_API_KEY="$LANGFLOW_API_KEY" \
        --env COS_COMPONENT_ID="$COS_COMPONENT_ID"
    echo "✓ App updated"
else
    echo "Creating app '$CE_APP_NAME'..."
    ibmcloud ce app create \
        --name "$CE_APP_NAME" \
        --build-source . \
        --port 8080 \
        --min-scale 0 \
        --max-scale 1 \
        --env LANGFLOW_URL="$LANGFLOW_URL" \
        --env LANGFLOW_API_KEY="$LANGFLOW_API_KEY" \
        --env COS_COMPONENT_ID="$COS_COMPONENT_ID"
    echo "✓ App created"
fi

CE_APP_URL=$(ibmcloud ce app get --name "$CE_APP_NAME" \
    | awk '/^URL:/{print $2}')

echo "  App URL: $CE_APP_URL"
echo ""

# ============================================================================
# STEP 4: Create IAM Authorization and COS Subscription
# ============================================================================

echo "Step 4: Configuring COS event subscription..."

# Get COS service instance ID via the Resource Configuration API
IAM_TOKEN=$(ibmcloud iam oauth-tokens | awk '/^IAM token:/{print $4}')
if [ -z "$IAM_TOKEN" ]; then
    echo "ERROR: Failed to retrieve IAM token"
    exit 1
fi

COS_INSTANCE_ID=$(curl -s \
    "https://config.cloud-object-storage.cloud.ibm.com/v1/b/${COS_BUCKET_NAME}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['service_instance_id'])")

echo "  COS Instance ID: $COS_INSTANCE_ID"

# Create IAM authorization: Code Engine project → COS (required for subscriptions)
echo "Creating IAM authorization (Code Engine → COS)..."
if ibmcloud iam authorization-policy-create codeengine cloud-object-storage \
    "Notifications Manager" \
    --source-service-instance-id "$CE_PROJECT_ID" \
    --target-service-instance-id "$COS_INSTANCE_ID" 2>/dev/null; then
    echo "✓ IAM authorization created"
else
    echo "✓ IAM authorization already exists"
fi

# Create COS subscription
CE_SUB_NAME="${CE_APP_NAME}-cos-sub"

if ibmcloud ce subscription cos get --name "$CE_SUB_NAME" &>/dev/null; then
    echo "✓ COS subscription '$CE_SUB_NAME' already exists"
else
    echo "Creating COS subscription '$CE_SUB_NAME'..."
    ibmcloud ce subscription cos create \
        --name "$CE_SUB_NAME" \
        --destination "$CE_APP_NAME" \
        --destination-type app \
        --bucket "$COS_BUCKET_NAME" \
        --event-type write
    echo "✓ COS subscription created"
fi

# Verify ready status
READY_STATUS=$(ibmcloud ce subscription cos get --name "$CE_SUB_NAME" \
    | awk '/^Ready:/{print $2}')
if [ "$READY_STATUS" = "true" ]; then
    echo "✓ Subscription is ready"
else
    echo "  Note: Subscription may still be initializing. Check with:"
    echo "  ibmcloud ce subscription cos get --name $CE_SUB_NAME"
fi

echo ""

# ============================================================================
# SETUP COMPLETE
# ============================================================================

echo "=========================================="
echo "✓ Setup Complete!"
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "  COS Bucket:    $COS_BUCKET_NAME (region: $COS_REGION)"
echo "  CE Project:    $CE_PROJECT_NAME ($CE_PROJECT_ID)"
echo "  CE App:        $CE_APP_NAME"
echo "  App URL:       $CE_APP_URL"
echo "  Subscription:  $CE_SUB_NAME"
echo ""
echo "Next Steps:"
echo "  1. Test by uploading a file to the bucket:"
echo "     ibmcloud cos object-put --bucket $COS_BUCKET_NAME --key test/sample.pdf --body ./sample.pdf --region $COS_REGION"
echo ""
echo "  2. Watch the app logs to confirm the trigger fired:"
echo "     ibmcloud ce app logs --name $CE_APP_NAME --follow"
echo ""
echo "  3. Or test the app directly:"
echo "     curl -X POST $CE_APP_URL -H 'Content-Type: application/json' -d '{\"bucket\":\"$COS_BUCKET_NAME\",\"key\":\"test/sample.pdf\"}'"
echo ""
echo "  4. To teardown everything, run: ./teardown.sh"
echo ""

# Made with Bob
