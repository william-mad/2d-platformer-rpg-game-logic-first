# NPC companion travel

The first playable companion is `MomNpc` (`mom`). Its `TravelCompanion` child only declares eligibility, minimum favor, and the `default_companion` policy; the existing social NPC remains the authority for needs, relationships, inventory, health, combat, and persistent location.

## Ownership and lifecycle

`PlayerRuntime` owns the serializable, single-companion travel session. `GameSaveSystem` stores that session beside the existing world systems, and missing travel data in an older save resolves to an inactive session. `NpcLocations` remains the only NPC record repository. Before a player scene change, the active companion record is captured and assigned to the destination scene. The destination `NpcLocationScene` reconstructs the accepted instance, and `PlayerRuntime` places it at `companion_spawn` (or a safe player offset) and resumes `TravelFollow`. Live node references and breadcrumbs are never saved.

Ordinary `NpcWorldSimulation` passes skip the active companion ID, preventing a simultaneous off-screen copy. Duplicate scene-authored instances continue to be rejected by `NpcLocations`.

## Following and combat

The player's `BreadcrumbRecorder` publishes ordinary samples only while grounded. Leaving the floor opens an internal pending traversal without adding airborne positions; landing publishes one durable, sequenced jump/drop segment containing takeoff, landing, initial velocity, direction, duration, and peak height. `TravelFollow` consumes completed segments in order, approaches their recorded takeoff with tolerances, and retains the landing target until the transition succeeds. Ordinary grounded following uses the newest sample, distance-scaled speed, and braking distance.

Existing `Fight`, `Downed`, and `DisabledDead` states remain authoritative. An active fight interrupts following through the normal state machine. Requests to return to `Idle` are redirected to `TravelFollow` while the session remains active; ordinary work, recreation, routine, sleep, and autonomous social-seeking states are rejected. Ending travel restores normal state selection.

Platform transitions remain subordinate to breadcrumbs. A cached `NpcPlatformTransitionProbe` samples the leading and far floor, feet/torso/head obstacles, upward clearance, and a proposed landing. When a transition is needed, it tests exactly three ballistic candidates with 8–12 collision-shape samples. Accepted plans remain committed until landing, blocking collision, combat interruption, or timeout. There is no nested route planning: after a failed jump Mom abandons that completed traversal, optionally walks once to a nearby safe point at the same height, and resumes ordinary following. Target-position suppression prevents the same failed jump from looping until the player establishes a meaningfully different target or completes a new traversal. Probe distances, landing tolerances, reposition bounds, arc samples, jump limits, and recalculation thresholds are exported by `TravelFollow`.

## Travel policy, needs, and food

`default_companion.tres` applies sleep growth at `0.35`, hunger at `1.0`, social-need growth at `0.0`, relationship progression at `0.0`, disables social planning, and keeps combat and inventory eating enabled. Multipliers are applied at the live state-machine need tick and by `NpcNeedsSimulator` for a return skip; frozen social values are not advanced and rolled back later. Relationship fear/anger decay is also paused for the active companion. Existing `Eat` behavior continues to use authoritative inventory reservations. A return skip uses the existing food service deterministically if hunger reaches the normal eating threshold.

## Return presets and village simulation

The existing `level_1` route contains one `TravelReturnPoint`. It offers Return now plus the next occurrences of 07:00, 13:00, 18:00, and 22:00, displays elapsed hours, and requires the selected option twice to confirm. On confirmation, `NpcWorldSimulation.simulate_companion_return_skip` advances ordinary NPC needs and schedule selection without invoking the social planner or relationship decay. The companion receives exactly one travel-policy need pass and is excluded from the ordinary pass. `WorldTime` is set once, the village is loaded through the existing scene loader, the same record is restored near the player, and the session is cleared.

Stopping outside the origin village is rejected so a companion cannot be abandoned in an invalid persistent location.
