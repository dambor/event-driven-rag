#!/bin/bash
set -euo pipefail  # Exit on error, unset vars, and pipe failures

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

echo "WARNING: This will delete the COS subscription, the Code Engine app,"
echo "         and optionally the Code Engine project."
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Teardown cancelled."
    exit 0
fi

echo ""

# Target the correct region
ibmcloud target -r "$COS_REGION" > /dev/null

# ============================================================================
# STEP 1: Delete COS Subscription
# ============================================================================

echo "Step 1: Deleting COS event subscription..."

CE_SUB_NAME="${CE_APP_NAME}-cos-sub"

if ibmcloud ce project select --name "$CE_PROJECT_NAME" 2>/dev/null; then
    if ibmcloud ce subscription cos get --name "$CE_SUB_NAME" &>/dev/null; then
        ibmcloud ce subscription cos delete --name "$CE_SUB_NAME" -f
        echo "✓ COS subscription '$CE_SUB_NAME' deleted"
    else
        echo "✓ COS subscription '$CE_SUB_NAME' not found (already deleted?)"
    fi
else
    echo "✓ Code Engine project '$CE_PROJECT_NAME' not found (already deleted?)"
fi

echo ""

# ============================================================================
# STEP 2: Delete Code Engine App
# ============================================================================

echo "Step 2: Deleting Code Engine app..."

if ibmcloud ce project select --name "$CE_PROJECT_NAME" 2>/dev/null; then
    if ibmcloud ce app get --name "$CE_APP_NAME" &>/dev/null; then
        ibmcloud ce app delete --name "$CE_APP_NAME" -f
        echo "✓ App '$CE_APP_NAME' deleted"
    else
        echo "✓ App '$CE_APP_NAME' not found (already deleted?)"
    fi

    echo ""
    read -p "Delete the entire Code Engine project '$CE_PROJECT_NAME'? (yes/no): " DELETE_PROJECT

    if [ "$DELETE_PROJECT" = "yes" ]; then
        echo "Deleting Code Engine project '$CE_PROJECT_NAME'..."
        ibmcloud ce project delete --name "$CE_PROJECT_NAME" -f --hard
        echo "✓ Code Engine project deleted"
    else
        echo "✓ Code Engine project preserved"
    fi
else
    echo "✓ Code Engine project '$CE_PROJECT_NAME' not found (already deleted?)"
fi

echo ""

# ============================================================================
# STEP 3: Remove IAM Authorization
# ============================================================================

echo "Step 3: Removing IAM authorization (Code Engine → COS)..."

CE_PROJECT_ID=$(ibmcloud ce project list --output json 2>/dev/null \
    | CE_PROJECT_NAME="$CE_PROJECT_NAME" python3 -c "
import sys, json, os
name = os.environ['CE_PROJECT_NAME']
projects = [p for p in json.load(sys.stdin) if p['name'] == name]
print(projects[0]['guid'] if projects else '')
" 2>/dev/null || echo "")

if [ -n "$CE_PROJECT_ID" ]; then
    AUTH_POLICY_ID=$(ibmcloud iam authorization-policies --output json 2>/dev/null \
        | CE_PROJECT_ID="$CE_PROJECT_ID" python3 -c "
import sys, json, os
ce_id = os.environ['CE_PROJECT_ID']
try:
    for p in json.load(sys.stdin):
        for s in p.get('subjects', []):
            for attr in s.get('attributes', []):
                if attr.get('name') == 'serviceInstance' and attr.get('value') == ce_id:
                    print(p['id'])
                    sys.exit(0)
    print('')
except:
    print('')
" 2>/dev/null || echo "")

    if [ -n "$AUTH_POLICY_ID" ]; then
        ibmcloud iam authorization-policy-delete "$AUTH_POLICY_ID" -f 2>/dev/null || true
        echo "✓ IAM authorization removed"
    else
        echo "✓ IAM authorization not found (already removed?)"
    fi
else
    echo "✓ CE project not found, skipping IAM authorization removal"
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
