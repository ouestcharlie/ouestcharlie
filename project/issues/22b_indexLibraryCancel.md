# OEC#22b — Stop button: cancel indexing from gallery UI

#status:done

## Context

The `IndexingProgress` widget (OEC#22) has no way to abort a running indexing job. A "Stop" button should cancel the background Whitebeard task and transition the widget to a neutral "Indexing stopped" state without triggering a Claude turn.

Whitebeard's `index_library` is fully async with many `await` checkpoints, so `asyncio.Task.cancel()` is effective and propagates cleanly through `asyncio.gather` → each `index_partition` → file-level awaits.

## Signal flow

```
[Stop button] → POST /api/indexing/{id}/cancel
             → IndexingSessionManager.cancel(session_id)   # task.cancel() + status="cancelling"
             → asyncio.Task.cancel()
             → CancelledError propagates through _call_ephemeral → kills Whitebeard subprocess
             → on_error(CancelledError) → IndexingSessionManager.cancelled(session_id)
             → next poll → status="cancelled" → UI shows "Indexing stopped"
```

## Changes required

### `indexing_session_manager.py`

Add `_tasks: dict[str, asyncio.Task]` alongside `_sessions`.

New/changed methods:
```python
def register_task(self, session_id: str, task: asyncio.Task) -> None:
    self._tasks[session_id] = task

def cancel(self, session_id: str) -> bool:
    """Request cancellation. Returns False if session unknown or not running."""
    session = self._sessions.get(session_id)
    if session is None or session["status"] != "running":
        return False
    session["status"] = "cancelling"
    task = self._tasks.get(session_id)
    if task:
        task.cancel()
    return True

def cancelled(self, session_id: str) -> None:
    """Mark session as cancelled (called from on_error when CancelledError)."""
    session = self._sessions.get(session_id)
    if session is None:
        return
    session["status"] = "cancelled"
```

`start()` eviction loop must also remove from `_tasks`.

New statuses: `"running"` | `"cancelling"` | `"cancelled"` | `"completed"` | `"failed"`

### `agent_client.py` — `call_tool_background`

In the inner `_run()` coroutine, catch `asyncio.CancelledError` explicitly so `on_error` is invoked before re-raising:

```python
except asyncio.CancelledError as exc:
    if on_error:
        on_error(exc)
    raise  # keep task properly cancelled
```

Without this, `CancelledError` bypasses `on_error` and the session stays in `"cancelling"` forever.

### `server.py`

Store the returned task and register it:
```python
task = self._agent.call_tool_background(...)
self._indexing_sessions.register_task(session_id, task)
```

In `_on_error`, distinguish cancellation:
```python
def _on_error(exc):
    if isinstance(exc, asyncio.CancelledError):
        self._indexing_sessions.cancelled(session_id)
    else:
        self._indexing_sessions.fail(session_id, str(exc))
```

### `http_server.py`

Add a POST route (placed before the catch-all proxy, and before `/api/indexing/{session_id}`):
```python
async def api_indexing_cancel(request: Request) -> Response:
    if indexing_session_manager is None:
        return JSONResponse({"error": "not configured"}, status_code=503)
    sid = request.path_params["session_id"]
    ok = indexing_session_manager.cancel(sid)
    if not ok:
        return JSONResponse({"error": "not cancellable"}, status_code=409)
    return JSONResponse({"status": "cancelling"})

Route("/api/indexing/{session_id}/cancel", api_indexing_cancel, methods=["POST"])
```

### `IndexingProgress.svelte`

Add a `Stop` button visible only when `status === 'running'`:
```svelte
{#if status === 'running'}
  <button class="stop-btn" onclick={stopIndexing} disabled={stopping}>Stop</button>
{/if}
```

```js
let stopping = $state(false);

async function stopIndexing() {
  stopping = true;
  try {
    await fetch(`${serverUrl}/api/indexing/${sessionId}/cancel`, { method: 'POST' });
  } catch { /* poll will reflect the new status */ }
}
```

Handle `"cancelling"` and `"cancelled"` in the template:
- Status chip: neutral colour for "cancelling" (amber) and "cancelled" (grey)
- When `status === 'cancelled'`: show a neutral card "Indexing stopped." — no MCP `updateModelContext`/`sendMessage`
- Keep polling while `status === 'cancelling'`; stop when `cancelled` | `completed` | `failed`
- `$effect` for `handleDone`: `'cancelled'` is a terminal status but skips all MCP calls

## Tests

- `test_indexing_session_manager.py`: `cancel()` transitions to "cancelling", task.cancel() called; `cancelled()` transitions; cancel on unknown/non-running returns False
- `test_http_server.py`: POST cancel returns 200 when running; 409 when already completed
- `test_server.py`: `register_task` called after `call_tool_background`; `_on_error(CancelledError)` calls `cancelled()` not `fail()`
- `IndexingProgress.test.js`: Stop button visible while running, hidden after; POST to cancel endpoint on click; "cancelled" status shows neutral card not error card
