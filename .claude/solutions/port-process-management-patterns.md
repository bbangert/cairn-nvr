---
title: Supervising external processes (ffmpeg/plugins) via Ports — the patterns that held up
tags: [otp, port, ffmpeg, supervision, backoff]
date: 2026-07-22
module: Cairn.FFmpegPort / Cairn.PluginPort / Cairn.Probe
---

# Patterns validated against a real camera

1. **Backoff inside the GenServer, not the supervisor.** A dead camera is
   a normal long-lived state; reconnect loops (`Process.send_after(self(),
   :spawn, jittered_backoff)`) must not burn supervisor restart intensity.
   Supervisor restarts are reserved for crashes of the GenServer itself.

2. **`/bin/sh -c "exec ffmpeg … 2>> logfile"` spawn.** A Port either
   merges stderr into stdout (corrupting a binary stream) or drops it.
   The sh wrapper keeps stdout clean, lands stderr in a per-camera log,
   and `exec` makes the sh pid == the ffmpeg pid so `kill os_pid` from
   `Port.info(port, :os_pid)` reaches the real process.

3. **Hard timeouts need an os-pid kill.** `Task.shutdown` after
   `System.cmd` does NOT kill a hung child. For ffprobe: own the Port,
   `receive ... after timeout_ms -> System.cmd("kill", ["-KILL", os_pid])`.

4. **Emit the first status transition.** If the struct's initial status
   equals the first real transition (`:connecting`), a dedupe guard in
   `set_status` silently swallows it. Start from a sentinel (`:init`).
   (Found because a test only passed by accident on the *second*
   connecting transition.)

5. **kill -9 of the BEAM orphans the children.** sh-exec'd ffmpeg survives
   a brutal beam kill until its stdout pipe write fails. `terminate/2`
   sends SIGTERM to the os_pid, but hard kills skip terminate — during
   dev, `pkill -f <unique-argv-substring>` cleanup is sometimes needed.
   (Careful: the pkill pattern can match your own shell's cmdline;
   bracket-trick the pattern.)

6. **line-mode Ports** (`{:line, n}`) for ndjson plugins give
   `{:eol, line}` / `{:noeol, partial}` — track a `skipping_long_line`
   flag so an oversized line drops cleanly instead of splicing.
