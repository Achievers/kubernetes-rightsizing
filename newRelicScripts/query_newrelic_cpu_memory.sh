#!/bin/bash
#
# Query New Relic NerdGraph API for CPU and Memory metrics over a long time period
#
# Usage: ./query_newrelic_cpu_memory.sh <namespace>
#
# Example: ./query_newrelic_cpu_memory.sh my-namespace
#

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <namespace>"
    echo ""
    echo "Example:"
    echo "  $0 my-namespace"
    exit 1
fi

NAMESPACE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_SCRIPT="${SCRIPT_DIR}/query_newrelic.sh"

# Build the NRQL query
NRQL_QUERY="SELECT (average(containerCpuCfsThrottledPeriodsDelta) / average(containerCpuCfsPeriodsDelta)) * 100 AS 'Throttle %', average(containerCpuCfsThrottledSecondsDelta) * 1000 AS 'Throttled ms', latest(cpuRequestedCores)*1000 AS 'current CPU request', average(cpuUsedCores)*1000 AS 'avg CPU usage', percentile(cpuUsedCores, 50)*1000 AS 'p50 CPU usage', ceil(percentile(cpuUsedCores, 85) * 100)*10 AS 'suggested CPU request (p85)', ceil(percentile(cpuUsedCores, 99) * 100)*10 AS 'suggested CPU request (p99)', latest(cpuLimitCores)*1000 AS 'current CPU limit', clamp_min(ceil(percentile(cpuUsedCores, 99.9) *1000/256)*256,156) AS 'suggested CPU limit', latest(memoryRequestedBytes / 1024 / 1024) AS 'current Memory request (MB)', ceil(percentile(memoryUsedBytes / 1024 / 1024, 60) * (1 + 50 / 100)) AS 'suggested Memory request (MB)', latest(memoryLimitBytes / 1024 / 1024) AS 'current Memory limit (MB)', ceil(percentile(memoryUsedBytes / 1024 / 1024, 100) * 1.1 + 128) AS 'suggested Memory limit (MB)' FROM K8sContainerSample SINCE 1 month ago WHERE weekdayOf(timestamp) NOT IN (1, 7) AND namespaceName = '$NAMESPACE' FACET containerName,deploymentName, namespaceName LIMIT MAX"

echo "Querying New Relic for namespace: $NAMESPACE"
echo "This may take a while due to the 1-month time range..."
echo ""

# Create a temporary file for the query
QUERY_FILE=$(mktemp)
trap "rm -f ${QUERY_FILE}" EXIT
echo "$NRQL_QUERY" > "${QUERY_FILE}"

# Parse and display results
echo "CPU AND MEMORY METRICS (1 month, weekdays only):"
echo "=================================================="
echo ""

# Use the generic query script with extended timeout (5 minutes)
# Capture both stdout and stderr to parse the results ourselves
TEMP_OUTPUT=$(mktemp)
trap "rm -f ${QUERY_FILE} ${TEMP_OUTPUT}" EXIT

if "${QUERY_SCRIPT}" -t 300 -q "${QUERY_FILE}" -f json 2>/dev/null > "${TEMP_OUTPUT}"; then
    RESULTS=$(cat "${TEMP_OUTPUT}")

    if [ "$RESULTS" = "[]" ] || [ "$RESULTS" = "null" ]; then
        echo "No results found for namespace: $NAMESPACE"
        exit 0
    fi

    # Format the output in a readable table format
    echo "$RESULTS" | jq -r '.[] |
        def format_number: if type == "number" then (. * 100 | round / 100) else . end;
        "Container: \(.containerName // .facet[0])",
        "Deployment: \(.deploymentName // .facet[1])",
        "Namespace: \(.namespaceName // .facet[2])",
        "  CPU Throttle %:              \(.["Throttle %"] // "N/A" | format_number)",
        "  CPU Throttled ms:            \(.["Throttled ms"] // "N/A" | format_number)",
        "  Current CPU Request:         \(.["current CPU request"] // "N/A" | format_number) m",
        "  Avg CPU Usage:               \(.["avg CPU usage"] // "N/A" | format_number) m",
        "  P50 CPU Usage:               \(.["p50 CPU usage"] // "N/A" | format_number) m",
        "  Suggested CPU Request (p85): \(.["suggested CPU request (p85)"] // "N/A" | format_number) m",
        "  Suggested CPU Request (p99): \(.["suggested CPU request (p99)"] // "N/A" | format_number) m",
        "  Current CPU Limit:           \(.["current CPU limit"] // "N/A" | format_number) m",
        "  Suggested CPU Limit:         \(.["suggested CPU limit"] // "N/A" | format_number) m",
        "  Current Memory Request:      \(.["current Memory request (MB)"] // "N/A" | format_number) MB",
        "  Suggested Memory Request:    \(.["suggested Memory request (MB)"] // "N/A" | format_number) MB",
        "  Current Memory Limit:        \(.["current Memory limit (MB)"] // "N/A" | format_number) MB",
        "  Suggested Memory Limit:      \(.["suggested Memory limit (MB)"] // "N/A" | format_number) MB",
        ""'
else
    echo "ERROR: Could not retrieve metrics from New Relic"
    exit 1
fi
