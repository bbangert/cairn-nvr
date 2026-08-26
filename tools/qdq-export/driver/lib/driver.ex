defmodule Driver do
  @moduledoc """
  HTP campaign driver speaking `:erpc` to the board's host BEAM node
  (`Vagus.Dist`), replacing `run_htp_campaign.sh`'s ssh/scp transport.

  The port changes how commands run and files move, never what the
  evidence means: board-side scripts (`htp_content_test.sh`, `bench.sh`)
  stay busybox `sh` pushed and exec'd as-is, and the analyzers
  (`campaign_meta.py`, `htp_report.py`) consume the same fetched layout.

  Layout: `Driver.Board` is the session/transport layer,
  `Driver.Campaign` the stages, `Driver.CLI` the entry point.
  Contract: `docs/handoff/vagus-rpc-endpoint.md`.
  """
end
