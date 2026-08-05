# The twin gate delisted — the pre-#68 cold-start double mint, preserved as
# the deliberate NMS-free escape hatch (`twin_mint: false`).
#
# One parked car arrives as two evidence-grade boxes (the observed failure
# shape: overlap far above the suppression threshold). With the gate listed
# — every other fixture, since it defaults on — the lower-scored box drops
# and the object mints once. Here the gate is off, both boxes mint, and the
# golden pins the double identity: two `:started` events in the first batch,
# two live tracks matching one object thereafter.
%{
  policy: %{
    max_unseen_ms: 3_000,
    max_live_tracks: 128,
    stationary_after_ms: 10_000,
    min_score: %{"default" => 0.5},
    bbd: true,
    oru: true,
    twin_mint: false
  },
  steps:
    [
      for ms <- [0, 500, 1000] do
        {:observe,
         %{
           at_ms: ms,
           objects: [
             %{label: "car", bbox: [0.30, 0.30, 0.20, 0.40], score: 0.9},
             %{label: "car", bbox: [0.32, 0.30, 0.20, 0.40], score: 0.7}
           ]
         }}
      end
    ]
    |> List.flatten()
}
