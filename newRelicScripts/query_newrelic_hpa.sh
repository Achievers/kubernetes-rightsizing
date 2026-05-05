#!/bin/bash
#
# Query New Relic NerdGraph API for HPA scaling metrics
#
# Usage: scripts/query_newrelic_hpa.sh <namespace> <hpa-name> [days]
#
#   days: optional number of days to query (default: 30)
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <namespace> <hpa-name> [days]"
    echo ""
    echo "Example:"
    echo "  $0 my-namespace my-hpa"
    echo "  $0 my-namespace my-hpa 7"
    exit 1
fi

NAMESPACE="$1"
HPA_NAME="$2"
DAYS="${3:-30}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_SCRIPT="${SCRIPT_DIR}/query_newrelic.sh"

# Build the NRQL query
# percentage(count(*), WHERE desiredReplicas > minReplicas) gives the fraction of
# samples where the HPA was scaled above its minimum, i.e. actively scaling.
NRQL_QUERY="SELECT min(desiredReplicas), max(desiredReplicas), percentile(desiredReplicas,50,85,99), percentage(count(*), WHERE desiredReplicas > minReplicas) AS aboveMinPct, percentage(count(*), WHERE desiredReplicas >= maxReplicas) AS atMaxPct FROM K8sHpaSample WHERE namespaceName = '$NAMESPACE' AND displayName = '$HPA_NAME' SINCE $DAYS days ago"

# Create a temporary file for the query
QUERY_FILE=$(mktemp)
TEMP_OUTPUT=$(mktemp)
trap "rm -f ${QUERY_FILE} ${TEMP_OUTPUT}" EXIT
echo "$NRQL_QUERY" > "${QUERY_FILE}"

# Parse and display results
echo "HPA SCALING METRICS (${DAYS} days):"

if "${QUERY_SCRIPT}" -q "${QUERY_FILE}" -f json 2>/dev/null > "${TEMP_OUTPUT}"; then
    RESULTS=$(cat "${TEMP_OUTPUT}")

    # Extract results using jq
    if [ "$RESULTS" != "[]" ] && [ "$RESULTS" != "null" ]; then
        echo "$RESULTS" | jq -r '.[] |
            "  Min Replicas:          \(.["min.desiredReplicas"] // "N/A")",
            "  Max Replicas:          \(.["max.desiredReplicas"] // "N/A")",
            "  P50 Replicas:          \(.["percentile.desiredReplicas"]["50"] // "N/A")",
            "  P85 Replicas:          \(.["percentile.desiredReplicas"]["85"] // "N/A")",
            "  P99 Replicas:          \(.["percentile.desiredReplicas"]["99"] // "N/A")",
            "  % Time Above Min:      \(.aboveMinPct | if . != null then (. * 10 | round / 10 | tostring) + "%" else "N/A" end)",
            "  % Time At Max:         \(.atMaxPct | if . != null then (. * 10 | round / 10 | tostring) + "%" else "N/A" end)"'
    else
        echo "  No results found"
    fi
else
    echo "  ERROR: Could not retrieve HPA metrics from New Relic"
fi
echo ""
