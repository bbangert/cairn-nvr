---
title: cancel_timer doesn't flush — guard timers with a token
tags: [otp, genserver, timers, race-condition]
date: 2026-07-22
module: Cairn.DetectionAggregator
---

# Problem

A GenServer schedules a debounce/window timer with `Process.send_after`,
and cancels+reschedules it on activity (`Process.cancel_timer(ref)`).
If the timer message was **already delivered to the mailbox** when
`cancel_timer` runs, the stale message still gets processed — here it
finalized (truncated) a still-active recording event, because the message
carried only `{camera_id, event_id}` and the event id hadn't changed.

# Solution

Attach a fresh `make_ref()` token to every scheduled message and store it
in state; validate on receipt:

```elixir
defp schedule(kind, id, seconds) do
  token = make_ref()
  tref = Process.send_after(self(), {kind, id, token}, seconds * 1_000)
  {tref, token}
end

def handle_info({:post_window, id, token}, state) do
  if token == state.post_token, do: finalize(...), else: {:noreply, state}
end
```

`Process.cancel_timer(ref)` remains as a best-effort optimization; the
token is the correctness mechanism. (`cancel_timer(ref, async: false,
info: true)` can tell you delivery happened, but the token pattern is
simpler and covers reschedule loops.)

# How it was caught

elixir-reviewer agent flagged it during the /phx:full review phase; a
regression test (`detection_aggregator_test.exs` "already-delivered timer
message from before a reschedule cannot finalize") pins it.
