#!/bin/bash
# CRM app test suite
# Usage: ./test_crm.sh

set -e

SCRIPT_DIR="$(dirname "$0")"
CURL_HELPER="/home/alistair/mochi/claude/scripts/curl.sh"

PASSED=0
FAILED=0
CRM_ENTITY=""
OBJECT_ID=""
OBJECT_ID_2=""
COMMENT_ID=""

pass() {
    echo "[PASS] $1"
    ((PASSED++)) || true
}

fail() {
    echo "[FAIL] $1: $2"
    ((FAILED++))
}

# Helper for class-level routes (no entity context)
crm_curl() {
    local method="$1"
    local path="$2"
    shift 2
    "$CURL_HELPER" -a admin -X "$method" "$@" "/crm$path"
}

# Helper for entity-level routes (uses /-/ prefix)
crm_api_curl() {
    local method="$1"
    local path="$2"
    shift 2
    "$CURL_HELPER" -a admin -X "$method" "$@" "$BASE_URL/-$path"
}

echo "=============================================="
echo "CRM Test Suite"
echo "=============================================="

# ============================================================================
# CRM CREATION
# ============================================================================

echo ""
echo "--- CRM Creation ---"

# Test: Create CRM
RESULT=$(crm_curl POST "/-/create" -H "Content-Type: application/json" -d '{"name":"Test CRM","prefix":"TST"}')
if echo "$RESULT" | grep -q '"id":"'; then
    CRM_ENTITY=$(echo "$RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    if [ -n "$CRM_ENTITY" ]; then
        pass "Create CRM (entity: $CRM_ENTITY)"
        BASE_URL="/crm/$CRM_ENTITY"
    else
        fail "Create CRM" "Could not extract entity ID"
        exit 1
    fi
else
    fail "Create CRM" "$RESULT"
    exit 1
fi

# Test: Create CRM without name (should fail)
RESULT=$(crm_curl POST "/-/create" -H "Content-Type: application/json" -d '{}')
if echo "$RESULT" | grep -q '"error"'; then
    pass "Create CRM without name (rejected)"
else
    fail "Create CRM without name" "Expected error, got: $RESULT"
fi

# ============================================================================
# CRM INFO & UPDATE
# ============================================================================

echo ""
echo "--- CRM Info & Update ---"

# Test: Get CRM info
RESULT=$(crm_api_curl GET "/info")
if echo "$RESULT" | grep -q '"name":"Test CRM"' && echo "$RESULT" | grep -q '"prefix":"TST"'; then
    pass "Get CRM info"
else
    fail "Get CRM info" "$RESULT"
fi

# Test: CRM has template-created classes
RESULT=$(crm_api_curl GET "/info")
if echo "$RESULT" | grep -q '"classes":\['; then
    pass "CRM has classes from template"
else
    fail "CRM has classes from template" "$RESULT"
fi

# Test: CRM has template-created views
if echo "$RESULT" | grep -q '"views":\['; then
    pass "CRM has views from template"
else
    fail "CRM has views from template" "$RESULT"
fi

# Test: Update CRM
RESULT=$(crm_api_curl POST "/update" -H "Content-Type: application/json" -d '{"name":"Updated CRM","description":"A test CRM"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Update CRM"
else
    fail "Update CRM" "$RESULT"
fi

# Verify update
RESULT=$(crm_api_curl GET "/info")
if echo "$RESULT" | grep -q '"name":"Updated CRM"' && echo "$RESULT" | grep -q '"description":"A test CRM"'; then
    pass "Verify CRM update"
else
    fail "Verify CRM update" "$RESULT"
fi

# ============================================================================
# CLASS MANAGEMENT
# ============================================================================

echo ""
echo "--- Class Management ---"

# Test: List classes
RESULT=$(crm_api_curl GET "/classes")
if echo "$RESULT" | grep -q '"classes":\['; then
    pass "List classes"
else
    fail "List classes" "$RESULT"
fi

# Test: Create class
RESULT=$(crm_api_curl POST "/classes/create" -H "Content-Type: application/json" -d '{"id":"lead","name":"Lead"}')
if echo "$RESULT" | grep -q '"id":"lead"'; then
    pass "Create class"
else
    fail "Create class" "$RESULT"
fi

# Test: Update class
RESULT=$(crm_api_curl POST "/classes/lead/update" -H "Content-Type: application/json" -d '{"name":"Sales Lead"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Update class"
else
    fail "Update class" "$RESULT"
fi

# ============================================================================
# FIELD MANAGEMENT
# ============================================================================

echo ""
echo "--- Field Management ---"

# Test: Create field (server generates ID as classid_fieldname)
RESULT=$(crm_api_curl POST "/classes/lead/fields/create" -H "Content-Type: application/json" -d '{"id":"source","name":"Lead Source","fieldtype":"enumerated"}')
FIELD_ID=$(echo "$RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
if [ -n "$FIELD_ID" ]; then
    pass "Create field (id: $FIELD_ID)"
else
    fail "Create field" "$RESULT"
    FIELD_ID="lead_source"  # fallback
fi

# Test: List fields
RESULT=$(crm_api_curl GET "/classes/lead/fields")
if echo "$RESULT" | grep -q "\"$FIELD_ID\""; then
    pass "List fields"
else
    fail "List fields" "$RESULT"
fi

# Test: Create field option
RESULT=$(crm_api_curl POST "/classes/lead/fields/$FIELD_ID/options/create" -H "Content-Type: application/json" -d '{"id":"website","name":"Website","colour":"#3b82f6"}')
if echo "$RESULT" | grep -q '"id":"website"'; then
    pass "Create field option"
else
    fail "Create field option" "$RESULT"
fi

# Test: Create second option
RESULT=$(crm_api_curl POST "/classes/lead/fields/$FIELD_ID/options/create" -H "Content-Type: application/json" -d '{"id":"referral","name":"Referral","colour":"#22c55e"}')
if echo "$RESULT" | grep -q '"id":"referral"'; then
    pass "Create second option"
else
    fail "Create second option" "$RESULT"
fi

# Test: List options
RESULT=$(crm_api_curl GET "/classes/lead/fields/$FIELD_ID/options")
if echo "$RESULT" | grep -q '"website"' && echo "$RESULT" | grep -q '"referral"'; then
    pass "List field options"
else
    fail "List field options" "$RESULT"
fi

# Test: Update field
RESULT=$(crm_api_curl POST "/classes/lead/fields/$FIELD_ID/update" -H "Content-Type: application/json" -d '{"name":"Source Channel"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Update field"
else
    fail "Update field" "$RESULT"
fi

# ============================================================================
# HIERARCHY
# ============================================================================

echo ""
echo "--- Hierarchy ---"

# Test: Set hierarchy (lead can be a root object; parents is a comma-separated string, "" means root)
RESULT=$(crm_api_curl POST "/classes/lead/hierarchy/set" -H "Content-Type: application/json" -d '{"parents":""}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Set hierarchy"
else
    fail "Set hierarchy" "$RESULT"
fi

# Test: Get hierarchy
RESULT=$(crm_api_curl GET "/classes/lead/hierarchy")
if echo "$RESULT" | grep -q '"parents"'; then
    pass "Get hierarchy"
else
    fail "Get hierarchy" "$RESULT"
fi

# ============================================================================
# OBJECT LIFECYCLE
# ============================================================================

echo ""
echo "--- Object Lifecycle ---"

# Test: Create object (use template "company" class which can be root)
RESULT=$(crm_api_curl POST "/objects/create" -H "Content-Type: application/json" -d '{"class":"company","title":"Acme Corp"}')
if echo "$RESULT" | grep -q '"id":"'; then
    OBJECT_ID=$(echo "$RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    pass "Create object (id: $OBJECT_ID)"
else
    fail "Create object" "$RESULT"
fi

# Test: Create second object
RESULT=$(crm_api_curl POST "/objects/create" -H "Content-Type: application/json" -d '{"class":"company","title":"Beta Inc"}')
if echo "$RESULT" | grep -q '"id":"'; then
    OBJECT_ID_2=$(echo "$RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    pass "Create second object (id: $OBJECT_ID_2)"
else
    fail "Create second object" "$RESULT"
fi

# Test: List objects
RESULT=$(crm_api_curl GET "/objects")
if echo "$RESULT" | grep -q '"objects":\[' && echo "$RESULT" | grep -q "$OBJECT_ID"; then
    pass "List objects"
else
    fail "List objects" "$RESULT"
fi

# Test: Get object
RESULT=$(crm_api_curl GET "/objects/$OBJECT_ID")
if echo "$RESULT" | grep -q "$OBJECT_ID"; then
    pass "Get object"
else
    fail "Get object" "$RESULT"
fi

# Test: Update object
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/update" -H "Content-Type: application/json" -d '{"class":"company"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Update object"
else
    fail "Update object" "$RESULT"
fi

# ============================================================================
# VALUES
# ============================================================================

echo ""
echo "--- Values ---"

# Test: Set single field value (use "domain" field from template's company class)
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/values/domain" -H "Content-Type: application/json" -d '{"value":"acme.com"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Set field value"
else
    fail "Set field value" "$RESULT"
fi

# Verify value was set
RESULT=$(crm_api_curl GET "/objects/$OBJECT_ID")
if echo "$RESULT" | grep -q '"acme.com"'; then
    pass "Verify field value"
else
    fail "Verify field value" "$RESULT"
fi

# Test: Set multiple values (bulk)
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/values" -H "Content-Type: application/json" -d '{"domain":"acme.io","name":"Acme Corp Updated"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Set multiple values"
else
    fail "Set multiple values" "$RESULT"
fi

# ============================================================================
# LINKS
# ============================================================================

echo ""
echo "--- Links ---"

# Test: Create link (requires linktype: blocks, blocked_by, relates, or duplicates)
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/links/create" -H "Content-Type: application/json" -d "{\"target\":\"$OBJECT_ID_2\",\"linktype\":\"relates\"}")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Create link"
else
    fail "Create link" "$RESULT"
fi

# Test: List links
RESULT=$(crm_api_curl GET "/objects/$OBJECT_ID/links")
if echo "$RESULT" | grep -q "$OBJECT_ID_2"; then
    pass "List links"
else
    fail "List links" "$RESULT"
fi

# Test: Delete link
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/links/delete" -H "Content-Type: application/json" -d "{\"target\":\"$OBJECT_ID_2\",\"linktype\":\"relates\"}")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete link"
else
    fail "Delete link" "$RESULT"
fi

# ============================================================================
# COMMENTS
# ============================================================================

echo ""
echo "--- Comments ---"

# Test: Create comment (field is "content", uses FormData)
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/comments/create" -F "content=This is a test comment")
if echo "$RESULT" | grep -q '"id":"'; then
    COMMENT_ID=$(echo "$RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    pass "Create comment (id: $COMMENT_ID)"
else
    fail "Create comment" "$RESULT"
fi

# Test: List comments
RESULT=$(crm_api_curl GET "/objects/$OBJECT_ID/comments")
if echo "$RESULT" | grep -q '"comments":\[' && echo "$RESULT" | grep -q "This is a test comment"; then
    pass "List comments"
else
    fail "List comments" "$RESULT"
fi

# Test: Update comment
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/comments/$COMMENT_ID/update" -H "Content-Type: application/json" -d '{"content":"Updated comment"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Update comment"
else
    fail "Update comment" "$RESULT"
fi

# Test: Delete comment
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/comments/$COMMENT_ID/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete comment"
else
    fail "Delete comment" "$RESULT"
fi

# ============================================================================
# WATCHERS
# ============================================================================

echo ""
echo "--- Watchers ---"

# Test: Add watcher
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/watchers/add")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Add watcher"
else
    fail "Add watcher" "$RESULT"
fi

# Test: List watchers
RESULT=$(crm_api_curl GET "/objects/$OBJECT_ID/watchers")
if echo "$RESULT" | grep -q '"watchers":\['; then
    pass "List watchers"
else
    fail "List watchers" "$RESULT"
fi

# Test: Remove watcher
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/watchers/remove")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Remove watcher"
else
    fail "Remove watcher" "$RESULT"
fi

# ============================================================================
# ACTIVITY
# ============================================================================

echo ""
echo "--- Activity ---"

# Test: Get activity (should have entries from previous operations)
RESULT=$(crm_api_curl GET "/objects/$OBJECT_ID/activity")
if echo "$RESULT" | grep -q '"activities":\['; then
    pass "Get activity"
else
    fail "Get activity" "$RESULT"
fi

# ============================================================================
# VIEW MANAGEMENT
# ============================================================================

echo ""
echo "--- View Management ---"

# Test: List views
RESULT=$(crm_api_curl GET "/views")
if echo "$RESULT" | grep -q '"views":\['; then
    pass "List views"
else
    fail "List views" "$RESULT"
fi

# Test: Create view
RESULT=$(crm_api_curl POST "/views/create" -H "Content-Type: application/json" -d '{"name":"Test View","viewtype":"list"}')
if echo "$RESULT" | grep -q '"id":"'; then
    VIEW_ID=$(echo "$RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    pass "Create view (id: $VIEW_ID)"
else
    fail "Create view" "$RESULT"
fi

# Test: Update view
RESULT=$(crm_api_curl POST "/views/$VIEW_ID/update" -H "Content-Type: application/json" -d '{"name":"Updated View"}')
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Update view"
else
    fail "Update view" "$RESULT"
fi

# Test: Delete view
RESULT=$(crm_api_curl POST "/views/$VIEW_ID/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete view"
else
    fail "Delete view" "$RESULT"
fi

# ============================================================================
# DESIGN EXPORT/IMPORT
# ============================================================================

echo ""
echo "--- Design Export/Import ---"

# Test: Export design
RESULT=$(crm_api_curl GET "/design/export")
if echo "$RESULT" | grep -q '"classes":\[' && echo "$RESULT" | grep -q '"fields":'; then
    pass "Export design"
else
    fail "Export design" "$RESULT"
fi

# ============================================================================
# PEOPLE
# ============================================================================

echo ""
echo "--- People ---"

# Test: List people
RESULT=$(crm_api_curl GET "/people")
if echo "$RESULT" | grep -q '"people":\['; then
    pass "List people"
else
    fail "List people" "$RESULT"
fi

# ============================================================================
# ACCESS CONTROL
# ============================================================================

echo ""
echo "--- Access Control ---"

# Test: List access
RESULT=$(crm_api_curl GET "/access")
if echo "$RESULT" | grep -q '"rules":\['; then
    pass "List access"
else
    fail "List access" "$RESULT"
fi

# ============================================================================
# CLEANUP
# ============================================================================

echo ""
echo "--- Cleanup ---"

# Test: Delete object
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete object"
else
    fail "Delete object" "$RESULT"
fi

# Test: Delete second object
RESULT=$(crm_api_curl POST "/objects/$OBJECT_ID_2/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete second object"
else
    fail "Delete second object" "$RESULT"
fi

# Test: Delete option
RESULT=$(crm_api_curl POST "/classes/lead/fields/$FIELD_ID/options/website/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete option"
else
    fail "Delete option" "$RESULT"
fi

# Test: Delete field
RESULT=$(crm_api_curl POST "/classes/lead/fields/$FIELD_ID/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete field"
else
    fail "Delete field" "$RESULT"
fi

# Test: Delete class
RESULT=$(crm_api_curl POST "/classes/lead/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete class"
else
    fail "Delete class" "$RESULT"
fi

# Test: Delete CRM
RESULT=$(crm_api_curl POST "/delete")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "Delete CRM"
else
    fail "Delete CRM" "$RESULT"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "=============================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=============================================="

if [ $FAILED -gt 0 ]; then
    exit 1
fi
