# Woof Low-Level Requirements

This document captures the requirements for Woof, the user-facing controller component of OuEstCharlie. For Woof's role in the overall architecture, see [HLD.md § Woof](../HLD.md#woof-user-facing-application-and-controller).

## Agent Lifecycle Management

- Woof shall expose an HTTP API on localhost for agent communication (see [controler_api.md](../controler_api.md))
- Woof shall track each agent run through a state machine: `pending → running → completed | failed | timeout`
- Woof shall detect stuck agents via heartbeat timeout (default: 5 minutes without heartbeat) and transition them to `timeout` state
- Woof shall revoke the scoped token of any agent that transitions to `timeout` or is cancelled by the user
- Woof shall chain dependent agents automatically (e.g., ingestion → housekeeping → enrichment) without user intervention once the initial trigger is approved

## Agent Progress Reporting

- Agents shall report progress to Woof via periodic heartbeat calls to the controller API
- Each heartbeat shall include: partition being processed, items processed, total items, and current operation
- Agents shall report completion with a summary: photos processed, errors encountered, artifacts written
- Agents shall report failure with actionable context: which photo, which operation, what error

## Observability

### Activity Log

- Woof shall maintain a device-local activity log (`~/.ouestcharlie/activity.json`) recording all agent runs
- Each entry shall record: agent type, agent ID, backend, partition scope, start time, end time, status, summary stats, and error details
- Woof shall prune activity log entries older than a configurable retention period (default: 30 days)
- The activity log is disposable — loss of the log has no impact on data integrity

### User Surface

- Woof shall expose the following observability surfaces to the UI layer:
  - **Activity feed**: current and recent agent runs with real-time status and progress
  - **Partition health**: per-partition indicators — last housekeeping run, pending dirty changes, missing thumbnails, enrichment coverage percentage
  - **Error drill-down**: per-error detail showing which photo/partition failed, which agent, and the error message

### Alerting

- Woof shall surface agent failures and timeouts to the user via the UI (notification or status indicator)
- Woof shall not require external alerting infrastructure — all observability is self-contained

## Configuration Ownership

- Woof shall own the device-local configuration directory (`~/.ouestcharlie/`):
  - `config.json` — backend connection info
  - `albums.json` — album definitions (saved filters)
  - `activity.json` — agent run history
  - OS keychain entries — master credentials

## Credential Management

- Woof shall store master credentials (S3 IAM keys, OAuth refresh tokens, service account keys) in the OS keychain
- Woof shall never expose master credentials to agents
- Woof shall mint scoped, short-lived tokens for each agent run, restricted to the approved grants
- Woof shall support token revocation for cancelled or timed-out agents

## Change Detection Orchestration

- Woof shall manage the change detection pipeline (triggers + sweep) as described in [HLD.md § Change detection](../HLD.md#change-detection)
- Woof shall maintain a dirty partition queue with debounce logic (default: 10 minutes quiet period)
- Woof shall schedule housekeeping agents for dirty partitions after the debounce window expires

## User Approval

- Woof shall present agent scope requests to the user for explicit approval before issuing credentials
- Once approved, Woof may trigger subsequent runs of the same agent type within the approved grants without further confirmation
