---
name: k8s-rightsizing
description: Use when rightsizing Kubernetes resource requests, CPU/memory limits, or HPA thresholds for Achievers services using New Relic production metrics. Applies when working in abattoir-values helm values files, analyzing container CPU throttling, or configuring KEDA/HPA pubsub scaling.
---

# K8s Rightsizing — Achievers

## Overview

Optimize Kubernetes resource requests/limits and HPA thresholds using New Relic PRD metrics (p85/p99 for CPU, p60 for memory requests, p99 for memory limits) to reduce over-provisioning while maintaining performance headroom.

## Prerequisites

Run `newRelicScripts/query_newrelic_cpu_memory.sh` filtered to the target namespace. Query uses:
- **Time range**: Past 1 month, weekdays only (`weekdayOf(timestamp) NOT IN (1, 7)`)
- **Percentiles**: p60 (memory requests), p85 (CPU conservative), p99 (CPU requests, memory limits), max

Script output columns: Container Name, Namespace, Throttle %, current/suggested CPU request (p85/p90/p99.9), current/suggested CPU limit, current/suggested Memory request (MB), current/suggested Memory limit (MB).

## Workflow

### 1. Analysis Table

Build before making changes:

| Deployment | Current Request | p85 Suggested | p99 Suggested | Avg Usage | Conservative Request | HPA Assessment |
|------------|-----------------|---------------|---------------|-----------|---------------------|----------------|

Include: usage range, % change, current HPA type, HPA assessment.

### 2. CPU Request Strategy

- **Default**: p85 suggested value
- **p99 > 100m**: Verify with user before committing
- **Large p85–p99 gap**: Use p99 × 0.9 or user-specified conservative value
- **User overrides**: Honor exact values ("set to 50m", "100m request")
- **Standardization**: For non-critical services, user may standardize namespace-wide (e.g., "50m for all")
- **Extremely low usage**: Use p85 or user-specified minimum

### 3. CPU Limit Strategy

**Python services (single-threaded)**:
- **High-priority services** (user specifies): 1000m for burstability — e.g., announcementconfig-grpc, followmgmt-grpc, newsfeed-grpc, fileupload-grpc, engine-grpc
- **Exceptional services**: May need higher (e.g., system-prisma engine-pubsub = 2300m due to extreme throttling)
- **Regular priority**: Use script output suggested limit (256m, 512m, etc.)
- Never assume priority — user will specify

**Go services**:
- Use script output suggested CPU limit
- Throttling > 10%: Consider raising limit (e.g., 256m → 512m)
- Go goroutines create burst patterns — raise limit, not request

**Gateway/Node.js**:
- Critical services (e.g., gateway-apollo): No CPU limit (unlimited) for burst capacity

### 4. Memory Strategy

- **Memory request**: Use p60 exact value (e.g., 369Mi, 428Mi) — do not round
- **Memory limit**: Use p99 exact value (e.g., 1488Mi, 778Mi) — apply directly from script output

### 5. HPA Configuration

**CPU-based (most gRPC services)**:
- Default target: **80%**
- High-variance services: **60%** (user specifies)

**Pubsub-based**:
- **Keep pubsub scaling unchanged** (e.g., averageValue: 25 messages)
- Never convert pubsub → CPU without explicit user approval

**Dual-metric (pubsub + CPU)**:
- Preserve both scaling triggers
- CPU threshold: always 80% for dual-metric HPAs
- Pubsub threshold: keep unchanged

**Global HPA rule**: CPU request < 100m AND current HPA < 80% → raise HPA to 80%

**Malformed configs**: Fix type errors (e.g., averageUtilization → averageValue for AverageValue type). Document in analysis table.

**Average ≈ p85**: Means constant scaling if threshold too low — aim for 80%+ threshold.

### 6. Update Process

1. Create task list for all deployments in namespace
2. Mark current deployment `in_progress`
3. Apply in order: CPU request → CPU limit → Memory request/limit → HPA threshold
4. Mark `completed` immediately after each deployment
5. Move to next — complete one deployment fully before the next

### 7. Topology Spread Constraints

For deployments with `maxReplicas >= 30`:

```yaml
topologySpreadConstraints:
  - maxSkew: 3
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: {deployment-name}
  - maxSkew: 9
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: {deployment-name}
```

**Purpose**: Prevent pod clustering during HPA burst scaling. Never use tight maxSkew (<3) with DoNotSchedule.

## Decision Framework

### Always Ask User
- Python deployment priority level (high vs regular)
- Raising pubsub queue thresholds
- Converting HPA types (CPU ↔ pubsub)
- Significant deviations from p85 (>2x)
- Critical service changes

### Never Do Without Approval
- Change pubsub scaling to CPU-based
- Set aggressive HPA thresholds (<50%)
- Remove CPU limits from services that have them
- Skip deployments shown in script output

## Special Patterns

**Pubsub services with multiple queues**: Higher CPU variance is normal — may need request above p85.

**Throttling despite low average CPU**: CFS throttling in 100ms periods. Common in Go (goroutines). Fix: raise CPU limit, not request.

**Extreme variance services** (e.g., grpc-gateway p85: 190m, p99.9: 1720m): Keep conservative requests, focus on HPA tuning.

**Exceptional services** (high throttling, user calls out as "odd beast"): May need CPU limits well above p99. Apply user-specified values; don't adjust HPA for these.

**Deployment not in output but in yaml**: Query was filtered or service absent from PRD — ask user whether to include.

## Runtime Patterns

| Runtime | CPU Pattern | Recommended Approach |
|---------|-------------|---------------------|
| Python (single-threaded) | Low steady (10–100m typical) | p85 request, 1000m limit if high-priority |
| Go (concurrent) | Burst via goroutines, high throttle % | p85 request, raise limit not request |
| Pubsub consumers | Variable (queue spikes) | Conservative p85 request, keep pubsub HPA |
| Node.js API Gateway | Extreme p85–p99.9 variance | No CPU limit, conservative HPA (40–60%) |

## Output Format

```
Completed {namespace} namespace updates:

**Summary of changes**:
- {deployment-1}: {request} request (from {old}), {limit} limit, {hpa}% HPA
- {deployment-2}: {request} request (from {old}), kept pubsub HPA
...

Remaining namespaces: {list}
```
