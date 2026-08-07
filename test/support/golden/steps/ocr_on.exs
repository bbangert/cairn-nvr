# Observation-centric recovery, listed (`ocr: true`) — the mover that
# pauses behind an occluder, the case `Cairn.Tracker.Stage.Ocr` exists for.
#
# Seven steady steps teach the filter a rightward walk, four unobserved
# batches let the prediction sail on, and the person reappears exactly
# where they vanished. Flag off, that box overlaps nothing the association
# offers and duplicate suppression swallows it as the coasted track's
# stored-box twin — invisible, no event. With recovery listed the stored
# box is offered before suppression can weigh it, and the golden pins the
# resumption: one identity across the pause, an `:updated` at the
# reappearance, and no second `:started` anywhere.
%{
  policy: %{
    max_unseen_ms: 3_000,
    max_live_tracks: 128,
    stationary_after_ms: 10_000,
    min_score: %{"default" => 0.5},
    bbd: false,
    oru: false,
    ocr: true,
    twin_mint: true
  },
  steps:
    [
      for step <- 0..6 do
        {:observe,
         %{
           at_ms: step * 500,
           objects: [
             %{label: "person", bbox: [0.10 + step * 0.08, 0.40, 0.20, 0.20], score: 0.9}
           ]
         }}
      end,
      for ms <- [3_500, 4_000, 4_500, 5_000] do
        {:observe, %{at_ms: ms, objects: []}}
      end,
      {:observe,
       %{
         at_ms: 5_500,
         objects: [%{label: "person", bbox: [0.58, 0.40, 0.20, 0.20], score: 0.9}]
       }}
    ]
    |> List.flatten()
}
