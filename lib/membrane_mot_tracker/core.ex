defmodule Membrane.MOTTracker.Core do
  @moduledoc """
  The multi-object tracker `Membrane.MOTTracker` hosts: observations in,
  identities and lifecycle events out, as pure functions over an opaque state.

  A core is passed to the element as `{module, opts}` and is never a process.
  Everything it decides on is handed to it — the clock included, as
  `context.at_ms` — so a batch replayed with the same arguments produces the
  same tracks, which is what makes a core comparable against a reference
  implementation offline and what keeps the element free of policy.

  The vocabulary of an object, a context and a track summary belongs to the
  host, not to this tree: a core receives whatever maps its host stamps onto
  the buffers and returns summaries in the host's own shape. Only the tuple
  shapes below are this behaviour's.

  ## The two clocks that are one

  `at_ms` (a batch) and `cut_ms` (an epoch boundary) are the same clock, and
  every bound a core measures is a subtraction of two of them. A host whose
  batches carry media time must therefore cut on that same time — a core is
  entitled to compare the two and cannot tell them apart.
  """

  @typedoc "A core's own state, threaded by the element and opaque to it."
  @type state :: term()

  @typedoc """
  One detected object, in the host's vocabulary — at minimum something with a
  box and a label a core can match on.
  """
  @type object :: map()

  @typedoc """
  Everything about one batch the core is allowed to decide on: `at_ms` and
  whatever thresholds the host resolved for this camera. Built per buffer
  upstream, never held as core state, so a policy reload takes effect on the
  next batch without touching the tracker.
  """
  @type context :: %{required(:at_ms) => number(), optional(atom()) => term()}

  @typedoc "A track summary in the host's shape, as its consumers publish it."
  @type track :: map()

  @typedoc """
  One lifecycle transition: the kind (`:started`, `:updated`, `:ended` and
  whatever else a host's consumers understand) and the summary it happened to.
  """
  @type event :: {atom(), track()}

  @typedoc """
  What one `c:suspend/3` did, for the caller's link-health report: how many
  tracks are waiting for adoption, how many were ended instead (exactly the
  length of the event list returned beside it), and `at` — the last sign of
  life before the cut, which is what an outage gap is measured from, or `nil`
  when there has been none.
  """
  @type suspension :: %{suspended: non_neg_integer(), ended: non_neg_integer(), at: term()}

  @doc """
  A tracker with no tracks in it, configured by `opts` from the element's
  `tracker:` option.
  """
  @callback new(opts :: keyword()) :: state()

  @doc """
  Folds one batch of objects into the tracker.

  Returns `{state, tagged, events}`. `tagged` is what the core says this batch
  amounts to: every entry carries the identity it was assigned, and consumers
  read it as the frame's answer rather than as the input annotated. A core that
  refuses an object leaves it out, and one whose estimate of a box is not the
  detection's — a filtered position, say — is entitled to report its own, in an
  order of its own. `events` are the transitions this batch caused, in the order
  a consumer should apply them.

  Called once per buffer, so it is also the only clock a core gets for free: a
  bound that must expire without further batches needs `c:expire_suspended/2`
  driven by the element's timer.
  """
  @callback track(state(), objects :: [object()], context()) ::
              {state(), tagged :: [object()], [event()]}

  @doc """
  Moves the live tracks aside at a stream-epoch boundary, keeping them
  adoptable.

  Nothing observed the boundary, so no track may go on matching ordinarily
  across it; suspending rather than ending them is what lets a detection in the
  new epoch resume an identity instead of minting a duplicate of an object that
  never left.

  `cut_ms` is the boundary on the batch clock — the caller's, since no
  observation marks a cut. `max_suspended` caps what is kept: a camera
  reconnecting in a loop must not accumulate a generation of ghosts per
  attempt. The returned events are the tracks that did **not** survive the
  suspension (capped out, or already lapsed by `cut_ms`), and the returned
  state must hold no live tracks.
  """
  @callback suspend(state(), max_suspended :: pos_integer(), cut_ms :: number()) ::
              {state(), [event()], suspension()}

  @doc """
  Ends every suspended track whose adoption window has run out at `at_ms`.

  Idempotent at a given `at_ms` and safe to call with nothing suspended: it is
  driven twice over, by every `c:track/3` and by the element's own timer for a
  camera whose stream never comes back — nothing else would collect a
  suspension on a dead link, and the finals its consumers are owed would never
  go out.
  """
  @callback expire_suspended(state(), at_ms :: number()) :: {state(), [event()]}

  @doc """
  Ends every live track with `reason`, and every suspended one, returning an
  emptied state.

  For where nothing may be waited for any longer: detection turned off, a
  camera stopped, a shutdown. A core may end a suspended track under a reason
  of its own — what the track was last seen by does not change because a caller
  gave up on the wait early.
  """
  @callback end_all(state(), reason :: atom()) :: {state(), [event()]}

  @doc """
  Every track this state still owes a final summary for — the live ones and the
  suspended ones together, in a stable order.

  Ships on every out-buffer, so a consumer that persists it never has to ask
  the element for it. Stable order is required, not incidental: the snapshot is
  compared against the last one written, and a reshuffle would read as a change.
  """
  @callback checkpoint_tracks(state()) :: [track()]

  @doc """
  How long a suspended track stays adoptable, on the batch clock.

  The window is the core's, so the element reads it from here rather than
  taking it as an option: its timer only has to outlive the window, and a core
  that keeps no suspensions can leave this out — the element then arms no
  timer, which is what omitting it means.
  """
  @callback adoption_window_ms() :: pos_integer()

  @optional_callbacks adoption_window_ms: 0
end
