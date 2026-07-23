# Elixir Code Review: cairn-nvr (greenfield lib/)

## Summary
- **Status**: Changes Requested
- **Issues Found**: 8 (1 critical, 4 warnings, 3 nits)

## Critical Issues

1. **lib/cairn/detection_aggregator.ex:143-151 (`update_event`)**: `Process.cancel_timer(cam.post_ref)` does not guarantee the pending `{:post_window, camera_id, event_id}` message hasn't already been delivered to the mailbox before cancellation runs (classic OTP timer race — cancel_timer only stops *future* delivery, it never flushes an already-sent message). Since `event_id` is unchanged across updates, that stale message will later match in `maybe_finalize/4` (`%{event: %Event{id: ^event_id}}`) and can **finalize/close an event that is still actively receiving detections**, silently truncating clips and racing with the just-scheduled new timer.
   ```elixir
   # Current
   if cam.post_ref, do: Process.cancel_timer(cam.post_ref)
   EventCheckpoint.put(event.camera_id, event)
   ...
   post_ref: schedule(:post_window, event.camera_id, event.id, windows.post)

   # Suggested: give every scheduled timer a unique ref and store/compare it,
   # e.g. store {ref, event_id} in cam and validate the *ref* (not just event_id)
   # in handle_info before finalizing:
   def handle_info({:post_window, camera_id, event_id, ref}, state) do
     case state.cameras[camera_id] do
       %{post_ref: ^ref} -> maybe_finalize(state, camera_id, event_id, :post_window)
       _ -> {:noreply, state}  # stale message from an already-rescheduled timer
     end
   end
   ```

## Warnings

1. **lib/cairn/mp4/demuxer.ex:65-88 (`next_box`/`framed`)**: The extended-size (64-bit `largesize`) box path never validates `largesize >= 16` (the minimum header length for that format). A corrupt/truncated box declaring a `largesize` smaller than the header causes `payload/1` and `children_of/2` to hit binary patterns with negative `size - 8`/`size - 16`, raising `ArgumentError`/`FunctionClauseError` and crashing the demuxer (and its owning `FFmpegPort` GenServer) instead of emitting a clean `{:error, _}` event. Add a `largesize < 16 -> {:error, {:bad_box_size, largesize}}` guard in `framed/3` alongside the existing `@max_box_bytes` check.

2. **lib/cairn/detection_aggregator.ex:171-190 (`restore_from_checkpoint`)**: On aggregator restart, restored active events only get a rescheduled `post_window` timer (`cam.post_ref`); `max_ref` is left `nil`. An event that keeps receiving steady detections after a restart will never hit its `max_event` cap and can run/record indefinitely. Reschedule `max_ref` too, using the elapsed time since `event.started_at` (or accept the doc tradeoff explicitly and note the cap is lost across restarts).

3. **lib/cairn/ffmpeg_port.ex:177-189 (`handle_info(:spawn, ...)` / transcode-unavailable path)**: When `transcode_capable?/1` is false, the GenServer sets status `:transcode_unavailable` and never schedules another `:spawn` or watchdog action tied to recovery — the camera is permanently wedged until the whole process is restarted (e.g. config reload). If this is deliberate (config change is expected to restart the child), consider a comment noting it explicitly; otherwise add a periodic re-probe.

4. **lib/cairn_web/controllers/hls_controller.ex / lib/cairn/events.ex:160-163 (`filter_label`)**: `path = "$.max_scores.#{label}"` builds a SQLite JSON-path expression by interpolating the user-supplied `label` query param directly into the path string (it is passed as a bound `^path` value, so this is *not* SQL injection, but a label containing `$`, `[`, `]`, `.` or other JSON-path metacharacters can produce an invalid path and make `json_extract` raise, turning a bad query-string param into a 500). Validate/escape `label` (e.g. reject non-alphanumeric labels, or use a stored generated column) before building the path.

## Suggestions

1. **lib/cairn/events.ex:118-125 (`known_labels/0`)**: Loads every event row's `labels` JSON blob into memory (`Repo.all` with no limit) just to compute the distinct label set for a dropdown; will scale linearly with total event count. Prefer a `DISTINCT`-style query via `json_each`/a normalized labels table, or cache the result.

2. **lib/cairn/detection_aggregator.ex:207-221 (`label_entries/3`)**: `Enum.take(entries ++ new, @max_label_entries)` rebuilds/copies the whole (capped at 5000) list on every detection batch; for long-running high-frequency events this is O(n) work repeated every batch. Consider prepending and reversing at read/write time instead of `++`.

3. **lib/cairn/ffmpeg_port.ex:311-316 / lib/cairn/plugin_port.ex:185-195 (`kill_port`)**: `System.cmd("kill", ["-TERM", ...])` runs synchronously inside the GenServer's `handle_info`/`terminate`, blocking the process (and, in `terminate/2`, blocking supervisor shutdown) for the duration of the external `kill` invocation. Low risk given it's a local signal send, but worth a comment or a timeout-bounded call if shutdown latency ever matters.

## Notes / Not Flagged (verified as deliberate or correct)
- `Cairn.Camera`'s `:probe` child is `restart: :temporary` and first in a `:rest_for_one` list — OTP only cascades sibling restarts for children whose *own* restart type is `:permanent`/`:transient`; a temporary child's exit is simply removed from the supervisor without triggering the rest_for_one cascade, so this is correct, not a bug.
- `RingBuffer.drain_and_subscribe/3` is genuinely race-free (single-process atomicity) — no gap between pre-window drain and live subscription for extractors.
- `StreamChannel`'s fetch-then-subscribe gap and the RTP replay/live boundary in `CairnWeb.WebRTC.Session` are both explicitly documented as acceptable races; not re-flagged.
