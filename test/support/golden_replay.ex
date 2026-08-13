defmodule Cairn.GoldenReplay do
  @moduledoc """
  Replays recorded detector output — and hand-authored step scripts — through
  `Cairn.Tracker`, rendering the result as canonical golden text compared with
  **exact equality**.

  This is a regression harness for extraction PRs: a refactor whose golden
  diff is empty has proved itself bit-identical on these fixtures. It is
  **not** the soak — see `test/support/golden/README.md` for what it cannot
  see and for the fixture capture recipe.

  ## Replay path

  Capture fixtures replay the real ingestion pipeline below the port:
  `Cairn.PluginProtocol.decode_line/2` → `Cairn.ObservationClock.stamp/3`
  (with the *recorded* arrival `now_ms` — arrival timing shapes `at_ms` and is
  not in the lines) → `Cairn.Tracker.context/3` → `Cairn.Tracker.track/3`, one
  batch per `frame.objects` line. Step scripts drive three of the core
  callbacks `Membrane.MOTTracker` drives — `track/3`, `suspend/3`,
  `expire_suspended/2` — for the paths recorded clips never hit.

  ## Canonicalization

  Two sources of run-to-run noise are canonicalized away; nothing else is.

    * **ULIDs.** `Cairn.Tracker` mints ids with `Cairn.ULID.generate/0`
      (wall clock + crypto random), so ids differ across runs while mint
      *order* is deterministic (batch index order, `apply_assignments/5`).
      Every id is replaced by its mint ordinal — `T0001`, `T0002`, … in
      `:started`-event order. An id that never appeared in a `:started` event
      is unknown, and rendering it raises: silence there would mean a track
      the harness cannot account for.
    * **Same-kind event runs.** Two emitters build event lists by map
      comprehension — `expire/2` and `end_all/2` — and past 32 live tracks
      Erlang's hashmap iteration order is arbitrary. Each *maximal run of
      consecutive same-kind events* within a batch is sorted by canonical id.
      Runs are never merged across kinds: the within-batch order
      `lapsed ++ lifecycle ++ expired` and the documented
      `:updated`-before-transition adjacency are meaningful and must stay
      able to fail a comparison.

  Floats are compared exactly (via Jason's shortest-round-trip encoding):
  bit-identity is the point, and goldens are expected to churn — under human
  review — on any PR that deliberately reorders arithmetic.

  ## Golden text

  One JSON line per batch (`i`, `step`, `at_ms`, `events`, `tagged` — plus
  `suspension` on suspend steps), then a `checkpoint` line
  (`Cairn.Tracker.checkpoint_tracks/1`, re-sorted by canonical id because the
  ULID sort it ships in is not stable under id substitution) and a
  `state_hash` line — a SHA-256 over the *entire* canonicalized end-state
  tracker struct, kalman internals included, as a tripwire for divergence the
  observable stream missed. All object keys are emitted sorted, so the text
  is deterministic across OTP versions.

  The hash tags every struct with its module name, so **renaming** a struct the
  tracker holds moves it while every observable line stays byte-identical —
  which is the one shape of golden diff a pure extraction can legitimately
  have, and the only one where "hash line only" is the whole review.
  """

  alias Cairn.{Observation, ObservationClock, PluginProtocol, Track, Tracker}

  @golden_dir Path.join(["test", "support", "golden"])
  @camera_id "test"

  # The policy every capture replays under, mirroring the step-7 BBD+ORU soak
  # (`.claude/plans/tracker-reeval/soak-results.md`): defaults 3000/128/10000,
  # the plugin's own 0.5 floor, both flags on. Hardcoded rather than read from
  # `Cairn.Config`: a golden must not move because a config default did.
  @capture_policy %{
    max_unseen_ms: 3_000,
    max_live_tracks: 128,
    stationary_after_ms: 10_000,
    min_score: %{"default" => 0.5},
    bbd: true,
    oru: true
  }

  @doc "The fixed policy capture fixtures replay under."
  @spec capture_policy() :: Tracker.policy()
  def capture_policy, do: @capture_policy

  # -- replay drivers ---------------------------------------------------------

  @doc """
  Replays a committed capture (`captures/<name>.tsv.gz`) and returns golden
  text.

  Non-frame lines (`plugin.hello`, `plugin.status`, ignored types) are
  skipped; a line the protocol *rejects* raises — the fixture was validated at
  capture time, so a decode error here is harness rot, not noise.
  """
  @spec replay_capture(String.t(), Tracker.policy()) :: String.t()
  def replay_capture(name, policy \\ @capture_policy) do
    lines =
      [@golden_dir, "captures", name <> ".tsv.gz"]
      |> Path.join()
      |> File.read!()
      |> :zlib.gunzip()
      |> String.split("\n", trim: true)

    initial = %{
      tracker: Tracker.new(),
      clock: ObservationClock.new(),
      canon: new_canon(),
      batches: [],
      count: 0
    }

    state =
      Enum.reduce(lines, initial, fn line, state ->
        [now_ms, raw] = String.split(line, "\t", parts: 2)

        case PluginProtocol.decode_line(raw, :camera) do
          {:objects, observation} ->
            {observation, clock} =
              ObservationClock.stamp(state.clock, observation, String.to_integer(now_ms))

            context = Tracker.context(observation, @camera_id, policy)
            observe(%{state | clock: clock}, observation.objects, context, :observe)

          {:hello, _hello} ->
            state

          {:status, _status} ->
            state

          {:ignore, _reason} ->
            state

          {:error, reason} ->
            raise "capture #{name}: line failed protocol decode (#{inspect(reason)}): #{raw}"
        end
      end)

    render(state)
  end

  @doc """
  Runs a step script (`steps/<name>.exs`) and returns golden text.

  A script evaluates to `%{policy: policy, steps: [step]}` with the step
  vocabulary matching the three core callbacks the tracker element drives:

      {:observe, %{at_ms: ms, objects: [object]}}     # Tracker.track/3
      {:suspend, %{cut_ms: ms}}                       # Tracker.suspend/3
      {:expire_suspended, %{at_ms: ms}}               # Tracker.expire_suspended/2

  An observe step takes optional `epoch:` (default `"epoch_one"`) and
  `observed_at:` (default: the wall instant `at_ms` names, as in
  `tracker_test.exs`'s `ctx/1`); a suspend step optional `max_suspended:`
  (default 32). Objects take `label:`/`bbox:` with optional `score:`
  (default 0.9) and `kind:` (default `"detected"`).
  """
  @spec replay_steps(String.t()) :: String.t()
  def replay_steps(name) do
    {%{policy: policy, steps: steps}, _bindings} =
      Code.eval_file(Path.join([@golden_dir, "steps", name <> ".exs"]))

    initial = %{tracker: Tracker.new(), canon: new_canon(), batches: [], count: 0}

    state = Enum.reduce(steps, initial, &run_step(&2, &1, policy))
    render(state)
  end

  defp run_step(state, {:observe, step}, policy) do
    at_ms = Map.fetch!(step, :at_ms)

    observation = %Observation{
      camera_id: @camera_id,
      epoch: Map.get(step, :epoch, "epoch_one"),
      at_ms: at_ms,
      observed_at: Map.get_lazy(step, :observed_at, fn -> wall(at_ms) end)
    }

    context = Tracker.context(observation, @camera_id, policy)
    objects = Enum.map(Map.fetch!(step, :objects), &step_object/1)
    observe(state, objects, context, :observe)
  end

  defp run_step(state, {:suspend, step}, _policy) do
    {tracker, events, suspension} =
      Tracker.suspend(state.tracker, Map.get(step, :max_suspended, 32), Map.fetch!(step, :cut_ms))

    canon = assign_ordinals(state.canon, events)

    batch =
      base_batch(state, :suspend, Map.fetch!(step, :cut_ms), canon)
      |> Map.put("events", canon_events(events, canon))
      |> Map.put("suspension", canon_plain(suspension, canon))

    %{
      state
      | tracker: tracker,
        canon: canon,
        batches: [batch | state.batches],
        count: state.count + 1
    }
  end

  defp run_step(state, {:expire_suspended, step}, _policy) do
    at_ms = Map.fetch!(step, :at_ms)
    {tracker, events} = Tracker.expire_suspended(state.tracker, at_ms)
    canon = assign_ordinals(state.canon, events)

    batch =
      base_batch(state, :expire_suspended, at_ms, canon)
      |> Map.put("events", canon_events(events, canon))

    %{
      state
      | tracker: tracker,
        canon: canon,
        batches: [batch | state.batches],
        count: state.count + 1
    }
  end

  defp observe(state, objects, context, kind) do
    {tracker, tagged, events} = Tracker.track(state.tracker, objects, context)
    canon = assign_ordinals(state.canon, events)

    batch =
      base_batch(state, kind, context.at_ms, canon)
      |> Map.put("events", canon_events(events, canon))
      |> Map.put("tagged", Enum.map(tagged, &canon_plain(&1, canon)))

    %{
      state
      | tracker: tracker,
        canon: canon,
        batches: [batch | state.batches],
        count: state.count + 1
    }
  end

  defp base_batch(state, kind, at_ms, _canon) do
    %{"i" => state.count, "step" => Atom.to_string(kind), "at_ms" => at_ms}
  end

  defp step_object(object) do
    %{
      label: Map.fetch!(object, :label),
      bbox: Map.fetch!(object, :bbox),
      score: Map.get(object, :score, 0.9),
      track_id: nil,
      observation_kind: Map.get(object, :kind, "detected")
    }
  end

  # The wall instant an `at_ms` names, as `tracker_test.exs`'s `at/1` builds it:
  # `observed_at` is reporting data, not a clock the tracker decides on, but it
  # flows into `stationary_since` and track summaries, so it must be scripted.
  defp wall(at_ms), do: DateTime.add(~U[2026-07-26 12:00:00Z], trunc(at_ms), :millisecond)

  # -- canonicalization -------------------------------------------------------

  defp new_canon, do: %{ids: %{}, next: 1}

  # Mint ordinals are assigned in `:started`-event order, which is
  # deterministic (batch index order) even though the ULIDs themselves are not.
  defp assign_ordinals(canon, events) do
    Enum.reduce(events, canon, fn
      {:started, %Track{object_id: id}}, canon ->
        if Map.has_key?(canon.ids, id) do
          canon
        else
          ordinal = "T" <> String.pad_leading(Integer.to_string(canon.next), 4, "0")
          %{canon | ids: Map.put(canon.ids, id, ordinal), next: canon.next + 1}
        end

      _event, canon ->
        canon
    end)
  end

  # `object_id` fields go through this, not `canon_value/2`: other binaries
  # (labels, epochs) are never ids and pass through untranslated, while an
  # object id with no ordinal is a track minted without a `:started` event,
  # which the harness must not paper over. A ULID leaking into any *rendered*
  # value outside an `object_id` field stays raw, differs between the
  # double-run's two replays, and fails the identity assert. The state hash
  # is a separate regime on purpose: `hash_term/2` substitutes *known* ids
  # wherever they appear — they are map keys in `tracker.objects`/`suspended`,
  # which is canonicalization, not a leak — while an unknown ULID stays raw
  # there too and still breaks the double-run via a differing hash.
  defp canon_id(id, canon) when is_binary(id) do
    Map.get(canon.ids, id) ||
      raise "golden replay: id #{id} appeared without a :started event — " <>
              "the harness cannot account for this track"
  end

  # Sort each maximal run of consecutive same-kind events by canonical id;
  # never across kinds (see the moduledoc).
  defp canon_events(events, canon) do
    events
    |> Enum.map(fn {kind, %Track{} = track} ->
      %{"kind" => Atom.to_string(kind), "track" => canon_track(track, canon)}
    end)
    |> Enum.chunk_by(& &1["kind"])
    |> Enum.flat_map(fn run -> Enum.sort_by(run, & &1["track"]["object_id"]) end)
  end

  defp canon_track(%Track{} = track, canon) do
    track |> Map.from_struct() |> canon_plain(canon)
  end

  # Tagged objects, track fields and suspension reports: plain maps with atom
  # keys, `object_id` strictly translated.
  defp canon_plain(%{} = map, canon) do
    Map.new(map, fn
      {:object_id, id} -> {"object_id", canon_id(id, canon)}
      {key, value} -> {Atom.to_string(key), canon_value(value, canon)}
    end)
  end

  defp canon_value(%DateTime{} = at, _canon), do: DateTime.to_iso8601(at)

  defp canon_value(value, _canon) when is_atom(value) and not is_boolean(value) and value != nil,
    do: Atom.to_string(value)

  defp canon_value(list, canon) when is_list(list), do: Enum.map(list, &canon_value(&1, canon))
  defp canon_value(value, _canon), do: value

  # -- golden text ------------------------------------------------------------

  defp render(state) do
    tracker = state.tracker
    canon = state.canon

    checkpoint =
      tracker
      |> Tracker.checkpoint_tracks()
      |> Enum.map(&canon_track(&1, canon))
      |> Enum.sort_by(& &1["object_id"])

    batch_lines = state.batches |> Enum.reverse() |> Enum.map(&encode/1)

    trailer = [
      encode(%{"checkpoint" => checkpoint}),
      encode(%{"state_hash" => state_hash(tracker, canon)})
    ]

    Enum.join(batch_lines ++ trailer, "\n") <> "\n"
  end

  # Deterministic JSON: every object's keys sorted, so the text does not depend
  # on Erlang map iteration order (or its >32-key hashmap boundary).
  defp encode(term), do: term |> ordered() |> Jason.encode!()

  defp ordered(%Jason.OrderedObject{} = object), do: object

  defp ordered(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  # The end-state tripwire: everything in the tracker struct — kalman
  # covariances included — reduced to a canonical term (ids substituted, maps
  # sorted, structs and tuples tagged, atoms stringified) and hashed. A
  # divergence that never surfaced in events, tags or the checkpoint still
  # moves this.
  defp state_hash(%Tracker{} = tracker, canon) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(hash_term(tracker, canon)))
    |> Base.encode16(case: :lower)
  end

  defp hash_term(%DateTime{} = at, _canon), do: DateTime.to_iso8601(at)

  defp hash_term(%module{} = struct, canon),
    do: ["struct", Atom.to_string(module), hash_term(Map.from_struct(struct), canon)]

  defp hash_term(%{} = map, canon) do
    map
    |> Enum.map(fn {key, value} -> [hash_term(key, canon), hash_term(value, canon)] end)
    |> Enum.sort()
  end

  defp hash_term(list, canon) when is_list(list), do: Enum.map(list, &hash_term(&1, canon))

  defp hash_term(tuple, canon) when is_tuple(tuple),
    do: ["tuple" | tuple |> Tuple.to_list() |> Enum.map(&hash_term(&1, canon))]

  defp hash_term(value, canon) when is_binary(value), do: Map.get(canon.ids, value, value)
  defp hash_term(value, _canon) when is_atom(value), do: ["atom", Atom.to_string(value)]
  defp hash_term(value, _canon), do: value

  # -- golden files -----------------------------------------------------------

  @doc """
  Compares `text` against `goldens/<name>.golden`, or rewrites it when
  `GOLDEN_REGEN` is set (via `mix cairn.golden.regen` — the diff is the review
  artifact and must be read, not merely regenerated).
  """
  @spec check_golden(String.t(), String.t()) :: :ok
  def check_golden(name, text) do
    path = Path.join([@golden_dir, "goldens", name <> ".golden"])

    # Exactly "1" (what `mix cairn.golden.regen` sets), not any non-empty
    # value: a stray GOLDEN_REGEN=0 or =false in the environment must not
    # silently flip the whole suite into rewrite mode.
    if System.get_env("GOLDEN_REGEN") == "1" do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
      :ok
    else
      unless File.exists?(path) do
        raise "missing golden #{path} — run `mix cairn.golden.regen` and review the new file"
      end

      golden = File.read!(path)

      if golden != text do
        raise ExUnit.AssertionError,
          message:
            "golden diff for #{name} (#{first_divergence(golden, text)}).\n" <>
              "If this change is deliberate, run `mix cairn.golden.regen` and review the diff — " <>
              "an extraction PR's golden diff must be empty, or (for a struct rename) " <>
              "the state_hash line and nothing else."
      end

      :ok
    end
  end

  defp first_divergence(golden, text) do
    golden_lines = String.split(golden, "\n")
    text_lines = String.split(text, "\n")

    case Enum.find_index(Enum.zip(golden_lines, text_lines), fn {a, b} -> a != b end) do
      nil ->
        "line counts differ: golden #{length(golden_lines)}, actual #{length(text_lines)}"

      index ->
        "first divergence at line #{index + 1}:\n" <>
          "  golden: #{Enum.at(golden_lines, index)}\n" <>
          "  actual: #{Enum.at(text_lines, index)}"
    end
  end
end
