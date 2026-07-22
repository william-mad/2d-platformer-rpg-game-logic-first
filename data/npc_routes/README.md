# NPC scene routes

Scene routes are directed `NpcSceneRouteEdge` resources collected by a
`NpcSceneRouteMap`. The same edge resource must be assigned to the matching
`NpcTravelDoor`; this keeps planning, permissions, callback identity, and the
target arrival position in one place.

To add a route:

1. Create one edge resource per travel direction under `edges/`.
2. Give every edge a stable, unique `edge_id`, source and target scenes, and a
   finite arrival position in the target scene.
3. Add the edge to `household_routes.tres` (or another configured route map).
4. Assign that exact resource to the source scene's `NpcTravelDoor.route_edge`.
5. Rebuild the graph after changing resources at runtime.

Keep `map_id` and edge IDs free of leading/trailing whitespace. Bump the map's
`schema_version` when an authored change should invalidate persisted routes;
ordinary runtime rebuilds do not invalidate otherwise valid saved travel.

An empty edge allow-list permits any NPC; `blocked_npc_ids` always wins. Private
doors should use an explicit allow-list as the Mom bedroom route does. An empty
NPC identity is always denied. For a route-wired door, the edge is the sole NPC
authorization source so loaded movement and offscreen simulation cannot apply
different rules. The door's owner/legacy NPC gates still apply to non-route
doors (and owner IDs still gate player use).

## Debugging and kill switches

- `NpcSceneRoutes.get_debug_snapshot()` reports graph, cache, and validation state.
- `NpcSceneRoutes.get_diagnostic_events()` returns the bounded recent event log.
- Invalid authored graphs fail closed and produce one warning when rebuilt.
- `NpcSceneRoutes.set_enabled(false, "reason")` immediately rejects routed plans
  and hop execution; direct legacy doors keep working.
- `DebugToolsConfig.DEBUG_DISABLE_NPC_SCENE_ROUTES` is the startup kill switch
  when troubleshooting mode is enabled.
- `DebugToolsConfig.DEBUG_ENABLE_NPC_SCENE_ROUTE_LOGS` prints route diagnostics
  only when troubleshooting mode is enabled.

Pending travel keeps its final destination in the existing top-level fields.
Route-only progress lives under `pending_travel.scene_route`, making saves easy
to inspect without changing older direct-travel readers.

Fresh offscreen activity starts and ordinary cross-scene returns use the same
graph, permissions, and kill switch as loaded NPC movement. Offscreen routes
fast-forward while all remaining scenes are unloaded. If the next intermediate
or final scene is loaded, only that hop is committed and the NPC arrives at the
edge's explicit position so the rest of the route stays visible and debuggable.
Route-wired direct doors are validated before a live NPC reserves a spot or
starts moving, so disabling routes does not leave a claim waiting at a blocked
door.

A physical no-progress watchdog keeps an exact finish route retryable and adds
`movement_retry_count` plus `last_movement_retry_reason` to pending travel.
Structural failures (disabled manager, invalid graph, or missing edge) discard
that route leg while preserving a committed activity so it can be replanned.
The record's `finish_route_replan` marker keeps that intent across saves and
active schedule windows; it is cleared when a replacement route or final return
is accepted. A marker and `pending_travel` are mutually exclusive. Offscreen
marker recovery validates the graph and permissions, then atomically converts
the marker into ordinary routed pending travel; failure leaves the activity,
marker, location, and claim unchanged for a later retry.

The manager has no frame callback. Searches use bounded breadth-first traversal,
a bounded cache, and fixed-size diagnostics, so route cost is paid only when an
NPC actually needs or advances a route.
