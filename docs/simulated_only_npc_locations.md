# Simulated-only NPC locations

Simulated-only locations represent places the Player cannot enter, such as the Maid's
room or Dad's workplace. They use a real `.tscn` path as a stable address for the existing
NPC record and route systems, but the scene is deliberately empty. No NPC state machine,
physics, animation, or Player scene transition runs there.

## Precedent

Each simulated-only location has four parts:

1. An empty scene in `res://scenes/simulated/`. Its root has
   `_npc_simulated_only = true` and a matching `location_id` metadata value.
2. One or more normal `NpcSpotDefinition` resources in `res://data/npc_spots/`. These own
   the schedule and apply activity progress while the NPC record is off-screen.
3. Directed route edges into and out of the empty scene. A live departure still needs an
   `NpcTravelDoor` in the playable source scene; off-screen return hops use the same edges.
4. An `NpcSimulatedLocationDefinition` manifest in
   `res://data/npc_simulated_locations/`. It declares the scene, spots, NPCs, and expected
   origin scenes as one auditable contract.

Do not add playable geometry, a Player, `NpcLocationScene`, a live need spot, or an NPC to
the empty scene. The manifest audit rejects children on its root so this boundary stays
clear.

## Runtime behavior

At a scheduled start, the NPC walks to a route door in the loaded scene. Crossing it moves
the persistent NPC record to the empty scene and frees the live body. The world simulation
then advances normal passive needs from elapsed game time and applies the active spot's
value delta. For example, Work pauses passive boredom growth while hunger, sleep need, talk
need, and action tiredness continue; Sleep pauses sleep-need growth while its activity delta
recovers sleep need.

When the schedule closes, the activity's saved return scene and position are used. The
route system moves the off-screen record back through the authored return edges and spawns
the NPC if the destination scene is currently loaded.

## Diagnostics

`NpcWorldSimulation` runs a lightweight audit for every manifest at startup. It emits an
explicit warning for a missing or non-empty scene, missing/mismatched spot, unauthorized NPC,
or missing inbound or return route. It deliberately does not instantiate the large playable
maps during normal startup. The result remains available through:

- `NpcWorldSimulation.get_simulated_location_diagnostics()` for the static contract.
- `NpcWorldSimulation.audit_simulated_locations(true)` for the full development audit, which
  also loads each route source long enough to verify its matching live departure door.
- `NpcWorldSimulation.get_simulated_location_runtime_status()` for each NPC's current
  scene, activity, pending destination, and a `stranded` or `activity_scene_mismatch` state.
- `NpcSceneRoutes.get_diagnostic_events()` for individual route planning/execution reasons.

The runtime route and simulated-location tests exercise both authored locations. A broken
file path, permission, schedule contract, door edge, or round trip should therefore fail in
headless validation before it becomes a silent disappearing NPC in play.
