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
      ~w(models/yolox_m-qdq-a8.onnx models/yolox_s-qdq-a8.onnx models/yolox_tiny-qdq-a8.onnx models/yolox_nano-qdq-a16.onnx models/coco.names) do
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
  for n <- [2, 10, 13, 14, 28, 29, 39, 40, 41], into: %{} do
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

# The fixed-quantization ladder's Apache spine (packs absent, as deploys
# today; qdq-reexport 2026-08-21). All budgets but nano's are PROVISIONAL
# bench arithmetic (their ladder runs are owed, D-L6; the file says
# DRAFT) — pinned so the file cannot drift silently: yolox_m-a8 (25.0)
# carries fleets through 13, yolox_s-a8 (54.1) through 28, tiny-a8 (74,
# held strictly under nano for reachability) through 39. The derived
# rate rises with headroom (D-L4): 2 cameras split m's budget at 10 fps
# each, boundary fleets ride the floor.
{"yolox_m-qdq-a8.onnx", 10} = table[2]
{"yolox_m-qdq-a8.onnx", 2} = table[10]
{"yolox_m-qdq-a8.onnx", 2} = table[13]
{"yolox_s-qdq-a8.onnx", 4} = table[14]
{"yolox_s-qdq-a8.onnx", 2} = table[28]
{"yolox_tiny-qdq-a8.onnx", 2} = table[29]
{"yolox_tiny-qdq-a8.onnx", 2} = table[39]

# nano's 75 is the one boundary-MEASURED budget (tier1-capacity
# 2026-08-14, carried over on a matching p50): 40 × 1.875 = 75 exactly,
# and 41 exceeds the claim.
{"yolox_nano-qdq-a16.onnx", 2} = table[40]
# The CLAIM bound specifically, not merely any refusal: no_rung_fits would
# also refuse 41 with these budgets, and a claim drifted to 41+ must not
# hide behind it.
{:refused, errors_41} = table[41]
true = Enum.any?(errors_41, &(&1 =~ "exceed supported_cameras 40"))

IO.puts(
  "resolution check: PASS — m-a8 through 13, s-a8 through 28, tiny-a8 through 39 " <>
    "(all provisional), nano-a16 at 40 (measured), 41 refused by the claim"
)
