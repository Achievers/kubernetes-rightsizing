---
name: assess-hpa-sensitivity
description: Use when investigating whether Kubernetes HPAs are over-sensitive, scaling too aggressively, or hitting maxReplicas during off-peak periods. Applies when analyzing dead-period node spikes, services stuck at max replicas, or unexpected cluster autoscaler activity.
---

# HPA Sensitivity Assessment

## Overview

Diagnose HPA over-scaling by correlating replica behaviour with actual CPU usage and the **effective trigger** (request × threshold%). Most apparent "HPA sensitivity" problems are actually misconfigured CPU requests causing an absurdly low per-pod trigger.

## Effective Trigger — The Core Formula

```
effective trigger = cpu_request × (averageUtilization / 100)
```

A 10m request at 80% threshold = **8m trigger**. At average usage of 6m, the HPA perpetually votes to scale. The fix is usually the request, not the threshold.

## Step 1 — Establish the Off-Peak Window

**Ask the user to identify their off-peak period before querying.** Common examples:

- **Overnight**: "last night 2300–0300" — good for consumer SaaS with business-hours usage
- **Weekend**: "last Saturday" — good for B2B platforms with weekday-only traffic
- **Maintenance window**: a known scheduled quiet period

The goal is a window where legitimate load is minimal so any scaling is likely a misconfiguration signal rather than real demand. If unsure, ask: *"When does your platform see the least traffic — overnight, weekends, or a specific maintenance window?"*

Once confirmed, query that window:

```sql
SELECT
  max(desiredReplicas),
  min(desiredReplicas),
  min(minReplicas),
  max(maxReplicas),
  percentage(count(*), WHERE desiredReplicas > minReplicas)  AS aboveMinPct,
  percentage(count(*), WHERE desiredReplicas >= maxReplicas) AS atMaxPct
FROM K8sHpaSample
WHERE displayName LIKE '%grpc%'          -- filter by deployment pattern
  AND clusterName LIKE '%your-cluster%'  -- filter by cluster pattern
SINCE '<off-peak start>'
UNTIL '<off-peak end>'
FACET namespaceName, clusterName, displayName
LIMIT 100
```

**Red flags:**
| Signal | Meaning |
|---|---|
| `atMaxPct > 10%` | Hitting ceiling regularly — max too low or HPA too sensitive |
| `aboveMinPct = 100%` | Never scaled back — trigger may be below average load |
| `atMaxPct > 20%` during dead period | Almost certainly a mis-config, not real load |

## Step 2 — Concurrent Node Count (Accurate Method)

`uniqueCount` over long windows inflates during node churn (upgrade surge, replacements). Use a nested aggregation over 1-minute buckets:

```sql
SELECT
  max(nodeCount)            AS maxConcurrent,
  average(nodeCount)        AS avgConcurrent,
  percentile(nodeCount, 50) AS medianConcurrent
FROM (
  SELECT uniqueCount(nodeName) AS nodeCount
  FROM K8sNodeSample
  WHERE clusterName LIKE '%your-cluster%'
  FACET clusterName
  TIMESERIES 1 MINUTE
  LIMIT MAX
)
FACET clusterName
SINCE '<off-peak start>'
UNTIL '<off-peak end>'
```

If the 30-min `uniqueCount` is materially higher than the nested result, node churn (rolling upgrade, auto-repair) inflated it — not workload.

## Step 3 — Correlate with CPU Reality

Run `newRelicScripts/query_newrelic_cpu_memory.sh <namespace>` or query directly:

```sql
SELECT
  latest(cpuRequestedCores) * 1000       AS currentRequestM,
  average(cpuUsedCores) * 1000           AS avgUsageM,
  percentile(cpuUsedCores, 99) * 1000    AS p99UsageM,
  (average(containerCpuCfsThrottledSecondsDelta)
    / average(containerCpuCfsPeriodsDelta)) * 100 AS throttlePct
FROM K8sContainerSample
WHERE namespaceName = 'your-namespace'
  AND containerName = 'your-container'
  AND weekdayOf(timestamp) NOT IN (1, 7)
SINCE 1 month ago
FACET containerName, deploymentName
LIMIT MAX
```

## Step 4 — Classify Root Cause

Build this table for each flagged service:

| Service | Request | Threshold | Effective Trigger | 1m-weekday p99 | avg | atMaxPct | Root Cause |
|---|---|---|---|---|---|---|---|
| my-grpc | 10m | 80% | **8m** | 50m | 6m | 22% | Request too low |
| other-grpc | 100m | 50% | **50m** | 30m | 2m | 25% | Anomalous — investigate batch jobs |

### Root Cause Patterns

**Pattern A — Request too low (trigger < avg usage)**
- Symptom: `aboveMinPct = 100%`, avg CPU ≈ trigger
- Fix: Raise request to approximately `p99 × 0.9`

**Pattern B — p99 above trigger (legitimate spikes)**
- Symptom: avg CPU well below trigger, but occasional p99 spikes exceed it
- Fix: Raise request slightly, or raise threshold % if spikes are acceptable

**Pattern C — Anomalous (config looks correct but scaling to max)**
- Symptom: Trigger is above p99 yet HPA still hits max
- Cause: Batch/cron jobs causing spikes beyond 1-month p99; per-container p99 understates bursts
- Fix: Investigate scheduled jobs before changing config

**Pattern D — Node churn mistaken for workload**
- Symptom: Node count spike correlates with a GKE upgrade/repair event in Cloud Logging
- Fix: No action needed on HPA; check maintenance windows

## Step 5 — Check for Node Upgrade Activity

If node counts spike unexpectedly, check Cloud Logging before attributing to workload:

```bash
gcloud logging read \
  'resource.type="gke_cluster"
   AND (protoPayload.methodName:"UpdateClusterInternal"
        OR protoPayload.methodName:"UpdateNodePool")
   AND timestamp>="<off-peak start UTC>"
   AND timestamp<="<off-peak end UTC>"' \
  --project=YOUR_PROJECT \
  --format='table(timestamp,resource.labels.cluster_name,
                  protoPayload.methodName,
                  protoPayload.request.update.desiredNodeVersion)' \
  --limit=50
```

Rolling upgrades add surge nodes before draining old ones — expect a temporary 1.5–2× node count spike that resolves within ~1 hour.

## Suggested Request Calculation

```
suggested_request = ceil(p99_usage × 0.9 / 10) × 10   # round to nearest 10m
new_trigger       = suggested_request × (threshold / 100)
```

Validate: `new_trigger` should be comfortably above `avg_usage` and close to (but below) `p99_usage`.

## Output Format

```
HPA Assessment — <cluster> — <off-peak window e.g. "Sat 2025-01-04" or "overnight 2300–0300">

HITTING MAX (action required):
  <namespace>/<service>: atMax=X%, trigger=Ym, p99=Zm → raise request to ~Nm

ALWAYS ABOVE MIN (investigate):
  <namespace>/<service>: aboveMin=100%, avg=Xm, trigger=Ym → request likely too low

ANOMALOUS (needs investigation before changes):
  <namespace>/<service>: trigger=Xm > p99=Ym but hits max — check cron/batch jobs

NODE COUNT CONTEXT:
  <cluster>: max concurrent=N, peak at HH:MM UTC — [upgrade-driven | workload-driven]
```
