# Debug Troubleshooting Steps

Use these switches in `scripts/systems/debug_tools_config.gd` to bisect the loaded-save crash/freeze without deleting scene content.

## Current Default

- `TROUBLESHOOTING_MODE = true`
- `PERFORMANCE_WATCHDOG_ENABLED = true`
- `DEBUG_ENABLE_CRASH_BREADCRUMBS = true`
- `DEBUG_FORCE_BLOCKING_SCENE_LOADS = true`
- `DEBUG_DISABLE_SCENE_PRELOADS = true`
- `DEBUG_DISABLE_CHARACTER_STATS_OVERLAY = true`
- All feature kill-switches default to `false`.

Breadcrumbs are written to `user://crash_breadcrumbs.log` and also printed. Each line includes system time, current scene, WorldTime snapshot, source, and detail.

## Suggested Bisect Order

1. Reproduce once with only the default troubleshooting switches.
2. Set `DEBUG_DISABLE_NPC_LIVE_ACTIVITY_RESUME = true`.
   If the loaded save no longer freezes, the issue is likely activity restore or live state assignment.
3. Set `DEBUG_DISABLE_NPC_SCHEDULED_ACTIVITY_STARTS = true`.
   If this helps, check `npc_world:best_activity` and `npc_world:start_activity` breadcrumbs near the last lines.
4. Set `DEBUG_DISABLE_NPC_MEAL_CYCLE_RUNTIME = true`.
   If this helps, inspect `meal_cycle:*`, `work_spot:meal_state`, and `npc_world:meal_cycle_*`.
5. Set `DEBUG_DISABLE_EAT_STATE = true`, then `DEBUG_DISABLE_REST_STATE = true`.
   These isolate live state entry and per-frame state logic.
6. Set `DEBUG_DISABLE_TALK_SEARCH = true` to isolate autonomous conversation starts.
   These isolate NPC talk target scanning and social travel.
7. Set `DEBUG_DISABLE_PASSIVE_NEEDS = true`, then `DEBUG_DISABLE_VALUE_REACTIONS = true`.
   These isolate hunger/tired/talk/boredom growth and automatic state requests.
8. Use the realtest1-specific switches:
   - `DEBUG_DISABLE_REALTEST1_TALK_PARTNER = true`
   - `DEBUG_DISABLE_REALTEST1_MOM_NPC = true`
9. Use `DEBUG_DISABLE_MOM_MEAL_SPOT = true` or
   `DEBUG_DISABLE_MOM_WORK_SPOT = true` to isolate either authored spot regardless
   of which scene currently contains it.

## Reading the Breadcrumbs

- Last line before a hard crash/freeze is the first suspect.
- Repeated `work_spot:eat_accept` after `work_spot:meal_sated` points to meal owner state not sticking.
- Repeated `npc_world:resume_live_*` points to loaded-save restore or scene activation.
- Repeated `npc_state:value_cross_up/down` followed by state requests points to need/value reaction churn.
- Repeated `scene_loader:*` ending before `change_file_after` or `change_packed_after` points to scene loading.

After the culprit is narrowed down, turn the successful kill-switch back to `false` and keep bisecting with the next narrower switch.
