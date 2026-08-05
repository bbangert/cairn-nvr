# An epoch change where nothing is adopted — the complement of
# `adoption_across_cut.exs`. The new epoch's scene is a different object in a
# different place: the old track's suspension is not adopted by it, a fresh
# identity mints, and the suspension lapses when its window runs out.
#
# The lapse here arrives through `track/3` itself rather than a driver-called
# `expire_suspended/2`: `track/3` settles suspensions first, so the final
# observe step past the adoption window carries the `:ended`/`:stream_reset`
# in its own event list (`lapsed ++ lifecycle ++ expired` order).
%{
  policy: %{
    max_unseen_ms: 120_000,
    max_live_tracks: 128,
    stationary_after_ms: 10_000,
    min_score: %{"default" => 0.5},
    bbd: true,
    oru: true
  },
  steps:
    [
      for ms <- [0, 500, 1000] do
        {:observe,
         %{
           at_ms: ms,
           objects: [%{label: "person", bbox: [0.10, 0.30, 0.08, 0.25]}]
         }}
      end,
      [{:suspend, %{cut_ms: 1_400}}],
      # New epoch: a car on the other side of the frame. Same-label overlap is
      # what adoption needs; a different label in a different place mints.
      [
        {:observe,
         %{
           at_ms: 2_000,
           epoch: "epoch_two",
           objects: [%{label: "car", bbox: [0.65, 0.60, 0.22, 0.16], score: 0.85}]
         }},
        # Past the adoption window measured from the cut (60 s): this batch's
        # lapsed settlement ends the person's suspension.
        {:observe,
         %{
           at_ms: 65_000,
           epoch: "epoch_two",
           objects: [%{label: "car", bbox: [0.65, 0.60, 0.22, 0.16], score: 0.85}]
         }}
      ]
    ]
    |> List.flatten()
}
