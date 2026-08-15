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
  for n <- [26, 28, 30, 36, 38, 40, 41], into: %{} do
    result = resolve.(n)

    case result do
      {:refused, _errors} -> IO.puts("#{n},REFUSED,-")
      {artifact, fps} -> IO.puts("#{n},#{artifact},#{fps}")
    end

    {n, result}
  end

File.rm_rf!(tmp)

# Asserted against the MEASURED boundaries (tier1-boundary-20260815): the
# tiny rung's 67.5 budget puts the tiny→nano crossover at exactly 36
# (36 × 1.875 = 67.5), and nano carries 37–40; 41 exceeds the claim. A
# mismatch means the shipped file and the measured record drifted apart.
{"yolox_tiny_qdq.onnx", 2} = table[26]
{"yolox_tiny_qdq.onnx", 2} = table[28]
{"yolox_tiny_qdq.onnx", 2} = table[30]
{"yolox_tiny_qdq.onnx", 2} = table[36]
{"yolox_nano_qdq.onnx", 2} = table[38]
{"yolox_nano_qdq.onnx", 2} = table[40]
{:refused, _past_claim} = table[41]

IO.puts("resolution check: PASS — tiny through 36, nano 37–40, 41 refused")
