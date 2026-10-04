# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "coupling",
    file: "lib/cairn/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Cairn.CameraTracker registers with Cairn.EventExtractor when it starts, and Cairn.EventExtractor keeps a monitor or link for it. Both are children of the one_for_one supervisor Cairn.Application, which restarts either alone. When Cairn.EventExtractor restarts, its init/1 starts it afresh without what Cairn.CameraTracker put there, and Cairn.CameraTracker, which is not restarted with it, never registers again. When Cairn.CameraTracker restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: Cairn.EventExtractor is a per-event `restart: :temporary` child of the Cairn.EventSupervisor DynamicSupervisor, not a one_for_one sibling of Cairn.CameraTracker: it is never restarted, so no registration is lost on its restart. The owner monitors the extractor and handles its DOWN, and an owner replacement re-claims a live extractor via EventExtractor.owner/2 from the checkpoint (restore path), so a second registration replaces, not duplicates, the first."
  },
  %{
    analysis: "coupling",
    file: "lib/cairn/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Cairn.CameraTracker registers with Cairn.TrackRecorder when it starts, and Cairn.TrackRecorder keeps it in its state. Both are children of the one_for_one supervisor Cairn.Application, which restarts either alone. When Cairn.TrackRecorder restarts, its init/1 starts it afresh without what Cairn.CameraTracker put there, and Cairn.CameraTracker, which is not restarted with it, never registers again. When Cairn.CameraTracker restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: CameraTracker only casts finished track rows to Cairn.TrackRecorder (a batch writer). Nothing is registered: TrackRecorder holds buffered rows, not the tracker, and a TrackRecorder restart loses at most an unflushed batch, never a subscription the tracker would need to redo."
  },
  %{
    analysis: "coupling",
    file: "lib/cairn/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Cairn.EventExtractor registers with Cairn.Config.Server when it starts, and Cairn.Config.Server keeps it in its state. Both are children of the one_for_one supervisor Cairn.Application, which restarts either alone. When Cairn.Config.Server restarts, its init/1 starts it afresh without what Cairn.EventExtractor put there, and Cairn.EventExtractor, which is not restarted with it, never registers again. When Cairn.EventExtractor restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: Config.Server.get/0 is a read (GenServer.call returning the current %Config{}), used as the extractor's default `:config`. Config.Server keeps nothing for the caller, so neither side's restart leaves a stale or missing registration."
  },
  %{
    analysis: "coupling",
    file: "lib/cairn/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Cairn.EventExtractor registers with Cairn.RingBuffer when it starts, and Cairn.RingBuffer keeps a monitor or link for it. Both are children of the one_for_one supervisor Cairn.Application, which restarts either alone. When Cairn.RingBuffer restarts, its init/1 starts it afresh without what Cairn.EventExtractor put there, and Cairn.EventExtractor, which is not restarted with it, never registers again. When Cairn.EventExtractor restarts, it registers a second time beside what its old process left.",
    reason:
      "Deliberate: the extractor's ring subscription is tied to that ring process on purpose. The extractor monitors the ring it drained (`ring_ref`) and ends the clip on its DOWN, because a replacement ring (a media restart) has a new epoch and must not feed this clip; the extractor is `restart: :temporary`, so it never re-registers twice either."
  },
  %{
    analysis: "coupling",
    file: "lib/cairn/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Cairn.PresenceRecorder registers with Cairn.EventExtractor when it starts, and Cairn.EventExtractor keeps a monitor or link for it. Both are children of the one_for_one supervisor Cairn.Application, which restarts either alone. When Cairn.EventExtractor restarts, its init/1 starts it afresh without what Cairn.PresenceRecorder put there, and Cairn.PresenceRecorder, which is not restarted with it, never registers again. When Cairn.PresenceRecorder restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: Cairn.EventExtractor is a per-event `restart: :temporary` child of the Cairn.EventSupervisor DynamicSupervisor, not a one_for_one sibling of Cairn.PresenceRecorder: it is never restarted, so no registration is lost on its restart. The owner monitors the extractor and handles its DOWN, and an owner replacement re-claims a live extractor via EventExtractor.owner/2 from the checkpoint (restore path), so a second registration replaces, not duplicates, the first."
  },
  %{
    analysis: "coupling",
    file: "lib/cairn/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Cairn.PresenceRecorder registers with Cairn.PresenceCheckpoint when it starts, and Cairn.PresenceCheckpoint keeps it as an ETS row. Both are children of the one_for_one supervisor Cairn.Application, which restarts either alone. When Cairn.PresenceCheckpoint restarts, its init/1 starts it afresh without what Cairn.PresenceRecorder put there, and Cairn.PresenceRecorder, which is not restarted with it, never registers again. When Cairn.PresenceRecorder restarts, it registers a second time beside what its old process left.",
    reason:
      "Deliberate, documented in Cairn.PresenceCheckpoint's moduledoc: the checkpoint row is a crash-recovery snapshot that recorders rewrite on every change, and a PresenceCheckpoint crash (which takes the table) is absorbed — put/5 drops, get/1 answers nil — while a restarting recorder sweeps stranded extractors (PresenceRecorder.sweep_stranded/1). Rows are keyed by camera id, so a recorder restart overwrites, not duplicates, its row."
  },
  %{
    analysis: "coupling",
    file: "lib/cairn/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Cairn.SoakMonitor registers with Cairn.Config.Server when it starts, and Cairn.Config.Server keeps it in its state. Both are children of the one_for_one supervisor Cairn.Application, which restarts either alone. When Cairn.Config.Server restarts, its init/1 starts it afresh without what Cairn.SoakMonitor put there, and Cairn.SoakMonitor, which is not restarted with it, never registers again. When Cairn.SoakMonitor restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: SoakMonitor calls Config.Server.get/0 once in init/1 to read data_dir; that is a read, and Config.Server keeps nothing for SoakMonitor, so no registration can be lost or duplicated on either restart."
  },
  %{
    analysis: "shutdown",
    file: "lib/cairn/ffmpeg_port.ex",
    title: "terminate/2 does unbounded work inside the shutdown timeout",
    at_label: "unbounded work inside the shutdown timeout",
    detail:
      "Cairn.FFmpegPort.kill_port/1 calls System.cmd/3 — a port or OS operation — from Cairn.FFmpegPort's terminate/2. The module traps exits, so the callback is reached, but a GenServer child gets only its shutdown timeout (5000ms unless the child spec says otherwise) before the supervisor brutal-kills it. A call with no bound of its own can exceed that, and the cleanup is truncated at whatever point it had reached — often worse than not starting.",
    reason:
      "Bounded in practice: the System.cmd/3 in terminate/2 is `kill -TERM <os_pid>`, which returns immediately (it only signals ffmpeg; Port.close follows). It cannot approach the 5000ms shutdown timeout, and skipping it would orphan the ffmpeg holding the camera's RTSP session."
  },
  %{
    analysis: "shutdown",
    file: "lib/cairn_web/webrtc/session.ex",
    title: "Children started under another tree outlive their owner",
    at_label: "start_child onto a supervisor in another tree",
    detail:
      "CairnWeb.WebRTC.Session.start/2 starts children under CairnWeb.WebRTC.Supervisor, a DynamicSupervisor CairnWeb.WebRTCChannel does not sit under. Their lifetime follows CairnWeb.WebRTC.Supervisor's tree, not CairnWeb.WebRTCChannel's: when CairnWeb.WebRTCChannel's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and CairnWeb.WebRTCChannel's terminate/2 does not stop them.",
    reason:
      "Deliberate: WebRTC sessions live under the capped CairnWeb.WebRTC.Supervisor on purpose (a signaling flood cannot exhaust recording or the machine). A channel-owned session monitors its owner and stops `:normal` on its DOWN, so it never outlives the channel; WHEP sessions have no owner by design and are reaped by DELETE or the connect deadline."
  },
  %{
    analysis: "shutdown",
    file: "lib/cairn_web/webrtc/session.ex",
    title: "terminate/2 does work a supervisor shutdown will skip",
    at_label: "a supervisor shutdown skips this",
    detail:
      "CairnWeb.WebRTC.Session does not trap exits, so a GenServer shutdown from its supervisor kills it outright and terminate/2 never runs. CairnWeb.WebRTC.Session.terminate/2 calls ExWebRTC.PeerConnection.close/1, which the effect model cannot classify — so this cannot say WHAT is skipped, only that terminate/2 does more than log and none of it will happen on the normal stop path. If that call releases a lease, closes a session or flushes a buffer, it is silently not happening in production.",
    reason:
      "Benign: on a supervisor shutdown the session is killed, and its ExWebRTC.PeerConnection is started with start_link, so the linked PeerConnection exits with it and its sockets close; the explicit close/1 in terminate/2 only matters on a normal stop, where terminate/2 does run."
  },
  %{
    analysis: "failure",
    file: "lib/membrane_rtsp_dual_stream/source.ex",
    title: "Unlinked process spawned",
    at_label: "spawned here",
    detail:
      "Membrane.RTSPDualStream.Source.stop_client_async/2 spawns a process with bare spawn — no link, no monitor. If the process crashes, nothing observes it: no restart, no log, no cleanup.",
    reason:
      "Deliberate: the stopper must outlive the source element that is tearing down (a link would kill it with the element, defeating the point), and this Membrane plugin is Cairn-agnostic, so there is no Cairn.TaskSupervisor to start it under. It monitors its own worker (spawn_monitor) and its only job is a 3s-bounded stop-then-kill of the RTSP client."
  },
  %{
    analysis: "startup",
    file: "lib/cairn/event_extractor.ex",
    title: "init/1 makes a synchronous supervisor call",
    at_label: "this call blocks init until the supervisor answers",
    detail:
      "Cairn.CameraTracker.init/1 reaches DynamicSupervisor.start_child on Cairn.EventSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Cairn.CameraTracker, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Benign: the start_child is reached only when restoring an event from the checkpoint. Cairn.EventSupervisor is started before every camera tree, and EventExtractor.init/1 never calls back into the tracker (it reads Config.Server and the camera's RingBuffer), so it cannot deadlock the boot."
  },
  %{
    analysis: "startup",
    file: "lib/cairn/event_extractor.ex",
    title: "init/1 makes a synchronous supervisor call",
    at_label: "this call blocks init until the supervisor answers",
    detail:
      "Cairn.PresenceRecorder.init/1 reaches DynamicSupervisor.start_child on Cairn.EventSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Cairn.PresenceRecorder, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Benign: the start_child is reached only when restoring an event from the checkpoint. Cairn.EventSupervisor is started before every camera tree, and EventExtractor.init/1 never calls back into the recorder (it reads Config.Server and the camera's RingBuffer), so it cannot deadlock the boot."
  },
  %{
    analysis: "mailbox",
    file: "lib/cairn/native/parity.ex",
    title: "Task.async in library code links to an unknown caller",
    at_label: "linked task started in library code",
    detail:
      "Cairn.Native.Parity.plugin_run/3 is a plain function, not a process callback, so the task it starts with Task.async is linked to whichever process called it. A caller that traps exits then receives the task's exit as an {:EXIT, pid, :normal} message that Task.await never consumes, and a crashing task takes the caller down with it.",
    reason:
      "Deliberate: Cairn.Native.Parity is an offline comparison harness driven by `mix cairn.parity` and its tests, not runtime code; plugin_run/3 awaits the feed task inline (Task.await :infinity) and no caller traps exits, so the link is the intended crash propagation."
  },
  %{
    analysis: "failure",
    file: "test/support/presence_fixtures.ex",
    title: "Unlinked process spawned",
    at_label: "spawned here",
    detail:
      "Cairn.PresenceFixtures.relay/1 spawns a process with bare spawn — no link, no monitor. If the process crashes, nothing observes it: no restart, no log, no cleanup.",
    reason:
      "Test-only, deliberate (documented on relay/1): the relay is unlinked so a test that kills it survives, and it monitors the test process so it is reaped when the test ends."
  }
]
