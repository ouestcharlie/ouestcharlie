# Woof Low-Level Design

This document details the internal design of Woof. For requirements, see [woof_LLR.md](woof_LLR.md). For the HTTP API specification, see [controler_api.md](../controler_api.md).

## Architecture Overview

Woof runs as a long-lived process on the user's device. It serves two roles:

1. **UI backend**: serves the photo browsing experience (web, mobile, desktop)
2. **Controller API**: a localhost HTTP server that agents call for lifecycle reporting

Both roles share a single process and in-memory state.

## Controller HTTP Server

Woof runs a lightweight HTTP server bound to `127.0.0.1` on a configurable port (default: `19847`). This server is the sole communication channel between Woof and agents.

### Binding and security

- **Localhost only**: the server binds to `127.0.0.1`, not `0.0.0.0` — it is not reachable from the network
- **Bearer token authentication**: each agent receives a unique bearer token when launched. The controller API validates this token on every request to prevent unauthorized access from other local processes
- **No TLS**: since traffic is localhost-only, TLS is unnecessary

### Port discovery

When Woof launches an agent, it passes the controller URL (`http://127.0.0.1:{port}`) and the bearer token as environment variables:

```
WOOF_CONTROLLER_URL=http://127.0.0.1:19847
WOOF_AGENT_TOKEN=<unique-bearer-token>
```

## Agent Lifecycle State Machine

```
                 launch
    pending ──────────────► running
                              │
                 ┌────────────┼────────────┐
                 │            │            │
                 ▼            ▼            ▼
            completed      failed      timeout
                                     (no heartbeat
                                      for 5 min)
```

Woof maintains the state of each agent run in memory and persists it to `activity.json` on state transitions.

### Timeout detection

Woof runs a periodic check (every 60 seconds) against all `running` agents. If an agent's last heartbeat is older than the configured timeout (default: 5 minutes):

1. Agent state transitions to `timeout`
2. Woof revokes the agent's scoped storage token (if the backend supports revocation) or lets it expire
3. The activity log entry is updated with status `timeout` and the last known progress

### Agent chaining

After an agent completes successfully, Woof evaluates whether dependent agents should be triggered:

| Completed agent | Next agent(s) | Condition |
|---|---|---|
| Ingestion | Housekeeping (thumbnails + manifest rebuild) | Always |
| Housekeeping | Enrichment | If unenriched photos exist in affected partitions |
| Change detection (dirty partition) | Housekeeping | After debounce window expires |

Chaining is configured declaratively, not hardcoded — new agent types can declare their dependencies at registration time.

## Activity Log

### Storage

The activity log is stored as a JSON file at `~/.ouestcharlie/activity.json`. Each entry is a self-contained record:

```json
{
  "runs": [
    {
      "id": "run-20260220-143012-abc123",
      "agentType": "housekeeping",
      "agentId": "builtin-housekeeping-v1",
      "backend": "cloud-s3",
      "scope": ["2024/2024-07/"],
      "startTime": "2026-02-20T14:30:12Z",
      "endTime": "2026-02-20T14:32:45Z",
      "status": "completed",
      "summary": {
        "photosProcessed": 1023,
        "sidecarsUpdated": 5,
        "thumbnailsRebuilt": true,
        "errors": 0
      },
      "lastHeartbeat": "2026-02-20T14:32:40Z"
    }
  ]
}
```

### Pruning

Woof prunes entries older than the retention period (default: 30 days) on startup and daily thereafter. The log is append-only during normal operation — no concurrent write conflicts.

## Dirty Partition Queue

Woof maintains an in-memory queue of partitions marked dirty by the change detection pipeline. Each entry tracks:

- Backend name
- Partition path
- First change timestamp
- Last change timestamp
- Change count

The debounce logic: a partition is eligible for housekeeping when `now - lastChangeTimestamp > debounceWindow` (default: 10 minutes). Woof evaluates the queue every 60 seconds.

The dirty queue is persisted to `~/.ouestcharlie/dirty_partitions.json` so that pending work survives a Woof restart.

## Partition Health

Woof computes partition health indicators by reading manifest metadata. These are cached in memory and refreshed when manifests change:

| Indicator | Source | Computation |
|---|---|---|
| Last housekeeping run | Activity log | Most recent completed housekeeping run for the partition |
| Pending dirty changes | Dirty partition queue | Non-zero if partition is in the queue |
| Missing thumbnails | Manifest | Photo count vs. thumbnail tile count mismatch |
| Enrichment coverage | Manifest | Percentage of photos with `ouestcharlie:faces` and `ouestcharlie:scene` fields populated |

## Error Handling

Agent errors are categorized for the user surface:

| Category | Example | User action |
|---|---|---|
| Transient | Network timeout, rate limit | Woof auto-retries (up to 3 times) |
| Permanent | Corrupt image file, unsupported format | Flagged to user; photo skipped |
| Configuration | Invalid credentials, missing permissions | Flagged to user; agent paused until resolved |

Permanent errors are recorded per-photo in the activity log. Woof does not retry permanent errors — the user must resolve the root cause.
