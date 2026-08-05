defmodule Mix.Tasks.Cairn.Golden.Regen do
  @shortdoc "Regenerates golden replay fixtures (the diff must be reviewed)"

  @moduledoc """
  Rewrites every golden under `test/support/golden/goldens/` from a fresh
  replay of the committed fixtures.

      mix cairn.golden.regen

  **The diff is the artifact.** These goldens exist so an extraction PR can
  prove "bit-identical" with an *empty* golden diff; a PR that regenerates
  them is asserting its behaviour change is deliberate, and the regenerated
  diff must be read line by line in review, not merely committed. Exact float
  comparison means goldens also churn on intentional arithmetic-order changes
  — that churn is the signal, not noise to suppress.

  Runs the golden suite with `GOLDEN_REGEN=1`, under which
  `Cairn.GoldenReplay.check_golden/2` writes instead of comparing.
  """

  use Mix.Task

  @impl true
  def run(_argv) do
    {_output, status} =
      System.cmd("mix", ["test", "test/cairn/golden_replay_test.exs"],
        env: [{"GOLDEN_REGEN", "1"}],
        into: IO.stream(:stdio, :line)
      )

    if status != 0 do
      Mix.raise("golden regeneration failed (mix test exited #{status})")
    end

    Mix.shell().info("goldens rewritten under test/support/golden/goldens/ — review the diff")
  end
end
