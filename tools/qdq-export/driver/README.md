# driver

The HTP campaign driver: `Driver.Board` speaks `:erpc` to the board's
`Vagus.Dist` node, `Driver.Campaign` runs the stages, `Driver.CLI` is
the entry point. Invocation, stage semantics, and the deprecated bash
reference are documented in the parent `tools/qdq-export/README.md`
(board-leg section); the board contract is
`docs/handoff/vagus-rpc-endpoint.md`.

```
mix test    # :peer-based Board suite + ScriptedBoard stage suite, no board needed
```
