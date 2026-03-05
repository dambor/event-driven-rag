#!/bin/bash
set -e  # Exit on any error

# ============================================================================
# COS → Langflow Auto-Trigger Teardown Script
# ============================================================================
# This script removes all resources created by setup.sh
# ============================================================================

echo "=========================================="
echo "COS → Langflow Auto-Trigger Teardown"
echo "=========================================="
echo ""

# ============================================================================
# LOAD CONFIGURATION FROM .env FILE
# ============================================================================

if [ ! -f ".env" ]; then
    echo "ERROR: .env file not found"
    echo ""
    echo "Cannot proceed without configuration."
    echo ""
    exit 1
fi

echo "Loading configuration from .env..."
set -a  # automatically export all variables
source .env
set +a
echo "✓ Configuration loaded"
echo ""

echo "WARNING: This will delete all Event Notifications resources,"
echo "         the Code Engine function, and remove activity tracking"
echo "         from the COS bucket."
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Teardown cancelled."
    exit 0
fi

echo ""

# ============================================================================
# STEP 1: Delete Event Notifications Resources
# ============================================================================

echo "Step 1: Deleting Event Notifications resources..."

# Get EN instance ID
EN_INSTANCE_ID=$(ibmcloud resource service-instances --service-name event-notifications --output json \
    | python3 -c "
import sys, json
instances = [i for i in json.load(sys.stdin) if i['name'] == '$EN_INSTANCE_NAME']
if instances:
    print(instances[0]['guid'])
else:
    print('')
")

if [ -z "$EN_INSTANCE_ID" ]; then
    echo "✓ Event Notifications instance '$EN_INSTANCE_NAME' not found (already deleted?)"
else
    echo "Found EN instance: $EN_INSTANCE_ID"
    
    # Delete all subscriptions
    echo "  Deleting subscriptions..."
    SUBSCRIPTION_IDS=$(ibmcloud event-notifications subscriptions --instance-id "$EN_INSTANCE_ID" --output json 2>/dev/null \
        | python3 -c "import sys,json; [print(x['id']) for x in json.load(sys.stdin).get('subscriptions', [])]" 2>/dev/null || echo "")
    
    if [ -n "$SUBSCRIPTION_IDS" ]; then
        echo "$SUBSCRIPTION_IDS" | while read -r SUB_ID; do
            if [ -n "$SUB_ID" ]; then
                ibmcloud event-notifications subscription-delete \
                    --instance-id "$EN_INSTANCE_ID" \
                    --id "$SUB_ID" -f 2>/dev/null || true
            fi
        done
        echo "  ✓ Subscriptions deleted"
    else
        echo "  ✓ No subscriptions to delete"
    fi
    
    # Delete custom webhook destinations
    echo "  Deleting webhook destinations..."
    WEBHOOK_IDS=$(ibmcloud event-notifications destinations --instance-id "$EN_INSTANCE_ID" --output json 2>/dev/null \
        | python3 -c "
import sys, json
for d in json.load(sys.stdin).get('destinations', []):
    if d['type'] == 'webhook':
        print(d['id'])
" 2>/dev/null || echo "")
    
    if [ -n "$WEBHOOK_IDS" ]; then
        echo "$WEBHOOK_IDS" | while read -r DEST_ID; do
            if [ -n "$DEST_ID" ]; then
                ibmcloud event-notifications destination-delete \
                    --instance-id "$EN_INSTANCE_ID" \
                    --id "$DEST_ID" -f 2>/dev/null || true
            fi
        done
        echo "  ✓ Webhook destinations deleted"
    else
        echo "  ✓ No webhook destinations to delete"
    fi
    
    # Delete all topics
    echo "  Deleting topics..."
    TOPIC_IDS=$(ibmcloud event-notifications topics --instance-id "$EN_INSTANCE_ID" --output json 2>/dev/null \
        | python3 -c "import sys,json; [print(x['id']) for x in json.load(sys.stdin).get('topics', [])]" 2>/dev/null || echo "")
    
    if [ -n "$TOPIC_IDS" ]; then
        echo "$TOPIC_IDS" | while read -r TOPIC_ID; do
            if [ -n "$TOPIC_ID" ]; then
                ibmcloud event-notifications topic-delete \
                    --instance-id "$EN_INSTANCE_ID" \
                    --id "$TOPIC_ID" -f 2>/dev/null || true
            fi
        done
        echo "  ✓ Topics deleted"
    else
        echo "  ✓ No topics to delete"
    fi
    
    # Disable Resource Lifecycle Events source
    echo "  Disabling Resource Lifecycle Events source..."
    RLE_SOURCE_ID=$(ibmcloud event-notifications sources --instance-id "$EN_INSTANCE_ID" --output json 2>/dev/null \
        | python3 -c "
import sys, json
for s in json.load(sys.stdin).get('sources', []):
    if s['type'] == 'resource-lifecycle-events':
        print(s['id'])
" 2>/dev/null || echo "")
    
    if [ -n "$RLE_SOURCE_ID" ]; then
        ibmcloud event-notifications source-update \
            --instance-id "$EN_INSTANCE_ID" \
            --id "$RLE_SOURCE_ID" \
            --enabled=false 2>/dev/null || true
        echo "  ✓ Resource Lifecycle Events source disabled"
    fi
fi

echo ""

# ============================================================================
# STEP 2: Delete Event Notifications Service Instance
# ============================================================================

echo "Step 2: Deleting Event Notifications service instance..."

if [ -n "$EN_INSTANCE_ID" ]; then
    ibmcloud resource service-instance-delete "$EN_INSTANCE_NAME" -f --recursive 2>/dev/null || true
    echo "✓ Event Notifications instance deleted"
else
    echo "✓ Event Notifications instance not found (already deleted?)"
fi

echo ""

# ============================================================================
# STEP 3: Remove Activity Tracking from COS Bucket
# ============================================================================

echo "Step 3: Removing activity tracking from COS bucket '$COS_BUCKET_NAME'..."

IAM_TOKEN=$(ibmcloud iam oauth-tokens | grep "IAM token" | awk '{print $4}')

# Remove activity tracking
curl -s -X PATCH \
    "https://config.cloud-object-storage.cloud.ibm.com/v1/b/${COS_BUCKET_NAME}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"activity_tracking": null}' > /dev/null 2>&1 || true

# Verify removal
TRACKING_STATUS=$(curl -s \
    "https://config.cloud-object-storage.cloud.ibm.com/v1/b/${COS_BUCKET_NAME}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('enabled' if 'activity_tracking' in d and d['activity_tracking'] and d['activity_tracking'].get('activity_tracker_crn') else 'disabled')" 2>/dev/null || echo "disabled")

if [ "$TRACKING_STATUS" = "disabled" ]; then
    echo "✓ Activity tracking removed from bucket '$COS_BUCKET_NAME'"
else
    echo "⚠ Could not verify activity tracking removal (bucket may not exist)"
fi

echo ""

# ============================================================================
# STEP 4: Delete Code Engine Function and Project
# ============================================================================

echo "Step 4: Deleting Code Engine function..."

# Check if project exists
CE_PROJECT_EXISTS=$(ibmcloud ce project list --output json 2>/dev/null \
    | python3 -c "import sys,json; projects=[p for p in json.load(sys.stdin) if p['name']=='$CE_PROJECT_NAME']; print('yes' if projects else 'no')" 2>/dev/null || echo "no")

if [ "$CE_PROJECT_EXISTS" = "yes" ]; then
    # Select the project
    ibmcloud ce project select --name "$CE_PROJECT_NAME" 2>/dev/null || true
    
    # Delete the function
    echo "  Deleting function '$CE_FUNCTION_NAME'..."
    ibmcloud ce fn delete --name "$CE_FUNCTION_NAME" -f 2>/dev/null || true
    echo "  ✓ Function deleted"
    
    # Ask if user wants to delete the entire project
    echo ""
    read -p "  Delete the entire Code Engine project '$CE_PROJECT_NAME'? (yes/no): " DELETE_PROJECT
    
    if [ "$DELETE_PROJECT" = "yes" ]; then
        echo "  Deleting Code Engine project '$CE_PROJECT_NAME'..."
        ibmcloud ce project delete --name "$CE_PROJECT_NAME" -f --hard 2>/dev/null || true
        echo "  ✓ Code Engine project deleted"
    else
        echo "  ✓ Code Engine project preserved"
    fi
else
    echo "✓ Code Engine project '$CE_PROJECT_NAME' not found (already deleted?)"
fi

echo ""

# ============================================================================
# TEARDOWN COMPLETE
# ============================================================================

echo "=========================================="
echo "✓ Teardown Complete!"
echo "=========================================="
echo ""
echo "All resources have been removed."
echo ""
echo "To set up again, run: ./setup.sh"
echo ""

# Made with Bob
