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

for stub <-
      ~w(models/yolox_m_qdq.onnx models/yolox_tiny_qdq.onnx models/yolox_nano_qdq.onnx models/coco.names) do
  File.write!(Path.join(tmp, stub), "stub")
end

original_cwd = File.cwd!()
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
  for n <- [2, 10, 11, 26, 28, 30, 36, 38, 40, 41], into: %{} do
    result = resolve.(n)

    case result do
      {:refused, _errors} -> IO.puts("#{n},REFUSED,-")
      {artifact, fps} -> IO.puts("#{n},#{artifact},#{fps}")
    end

    {n, result}
  end

# Back out before deleting: removing the process's own cwd leaves mix
# teardown running relative-path operations in a vanished directory.
File.cd!(original_cwd)
File.rm_rf!(tmp)

# The yolox_m head of the ladder (packs absent, as deploys today): its
# PROVISIONAL 20 budget carries fleets through 10 and hands 11 to tiny —
# arithmetic pinned so the file cannot drift silently, not a measured
# boundary (its ladder run is owed, D-L6; the file says DRAFT). The
# derived rate rises with headroom (D-L4): 2 cameras split the 20 budget
# at 10 fps each, 10 cameras ride the floor.
{"yolox_m_qdq.onnx", 10} = table[2]
{"yolox_m_qdq.onnx", 2} = table[10]
{"yolox_tiny_qdq.onnx", 7} = table[11]

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
# The CLAIM bound specifically, not merely any refusal: no_rung_fits would
# also refuse 41 with these budgets, and a claim drifted to 41+ must not
# hide behind it.
{:refused, errors_41} = table[41]
true = Enum.any?(errors_41, &(&1 =~ "exceed supported_cameras 40"))

IO.puts(
  "resolution check: PASS — yolox_m through 10 (provisional), tiny 11–36, nano 37–40, " <>
    "41 refused by the claim"
)
