class_name DebugToolsConfig extends RefCounted

# Heavy debug tracker: FPS panel, spike logging, scene/change scanning.
const PERFORMANCE_WATCHDOG_ENABLED := false

# Light in-game HUD: clock, HP, and fading event text.
const CLOCK_HP_EVENTS_HUD_ENABLED := true

# Separate switch for the in-scene stats overlay.
const CHARACTER_STATS_OVERLAY_ENABLED := true

# Master troubleshooting mode. When false, all debug kill-switches behave normally.
const TROUBLESHOOTING_MODE := false

# Scene loading
const DEBUG_FORCE_BLOCKING_SCENE_LOADS := false
const DEBUG_DISABLE_SCENE_PRELOADS := false

# UI/debug
const DEBUG_DISABLE_CHARACTER_STATS_OVERLAY := false
const DEBUG_ENABLE_CRASH_BREADCRUMBS := false
const DEBUG_ENABLE_VERBOSE_NPC_LOGS := false

# NPC world systems
const DEBUG_DISABLE_NPC_LOCATION_SCENE_REGISTRATION := false
const DEBUG_DISABLE_NPC_WORLD_SIMULATION_TICK := false
const DEBUG_DISABLE_NPC_LIVE_ACTIVITY_RESUME := false
const DEBUG_DISABLE_NPC_SCHEDULED_ACTIVITY_STARTS := false
const DEBUG_DISABLE_NPC_MEAL_CYCLE_RUNTIME := false
const DEBUG_DISABLE_NPC_SCENE_ROUTES := false
const DEBUG_ENABLE_NPC_SCENE_ROUTE_LOGS := false
const DEBUG_DISABLE_NPC_MOVE_STUCK_WATCHDOG := false

# NPC state/value systems
const DEBUG_DISABLE_PASSIVE_NEEDS := false
const DEBUG_DISABLE_VALUE_REACTIONS := false
const DEBUG_DISABLE_EAT_STATE := false
const DEBUG_DISABLE_REST_STATE := false
const DEBUG_DISABLE_TALK_SEARCH := false
const DEBUG_DISABLE_MAGIC_LESSON_ACTIVITY := false

# realtest1-specific suspects
const DEBUG_DISABLE_REALTEST1_MEAL_SPOT := false
const DEBUG_DISABLE_REALTEST1_WORK_SPOT := false
const DEBUG_DISABLE_REALTEST1_TALK_PARTNER := false
const DEBUG_DISABLE_REALTEST1_MOM_NPC := false
