# Suspension and adoption across a stream cut — the path no recorded capture
# hits (both captures run a single epoch end to end).
#
# Two tracks are live at the cut. In the new epoch the person re-appears where
# it was and is adopted (`:adopted`, keeping its identity); the car never
# comes back and its suspension lapses at `expire_suspended/2`
# (`:ended`/`:stream_reset`). The final expire step is past the adoption
# window (a minute from the cut), so the lapse actually fires.
#
# ORU is on, and the person's re-appearance opens a 3.5 s gap since its last
# detection (at_ms 5_500 against 2_000) with motion on the far side — inside
# `@oru_min_gap_ms..@oru_max_gap_ms` (1_000..10_000) — so the adopted track's
# cross-cut replay path is exercised, not just the identity hand-off.
%{
  policy: %{
    max_unseen_ms: 3_000,
    max_live_tracks: 128,
    stationary_after_ms: 10_000,
    min_score: %{"default" => 0.5},
    bbd: true,
    oru: true
  },
  steps:
    [
      # Establish two tracks: a person walking right, a parked car.
      for ms <- [0, 400, 800, 1200, 1600, 2000] do
        x = 0.20 + ms / 2000 * 0.10

        {:observe,
         %{
           at_ms: ms,
           objects: [
             %{label: "person", bbox: [x, 0.30, 0.08, 0.25]},
             %{label: "car", bbox: [0.60, 0.55, 0.25, 0.18], score: 0.85}
           ]
         }}
      end,
      # The stream cuts 500 ms after the last observation.
      [{:suspend, %{cut_ms: 2_500}}],
      # New epoch, 3 s after the cut: the person is a little further along its
      # walk (overlapping its predicted box, same label — adoptable), the car
      # is gone. Motion continues on the far side so ORU's resumed-motion test
      # sees a mover.
      [
        {:observe,
         %{
           at_ms: 5_500,
           epoch: "epoch_two",
           objects: [%{label: "person", bbox: [0.325, 0.30, 0.08, 0.25]}]
         }},
        {:observe,
         %{
           at_ms: 5_900,
           epoch: "epoch_two",
           objects: [%{label: "person", bbox: [0.335, 0.30, 0.08, 0.25]}]
         }},
        {:observe,
         %{
           at_ms: 6_300,
           epoch: "epoch_two",
           objects: [%{label: "person", bbox: [0.345, 0.30, 0.08, 0.25]}]
         }}
      ],
      # Well past the adoption window (60 s from the cut): the car's
      # suspension lapses as a :stream_reset final.
      [{:expire_suspended, %{at_ms: 70_000}}]
    ]
    |> List.flatten()
}
