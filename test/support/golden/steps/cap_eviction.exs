# The live-track cap — a path no recorded capture hits (the captures replay
# with `max_live_tracks: 128` and never approach it).
#
# With the cap at 2: two tracks are established, then a third object arrives
# in a batch that also matches both existing tracks — every live track is
# protected (assigned this batch), so there is no eviction candidate and the
# new object is *dropped* (absent from `tagged`, no `:started`). Then a batch
# with only the new object and one of the old ones: the unmatched old track is
# now evictable, and the mint goes through over an `:ended`/`:evicted` final.
%{
  policy: %{
    max_unseen_ms: 60_000,
    max_live_tracks: 2,
    stationary_after_ms: 10_000,
    min_score: %{"default" => 0.5},
    bbd: true,
    oru: true
  },
  steps:
    [
      # Two tracks. Long max_unseen so nothing expires on its own.
      for ms <- [0, 500, 1000] do
        {:observe,
         %{
           at_ms: ms,
           objects: [
             %{label: "person", bbox: [0.10, 0.30, 0.08, 0.25]},
             %{label: "car", bbox: [0.60, 0.55, 0.25, 0.18], score: 0.85}
           ]
         }}
      end,
      # Third object while both existing tracks are matched in the same batch:
      # everything live is protected, the cap holds, the dog is refused.
      [
        {:observe,
         %{
           at_ms: 1_500,
           objects: [
             %{label: "person", bbox: [0.10, 0.30, 0.08, 0.25]},
             %{label: "car", bbox: [0.60, 0.55, 0.25, 0.18], score: 0.85},
             %{label: "dog", bbox: [0.40, 0.70, 0.10, 0.10], score: 0.8}
           ]
         }}
      ],
      # Now the person is absent from the batch: it is unprotected, and the
      # dog's mint evicts it as the least recently seen.
      [
        {:observe,
         %{
           at_ms: 2_000,
           objects: [
             %{label: "car", bbox: [0.60, 0.55, 0.25, 0.18], score: 0.85},
             %{label: "dog", bbox: [0.40, 0.70, 0.10, 0.10], score: 0.8}
           ]
         }}
      ]
    ]
    |> List.flatten()
}
