#!/bin/bash
#
# Valkey/Redis Service Assessment Script
#
# Usage: scripts/assess_valkey_service.sh <namespace>
#
# Example: scripts/assess_valkey_service.sh my-namespace
#

set -e

if [ -z "$1" ]; then
    echo "ERROR: Namespace required" >&2
    echo "Usage: $0 <namespace>" >&2
    exit 1
fi

NAMESPACE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_SCRIPT="${SCRIPT_DIR}/query_newrelic.sh"

echo "========================================="
echo "Valkey Assessment: ${NAMESPACE}"
echo "========================================="
echo "Namespace: ${NAMESPACE}"
echo ""

# Query: Cache-Specific Metrics
echo ">>> Querying Cache-Specific Metrics..."
CACHE_QUERY_FILE=$(mktemp)
trap "rm -f ${CACHE_QUERY_FILE}" EXIT
cat > "${CACHE_QUERY_FILE}" <<EOF
FROM Metric SELECT
  average(redis_connected_clients) AS 'Avg Connections',
  percentile(redis_connected_clients, 95) AS 'p95 Connections',
  latest(redis_config_maxclients) AS 'Max Connections',
  latest(redis_evicted_keys_total) AS 'Total Evictions',
  rate(sum(redis_evicted_keys_total), 1 hour) AS 'Evictions/hour',
  sum(redis_keyspace_hits_total) AS 'Total Cache Hits',
  sum(redis_keyspace_misses_total) AS 'Total Cache Misses',
  (sum(redis_keyspace_hits_total) / (sum(redis_keyspace_hits_total) + sum(redis_keyspace_misses_total))) * 100 AS 'Hit Rate %',
  average(redis_mem_fragmentation_ratio) AS 'Avg Fragmentation',
  percentile(redis_mem_fragmentation_ratio, 95) AS 'p95 Fragmentation',
  average(redis_memory_used_bytes) / 1024 / 1024 AS 'Avg Memory Used (MB)',
  percentile(redis_memory_used_bytes / 1024 / 1024, 95) AS 'p95 Memory Used (MB)',
  latest(redis_config_maxmemory) / 1024 / 1024 AS 'Maxmemory (MB)',
  latest(redis_rejected_connections_total) AS 'Rejected Connections'
WHERE namespaceName = '${NAMESPACE}'
FACET CASES (
  WHERE podName LIKE '%sentinel%' AS 'sentinel',
  WHERE podName LIKE '%valkey%' AS 'valkey',
  WHERE podName LIKE '%redis%' AS 'redis'
)
SINCE 1 month ago
LIMIT MAX
EOF

"${QUERY_SCRIPT}" -t 300 -q "${CACHE_QUERY_FILE}"
