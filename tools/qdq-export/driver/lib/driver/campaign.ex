defmodule Driver.Campaign do
  @moduledoc """
  Campaign stages, one function per bash-driver stage, same evidence
  layout under `out-*/htp/`. Board-side methodology stays in the pushed
  `sh` scripts (their sha IS the methodology digest); the retry guard
  keeps shelling out to `campaign_meta.py` locally. What the port
  deletes is transport ritual: `remote_verified`'s nonce/digest protocol
  is `cmd/3`'s real rc, and `fetch()`'s existence heuristics are
  `read!/2`'s whole-or-error.

  Stage functions take and return the board session — reboots (CDSP
  budget) replace it mid-stage.
  """

  require Logger

  alias Driver.Board
  alias Driver.Campaign.Config

  @stages ~w(push envcheck content latency fetch finish)a

  @spike_timeout 240_000
  @content_timeout 420_000
  @bench_timeout 200_000

  @doc "Stage names in campaign order (`all` runs the lot)."
  @spec stages() :: [atom()]
  def stages, do: @stages

  @spec run(atom(), Board.t(), Config.t()) :: {:ok, Board.t()} | {:error, term()}
  def run(stage, board, config)

  def run(:push, board, cfg) do
    log(cfg, "== push: content script + #{length(Config.rungs(cfg))} artifacts")

    script = Path.join(cfg.qdq_dir, "htp_content_test.sh")

    artifacts =
      for {name, _, _} <- Config.rungs(cfg), do: Path.join(Config.art(cfg), "#{name}.onnx")

    # Refuse missing files up front — before anything lands on the board.
    case Enum.reject([script | artifacts], &File.exists?/1) do
      [] ->
        with :ok <- verify_against_record(cfg, artifacts) do
          cfg.board.write!(board, script, Path.join(cfg.bench_dir, "htp_content_test.sh"))

          for artifact <- artifacts do
            cfg.board.write!(
              board,
              artifact,
              Path.join([cfg.bench_dir, "artifacts-fixed", Path.basename(artifact)])
            )
          end

          # htp_report.py authenticates every latency row against this
          # file (bench ran THESE bytes); same wildcard listing as bash.
          case cfg.board.cmd(board, "sha256sum #{cfg.bench_dir}/artifacts-fixed/*.onnx",
                 timeout: 300_000
               ) do
            {out, 0} ->
              File.mkdir_p!(Config.htp(cfg))
              File.write!(Path.join(Config.htp(cfg), "pushed.sha256"), out)
              log(cfg, "push verified: #{length(artifacts)}/#{length(artifacts)} sha256 match")
              {:ok, board}

            {out, rc} ->
              {:error, {:pushed_sha_unreadable, rc, out}}
          end
        end

      missing ->
        {:error, {:missing_local_files, missing}}
    end
  end

  def run(:envcheck, board, cfg) do
    log(cfg, "== envcheck: nano-parity spike (N=20)")

    with :ok <- cfg.board.engine_stop(board, cfg.container),
         {out, rc} <- cfg.board.cmd(board, cfg.spike_cmd, timeout: @spike_timeout) do
      # Saved on the failure path too — a failing spike's output is
      # exactly the evidence someone will want (bash fetched it before
      # FATALing).
      File.mkdir_p!(Config.htp(cfg))
      File.write!(Path.join(Config.htp(cfg), "spike-env.txt"), out)

      with {:rc, 0} <- {:rc, rc},
           {:pass, line} <- envcheck_verdict(out) do
        log(cfg, line)
        {:ok, board}
      else
        {:rc, rc} ->
          {:error, {:spike_failed, rc, out}}

        {:fail, line} ->
          log(cfg, line)
          {:error, :envcheck_failed}
      end
    end
  end

  def run(:reboot, board, cfg), do: reboot(board, cfg)

  def run(:content, board, cfg) do
    clips = Enum.join(cfg.clips, " ")

    log(
      cfg,
      "== content runs: #{clips} x (#{length(Config.rungs(cfg))} rungs qnn + nano ort control + old-nano defect control)"
    )

    # Anchor the session counter to a clean CDSP: envcheck (and any prior
    # manual session this boot) has already leaked graph handles.
    with {:ok, board} <- reboot(board, cfg),
         {:ok, board} <- pin_governor(board, cfg),
         {:ok, board} <-
           reduce_rungs(cfg, board, fn {name, profile, insize}, b ->
             content_run(
               b,
               cfg,
               "qnn",
               "#{cfg.bench_dir}/artifacts-fixed/#{name}.onnx",
               name,
               profile,
               insize,
               cfg.clips
             )
           end),
         # CPU-EP control: ties board decode+sampling to the local CPU reference.
         {:ok, board} <-
           content_run(
             board,
             cfg,
             "ort",
             "#{cfg.bench_dir}/artifacts-fixed/yolox_nano-qdq-a16.onnx",
             "yolox_nano-qdq-a16",
             "yolox",
             416,
             cfg.clips
           ),
         :ok <- verify_control_bytes(board, cfg) do
      # Sensitivity control: the SHIPPED defective nano must show its
      # baked ceiling through this exact methodology.
      content_run(
        board,
        cfg,
        "qnn",
        "#{cfg.bench_dir}/yolox_nano-qdq-a16.onnx",
        "control-old-nano-a16",
        "yolox",
        416,
        ["ac86"]
      )
    end
  end

  def run(:latency, board, cfg) do
    log(cfg, "== latency runs: bench.sh per rung, governor pinned")

    with {:ok, board} <- reboot(board, cfg),
         {:ok, board} <- pin_governor(board, cfg),
         {:ok, start} <- board_epoch(cfg, board) do
      # Board-sourced, not local date: run-dir timestamps this filters
      # against are board-generated, and the clocks disagree.
      File.mkdir_p!(Config.htp(cfg))
      File.write!(Path.join(Config.htp(cfg), ".latency-start"), "#{start}\n")

      with {:ok, board} <-
             reduce_rungs(cfg, board, fn {name, profile, insize}, b ->
               with :ok <- cfg.board.engine_stop(b, cfg.container) do
                 log(cfg, "latency #{name} qnn 60s")

                 bench =
                   "MODEL=#{cfg.bench_dir}/artifacts-fixed/#{name}.onnx SAMPLE_FPS=30 PIN_GOVERNOR=1 " <>
                     "sh #{cfg.bench_dir}/bench.sh qnn 60 1 --model-profile #{profile} --input-size #{insize} #{cfg.qnn_flags}"

                 try do
                   case cfg.board.cmd(b, bench, timeout: @bench_timeout) do
                     {_, 0} -> {:ok, b}
                     {_, rc} -> warn_ok(cfg, b, "latency #{name} rc #{rc}")
                   end
                 rescue
                   e -> warn_ok(cfg, b, "latency #{name} raised #{inspect(e)}")
                 end
               end
             end) do
        # One CPU-EP anchor (nano is cheap): with the per-rung QNN numbers
        # it detects whole-session CPU fallback.
        log(cfg, "latency yolox_nano-qdq-a16 ort 60s (CPU anchor)")

        anchor =
          "MODEL=#{cfg.bench_dir}/artifacts-fixed/yolox_nano-qdq-a16.onnx SAMPLE_FPS=30 PIN_GOVERNOR=1 " <>
            "sh #{cfg.bench_dir}/bench.sh ort 60 1 --model-profile yolox --input-size 416"

        try do
          case cfg.board.cmd(board, anchor, timeout: @bench_timeout) do
            {_, 0} -> {:ok, board}
            {_, rc} -> warn_ok(cfg, board, "latency CPU anchor rc #{rc}")
          end
        rescue
          e -> warn_ok(cfg, board, "latency CPU anchor raised #{inspect(e)}")
        end
      end
    end
  end

  def run(:fetch, board, cfg) do
    log(cfg, "== fetch evidence")
    content_dir = Path.join(Config.htp(cfg), "content")
    File.mkdir_p!(content_dir)

    case fetch_dir(cfg, board, Path.join(cfg.bench_dir, "content"), content_dir) do
      :ok -> :ok
      {:error, reason} -> log(cfg, "WARN: content fetch incomplete: #{inspect(reason)}")
    end

    fetch_bench_runs(board, cfg)

    counts =
      "fetched: #{count_entries(content_dir)} content dirs, " <>
        "#{count_entries(Path.join(Config.htp(cfg), "runs"))} bench runs"

    log(cfg, counts)
    {:ok, board}
  end

  def run(:finish, board, cfg) do
    log(cfg, "== finish: restore governor + restart container + final reboot")
    pinned_marker = Path.join(Config.htp(cfg), ".gov-pinned")
    # Cleanup failures must propagate: a green campaign that leaves the
    # board pinned to performance or the production NVR down is not green.
    gov_result =
      case cfg.board.restore_governor(board) do
        {:ok, {:restored, gov}} ->
          File.rm(pinned_marker)
          log(cfg, "governor restored to #{gov}")
          :ok

        {:ok, :nothing_to_restore} ->
          # This campaign pinned (local marker) yet the board has nothing
          # saved — that is NOT "nothing to restore": the board may still
          # be pinned. A finish without a pin keeps the no-op path.
          if File.exists?(pinned_marker),
            do: {:error, :pinned_but_nothing_saved},
            else: :ok

        {:error, reason} ->
          {:error, {:governor_restore, reason}}
      end

    engine_result =
      case cfg.board.engine_start(board, cfg.container) do
        :ok ->
          log(cfg, "cairn container back up")
          :ok

        {:error, reason} ->
          log(cfg, "FATAL: cairn container NOT verified running: #{inspect(reason)}")
          {:error, {:engine_start, reason}}
      end

    # Runs even when cleanup failed: distribution must not outlive the
    # campaign either way, and the supervisor restarts the addon on boot.
    reboot_result =
      case cfg.board.final_reboot(board, cfg.reboot_opts) do
        :ok ->
          log(cfg, "board rebooting — distribution off, CDSP clean")
          :ok

        {:error, :reboot_not_observed} ->
          log(cfg, "FATAL: final reboot not observed — distribution may still be enabled")
          {:error, :final_reboot_not_observed}
      end

    case Enum.reject([gov_result, engine_result, reboot_result], &(&1 == :ok)) do
      [] -> {:ok, board}
      failures -> {:error, {:finish_incomplete, Enum.map(failures, fn {:error, r} -> r end)}}
    end
  end

  # write! already proves board bytes == local bytes; this ties local
  # bytes to the RECORD, so a locally-regenerated artifact that drifted
  # from the campaign's recorded shas cannot ride a verified push.
  defp verify_against_record(cfg, artifacts) do
    record_path = Path.join([cfg.out, "records", "artifacts.sha256"])

    case File.read(record_path) do
      {:ok, record} ->
        lines = String.split(record, "\n", trim: true)

        mismatches =
          for artifact <- artifacts,
              base = Path.basename(artifact),
              want = recorded_sha(lines, base),
              have = sha256_hex(artifact),
              want != have,
              do: {base, want, have}

        if mismatches == [], do: :ok, else: {:error, {:artifact_record_mismatch, mismatches}}

      {:error, reason} ->
        {:error, {:artifacts_record_unreadable, record_path, reason}}
    end
  end

  defp recorded_sha(lines, base) do
    Enum.find_value(lines, fn line ->
      case String.split(line) do
        [sha, name | _] -> if Path.basename(name) == base, do: sha
        _ -> nil
      end
    end)
  end

  defp sha256_hex(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  # -- content machinery ---------------------------------------------------

  defp content_run(board, cfg, backend, model, label, profile, insize, clips) do
    flags = if backend == "qnn", do: cfg.qnn_flags, else: ""

    Enum.reduce_while(clips, {:ok, board}, fn clip, {:ok, b} ->
      tag = "#{label}-#{backend}-#{clip}"

      case retry_guard(cfg, tag, label, clip, flags, backend, profile, insize) do
        :skip ->
          log(cfg, "content #{tag}: already fetched, skip")
          {:cont, {:ok, b}}

        :run ->
          case content_run_one(b, cfg, backend, model, tag, profile, insize, flags, clip) do
            {:ok, b} -> {:cont, {:ok, b}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp content_run_one(board, cfg, backend, model, tag, profile, insize, flags, clip) do
    with {:ok, board} <- charge_qnn_budget(board, cfg, backend, tag),
         :ok <- cfg.board.engine_stop(board, cfg.container) do
      log(cfg, "content #{tag}: running")

      run_cmd =
        "PROFILE=#{profile} INSIZE=#{insize} sh #{cfg.bench_dir}/htp_content_test.sh " <>
          "#{backend} #{model} #{cfg.clip_dir}/clip-#{clip}.mp4 #{tag} #{flags}"

      # WARN-continue on nonzero rc AND on a raise (erpc timeout, node
      # down mid-call) — bash's `timeout ... || log WARN` treated both
      # the same way; the run's truth is checked on fetch either way.
      try do
        case cfg.board.cmd(board, run_cmd, timeout: @content_timeout) do
          {_, 0} -> :ok
          {_, rc} -> log(cfg, "WARN: #{tag} remote rc #{rc} (checked on fetch)")
        end
      rescue
        e -> log(cfg, "WARN: #{tag} run raised #{inspect(e)} (checked on fetch)")
      end

      # Fetch each run's evidence immediately: the retry-skip guard reads
      # the LOCAL copy, so without this a wedged run could only be
      # retried after a manual fetch stage.
      local = Path.join([Config.htp(cfg), "content", tag])
      File.mkdir_p!(local)

      case fetch_dir(cfg, board, "#{cfg.bench_dir}/content/#{tag}", local) do
        :ok -> :ok
        {:error, reason} -> log(cfg, "WARN: #{tag} evidence fetch failed: #{inspect(reason)}")
      end

      {:ok, board}
    end
  end

  defp charge_qnn_budget(board, _cfg, "ort", _tag), do: {:ok, board}

  defp charge_qnn_budget(board, cfg, "qnn", tag) do
    board =
      if board.qnn_sessions >= cfg.qnn_session_budget do
        log(
          cfg,
          "QNN session budget (#{cfg.qnn_session_budget}) reached — rebooting before #{tag}"
        )

        case reboot(board, cfg) do
          {:ok, fresh} -> fresh
          {:error, _} = error -> throw(error)
        end
      else
        board
      end

    {:ok, %{board | qnn_sessions: board.qnn_sessions + 1}}
  catch
    {:error, _} = error -> error
  end

  # rc 4 = "not current, rerun" — its own code, because 1 belongs to the
  # interpreter. ANY other nonzero status is a broken guard — fatal,
  # because a broken guard reads as "rerun everything" and would silently
  # redo an entire board campaign on every invocation.
  defp retry_guard(cfg, tag, label, clip, flags, backend, profile, insize) do
    model = Path.join(Config.art(cfg), "#{label}.onnx")
    clip_file = Path.join([cfg.out, "clips", "clip-#{clip}.mp4"])

    args =
      ["current", Path.join([Config.htp(cfg), "content", tag])] ++
        ["--script", Path.join(cfg.qdq_dir, "htp_content_test.sh"), "--extra-args=#{flags}"] ++
        ["--backend", backend, "--profile", profile, "--insize", "#{insize}"] ++
        if(File.exists?(model), do: ["--model", model], else: []) ++
        if(label == "control-old-nano-a16", do: ["--require-sha", cfg.old_nano_sha], else: []) ++
        if(File.exists?(clip_file), do: ["--clip", clip_file], else: [])

    guard = Path.join(cfg.qdq_dir, "campaign_meta.py")

    case System.cmd("python3", [guard | args], stderr_to_stdout: true) do
      {_, 0} -> :skip
      {_, 4} -> :run
      {out, rc} -> {:error, {:retry_guard_broken, rc, out}}
    end
  end

  defp verify_control_bytes(board, cfg) do
    case cfg.board.cmd(board, "sha256sum #{cfg.bench_dir}/yolox_nano-qdq-a16.onnx") do
      {out, 0} ->
        if String.contains?(out, cfg.old_nano_sha),
          do: :ok,
          else: {:error, {:control_bytes_not_defective_nano, cfg.old_nano_sha}}

      {out, rc} ->
        {:error, {:control_sha_unreadable, rc, out}}
    end
  end

  # -- envcheck gate -------------------------------------------------------

  # Phase-0 recorded: CPU p50 34.98-40.63 ms, QNN p50 6.40-6.66 ms (6.1x).
  # Bands are generous: the gate is "same regime", not "same run" — and
  # fail-closed: a missing or non-numeric p50 reads FAIL. The spike's
  # JSON lines swim in EP/DSP log noise — key off the lines, not their
  # position.
  defp envcheck_verdict(out) do
    p50 =
      for line <- String.split(out, "\n"),
          line = String.trim(line),
          String.starts_with?(line, ~s({"ep":)),
          {:ok, %{"ep" => ep, "p50_ms" => p50}} <- [JSON.decode(line)],
          into: %{} do
        {ep, p50}
      end

    cpu = p50["cpu"]
    qnn = p50["qnn"]
    finite = is_number(cpu) and is_number(qnn)
    ok = finite and cpu >= 25 and cpu <= 60 and qnn >= 4 and qnn <= 13 and cpu / qnn >= 3
    ratio = if finite and qnn > 0, do: "#{Float.round(cpu / qnn, 1)}x", else: "?"

    verdict = if ok, do: "PASS (matches phase-0 spike regime)", else: "FAIL"

    line =
      "envcheck: cpu p50=#{inspect(cpu)} qnn p50=#{inspect(qnn)} ratio=#{ratio} -> #{verdict}"

    {if(ok, do: :pass, else: :fail), line}
  end

  # -- fetch machinery -----------------------------------------------------

  defp fetch_bench_runs(board, cfg) do
    marker = Path.join(Config.htp(cfg), ".latency-start")

    with {:list, {out, 0}} <- {:list, cfg.board.cmd(board, "ls #{cfg.bench_dir}/runs")},
         {:marker, {:ok, raw}} <- {:marker, File.read(marker)},
         {:start, {start, ""}} when start > 0 <- {:start, Integer.parse(String.trim(raw))} do
      runs_dir = Path.join(Config.htp(cfg), "runs")
      File.mkdir_p!(runs_dir)

      for dir <- String.split(out, "\n", trim: true),
          ts = run_dir_timestamp(dir),
          ts != nil and ts >= start,
          not File.dir?(Path.join(runs_dir, dir)) do
        local = Path.join(runs_dir, dir)
        File.mkdir_p!(local)

        case fetch_dir(cfg, board, "#{cfg.bench_dir}/runs/#{dir}", local) do
          :ok -> :ok
          {:error, reason} -> log(cfg, "WARN: run #{dir} fetch failed: #{inspect(reason)}")
        end
      end

      :ok
    else
      {:list, {_, _rc}} -> log(cfg, "WARN: cannot list bench runs — skipping bench-run fetch")
      {:marker, {:error, _}} -> log(cfg, "no latency marker — skipping bench-run fetch")
      # Fail-closed like the analyzer: garbage or zero means no current
      # latency stage, not an unfiltered pull of every historical run.
      {:start, _} -> log(cfg, "invalid latency marker — skipping bench-run fetch")
    end
  end

  defp run_dir_timestamp(dir) do
    with [_, ts] <- Regex.run(~r/-(\d+)$/, dir),
         {n, ""} <- Integer.parse(ts),
         do: n,
         else: (_ -> nil)
  end

  # Whole-file reads mirrored into the local tree — never streamed
  # through a term printer. Listing rides eval! (D2): one round trip,
  # no board-side `find` (the busybox applet set shrank once already).
  defp fetch_dir(cfg, board, remote, local) do
    listing =
      cfg.board.eval!(
        board,
        ~s[dir |> Path.join("**") |> Path.wildcard() |> Enum.map(fn p -> {p, File.dir?(p)} end)],
        dir: remote
      )

    for {path, dir?} <- listing do
      rel = Path.relative_to(path, remote)
      dest = Path.join(local, rel)

      if dir? do
        File.mkdir_p!(dest)
      else
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, cfg.board.read!(board, path, 120_000))
      end
    end

    :ok
  rescue
    e -> {:error, e}
  end

  defp count_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} -> length(entries)
      {:error, _} -> 0
    end
  end

  # -- shared helpers ------------------------------------------------------

  defp reboot(board, cfg) do
    log(cfg, "== reboot: clearing CDSP session-leak state")

    with {:ok, fresh} <- cfg.board.reboot(board, cfg.reboot_opts) do
      # HA's supervisor autostarts the addon on boot; give it a moment so
      # engine_stop sees (and stops) the running container rather than
      # racing its startup.
      Process.sleep(Keyword.get(cfg.reboot_opts, :settle_ms, 30_000))
      log(cfg, "board back with a new boot id")
      {:ok, fresh}
    end
  end

  defp pin_governor(board, cfg) do
    case cfg.board.pin_governor(board) do
      {:ok, saved} ->
        # The local marker records that THIS campaign pinned: finish uses
        # it to distinguish "nothing to restore" from "saved value gone".
        File.mkdir_p!(Config.htp(cfg))
        File.write!(Path.join(Config.htp(cfg), ".gov-pinned"), saved <> "\n")
        log(cfg, "governor pinned (saved: #{saved})")
        {:ok, board}

      {:error, reason} ->
        {:error, {:pin_governor, reason}}
    end
  end

  defp board_epoch(cfg, board) do
    case cfg.board.cmd(board, "date +%s") do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {epoch, ""} -> {:ok, epoch}
          _ -> {:error, {:bad_board_epoch, out}}
        end

      {out, rc} ->
        {:error, {:board_epoch, rc, out}}
    end
  end

  defp reduce_rungs(cfg, board, fun) do
    Enum.reduce_while(Config.rungs(cfg), {:ok, board}, fn rung, {:ok, b} ->
      case fun.(rung, b) do
        {:ok, b} -> {:cont, {:ok, b}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp warn_ok(cfg, board, msg) do
    log(cfg, "WARN: #{msg}")
    {:ok, board}
  end

  @doc false
  def log(cfg, msg) do
    File.mkdir_p!(Config.htp(cfg))
    stamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    File.write!(Path.join(Config.htp(cfg), "campaign.log"), "[#{stamp}] #{msg}\n", [:append])
    Logger.info(msg)
    :ok
  end
end
