# Phase-3 preflight (tier1-ladder 3.2): prove the SHIPPED qcs6490-tier1
# ladder resolves the exact cells the boundary runs execute, so the board
# numbers are measurements of what config actually deploys — "through the
# new resolution path", not hand-picked parameters that merely resemble it.
#
# Run from the repo root (tier1-boundary.sh does):
#   mix run --no-start tools/board-pipeline/tier1_resolution_check.exs
#
# --no-start: this needs the code and the YAML parser, not a running node —
# a booted app would spin up whatever cameras the local config.yml names.
#
# Artifact paths in the shipped file are board paths, so resolution runs
# from a temp cwd holding stub files at the Apache-rung paths — config only
# File.regular?-checks them. The pack rungs stay absent on purpose: their
# skip warnings are part of what deploys today.

{:ok, _apps} = Application.ensure_all_started(:yaml_elixir)

tmp = Path.join(System.tmp_dir!(), "tier1-resolution-check-#{System.unique_integer([:positive])}")
File.mkdir_p!(Path.join(tmp, "models"))

for stub <- ~w(models/yolox_tiny_qdq.onnx models/yolox_nano_qdq.onnx models/coco.names) do
  File.write!(Path.join(tmp, stub), "stub")
end

File.cd!(tmp)

resolve = fn n ->
  map = %{
    "data_dir" => Path.join(tmp, "data"),
    "plugins" => %{
      "det" => %{"profile" => "qcs6490-tier1", "allow_experimental" => true}
    },
    "cameras" =>
      Enum.map(1..n, fn i ->
        %{"id" => "cam_#{i}", "rtsp_url" => "rtsp://h/#{i}", "plugin" => "det"}
      end)
  }

  case Cairn.Config.from_map(map) do
    {:ok, config, _warnings} ->
      [%{profile: profile}] = config.plugin_groups
      {Path.basename(Cairn.Config.Profile.artifact(profile)), profile.sample_fps}

    {:error, errors} ->
      {:refused, errors}
  end
end

IO.puts("n,resolved_artifact,derived_sample_fps")

table =
  for n <- [26, 28, 29, 30, 40, 41], into: %{} do
    result = resolve.(n)

    case result do
      {:refused, _errors} -> IO.puts("#{n},REFUSED,-")
      {artifact, fps} -> IO.puts("#{n},#{artifact},#{fps}")
    end

    {n, result}
  end

File.rm_rf!(tmp)

# The cells the boundary runs execute, asserted against what actually
# resolves — a mismatch means the run plan and the shipped file drifted
# apart, and the board time would measure the wrong thing.
{"yolox_nano_qdq.onnx", 2} = table[40]
{"yolox_tiny_qdq.onnx", 2} = table[28]
{"yolox_tiny_qdq.onnx", 2} = table[26]
# Draft budgets put the tiny→nano boundary at 54.6/1.875 ≈ 29: rung 30
# resolves NANO under the draft file. The tiny cells at 30 deliberately
# FORCE tiny past its predicted boundary — that overload cell is what
# locates the measured budget.
{"yolox_nano_qdq.onnx", 2} = table[30]
{:refused, _past_claim} = table[41]

IO.puts("resolution check: PASS — 40→nano@2 (the 3.2 cell), 26/28→tiny@2, 41 refused")
