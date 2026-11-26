# Building a board outside this repository

A board is an OTP application that tells the base which decoders and NPU runtimes a SoC family offers and which elements make a camera's detect branch. It is built apart from the core release and attached to it at boot from a directory named by `CAIRN_BOARD_DIR`. The release is not rebuilt for a board, and no board is named in this repository's Mix project.

This page is for the author of such a board in a repository of its own. What a board answers — the nine `Cairn.Stage.Board` callbacks, steps, chains, fused elements — is in [architecture.md § Boards](architecture.md#boards). What the loader does with a directory, and how it refuses one, is in [§ Board directories](architecture.md#board-directories).

## What a board takes from core

| What | From | How |
| ---- | ---- | --- |
| The contract library, `cairn_stage` | `libs/cairn_stage` | Mix git dependency, sparse |
| The inference stages and the engine hosting, if the board has a Rust crate | `plugins/cairn-detect`, `plugins/cairn-ort` | Cargo git dependencies |
| The release it attaches to | the `cairn-nvr-base-aarch64` image | `FROM`, in the board's image |

All three must be one core commit. Keep it in one place: a `CORE_REF` file at the board repository's root, holding a core version tag (a full commit sha while developing; no base image is published for one). Nothing in core reads that file; it is a convention the board's own build and checks follow.

A board never depends on the `:cairn` application. Its application starts inside `:cairn`'s start, before `:cairn`'s supervision tree, so it cannot use `:cairn`'s processes, and both the directory task and the loader refuse the dependency. A base library a board reuses — the software decoder, the CPU engine, the host — arrives in the `base` map the base passes to `detect_chain/1`, `decoder_backend/2` and `engine/2`.

## The contract number

`Cairn.Stage.contract/0` is the version of everything a board built elsewhere must agree with. It is checked in two places and published in a third:

- The board directory's manifest carries the number the board was built against. The loader compares it with the release's before any board code is on the code path, and refuses a difference, naming both.
- An engine NIF reports the number from `contract/0` (`cairn-ort`'s `CONTRACT` mirrors it for Rust). A library that loaded and reports another number fails conformance, which refuses the boot.
- The base image carries it as the label `cairn.contract`, for a board's image build to compare with the number it compiled against.

It is bumped for a change an existing board would break on: a non-optional callback added to or changed on `Cairn.Stage.Board` or a NIF behaviour; a context or capability key removed or re-typed; a step rule; the shape of a frame, of frame metadata or of `Cairn.Stage.DmaFrame`. An optional capability key is not a bump: `Cairn.Stage.Capabilities` reads each with a default, so a board that predates the key gets the cautious answer.

The number is a compatibility check and nothing more. A board built against contract *n* attaches to any core release with contract *n*, provided the applications both carry are the same versions (below).

## The Mix project

```elixir
defmodule Cairn.Foo.MixProject do
  use Mix.Project

  @core_ref __DIR__ |> Path.join("CORE_REF") |> File.read!() |> String.trim()

  def project do
    [
      app: :cairn_foo,
      version: "0.1.0",
      elixir: "~> 1.19",
      cairn_board: Cairn.Foo.Board,
      deps: [cairn_stage()]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp cairn_stage do
    case System.get_env("CAIRN_CORE_PATH") do
      nil ->
        {:cairn_stage,
         git: "https://github.com/bbangert/cairn-nvr.git", ref: @core_ref, sparse: "libs/cairn_stage"}

      core ->
        {:cairn_stage, path: Path.join(core, "libs/cairn_stage")}
    end
  end
end
```

`cairn_board:` names the board module; `mix cairn_stage.board` reads it. `sparse:` checks out `libs/cairn_stage` alone.

**Seed the lock from core's.** Copy core's `mix.lock` at `CORE_REF` to the board repository before the first `mix deps.get`, and again when `CORE_REF` moves. The directory task refuses an application the board depends on that the core release also carries at another version, and a fresh resolve picks the newest release of each shared dependency (Membrane, for one), not the one core locked.

## The Rust crate

A board with its own NIF takes core's crates by git:

```toml
[dependencies]
cairn-detect = { git = "https://github.com/bbangert/cairn-nvr.git", tag = "vX.Y.Z" }
cairn-ort = { git = "https://github.com/bbangert/cairn-nvr.git", tag = "vX.Y.Z", default-features = false }

[features]
ort-load-dynamic = ["cairn-detect/ort-load-dynamic", "cairn-ort/ort-load-dynamic"]
```

- **One URL and one spelling of the ref, in every entry.** Cargo treats `rev = "<sha>"`, a shortened sha and `tag =` as different sources even when they name one commit, and locks a second copy of `cairn-detect`: the board's NIF and `cairn-ort` would then disagree about every type that crosses between them. Cargo cannot read `CORE_REF`, so a check that the manifest's refs equal it belongs in the board's CI. After resolving, `Cargo.lock` must hold exactly one `cairn-detect` and one `cairn-ort`.
- **`default-features = false` on `cairn-ort`.** Its default `nif` feature is `CairnOrt`'s own NIF entry. Rustler collects every NIF function in the final binary into whichever `init!` that binary runs, so a crate that links `cairn-ort` under its own NIF module turns the feature off.

- **Build with `--features ort-load-dynamic`.** The base image's ONNX Runtime is loaded at startup from `ORT_DYLIB_PATH`; without the feature the crate links a runtime of its own, downloaded at build time.
- **FFmpeg 7.1 development files at build time.** `cairn-detect` binds FFmpeg 7.1 through `rsmpeg`. Core's own `.cargo/config.toml` files, which point its builds at one, are not read when its crates are dependencies, so the board's build supplies the headers and `pkg-config` path itself.

A board that brings a backend registers it from its crate as a `Descriptor` and a `Provider` built with `Provider::new` (the struct is `#[non_exhaustive]`, so a literal does not compile), with `with_contexts` if the engine should hold more than one context of the model; see [architecture.md § Adding a board](architecture.md#adding-a-board).

## Writing the board directory

```
MIX_ENV=prod mix compile
MIX_ENV=prod mix cairn_stage.board --core-rel <release>/releases/<vsn>/cairn.rel --out <dir>
```

The NIF library goes into the project's `priv` before the task runs: the task copies `ebin` and `priv` whole, so build outputs that are not meant to ship (dialyzer PLTs, for one) must live elsewhere. The task checks the build against the core release's `.rel` and writes nothing if anything fails; the rules are listed in [architecture.md § Board directories](architecture.md#board-directories).

Build on the toolchain the release was built on. The task refuses an ERTS other than the `.rel`'s, and the base image names the pair in its labels:

| Label | Holds |
| ----- | ----- |
| `cairn.elixir.version`, `cairn.otp.version` | the toolchain that built the release |
| `cairn.contract` | `Cairn.Stage.contract/0` |
| `org.opencontainers.image.revision` | the core commit |

## The image

`ghcr.io/bbangert/cairn-nvr-base-aarch64:<version>` is the release with no board, published when a core version tag is pushed and at no other time (`vX.Y.Z` publishes `:X.Y.Z`; there is no `latest`), starting with the first tag after this page was written. It holds the release at `/app`, the CPU ONNX Runtime, FFmpeg and the Apache-licensed model rungs, and nothing from any SoC vendor. A board image is `FROM` it and adds:

- the board's vendor userspace, with the loader path set so its libraries resolve;
- the board directory, and `ENV CAIRN_BOARD_DIR=<where it was copied>`;
- the board's canary executable, if a backend names one, on the `PATH`.

The `.rel` for `--core-rel` is in the base image at `/app/releases/<vsn>/cairn.rel`; `<vsn>` is the release's own version, which is not the image tag: read it as the second word of `/app/releases/start_erl.data`. Run `ldd` on the board's NIF and executables in the final stage: an unresolved library otherwise shows first on the board.

## Rules a board obeys

The full list, with what enforces each, is in [architecture.md § Board directories](architecture.md#board-directories). In short:

- It depends on `cairn_stage`, on applications the release ships and on applications its own directory carries; never on `:cairn`.
- An application the release ships is not shipped again, and is built at the release's version.
- It offers the backend `ort` and the decoder `auto`, which the base's shipped profile and defaults name.
- It implements no protocol the release ships. The release's protocols are consolidated, so the implementation would never dispatch.
- A NIF module whose `on_load` fails refuses the boot. One whose absence should not stop the node loads without its library and reports through `load_error/0`.
- Its application is started `:permanent`: if it fails to start, or exits later, the node halts.

`Cairn.Stage.Conformance.check/2` is the check the loader runs, as plain functions. Call it from the board's own test suite with `requires: %{backends: ["ort"], decoders: ["auto"]}`, which the loader passes and the default omits; without a base to lend libraries it lends a stand-in, and the loader repeats the check with the real one.

## Trust

A board directory is code that runs with the node's privileges. The loader loads every application under `lib/` and runs every module's `on_load`, in `bin/cairn eval` as well as at boot. Nothing is signed and nothing is verified: the contract number says the board was built for this release, not who built it. Whoever can write the directory runs code as the service, so attach only a directory whose build you control, and outside an image keep it unwritable by the service's user.

## Developing against a sibling checkout

With core checked out beside the board:

- **Mix**: `CAIRN_CORE_PATH=../cairn-nvr` switches the `cairn_stage` dependency above to the checkout.
- **Cargo**: a `[patch]` section, in a `.cargo/config.toml` that is not committed, replaces the git source:

  ```toml
  [patch."https://github.com/bbangert/cairn-nvr.git"]
  cairn-detect = { path = "../cairn-nvr/plugins/cairn-detect" }
  cairn-ort = { path = "../cairn-nvr/plugins/cairn-ort" }
  ```

- **Running it**: build core's release in the checkout (`MIX_ENV=prod mix release`), write the directory against its `.rel`, and start the release with the directory attached:

  ```
  CAIRN_BOARD_DIR=<dir> ../cairn-nvr/_build/prod/rel/cairn/bin/cairn start
  ```

Neither switch may reach a committed lock: `mix.lock` and `Cargo.lock` are resolved without them.

`test/fixture_board` in this repository is a complete small board with a stub NIF. `tools/ci/external-board-test.sh` builds it the way this page describes — out of the tree, `cairn_stage` by sparse git dependency, the lock seeded from core's, the Cargo resolution checked for one copy of each core crate — and boots the release with it.
