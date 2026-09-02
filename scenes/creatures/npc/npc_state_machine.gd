class_name NpcStateMachine extends Node

const NpcActivityIdentity = preload("res://scripts/systems/npc_activity_identity.gd")
const NpcActionSessionModel = preload("res://scripts/systems/npc_action_session.gd")
const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")
const SocialWriteRouter = preload(
	"res://scripts/systems/npc_social_write_router.gd"
)
const NpcBehaviorIntentModel = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_intent.gd"
)
const NpcBehaviorFeedbackFormatter = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_feedback_formatter.gd"
)
const NpcSocialMemoryPolicyModel = preload(
	"res://scripts/systems/npc_behavior/npc_social_memory_policy.gd"
)
const NpcSocialCandidateScorerModel = preload(
	"res://scripts/systems/npc_behavior/npc_social_candidate_scorer.gd"
)
const NpcSocialAcceptancePolicyModel = preload(
	"res://scripts/systems/npc_behavior/npc_social_acceptance_policy.gd"
)
const NpcSocialConfigurationValidator = preload(
	"res://scripts/systems/npc_behavior/npc_social_configuration_validator.gd"
)
const NpcTargetMemoryPolicyModel = preload(
	"res://scripts/systems/npc_behavior/npc_target_memory_policy.gd"
)
const NpcActivitySocialAffinityPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_activity_social_affinity_policy.gd"
)
const NpcPlayerInteractionMemoryPolicyModel = preload(
	"res://scripts/systems/npc_behavior/npc_player_interaction_memory_policy.gd"
)
signal state_changed(state_name: StringName, previous_state_name: StringName)
signal state_request_failed(state_name: StringName, reason: String)
signal target_changed(target: Node2D)
signal values_changed(changed_values: Dictionary, actor: Node2D)
signal values_replaced(values_snapshot: Dictionary, actor: Node2D)
signal player_interaction_invalidated(reason: String)
signal action_session_changed(descriptor: Dictionary)
signal policy_feedback_changed(
	policy_kind: StringName,
	descriptor: Dictionary
)
signal activity_target_selection_committed(descriptor: Dictionary)

const SOCIAL_FEEDBACK_VOLATILE_FIELDS := {
	"evaluated_game_hours": true,
	"evaluated_at_usec": true,
	"simulation_pass_id": true,
	"published_at_usec": true,
	"remaining_retry_hours": true,
}
const MAX_SOCIAL_CONFIGURATION_WARNING_KEYS := 2048

static var _emitted_social_configuration_warning_keys: Dictionary = {}

const VALUE_ALIASES := {
	"sleepiness": "sleep_need",
	"work_need": "boredom",
	"talk_interest": "talk_need",
}

const STORED_ONLY_VALUE_KEYS := {
	"curiosity": true,
	"sadness": true,
	"energy": true,
	"suspicion": true,
}
const DEPRECATED_GLOBAL_VALUE_KEYS := {
	"fear": true,
}

const STATE_ALIASES := {
	"ReactToPlayer": "ReactToEvent",
	"NoticeActor": "ReactToEvent",
	"routine_task": "RoutineTask",
	"Routine Task": "RoutineTask",
}

const PLAYER_INTERACTION_BLOCKED_STATE_REASONS := {
	"Fight": "npc_fighting",
	"Flee": "npc_fleeing",
	"Downed": "npc_downed",
	"DisabledDead": "npc_disabled",
	"Collapse": "npc_emergency",
	"ReactToEvent": "npc_emergency_reaction",
}

const SCRIPTED_CONTROL_EMERGENCY_STATES := {
	"Fight": true,
	"Flee": true,
	"Downed": true,
	"DisabledDead": true,
	"Collapse": true,
	"ReactToEvent": true,
}

const ACTIVE_TRAVEL_BLOCKED_STATES := {
	"Work": true,
	"Recreation": true,
	"RoutineTask": true,
	"LookForTalkTarget": true,
	"InvitePlayer": true,
	"Sleep": true,
	"Rest": true,
}

const MEMORY_FILTERED_LIVE_ACTIVITY_ACTIONS := {
	"Eat": true,
	"Rest": true,
	"Recreation": true,
	"Sleep": true,
	"Work": true,
}

enum MonsterSightReaction {
	NONE,
	FIGHT,
	FLEE,
	SCREAM,
}

@export_group("Setup")
@export var npc_path: NodePath
@export var initial_state_name: StringName = &"Idle"
@export var active: bool = true
@export var auto_move_and_slide: bool = true

@export_group("Movement")
@export var gravity: float = 1200.0
@export var walk_speed: float = 120.0
@export var run_speed: float = 161.0
@export var stop_distance: float = 12.0

@export_group("Movement Fatigue")
@export var fatigue_affects_movement: bool = true
@export_range(0.1, 1.0, 0.01) var minimum_fatigue_speed_multiplier: float = 0.6
@export_range(0.2, 4.0, 0.05) var fatigue_speed_curve: float = 1.4

@export_group("Default Durations")
@export var default_reaction_time: float = 0.6
# Work uses these as "time to clear a full work-needed spot."
@export var default_work_time: float = 3.0
@export_range(0.0, 24.0, 0.05, "suffix:h") var default_work_game_hours: float = 4.5
@export var default_eat_time: float = 2.0
@export_range(0.0, 1440.0, 1.0, "suffix:min") var default_eat_game_minutes: float = 60.0
@export var default_talk_time: float = 1.5
@export_range(0.0, 1440.0, 1.0, "suffix:min") var default_talk_game_minutes: float = 10.0
@export var default_look_for_talk_time: float = 4.0
@export var default_look_for_monster_time: float = 4.0
@export var default_flee_time: float = 4.0
@export var default_sleep_time: float = 4.0
@export_range(0.0, 24.0, 0.05, "suffix:h") var default_sleep_game_hours: float = 8.0
@export var default_collapse_time: float = 30.0

@export_group("Passive Needs")
@export var passive_needs_enabled: bool = true
@export_range(0.0, 100.0, 0.1, "suffix:/h") var sleep_need_growth_per_game_hour: float = 5.1
@export_range(0.0, 100.0, 0.1, "suffix:/h") var hunger_growth_per_game_hour: float = 7.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var boredom_growth_per_game_hour: float = 8.0
@export_range(0.0, 100.0, 0.1) var talk_need_growth_per_interval: float = 8.0
@export_range(0.1, 1440.0, 0.1, "suffix:min") var talk_need_growth_interval_game_minutes: float = 20.0
@export_range(1.0, 100.0, 0.1, "suffix:hp/day") var passive_healing_per_game_day: float = 10.0
@export_range(0.0, 100.0, 0.1, "suffix:hp/day") var starvation_damage_per_game_day: float = 5.0
@export var passive_needs_tick_seconds: float = 10.0
@export var stagger_passive_need_ticks: bool = true
@export var sleep_need_paused_states: Array[StringName] = [&"Sleep", &"Collapse"]
@export var hunger_paused_states: Array[StringName] = [&"Eat"]
@export var boredom_paused_states: Array[StringName] = [&"Work", &"Recreation", &"RoutineTask"]
@export var talk_need_paused_states: Array[StringName] = [&"Talk"]

@export_group("Action Fatigue")
@export var tired_enabled: bool = true
@export var tired_value_name: StringName = &"tired"
@export_range(0.0, 100.0, 0.1, "suffix:/h") var tired_growth_per_action_game_hour: float = 25.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var tired_growth_per_fight_game_hour: float = 60.0
@export_range(0.0, 200.0, 0.1, "suffix:/h") var tired_recovery_per_rest_game_hour: float = 100.0
@export var tired_inactive_states: Array[StringName] = [
	&"Idle",
	&"Sleep",
	&"Collapse",
	&"Downed",
	&"DisabledDead",
]

@export_group("Loneliness Recovery")
@export var loneliness_recovery_enabled: bool = true
@export_range(0.0, 100.0, 0.1) var loneliness_recovery_talk_need_below: float = 50.0
@export_range(0.1, 48.0, 0.1, "suffix:h") var loneliness_full_recovery_game_hours: float = 5.0
@export var loneliness_value_name: StringName = &"lonely"

@export_group("Social Seeking")
## Enables autonomous world-simulation social seeking. Candidate selection is
## intentionally limited to actors in the NPC's current scene.
@export var world_social_seeking_enabled: bool = true
@export_range(0.0, 100.0, 0.1) var cross_scene_talk_need_threshold: float = 70.0
@export_range(0, 100, 1) var cross_scene_talk_priority: int = 60
@export_range(0.0, 100.0, 0.1) var cross_scene_minimum_npc_favor: float = 10.0
@export var block_talk_search_while_moving_to_target: bool = true

@export_group("NPC Talk Handshake")
@export var npc_talk_requires_mutual_favor: bool = true
@export_range(0.0, 100.0, 0.1) var npc_talk_handshake_minimum_favor: float = 10.0
@export_range(0, 1000, 1) var npc_talk_handshake_priority: int = 70
@export var npc_talk_refuse_lower_priority_tasks: bool = true
@export_range(0.0, 120.0, 0.1, "suffix:s") var npc_talk_refusal_cooldown_seconds: float = 8.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var recent_refusal_retry_delay_game_hours: float = 0.25
@export_range(0.0, 24.0, 0.01, "suffix:h") var recent_harm_social_delay_game_hours: float = 0.5
@export_range(0.0, 24.0, 0.001, "suffix:h") var recent_conversation_repeat_delay_game_hours: float = 0.125
@export_range(0, 1000, 1) var npc_talk_moving_task_priority_bonus: int = 15
@export_range(0.0, 100.0, 0.1) var npc_social_acceptance_minimum_favor: float = 20.0
@export_range(0.0, 100.0, 0.1) var npc_social_acceptance_maximum_anger: float = 70.0
@export_range(0.0, 100.0, 0.1) var npc_social_acceptance_maximum_fear: float = 80.0

@export_group("Target Failure Memory")
@export_range(0.0, 24.0, 0.001, "suffix:h") var target_unavailable_retry_game_hours: float = 0.25
@export_range(0.0, 24.0, 0.001, "suffix:h") var movement_failed_retry_game_hours: float = 0.125
@export_range(0.0, 24.0, 0.001, "suffix:h") var intention_target_lost_retry_game_hours: float = 0.25

@export_group("Player Interaction")
@export_range(0.0, 30.0, 0.1, "suffix:s") var default_player_interaction_hold_seconds: float = 5.0
@export_range(0.0, 120.0, 0.1, "suffix:s") var default_player_interaction_cooldown_seconds: float = 20.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var recent_harm_interaction_delay_game_hours: float = 0.5
@export_range(0.0, 100.0, 0.1) var player_interaction_soft_refusal_minimum_favor: float = 40.0
@export_range(0.0, 100.0, 0.1) var player_interaction_repeat_bypass_minimum_favor: float = 70.0
@export_range(0.0, 100.0, 0.1) var player_interaction_all_refusal_bypass_above_favor: float = 95.0

@export_group("Relationship Fear Decay")
@export var fear_decay_enabled: bool = true
@export_range(0.0, 100.0, 0.1) var fear_panic_floor: float = 90.0
@export_range(0.0, 1440.0, 1.0, "suffix:min") var fear_panic_cooldown_game_minutes: float = 10.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var fear_slow_decay_per_game_hour: float = 5.0
@export_range(0.0, 10.0, 0.1) var fear_decay_stop_below_flee_threshold_by: float = 0.1

@export_group("Anger Decay")
@export var anger_decay_enabled: bool = true
@export var anger_decay_value_name: StringName = &"anger"
@export_range(0.1, 24.0, 0.1, "suffix:h") var anger_full_decay_game_hours: float = 4.0

@export_group("Optional Nodes")
@export var animation_controller_path: NodePath
@export var animation_player_path: NodePath
@export var sprite_path: NodePath
@export var debug_label_path: NodePath

@export_group("Feedback Presentation")
@export var player_feedback_enabled: bool = true
@export var developer_state_label_enabled: bool = true

@export_group("Values")
@export var clamp_percent_values: bool = true
@export var value_reactions_enabled: bool = true
@export var values: Dictionary = {
	"favor": 50.0,
	"love": 0.0,
	"trust": 50.0,
	"anger": 0.0,
	"hunger": 25.0,
	"energy": 100.0,
	"sleep_need": 0.0,
	"tired": 0.0,
	"boredom": 0.0,
	"bored": 0.0,
	"talk_need": 0.0,
	"lonely": 0.0,
	"sadness": 0.0,
	"suspicion": 0.0,
	"curiosity": 0.0,
	"hp": 100.0,
	"knockout": 0.0,
	"disabled": 0.0
}

# Rules are checked only when values change, when a target is seen, or when code asks for a state.
# Add new entries here to make a value drive a state without changing the state scripts.
@export var value_state_rules: Dictionary = {
	"dead_hp": {
		"value": "hp",
		"state": "DisabledDead",
		"at_most": 0.0,
		"priority": 100,
		"behavior_source": "emergency",
		"behavior_reason_code": "health_depleted",
		"behavior_feedback_text": "Health depleted",
		"behavior_origin_value": "hp",
	},
	"disabled": {
		"value": "disabled",
		"state": "DisabledDead",
		"truthy": true,
		"priority": 100,
		"behavior_source": "emergency",
		"behavior_reason_code": "disabled",
		"behavior_feedback_text": "Disabled",
		"behavior_origin_value": "disabled",
	},
	"knockout_downed": {
		"value": "knockout",
		"state": "Downed",
		"at_least": 100.0,
		"priority": 99,
		"behavior_source": "emergency",
		"behavior_reason_code": "knockout_high",
		"behavior_feedback_text": "Knocked down",
		"behavior_origin_value": "knockout",
	},
	"sleep_collapse": {
		"value": "sleep_need",
		"state": "Collapse",
		"at_least": 100.0,
		"priority": 95,
		"behavior_source": "emergency",
		"behavior_reason_code": "sleep_need_critical",
		"behavior_feedback_text": "Collapsing from exhaustion",
		"behavior_origin_value": "sleep_need",
	},
	"tired_rest": {
		"value": "tired",
		"state": "Rest",
		"at_least": 50.0,
		"requires_idle": true,
		"priority": 15,
		"behavior_source": "need",
		"behavior_reason_code": "tired_high",
		"behavior_feedback_text": "Tired",
		"behavior_origin_value": "tired",
	},
	"hungry": {
		"value": "hunger",
		"state": "Eat",
		"at_least": 75.0,
		"requires_idle": true,
		"requires_need_spot": true,
		"priority": 50,
		"behavior_source": "need",
		"behavior_reason_code": "hunger_high",
		"behavior_feedback_text": "Hungry",
		"behavior_origin_value": "hunger",
	},
	"casual_recreation": {
		"value": "boredom",
		"state": "Recreation",
		"at_least": 50.0,
		"requires_idle": true,
		"requires_casual_spot": true,
		"priority": 10,
		"behavior_source": "need",
		"behavior_reason_code": "boredom_high",
		"behavior_feedback_text": "Looking for recreation",
		"behavior_origin_value": "boredom",
	},
	"talk_to_seen_target": {
		"value": "talk_need",
		"state": "Talk",
		"at_least": 50.0,
		"requires_target": true,
		"target_groups": [&"npc", &"player"],
		"min_relationship_favor": 10.0,
		"priority": 60,
		"behavior_source": "social_ai",
		"behavior_reason_code": "social_need_high",
		"behavior_feedback_text": "Wants to talk",
		"behavior_origin_value": "talk_need",
	},
	"talk_search_for_people": {
		"value": "talk_need",
		"state": "LookForTalkTarget",
		"at_least": 70.0,
		"requires_idle": true,
		"priority": 60,
		"behavior_source": "social_ai",
		"behavior_reason_code": "social_need_high",
		"behavior_feedback_text": "Looking for someone to talk to",
		"behavior_origin_value": "talk_need",
	},
	"favor_dropped": {
		"value": "favor",
		"state": "ReactToEvent",
		"delta_at_most": -1.0,
		"priority": 35,
		"behavior_source": "event_reaction",
		"behavior_reason_code": "favor_dropped",
		"behavior_feedback_text": "Reacting to lost favor",
		"behavior_origin_value": "favor",
	}
}

# Extra value changes that happen when a need crosses a hard threshold.
# Example: reaching talk_need 100 can also add lonely +1.
@export var value_threshold_effects: Dictionary = {
	"talk_need_lonely_cap": {
		"value": "talk_need",
		"at_least": 100.0,
		"delta": {
			"talk_need": -40.0,
			"lonely": 1.0
		}
	},
	"boredom_bored_cap": {
		"value": "boredom",
		"at_least": 100.0,
		"delta": {
			"bored": 1.0
		}
	}
}

@export_group("Player Sight")
# Legacy export name kept for old scenes. Leave false for needs-driven NPCs.
@export var react_to_player_on_seen: bool = false
@export var player_seen_state_name: StringName = &"ReactToEvent"
@export var flee_from_seen_player_when_afraid: bool = true
@export var seen_player_flee_state_name: StringName = &"Flee"
@export var seen_player_flee_priority: int = 90

@export_group("Monster Sight")
@export var react_to_seen_monsters: bool = true
@export var monster_target_groups: Array[StringName] = [&"monster", &"monsters", &"enemy", &"enemies"]
@export var seen_monster_reaction: MonsterSightReaction = MonsterSightReaction.FIGHT
@export_range(0, 1000, 1) var seen_monster_reaction_priority: int = 94
@export var seen_monster_fight_state_name: StringName = &"Fight"
@export var seen_monster_flee_state_name: StringName = &"Flee"
@export var seen_monster_scream_state_name: StringName = &""
@export var look_for_monster_after_fight: bool = true
@export var look_for_monster_state_name: StringName = &"LookForMonster"

var npc: CharacterBody2D
var states: Array[NpcState] = []
var state_history: Array[NpcState] = []
# Perception and reaction context are deliberately separate from intentional actions.
var perceived_targets: Array[Node2D] = []
var selected_threat: Node2D
var last_event_actor: Node2D
# Deprecated compatibility mirrors. active_action remains authoritative; old scenes and
# callers may still populate/read these while migrating to the session getters below.
var target: Node2D
var move_target: Node2D
var work_target: Node2D
var eat_target: Node2D
var rest_target: Node2D
var recreation_target: Node2D
var routine_task_target: Node2D
var sleep_target: Node2D
var talk_target: Node2D
var invitation_spot: Node2D
var state_after_move: StringName = &"Idle"
var state_after_move_priority: int = 0
var last_actor: Node2D
var last_changed_values: Dictionary = {}
var idle_value_reaction_queued: bool = false
var suppress_next_idle_value_reaction_check: bool = false
var passive_need_elapsed_seconds: float = 0.0
var current_state_priority: int = 0
var previous_state_priority: int = 0
var interaction_overlay_priority: int = 0
var pending_state_priority: int = -1
var last_state_request_failure_reason: String = ""
var pending_player_talk_payout_session_id: String = ""
var prepaid_talk_session_id: String = ""
var talk_refusal_cooldowns: Dictionary = {}
var player_interaction_hold_timer: float = 0.0
var player_interaction_hold_actor: Node2D
var player_interaction_cooldown_timer: float = 0.0
var player_interaction_cooldown_actor: Node2D
var passive_need_skip_logged: bool = false
var scripted_control_claim_token: int = 0
var scripted_control_owner: WeakRef
var scripted_control_reason: StringName = &""
var scripted_control_allows_emergencies: bool = false
var _scripted_hold_animation: StringName = &"idle"
var _scripted_facing_target: WeakRef
var _logged_scripted_control_stale_commands: Dictionary = {}
var _logged_scripted_control_autonomous_rejections: Dictionary = {}

var primary_state: NpcState:
	get:
		if state_history.is_empty():
			return null
		return state_history.front()


# Compatibility alias: current_state now always means the authoritative primary lane.
# Use is_in_state(&"Talk") or interaction_overlay for effective interaction checks.
var current_state: NpcState:
	get:
		return primary_state


var interaction_overlay: NpcState
var active_action: NpcActionSession
var _proposed_action: NpcActionSession
var active_interaction_session: NpcActionSession
var last_terminal_action_session_id: String = ""
var _action_state_reconciliation_requested: bool = false
var _action_state_reconciliation_force_reentry: bool = false
var _pending_stale_state_reconciliation: Dictionary = {}
var _logged_stale_state_reconciliations: Dictionary = {}
var _legacy_behavior_request_counts: Dictionary = {}
var _logged_legacy_behavior_requests: Dictionary = {}
var _last_activity_target_selection_commit_key: String = ""


var previous_state: NpcState:
	get:
		if state_history.size() < 2:
			return null
		return state_history[1]

var _state_lookup: Dictionary = {}
var _pending_primary_state: NpcState
var _animation_controller: Node
var _animation_player: AnimationPlayer
var _sprite_2d: Sprite2D
var _debug_label: Label
var behavior_controller: NpcBehaviorController
var short_term_memory: NpcShortTermMemory
var memory_observer: NpcMemoryObserver
var memory_runtime_binding: NpcMemoryRuntimeBinding
var feedback_presenter: Node
var feedback_adapter: Node
var _behavior_action_replacement_in_progress: bool = false
var _social_memory_policy := NpcSocialMemoryPolicyModel.new()
var _social_candidate_scorer := NpcSocialCandidateScorerModel.new()
var _social_acceptance_policy := NpcSocialAcceptancePolicyModel.new()
var _target_memory_policy := NpcTargetMemoryPolicyModel.new()
var _player_interaction_memory_policy := (
	NpcPlayerInteractionMemoryPolicyModel.new()
)
var _social_selection_feedback: Dictionary = {}
var _social_scoring_descriptor: Dictionary = {}
var _last_social_acceptance_descriptor: Dictionary = {}
var _target_selection_feedback: Dictionary = {}
var _last_player_interaction_memory_policy: Dictionary = {}
var _social_configuration_validation_issues: Array[Dictionary] = []


func _set(property: StringName, value: Variant) -> bool:
	# Compatibility for scenes saved before the inspector setting was renamed.
	if property == &"cross_scene_talk_enabled":
		world_social_seeking_enabled = bool(value)
		return true
	return false


func _get(property: StringName) -> Variant:
	if property == &"cross_scene_talk_enabled":
		return world_social_seeking_enabled
	return null


func _ready() -> void:
	_normalize_values_in_place(values)
	_stagger_passive_need_tick()

	if npc == null:
		_resolve_npc()

	_cache_optional_nodes()
	_cache_behavior_controller()
	_cache_memory_components()
	_cache_feedback_components()
	initialize_states()
	_bind_npc_control_claim_notifications()
	call_deferred("refresh_social_configuration_validation")

	if active and current_state == null:
		request_state(initial_state_name, null, "initial")


func refresh_social_configuration_validation() -> Array[Dictionary]:
	_social_configuration_validation_issues = (
		NpcSocialConfigurationValidator.validate_state_machine_configuration(
			self,
			"",
			"npc.%s.social" % _get_npc_label()
		)
	)
	if npc != null and is_instance_valid(npc):
		_social_configuration_validation_issues.append_array(
			NpcSocialConfigurationValidator.validate_actor_id(
				NpcIdentity.get_stable_actor_id(npc),
				"npc.%s.actor_id" % _get_npc_label()
			)
		)
	if OS.is_debug_build():
		for issue in _social_configuration_validation_issues:
			var issue_key := _get_social_configuration_warning_key(
				issue,
				not _npc_has_authored_scene_origin()
			)
			if _emitted_social_configuration_warning_keys.has(issue_key):
				continue
			_emitted_social_configuration_warning_keys[issue_key] = true
			while (
				_emitted_social_configuration_warning_keys.size()
					> MAX_SOCIAL_CONFIGURATION_WARNING_KEYS
			):
				_emitted_social_configuration_warning_keys.erase(
					_emitted_social_configuration_warning_keys.keys()[0]
				)
			push_warning("NPC social configuration [%s] %s: %s" % [
				String(issue.get("code", "invalid_configuration")),
				String(issue.get("path", "social")),
				String(issue.get("message", "Invalid social configuration.")),
			])
	return get_social_configuration_validation_issues()


func get_social_configuration_validation_issues() -> Array[Dictionary]:
	return _social_configuration_validation_issues.duplicate(true)


static func _get_social_configuration_warning_key(
	issue: Dictionary,
	normalize_transient_actor_path: bool = false
) -> String:
	var code := String(issue.get("code", "invalid_configuration"))
	var issue_path := String(issue.get("path", "social"))
	if code == "missing_stable_actor_id" and normalize_transient_actor_path:
		# Identity-free legacy/test actors can be numerous and often have generated
		# node names. One global warning preserves visibility without one warning per
		# transient actor; every machine still retains its own structured issue.
		issue_path = "npc.*.actor_id"
	return JSON.stringify([
		String(issue.get("severity", "warning")),
		code,
		issue_path,
		String(issue.get("message", "Invalid social configuration.")),
	])


func _npc_has_authored_scene_origin() -> bool:
	if npc == null or not is_instance_valid(npc):
		return false
	return not String(npc.scene_file_path).is_empty() or npc.owner != null


func _exit_tree() -> void:
	if interaction_overlay != null:
		_cancel_interaction_overlay("scene_exit")


func _physics_process(delta: float) -> void:
	if not active or npc == null or current_state == null:
		return

	var velocity_after_gravity := npc.velocity
	_update_player_interaction_timers(delta)
	_update_talk_refusal_cooldowns(delta)
	if _reconcile_requested_active_action_state():
		_update_passive_needs(delta)
		if auto_move_and_slide:
			_move_npc_with_rope(delta, velocity_after_gravity)
		return
	if _reconcile_current_state_action_session_if_needed():
		_update_passive_needs(delta)
		if auto_move_and_slide:
			_move_npc_with_rope(delta, velocity_after_gravity)
		return
	apply_gravity(delta)
	velocity_after_gravity = npc.velocity
	if _process_npc_damage_hop(delta):
		_update_passive_needs(delta)
		if auto_move_and_slide:
			_move_npc_with_rope(delta, velocity_after_gravity)
		return

	if _player_interaction_hold_is_active():
		var hold_gate := can_begin_player_interaction(player_interaction_hold_actor)
		if bool(hold_gate.get("accepted", false)):
			_process_player_interaction_hold()
			_update_passive_needs(delta)
			if auto_move_and_slide:
				_move_npc_with_rope(delta, velocity_after_gravity)
			return
		_invalidate_player_interaction_hold(String(hold_gate.get("reason", "interaction_unavailable")))

	if interaction_overlay != null:
		_process_interaction_overlay(delta)
		_update_passive_needs(delta)
		if auto_move_and_slide:
			_move_npc_with_rope(delta, velocity_after_gravity)
		return

	# Only the primary state runs per-frame behavior; value-rule decisions stay event-driven.
	var state_at_start := current_state
	var requested_state := state_at_start.physics_process(delta)

	if requested_state != null and state_at_start == current_state:
		if _has_scripted_control_claim():
			_handle_scripted_control_state_return(state_at_start, requested_state)
		elif _pending_stale_reconciliation_matches(state_at_start, requested_state):
			_commit_stale_state_reconciliation(state_at_start, requested_state)
		else:
			change_state(requested_state, "state_tick")

	_update_passive_needs(delta)

	if auto_move_and_slide:
		_move_npc_with_rope(delta, velocity_after_gravity)


func _move_npc_with_rope(
	delta: float,
	velocity_after_gravity: Vector2
) -> void:
	npc.velocity = Rope.finalize_attached_body_velocity(
		npc,
		npc.velocity,
		velocity_after_gravity,
		delta
	)
	npc.move_and_slide()


func _process_interaction_overlay(delta: float) -> void:
	# The primary remains entered while Talk owns the interaction lane. Compatible
	# activities receive only their documented overlay-safe update, never physics_process().
	var overlay_at_start := interaction_overlay
	var primary_at_start := current_state
	if overlay_at_start == null or primary_at_start == null:
		return

	var primary_result = primary_at_start.process_talk_overlay(delta)
	if interaction_overlay != overlay_at_start:
		return
	if primary_at_start == current_state and typeof(primary_result) != TYPE_NIL:
		var requested_primary_name := StringName(String(primary_result))
		if requested_primary_name != &"" and requested_primary_name != StringName(primary_at_start.name):
			var requested_primary := get_state(requested_primary_name)
			if requested_primary == null:
				_cancel_interaction_overlay("missing_overlay_primary_%s" % String(requested_primary_name))
				return
			change_state(requested_primary, "talk_overlay_primary_tick", current_state_priority)

	if interaction_overlay != overlay_at_start:
		return
	var overlay_result := overlay_at_start.physics_process(delta)
	if interaction_overlay != overlay_at_start or overlay_result == null:
		return

	if bool(_get_property_if_present(overlay_at_start, &"talk_completed_successfully", false)):
		_complete_interaction_overlay("completed", true)
	else:
		_remove_interaction_overlay("cancelled")


func _process_npc_damage_hop(delta: float) -> bool:
	if npc == null or not npc.has_method("process_damage_hop"):
		return false

	return bool(npc.call("process_damage_hop", delta))


func bind_npc(bound_npc: CharacterBody2D) -> void:
	npc = bound_npc
	_cache_optional_nodes()
	_cache_behavior_controller()
	_cache_memory_components()
	_cache_feedback_components()

	for state in states:
		state.npc = npc
		state.machine = self


func initialize_states() -> void:
	states = []
	_state_lookup = {}

	# This mirrors the player setup: each child node is one reusable state.
	for child in get_children():
		var state := child as NpcState
		if state == null:
			continue

		states.append(state)
		_state_lookup[String(state.name)] = state
		state.npc = npc
		state.machine = self

	for state in states:
		state.init()

	if states.is_empty():
		set_physics_process(false)


func get_state(state_name: StringName) -> NpcState:
	var key := _canonical_state_key(state_name)
	return _state_lookup.get(key, null) as NpcState


func get_platform_traversal() -> NpcPlatformTraversal:
	if npc == null or not is_instance_valid(npc):
		return null
	return npc.get_node_or_null("NpcPlatformTraversal") as NpcPlatformTraversal


func request_scripted_state(
	claim_token: int,
	state_name: StringName,
	target_node: Node = null,
	arrival_state: StringName = &"ScriptedHold",
	reason: StringName = &"scripted_event"
) -> bool:
	if not _scripted_control_claim_token_is_current(claim_token):
		_warn_stale_scripted_control_command(&"request_scripted_state", claim_token)
		return false
	if state_name == &"":
		return _reject_state_request(state_name, "empty_scripted_state")

	var requested_state_name := state_name
	if requested_state_name == &"Idle":
		requested_state_name = &"ScriptedHold"
	if requested_state_name == &"ScriptedHold":
		return _reconcile_to_scripted_hold("scripted_event_hold")

	var target_2d := target_node as Node2D
	if target_node != null and (target_2d == null or not is_instance_valid(target_2d)):
		return _reject_state_request(requested_state_name, "invalid_scripted_target")
	if requested_state_name == &"MoveToTarget" and target_2d == null:
		return _reject_state_request(requested_state_name, "missing_scripted_move_target")

	var scripted_arrival := arrival_state
	if scripted_arrival in [&"", &"Idle", &"MoveToTarget"]:
		scripted_arrival = &"ScriptedHold"
	var destination_action_kind := requested_state_name
	if requested_state_name == &"MoveToTarget" and scripted_arrival != &"ScriptedHold":
		destination_action_kind = scripted_arrival
	return _request_state_direct(
		requested_state_name,
		target_2d,
		String(reason),
		maxi(current_state_priority, 1000),
		{
			"request_source": &"scripted_event",
			"scripted_claim_token": claim_token,
			"destination_action_kind": destination_action_kind,
			"arrival_state": scripted_arrival,
		}
	)


func set_scripted_hold_animation(claim_token: int, animation_name: StringName) -> bool:
	if not _scripted_control_claim_token_is_current(claim_token):
		_warn_stale_scripted_control_command(&"set_scripted_hold_animation", claim_token)
		return false
	_scripted_hold_animation = animation_name
	if _current_state_is(&"ScriptedHold") and animation_name != &"":
		play_animation(animation_name)
	return true


func set_scripted_facing_target(claim_token: int, target_node: Node) -> bool:
	if not _scripted_control_claim_token_is_current(claim_token):
		_warn_stale_scripted_control_command(&"set_scripted_facing_target", claim_token)
		return false
	if target_node != null and not is_instance_valid(target_node):
		return false
	_scripted_facing_target = weakref(target_node) if target_node != null else null
	return true


func get_scripted_hold_animation() -> StringName:
	return _scripted_hold_animation


func get_scripted_facing_target() -> Node:
	if _scripted_facing_target == null:
		return null
	return _scripted_facing_target.get_ref() as Node


func _bind_npc_control_claim_notifications() -> void:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_signal(&"npc_control_claim_changed"):
		return
	var callback := Callable(self, "_on_npc_control_claim_changed")
	if not gameplay_flow.is_connected(&"npc_control_claim_changed", callback):
		gameplay_flow.connect(&"npc_control_claim_changed", callback)
	if npc != null and gameplay_flow.has_method("is_npc_control_claimed"):
		if bool(gameplay_flow.call("is_npc_control_claimed", npc)):
			var claim: Dictionary = gameplay_flow.call("get_npc_control_claim", npc)
			_apply_scripted_control_claim(claim)


func _on_npc_control_claim_changed(claimed_npc: Node, claimed: bool, token_id: int) -> void:
	if claimed_npc != npc:
		return
	if claimed:
		var gameplay_flow := get_node_or_null("/root/GameplayFlow")
		if gameplay_flow == null or not gameplay_flow.has_method("get_npc_control_claim"):
			return
		var claim: Dictionary = gameplay_flow.call("get_npc_control_claim", npc)
		if int(claim.get("token_id", 0)) != token_id:
			return
		_apply_scripted_control_claim(claim)
		return
	_release_scripted_control_claim(token_id)


func _apply_scripted_control_claim(claim: Dictionary) -> void:
	if npc == null or claim.is_empty():
		return
	var npc_ref := claim.get("npc") as WeakRef
	if npc_ref == null or npc_ref.get_ref() != npc:
		return
	var token_id := int(claim.get("token_id", 0))
	if token_id == 0:
		return

	scripted_control_claim_token = token_id
	scripted_control_owner = claim.get("owner") as WeakRef
	scripted_control_reason = StringName(claim.get("reason", &""))
	scripted_control_allows_emergencies = bool(
		claim.get("allow_emergency_interrupts", false)
	)
	_scripted_hold_animation = &"idle"
	_scripted_facing_target = null
	_logged_scripted_control_stale_commands.clear()
	_logged_scripted_control_autonomous_rejections.clear()

	if _player_interaction_hold_is_active():
		_invalidate_player_interaction_hold("scripted_control_claimed")
	if interaction_overlay != null:
		_cancel_interaction_overlay("scripted_control_claimed")
	_cancel_and_clear_active_action("scripted_control_claimed")
	_proposed_action = null
	_action_state_reconciliation_requested = false
	_action_state_reconciliation_force_reentry = false
	_pending_stale_state_reconciliation.clear()
	_reconcile_to_scripted_hold("scripted_control_claimed", false)


func _release_scripted_control_claim(token_id: int) -> void:
	if token_id == 0 or token_id != scripted_control_claim_token:
		_warn_stale_scripted_control_command(&"release_notification", token_id)
		return

	if interaction_overlay != null:
		_cancel_interaction_overlay("scripted_control_released")
	_cancel_and_clear_active_action("scripted_control_released")
	_proposed_action = null
	_action_state_reconciliation_requested = false
	_action_state_reconciliation_force_reentry = false
	_pending_stale_state_reconciliation.clear()

	scripted_control_claim_token = 0
	scripted_control_owner = null
	scripted_control_reason = &""
	scripted_control_allows_emergencies = false
	_scripted_hold_animation = &"idle"
	_scripted_facing_target = null
	_logged_scripted_control_stale_commands.clear()
	_logged_scripted_control_autonomous_rejections.clear()

	var idle_state := get_state(&"Idle")
	if idle_state != null:
		_commit_state_change(idle_state, "scripted_control_released", 1000)
	_queue_idle_value_reaction_check()


func _cancel_and_clear_active_action(reason: String) -> void:
	if active_action == null:
		return
	var session_id := active_action.session_id
	if active_action.status not in [
		NpcActionSession.Status.COMPLETED,
		NpcActionSession.Status.FAILED,
	]:
		cancel_active_action(
			session_id,
			reason,
			_classify_neutral_action_cancellation(StringName(reason))
		)
	if (
		active_action != null
		and active_action.session_id == session_id
		and active_action.status in [
			NpcActionSession.Status.COMPLETED,
			NpcActionSession.Status.FAILED,
		]
	):
		clear_terminal_action(session_id)


func cancel_and_clear_active_action_for_override(reason: String) -> bool:
	# External gameplay contexts use this once when taking ownership from an
	# ordinary activity. Cancellation is authoritative for reservation release.
	_cancel_and_clear_active_action(reason)
	_proposed_action = null
	_action_state_reconciliation_requested = false
	_action_state_reconciliation_force_reentry = false
	_pending_stale_state_reconciliation.clear()
	return active_action == null


func _reconcile_to_scripted_hold(reason: String, cancel_action: bool = true) -> bool:
	if not _has_scripted_control_claim():
		return false
	if cancel_action:
		_cancel_and_clear_active_action(reason)
	var hold_state := get_state(&"ScriptedHold")
	if hold_state == null:
		return _reject_state_request(&"ScriptedHold", "missing_scripted_hold")
	if current_state == hold_state:
		if npc != null:
			npc.velocity.x = 0.0
		return true
	_action_state_reconciliation_requested = false
	_action_state_reconciliation_force_reentry = false
	_pending_stale_state_reconciliation.clear()
	return _commit_state_change(hold_state, reason, 1000)


func _handle_scripted_control_state_return(
	state_at_start: NpcState,
	requested_state: NpcState
) -> void:
	if state_at_start == null or requested_state == null or state_at_start != current_state:
		return
	var requested_name := StringName(requested_state.name)
	if requested_name == &"ScriptedHold":
		_reconcile_to_scripted_hold("scripted_event_arrived")
		return
	if (
		scripted_control_allows_emergencies
		and _is_scripted_control_emergency_state(requested_name)
	):
		_commit_state_change(requested_state, "scripted_control_emergency", current_state_priority)
		return
	if _is_current_scripted_action_arrival(requested_name):
		_commit_state_change(requested_state, "scripted_event_arrived", current_state_priority)
		return
	_reconcile_to_scripted_hold("scripted_control_state_return")


func _is_current_scripted_action_arrival(state_name: StringName) -> bool:
	if active_action == null or active_action.source != &"scripted_event":
		return false
	if int(active_action.metadata.get("scripted_claim_token", 0)) != scripted_control_claim_token:
		return false
	return active_action.arrival_state == state_name


func _has_scripted_control_claim() -> bool:
	return scripted_control_claim_token != 0


func has_scripted_control_claim() -> bool:
	return _has_scripted_control_claim()


func get_scheduled_activity_ownership_gate() -> Dictionary:
	var current_state_name := (
		StringName(current_state.name)
		if current_state != null
		else &""
	)
	var result := {
		"protected": false,
		"reason_code": &"available",
		"current_primary_state": current_state_name,
	}
	if _has_scripted_control_claim():
		result["protected"] = true
		result["reason_code"] = &"scripted_control"
		return result
	if interaction_overlay != null:
		result["protected"] = true
		result["reason_code"] = &"interaction_overlay"
		result["interaction_state"] = StringName(interaction_overlay.name)
		return result
	if current_state_name in [
		&"Fight",
		&"Flee",
		&"ReactToEvent",
		&"Collapse",
		&"Knockout",
		&"DisabledDead",
		&"Dead",
	]:
		result["protected"] = true
		result["reason_code"] = &"emergency_state"
		return result
	var intention_source := &""
	if behavior_controller != null and behavior_controller.current_intent != null:
		intention_source = behavior_controller.current_intent.source
	if intention_source in [&"emergency", &"scripted", &"scripted_event"]:
		result["protected"] = true
		result["reason_code"] = &"protected_intention"
		result["intention_source"] = intention_source
		return result
	if (
		active_action != null
		and active_action.source in [&"emergency", &"scripted", &"scripted_event"]
	):
		result["protected"] = true
		result["reason_code"] = &"protected_action"
		result["action_source"] = active_action.source
	return result


func _scripted_control_claim_token_is_current(claim_token: int) -> bool:
	if claim_token == 0 or claim_token != scripted_control_claim_token or npc == null:
		return false
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_method("get_npc_control_claim"):
		return false
	var claim: Dictionary = gameplay_flow.call("get_npc_control_claim", npc)
	if int(claim.get("token_id", 0)) != claim_token:
		return false
	var npc_ref := claim.get("npc") as WeakRef
	return npc_ref != null and npc_ref.get_ref() == npc


func _scripted_control_request_is_allowed(
	state_name: StringName,
	request_context: Dictionary
) -> bool:
	if not _has_scripted_control_claim():
		return true
	var claim_token := int(request_context.get("scripted_claim_token", 0))
	if (
		StringName(request_context.get("request_source", &"")) == &"scripted_event"
		and _scripted_control_claim_token_is_current(claim_token)
	):
		return true
	return (
		scripted_control_allows_emergencies
		and _is_scripted_control_emergency_state(state_name)
	)


func _is_scripted_control_emergency_state(state_name: StringName) -> bool:
	return SCRIPTED_CONTROL_EMERGENCY_STATES.has(String(state_name))


func _get_scripted_control_request_source(
	request_context: Dictionary,
	reason: String,
	state_name: StringName
) -> StringName:
	if request_context.has("request_source"):
		return StringName(request_context["request_source"])
	if _proposed_action != null:
		return _proposed_action.source
	return _get_action_source(reason, null, state_name)


func _reject_claimed_autonomous_request(
	state_name: StringName,
	request_source: StringName
) -> bool:
	var source := request_source if request_source != &"" else &"unknown"
	last_state_request_failure_reason = "scripted_control_claimed"
	_breadcrumb(
		"npc_state:scripted_control_reject",
		"%s state=%s source=%s" % [_get_npc_label(), String(state_name), String(source)]
	)
	var log_key := "%s|%s" % [String(source), String(state_name)]
	if OS.is_debug_build() and not _logged_scripted_control_autonomous_rejections.has(log_key):
		_logged_scripted_control_autonomous_rejections[log_key] = true
		push_warning(
			"NPC autonomous request rejected while claimed: npc=%s state=%s source=%s"
			% [_get_npc_label(), String(state_name), String(source)]
		)
	state_request_failed.emit(state_name, last_state_request_failure_reason)
	return false


func _warn_stale_scripted_control_command(command: StringName, claim_token: int) -> void:
	if not OS.is_debug_build():
		return
	var log_key := "%s|%d|%d" % [
		String(command), claim_token, scripted_control_claim_token
	]
	if _logged_scripted_control_stale_commands.has(log_key):
		return
	_logged_scripted_control_stale_commands[log_key] = true
	push_warning(
		"Stale NPC scripted-control command rejected: npc=%s command=%s token=%d current=%d"
		% [
			_get_npc_label(), String(command), claim_token, scripted_control_claim_token
		]
	)


func change_state(
	new_state: NpcState,
	reason: String = "",
	request_priority: int = 0
) -> bool:
	# Switches the active child state and gives the old state a clean exit.
	if new_state == null:
		return false
	if _has_scripted_control_claim() and String(new_state.name) != "ScriptedHold":
		if not (
			scripted_control_allows_emergencies
			and _is_scripted_control_emergency_state(StringName(new_state.name))
		):
			return _reject_claimed_autonomous_request(
				StringName(new_state.name), StringName(reason if not reason.is_empty() else "change_state")
			)
	if String(new_state.name) == "Talk":
		var requested_partner := get_talk_target()
		var overlay_priority := maxi(request_priority, get_effective_task_priority())
		# MoveToTarget used to replace itself with Talk. Finish that primary movement
		# into Idle first, then open Talk in the interaction lane.
		if _current_state_is(&"MoveToTarget"):
			var idle_state := get_state(&"Idle")
			if idle_state == null:
				return _reject_state_request(&"Talk", "missing_idle_for_talk_overlay")
			if not current_state.can_exit_to(idle_state, overlay_priority):
				return _reject_state_request(&"Talk", "cannot_finish_talk_approach")
			if not _commit_state_change(
				idle_state, "talk_overlay_handoff_approach", overlay_priority
			):
				return false
		return _request_talk_state(
			requested_partner, reason, overlay_priority, true,
			_resolve_talk_initiating_source(&"", requested_partner, reason)
		)

	var requested_name := StringName(new_state.name)
	var continuing_social_approach := (
		requested_name == &"LookForTalkTarget"
		and reason == "state_tick"
		and _current_state_is(&"MoveToTarget")
		and active_action != null
		and active_action.status == NpcActionSession.Status.ACTIVE
		and active_action.action_kind == &"LookForTalkTarget"
		and active_action.phase == &"executing"
	)
	if (
		requested_name == &"LookForTalkTarget"
		and is_socially_engaged()
		and not continuing_social_approach
	):
		return _reject_state_request(requested_name, "already_socially_engaged")
	if (
		_is_active_travel_companion()
		and not is_state_allowed_for_active_travel_companion(requested_name)
	):
		return _reject_state_request(
			requested_name,
			"Travel companion social/schedule activity disabled"
		)

	if current_state == new_state:
		return _reject_state_request(requested_name, "state_already_active")

	if current_state != null and not current_state.can_exit_to(new_state, request_priority):
		_breadcrumb(
			"npc_state:change_reject",
			"%s %s->%s reason=%s priority=%d" % [
				_get_npc_label(),
				String(current_state.name),
				String(new_state.name),
				reason,
				request_priority,
			]
		)
		return _reject_state_request(
			StringName(new_state.name),
			"cannot_exit_%s" % String(current_state.name)
		)

	var changed := _commit_state_change(new_state, reason, request_priority)
	if changed:
		_observe_internal_same_session_transition(new_state, reason)
	return changed


func _commit_state_change(
	new_state: NpcState,
	reason: String,
	request_priority: int
) -> bool:
	# Callers validate the transition and commit request context before entering here.
	last_state_request_failure_reason = ""

	var applied_priority := _get_applied_state_priority(new_state, request_priority)
	var previous_name := &""
	if current_state != null:
		previous_name = StringName(current_state.name)
		if interaction_overlay != null and not _overlay_survives_primary_transition(new_state):
			_cancel_interaction_overlay("primary_transition_%s" % String(new_state.name))
		if (
			String(new_state.name) == "Idle"
			and not reason.begins_with("talk_overlay_handoff")
			and active_action != null
			and active_action.status == NpcActionSession.Status.ACTIVE
			and current_state.action_session_id == active_action.session_id
		):
			complete_active_action(current_state.action_session_id, reason if not reason.is_empty() else "state_completed")
		_pending_primary_state = new_state
		current_state.exit()

	state_history.push_front(new_state)
	if state_history.size() > 3:
		state_history.resize(3)
	previous_state_priority = current_state_priority
	current_state_priority = applied_priority
	new_state.next_state = null
	new_state.enter()
	_pending_primary_state = null
	_refresh_interaction_animation_presentation()
	_invalidate_player_interaction_for_current_state()

	_update_debug_label()
	_breadcrumb(
		"npc_state:enter",
		"%s %s->%s reason=%s priority=%d" % [
			_get_npc_label(),
			String(previous_name),
			String(new_state.name),
			reason,
			applied_priority,
		]
	)
	state_changed.emit(StringName(new_state.name), previous_name)

	# Some need rules only run while idle. Re-check them after any state returns to Idle.
	if _value_reactions_enabled() and String(new_state.name) == "Idle":
		_queue_idle_value_reaction_check()

	return true


func request_state(
	state_name: StringName,
	actor: Node2D = null,
	reason: String = "manual",
	request_priority: int = 0
) -> bool:
	# External code can call this to force a state without waiting for value rules.
	if not _scripted_control_request_is_allowed(state_name, {}):
		return _reject_claimed_autonomous_request(
			state_name, _get_scripted_control_request_source({}, reason, state_name)
		)
	if state_name == &"":
		return _reject_state_request(state_name, "empty_state")
	if String(state_name) == "Talk":
		var requested_partner := actor if actor != null else get_talk_target()
		return _request_talk_state(
			requested_partner, reason, request_priority, true,
			_resolve_talk_initiating_source(&"", requested_partner, reason)
		)

	return _request_state_direct(state_name, actor, reason, request_priority)


func request_behavior_intent(
	intent: NpcBehaviorIntent,
	live_target: Node2D = null,
	request_context: Dictionary = {}
) -> bool:
	if intent == null or intent.requested_primary_state == &"":
		return _reject_state_request(&"", "invalid_behavior_intent")
	var submitted := intent.refreshed_copy()
	var context := request_context.duplicate(true)
	var forwarded_metadata := submitted.metadata.duplicate(true)
	for context_key in context:
		var context_key_text := String(context_key)
		if (
			context_key_text.begins_with("shared_activity_")
			or context_key_text.begins_with("activity_social_")
		):
			forwarded_metadata[context_key_text] = context[context_key]
	if forwarded_metadata != submitted.metadata:
		submitted = submitted.refreshed_copy({"metadata": forwarded_metadata})
	context["request_source"] = submitted.source
	context["explicit_behavior_intent"] = true
	context["behavior_source"] = submitted.source
	context["behavior_reason_code"] = submitted.reason_code
	context["behavior_feedback_text"] = submitted.feedback_text
	context["behavior_origin_value"] = submitted.origin_value
	if submitted.logical_action_kind != &"":
		context["destination_action_kind"] = submitted.logical_action_kind
	if not submitted.action_session_id.is_empty():
		context["action_session_id"] = submitted.action_session_id
		context["session_id"] = submitted.action_session_id
	if submitted.lifecycle_only:
		context["internal_lifecycle_transition"] = true
	var request_reason := submitted.reason
	if request_reason.is_empty():
		request_reason = String(submitted.reason_code)
	return _request_state_direct(
		submitted.requested_primary_state,
		live_target,
		request_reason,
		submitted.priority,
		context,
		submitted
	)


func _get_applied_state_priority(new_state: NpcState, request_priority: int) -> int:
	var applied_priority := request_priority
	if pending_state_priority >= 0:
		applied_priority = maxi(applied_priority, pending_state_priority)
		pending_state_priority = -1
	if new_state != null and String(new_state.name) == "MoveToTarget" and active_action != null:
		applied_priority = maxi(applied_priority, maxi(current_state_priority, active_action.priority))

	return applied_priority


func _request_state_direct(
	state_name: StringName,
	actor: Node2D = null,
	reason: String = "manual",
	request_priority: int = 0,
	request_context: Dictionary = {},
	explicit_behavior_intent: NpcBehaviorIntent = null
) -> bool:
	# Resolve and validate first. Request-owned targets are committed only once change_state accepts.
	if not _scripted_control_request_is_allowed(state_name, request_context):
		return _reject_claimed_autonomous_request(
			state_name,
			_get_scripted_control_request_source(request_context, reason, state_name)
		)
	var requested_state := get_state(state_name)
	if requested_state == null:
		return _reject_state_request(state_name, "Missing state: %s" % String(state_name))
	if String(requested_state.name) == "Talk":
		var requested_partner := actor if actor != null else get_talk_target()
		# Explicit behavior intents already carry their authority. Preserve that
		# source instead of re-inferring a Player-owned request from the partner type.
		var requested_source := StringName(String(request_context.get(
			"request_source",
			explicit_behavior_intent.source if explicit_behavior_intent != null else &""
		)))
		return _request_talk_state(
			requested_partner, reason, request_priority, true,
			_resolve_talk_initiating_source(requested_source, requested_partner, reason)
		)
	if String(requested_state.name) == "LookForTalkTarget":
		if (
			DebugToolsConfig.TROUBLESHOOTING_MODE
			and DebugToolsConfig.DEBUG_DISABLE_TALK_SEARCH
		):
			_breadcrumb("npc_state:talk_search_skip", _get_npc_label())
			return _reject_state_request(state_name, "talk_search_disabled")
		if is_socially_engaged():
			return _reject_state_request(state_name, "already_socially_engaged")
		if _current_look_for_talk_target_matches(actor) and _proposed_action == null:
			var matching_social_candidate := _build_behavior_candidate(
				requested_state,
				actor,
				reason,
				request_priority,
				request_context,
				explicit_behavior_intent
			)
			if not _evaluate_behavior_candidate(
				matching_social_candidate, state_name
			):
				return false
			_commit_behavior_candidate(matching_social_candidate)
			last_state_request_failure_reason = ""
			return true
		if not _can_start_look_for_talk_target():
			_breadcrumb("npc_state:request_reject", "%s moving_to_target %s" % [_get_npc_label(), String(state_name)])
			return _reject_state_request(state_name, "moving_to_target")

	var transition_state := requested_state
	if (
		_is_active_travel_companion()
		and not is_state_allowed_for_active_travel_companion(StringName(transition_state.name))
	):
		return _reject_state_request(
			state_name,
			"Travel companion social/schedule activity disabled"
		)

	var behavior_candidate := _build_behavior_candidate(
		transition_state,
		actor,
		reason,
		request_priority,
		request_context,
		explicit_behavior_intent
	)
	if not _evaluate_behavior_candidate(behavior_candidate, state_name):
		return false

	if current_state == transition_state:
		var request_descriptor := _get_state_request_activity_descriptor(
			transition_state,
			actor,
			request_context
		)
		if _state_request_supports_identity_reentry(transition_state):
			if is_following_activity_descriptor(request_descriptor):
				if _proposed_action != null and (
					active_action == null
					or active_action.session_id != _proposed_action.session_id
				):
					var adopted_session := _proposed_action
					_proposed_action = null
					replace_active_action(adopted_session, "adopt_existing_state")
					var adopted := _commit_current_state_reentry(reason, request_priority)
					if adopted:
						behavior_candidate = _update_behavior_candidate_from_session(
							behavior_candidate, adopted_session
						)
						_commit_behavior_candidate(behavior_candidate)
					return adopted
				last_state_request_failure_reason = ""
				_commit_behavior_candidate(behavior_candidate)
				return true
			if not NpcActivityIdentity.has_target_identity(request_descriptor):
				return _reject_state_request(state_name, "missing_activity_identity")
			if not current_state.can_exit_to(transition_state, request_priority):
				return _reject_state_request(
					state_name,
					"cannot_retarget_%s" % String(current_state.name)
				)
			var reentry_context := request_context.duplicate(true)
			var reentry_session := _consume_or_build_action_session(
				StringName(transition_state.name), actor, reason, request_priority, reentry_context
			)
			if reentry_session != null:
				var reservation_result := _ensure_action_session_spot_reservation(reentry_session)
				if not bool(reservation_result.get("accepted", false)):
					return _reject_state_request(
						state_name,
						String(reservation_result.get("status", "spot_reservation_rejected"))
					)
				reentry_context["action_session"] = reentry_session
			_commit_state_request_context(actor, reentry_context)
			var reentered := _commit_current_state_reentry(reason, request_priority)
			if reentered:
				behavior_candidate = _update_behavior_candidate_from_session(
					behavior_candidate, reentry_session
				)
				_commit_behavior_candidate(behavior_candidate)
			return reentered
		return _reject_state_request(state_name, "state_already_active")
	if current_state != null and not current_state.can_exit_to(transition_state, request_priority):
		return _reject_state_request(
			state_name,
			"cannot_exit_%s" % String(current_state.name)
		)

	var committed_context := request_context.duplicate(true)
	var action_session := _consume_or_build_action_session(
		StringName(transition_state.name), actor, reason, request_priority, committed_context
	)
	if action_session != null:
		var reservation_result := _ensure_action_session_spot_reservation(action_session)
		if not bool(reservation_result.get("accepted", false)):
			return _reject_state_request(
				state_name,
				String(reservation_result.get("status", "spot_reservation_rejected"))
			)
		committed_context["action_session"] = action_session
	_commit_state_request_context(actor, committed_context)

	var accepted := _commit_state_change(transition_state, reason, request_priority)
	if accepted:
		behavior_candidate = _update_behavior_candidate_from_session(
			behavior_candidate, action_session
		)
		_commit_behavior_candidate(behavior_candidate)
	_breadcrumb(
		"npc_state:request",
		"%s %s %s" % [_get_npc_label(), String(state_name), "accept" if accepted else "reject"]
	)
	return accepted


func _commit_current_state_reentry(reason: String, request_priority: int) -> bool:
	# Identity-aware target changes restart the same state without duplicating history.
	var reentered_state := current_state
	if reentered_state == null:
		return false

	last_state_request_failure_reason = ""
	if interaction_overlay != null:
		_cancel_interaction_overlay("primary_reentry_%s" % String(reentered_state.name))
	var applied_priority := _get_applied_state_priority(reentered_state, request_priority)
	var state_name := StringName(reentered_state.name)
	_pending_primary_state = reentered_state
	reentered_state.exit()
	previous_state_priority = current_state_priority
	current_state_priority = applied_priority
	reentered_state.next_state = null
	reentered_state.enter()
	_pending_primary_state = null
	_invalidate_player_interaction_for_current_state()
	_update_debug_label()
	_breadcrumb(
		"npc_state:reenter",
		"%s state=%s reason=%s priority=%d" % [
			_get_npc_label(),
			String(state_name),
			reason,
			applied_priority,
		]
	)
	state_changed.emit(state_name, state_name)
	return true


func _commit_state_request_context(actor: Node2D, request_context: Dictionary) -> void:
	var action_session = request_context.get("action_session", null) as NpcActionSession
	if action_session != null:
		replace_active_action(action_session, "request_accepted")
	if actor != null:
		last_event_actor = actor
		last_actor = actor
		target = actor
		if action_session != null and String(action_session.action_kind) in ["Fight", "Flee", "LookForMonster"]:
			select_combat_target(actor)


func _build_behavior_candidate(
	requested_state: NpcState,
	actor: Node2D,
	reason: String,
	request_priority: int,
	request_context: Dictionary,
	explicit_behavior_intent: NpcBehaviorIntent = null
) -> NpcBehaviorIntent:
	if requested_state == null or behavior_controller == null:
		return null

	var primary_state := StringName(requested_state.name)
	var logical_action := primary_state
	if primary_state == &"MoveToTarget":
		logical_action = StringName(String(request_context.get(
			"destination_action_kind",
			state_after_move if state_after_move != &"" else &"MoveToTarget"
		)))
	var actor_target_id := NpcActionSessionModel.get_persistent_id(actor)
	if explicit_behavior_intent != null:
		var explicit_target_id := explicit_behavior_intent.target_persistent_id
		if explicit_target_id.is_empty():
			explicit_target_id = actor_target_id
		var explicit_metadata := explicit_behavior_intent.metadata.duplicate(true)
		explicit_metadata["legacy_derived"] = false
		var explicit_commitment := explicit_behavior_intent.minimum_commitment_seconds
		var explicit_margin := explicit_behavior_intent.interrupt_priority_margin
		if NpcBehaviorIntentModel.is_autonomous_source(explicit_behavior_intent.source):
			if explicit_commitment <= 0.0:
				explicit_commitment = behavior_controller.minimum_autonomous_commitment_seconds
			if explicit_margin <= 0:
				explicit_margin = behavior_controller.autonomous_interruption_margin
		return explicit_behavior_intent.refreshed_copy({
			"requested_primary_state": primary_state,
			"logical_action_kind": (
				explicit_behavior_intent.logical_action_kind
				if explicit_behavior_intent.logical_action_kind != &""
				else logical_action
			),
			"source": NpcBehaviorIntentModel.canonicalize_source(
				explicit_behavior_intent.source
			),
			"priority": request_priority,
			"target_persistent_id": explicit_target_id,
			"minimum_commitment_seconds": explicit_commitment,
			"interrupt_priority_margin": explicit_margin,
			"lifecycle_only": (
				explicit_behavior_intent.lifecycle_only
				or _request_is_lifecycle_only(primary_state, reason, request_context)
			),
			"metadata": explicit_metadata,
		})

	var source := StringName(String(request_context.get("request_source", "")))
	var target_id := actor_target_id
	var session_id := ""
	var reason_code := StringName(String(request_context.get("behavior_reason_code", "")))
	var feedback_text := String(request_context.get("behavior_feedback_text", ""))
	var origin_value := StringName(String(request_context.get("behavior_origin_value", "")))
	var legacy_derived := false
	var action_metadata_for_intent: Dictionary = {}

	if _proposed_action != null:
		logical_action = _proposed_action.action_kind
		source = _proposed_action.source
		session_id = _proposed_action.session_id
		target_id = _get_action_session_behavior_target_id(_proposed_action, target_id)
		var session_behavior := _proposed_action.metadata
		action_metadata_for_intent = session_behavior.duplicate(true)
		if session_behavior.has("behavior_source"):
			source = StringName(String(session_behavior["behavior_source"]))
		reason_code = StringName(String(session_behavior.get(
			"behavior_reason_code", reason_code
		)))
		feedback_text = String(session_behavior.get(
			"behavior_feedback_text", feedback_text
		))
		origin_value = StringName(String(session_behavior.get(
			"behavior_origin_value", origin_value
		)))
	elif (
		active_action != null
		and active_action.status == NpcActionSession.Status.ACTIVE
		and active_action.action_kind == logical_action
		and (
			target_id.is_empty()
			or _get_action_session_behavior_target_id(active_action, "") == target_id
		)
	):
		session_id = active_action.session_id
		source = active_action.source
		target_id = _get_action_session_behavior_target_id(active_action, target_id)
		action_metadata_for_intent = active_action.metadata.duplicate(true)

	if source == &"":
		source = _get_action_source(reason, actor, logical_action)
		legacy_derived = true
		_record_legacy_behavior_request(primary_state, logical_action, reason)
	source = _canonical_behavior_source(source)
	var autonomous := NpcBehaviorIntentModel.is_autonomous_source(source)
	var commitment_seconds := (
		behavior_controller.minimum_autonomous_commitment_seconds
		if autonomous
		else 0.0
	)
	var interrupt_margin := (
		behavior_controller.autonomous_interruption_margin
		if autonomous
		else 0
	)
	var metadata := {
		"legacy_derived": legacy_derived,
	}
	for metadata_key in action_metadata_for_intent:
		if (
			String(metadata_key).begins_with("schedule_")
			or String(metadata_key).begins_with("shared_activity_")
			or String(metadata_key).begins_with("activity_social_")
		):
			metadata[String(metadata_key)] = action_metadata_for_intent[metadata_key]
	if request_context.has("arrival_state"):
		metadata["arrival_state"] = String(request_context["arrival_state"])
	return NpcBehaviorIntentModel.create(
		primary_state,
		logical_action,
		source,
		reason,
		request_priority,
		target_id,
		session_id,
		commitment_seconds,
		interrupt_margin,
		metadata,
		reason_code,
		feedback_text,
		origin_value,
		_request_is_lifecycle_only(primary_state, reason, request_context)
	)


func _evaluate_behavior_candidate(
	candidate: NpcBehaviorIntent,
	requested_state_name: StringName
) -> bool:
	if behavior_controller == null or candidate == null:
		return true
	var decision := behavior_controller.evaluate_candidate(candidate)
	if bool(decision.get("accepted", false)):
		return true
	var rejection_reason := StringName(String(decision.get(
		"reason", "behavior_commitment_active"
	)))
	behavior_controller.reject_candidate(candidate, rejection_reason)
	return _reject_state_request(requested_state_name, String(rejection_reason))


func _commit_behavior_candidate(candidate: NpcBehaviorIntent) -> void:
	if behavior_controller == null or candidate == null:
		return
	behavior_controller.commit_candidate(candidate)


func _update_behavior_candidate_from_session(
	candidate: NpcBehaviorIntent,
	session: NpcActionSession
) -> NpcBehaviorIntent:
	if candidate == null or session == null:
		return candidate
	return candidate.refreshed_copy({
		"action_session_id": session.session_id,
		"logical_action_kind": session.action_kind,
		"target_persistent_id": _get_action_session_behavior_target_id(
			session, candidate.target_persistent_id
		),
	})


func _get_action_session_behavior_target_id(
	session: NpcActionSession,
	fallback: String
) -> String:
	if session == null:
		return fallback.strip_edges()
	if not session.target_persistent_id.strip_edges().is_empty():
		return session.target_persistent_id.strip_edges()
	if session.spot_id != &"":
		return String(session.spot_id).strip_edges()
	return fallback.strip_edges()


func _canonical_behavior_source(source: StringName) -> StringName:
	return NpcBehaviorIntentModel.canonicalize_source(source)


func _request_is_lifecycle_only(
	primary_state: StringName,
	reason: String,
	request_context: Dictionary
) -> bool:
	if bool(request_context.get("internal_lifecycle_transition", false)):
		return true
	if primary_state == &"Idle" and not bool(
		request_context.get("explicit_goal_intent", false)
	):
		return true
	return reason in [
		"initial",
		"state_tick",
		"stale_action_session_reconcile",
		"action_state_reconciliation",
	]


func _record_legacy_behavior_request(
	primary_state: StringName,
	logical_action: StringName,
	reason: String
) -> void:
	var signature := "%s|%s|%s" % [
		String(primary_state), String(logical_action), reason
	]
	_legacy_behavior_request_counts[signature] = int(
		_legacy_behavior_request_counts.get(signature, 0)
	) + 1
	if (
		not DebugToolsConfig.TROUBLESHOOTING_MODE
		or _logged_legacy_behavior_requests.has(signature)
	):
		return
	_logged_legacy_behavior_requests[signature] = true
	push_warning("Legacy NPC behavior request lacks explicit intention metadata: %s" % signature)


func get_legacy_behavior_request_diagnostics() -> Dictionary:
	return _legacy_behavior_request_counts.duplicate(true)


func _clear_behavior_intent_for_session(
	session_id: String,
	reason: StringName
) -> bool:
	if behavior_controller == null:
		return false
	return behavior_controller.clear_intent_for_session(session_id, reason)


func _observe_internal_same_session_transition(
	new_state: NpcState,
	reason: String
) -> void:
	if (
		behavior_controller == null
		or behavior_controller.current_intent == null
		or active_action == null
		or active_action.status != NpcActionSession.Status.ACTIVE
		or behavior_controller.current_intent.action_session_id
			!= active_action.session_id
	):
		return
	var current_intent := behavior_controller.current_intent
	var refreshed_metadata := current_intent.metadata.duplicate(true)
	if not reason.is_empty():
		refreshed_metadata["latest_internal_transition_reason"] = reason
	var refreshed := current_intent.refreshed_copy({
		"requested_primary_state": StringName(new_state.name),
		"metadata": refreshed_metadata,
	})
	behavior_controller.refresh_current_intent(
		refreshed, active_action.session_id
	)


func request_action_from_descriptor(descriptor: Dictionary, live_target: Node2D = null) -> bool:
	var action_kind := StringName(String(descriptor.get(
		"action_kind",
		descriptor.get("state_name", "")
	)))
	if action_kind == &"":
		return _reject_state_request(action_kind, "action_kind_missing")
	var action_source := StringName(String(descriptor.get("source", "schedule")))
	if not _scripted_control_request_is_allowed(action_kind, {}):
		return _reject_claimed_autonomous_request(action_kind, action_source)
	if _persistent_schedule_blocks_autonomous_action(action_source, descriptor):
		last_state_request_failure_reason = "authoritative_scheduled_activity"
		_breadcrumb(
			"npc_state:autonomous_action_deferred",
			"%s state=%s source=%s" % [
				_get_npc_label(), String(action_kind), String(action_source)
			]
		)
		return false
	var session := NpcActionSessionModel.create(
		_get_action_owner_id(),
		action_kind,
		action_source,
		live_target,
		descriptor
	)
	if session.status not in [NpcActionSession.Status.PROPOSED, NpcActionSession.Status.ACTIVE]:
		return _reject_state_request(action_kind, "action_session_not_executable")
	_proposed_action = session
	var priority := session.priority
	var accepted := false
	match String(action_kind):
		"Work": accepted = assign_work_target(live_target, priority)
		"Eat": accepted = assign_eat_target(live_target, priority)
		"Rest": accepted = assign_rest_target(live_target, priority)
		"Recreation": accepted = assign_recreation_target(live_target, priority)
		"RoutineTask": accepted = assign_routine_task_target(live_target, priority)
		"Sleep": accepted = assign_sleep_target(live_target, priority)
		"InvitePlayer": accepted = assign_invitation_spot(live_target, priority)
		"MoveToTarget": accepted = request_action_movement_from_descriptor(
			descriptor,
			live_target,
			StringName(String(descriptor.get(
				"arrival_state",
				descriptor.get("resume_state", descriptor.get("destination_action_kind", "Idle"))
			)))
		)
		_:
			accepted = _request_state_direct(
				action_kind,
				live_target,
				String(descriptor.get("reason", String(action_source))),
				priority,
				{}
			)
	if _proposed_action == session:
		_proposed_action = null
	return accepted


func _persistent_schedule_blocks_autonomous_action(
	action_source: StringName,
	descriptor: Dictionary
) -> bool:
	if not NpcBehaviorIntentModel.is_autonomous_source(action_source):
		return false
	# This narrow gate exists only between a live scheduled execution cycle ending
	# and NpcWorldSimulation authoritatively finishing or resuming its persistent
	# activity. Ordinary autonomous actions must not erase that record in the gap.
	if (
		active_action == null
		or active_action.source != NpcBehaviorIntentModel.SOURCE_SCHEDULE
		or active_action.status != NpcActionSession.Status.COMPLETED
	):
		return false
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_record_snapshot"):
		return false
	var record = locations.call("get_record_snapshot", _get_action_owner_id())
	if not (record is Dictionary):
		return false
	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return false
	if String(activity.get("status", "active")) in [
		"completed", "failed", "cancelled", "cancelling",
	]:
		return false
	var persistent_session_id := NpcActionSessionModel._descriptor_session_id(activity)
	if persistent_session_id.is_empty() or persistent_session_id != active_action.session_id:
		return false
	return NpcActionSessionModel._descriptor_session_id(descriptor) != persistent_session_id


func request_action_movement_from_descriptor(
	descriptor: Dictionary,
	movement_target: Node2D,
	destination_action_kind: StringName = &"Idle"
) -> bool:
	var movement_source := StringName(String(descriptor.get("source", "schedule")))
	if not _scripted_control_request_is_allowed(&"MoveToTarget", {}):
		return _reject_claimed_autonomous_request(&"MoveToTarget", movement_source)
	if movement_target == null or not is_instance_valid(movement_target):
		return _reject_state_request(&"MoveToTarget", "movement_target_invalid")
	var logical_kind := StringName(String(descriptor.get(
		"action_kind",
		destination_action_kind if destination_action_kind not in [&"", &"Idle"] else &"MoveToTarget"
	)))
	if logical_kind == &"MoveToTarget" and destination_action_kind not in [&"", &"Idle", &"MoveToTarget"]:
		logical_kind = destination_action_kind
	var arrival_state := StringName(String(descriptor.get(
		"arrival_state",
		descriptor.get("resume_state", destination_action_kind)
	)))
	if logical_kind != &"MoveToTarget" and arrival_state in [&"", &"Idle", &"MoveToTarget"]:
		arrival_state = logical_kind
	elif arrival_state in [&"", &"MoveToTarget"]:
		arrival_state = logical_kind if logical_kind != &"MoveToTarget" else &"Idle"
	var movement_descriptor := descriptor.duplicate(true)
	movement_descriptor["action_kind"] = String(logical_kind)
	movement_descriptor["phase"] = "moving_to_target"
	movement_descriptor["arrival_state"] = String(arrival_state)
	var session := NpcActionSessionModel.create(
		_get_action_owner_id(),
		logical_kind,
		StringName(String(movement_descriptor.get("source", "manual"))),
		movement_target,
		movement_descriptor
	)
	if session.status not in [NpcActionSession.Status.PROPOSED, NpcActionSession.Status.ACTIVE]:
		return _reject_state_request(&"MoveToTarget", "action_session_not_executable")
	_proposed_action = session
	var accepted := _request_state_direct(
		&"MoveToTarget",
		movement_target,
		String(movement_descriptor.get("reason", "action_travel_handoff")),
		session.priority,
		{
			"destination_action_kind": logical_kind,
			"arrival_state": arrival_state,
		}
	)
	if _proposed_action == session:
		_proposed_action = null
	return accepted


func replace_active_action(session: NpcActionSession, reason: String = "replaced") -> bool:
	if session == null or session.session_id.is_empty() or session.action_kind == &"":
		return false
	if session.status in [
		NpcActionSession.Status.CANCELLING,
		NpcActionSession.Status.COMPLETED,
		NpcActionSession.Status.FAILED,
	]:
		return false
	if active_action != null and active_action.session_id == session.session_id:
		var previous_reservation_ids := active_action.reservation_ids.duplicate()
		var execution_changed := (
			active_action.action_kind != session.action_kind
			or active_action.phase != session.phase
			or active_action.target_persistent_id != session.target_persistent_id
			or active_action.get_live_target() != session.get_live_target()
		)
		active_action.action_kind = session.action_kind
		active_action.source = session.source
		active_action.priority = session.priority
		active_action.spot_id = session.spot_id
		active_action.scene_path = session.scene_path
		active_action.phase = session.phase
		active_action.arrival_state = session.arrival_state
		active_action.target_persistent_id = session.target_persistent_id
		active_action.set_live_target(session.get_live_target())
		active_action.replace_reservation_ids(session.reservation_ids)
		_release_replaced_spot_reservations(
			previous_reservation_ids,
			active_action.reservation_ids,
			active_action.session_id
		)
		active_action.status = NpcActionSession.Status.ACTIVE
		active_action.reason = ""
		_mirror_active_action_to_legacy_fields()
		_publish_active_action()
		_action_state_reconciliation_requested = true
		_action_state_reconciliation_force_reentry = execution_changed
		return true
	if active_action != null and active_action.status in [
		NpcActionSession.Status.PROPOSED,
		NpcActionSession.Status.ACTIVE,
		NpcActionSession.Status.CANCELLING,
	]:
		_behavior_action_replacement_in_progress = true
		cancel_active_action(active_action.session_id, reason, &"supersession")
		_behavior_action_replacement_in_progress = false
	active_action = session
	active_action.status = NpcActionSession.Status.ACTIVE
	if active_action.phase in [&"", &"proposed"]:
		active_action.phase = &"executing"
	active_action.reason = ""
	_mirror_active_action_to_legacy_fields()
	_publish_active_action()
	_action_state_reconciliation_requested = true
	_action_state_reconciliation_force_reentry = false
	_log_action_session("active", "")
	return true


func cancel_active_action(
	session_id: String,
	reason: String = "cancelled",
	terminal_classification: StringName = &"neutral_cancellation"
) -> bool:
	if not _active_action_id_matches(session_id):
		_log_stale_action_callback("cancel", session_id)
		return false
	var intent_descriptor := (
		behavior_controller.get_current_intent_descriptor()
		if behavior_controller != null
		else {}
	)
	active_action.status = NpcActionSession.Status.CANCELLING
	active_action.reason = reason
	_release_active_action_reservations_once(reason)
	last_terminal_action_session_id = active_action.session_id
	active_action.status = NpcActionSession.Status.FAILED
	_publish_active_action()
	if memory_observer != null:
		memory_observer.observe_action_terminal(
			active_action.to_descriptor(),
			intent_descriptor,
			terminal_classification,
			StringName(reason)
		)
	_action_state_reconciliation_requested = true
	_action_state_reconciliation_force_reentry = false
	if not _behavior_action_replacement_in_progress:
		_clear_behavior_intent_for_session(session_id, StringName(reason))
	_log_action_session("cancelled", reason)
	return true


func complete_active_action(session_id: String, reason: String = "completed") -> bool:
	if not _active_action_id_matches(session_id):
		_log_stale_action_callback("complete", session_id)
		return false
	active_action.status = NpcActionSession.Status.COMPLETED
	active_action.reason = reason
	_release_active_action_reservations_once(reason, true)
	last_terminal_action_session_id = active_action.session_id
	_publish_active_action()
	_action_state_reconciliation_requested = true
	_action_state_reconciliation_force_reentry = false
	_clear_behavior_intent_for_session(session_id, StringName(reason))
	_log_action_session("completed", reason)
	return true


func complete_social_search_handoff(expected_session_id: String) -> bool:
	if expected_session_id.is_empty():
		return false
	if (
		interaction_overlay == null
		or String(interaction_overlay.name) != "Talk"
		or active_interaction_session == null
		or active_interaction_session.status != NpcActionSession.Status.ACTIVE
		or active_interaction_session.session_id != expected_session_id
	):
		return false
	if active_action == null:
		return last_terminal_action_session_id == expected_session_id
	if (
		active_action.session_id != expected_session_id
		or active_action.action_kind != &"LookForTalkTarget"
	):
		return false
	if active_action.status == NpcActionSession.Status.COMPLETED:
		return active_action.reason == "talk_handoff_completed"
	if active_action.status != NpcActionSession.Status.ACTIVE:
		return false

	var preserved_overlay := interaction_overlay
	var preserved_interaction := active_interaction_session
	if not complete_active_action(expected_session_id, "talk_handoff_completed"):
		return false
	if (
		interaction_overlay != preserved_overlay
		or active_interaction_session != preserved_interaction
		or not is_interaction_session_current_for_execution(expected_session_id)
	):
		push_warning("Talk handoff completion disturbed the accepted overlay for %s." % _get_npc_label())
		return false
	return true


func fail_active_action(session_id: String, reason: String) -> bool:
	return cancel_active_action(
		session_id,
		reason,
		_classify_action_failure_reason(StringName(reason))
	)


func _classify_action_failure_reason(reason: StringName) -> StringName:
	match reason:
		&"missing_action_target", &"movement_target_missing", &"scheduled_routine_spot_missing":
			return &"target_unavailable"
		&"movement_stuck":
			return &"movement_failure"
	return &"failure"


func _classify_neutral_action_cancellation(reason: StringName) -> StringName:
	if reason in [&"scene_exit", &"restore_terminal_action"]:
		return &"lifecycle_cleanup"
	return &"neutral_cancellation"


func pause_active_action_movement_for_retry(
	session_id: String,
	reason: String = "movement_retry",
	require_movement_phase: bool = true
) -> bool:
	if not is_action_session_current_for_execution(session_id):
		_log_stale_action_callback("pause_movement_retry", session_id)
		return false
	if active_action.phase == &"route_retry_wait":
		return true
	if require_movement_phase and active_action.phase != &"moving_to_target":
		_log_stale_action_callback("pause_movement_retry_phase", session_id)
		return false
	var cleared_target := active_action.get_live_target()
	active_action.phase = &"route_retry_wait"
	active_action.reason = reason
	active_action.set_live_target(null)
	_set_legacy_action_target(active_action.action_kind, null)
	if move_target == cleared_target:
		move_target = null
	if target == cleared_target:
		target = null
	state_after_move = &"Idle"
	state_after_move_priority = 0
	_publish_active_action()
	# MoveToTarget returns Idle in the same physics tick. The caller either retains
	# this exact route for a physical retry or discards it for a clean replan.
	_action_state_reconciliation_requested = false
	_action_state_reconciliation_force_reentry = false
	_log_action_session("movement_retry_wait", reason)
	return true


func clear_terminal_action(session_id: String) -> bool:
	if not _active_action_id_matches(session_id):
		return false
	if active_action.status not in [NpcActionSession.Status.COMPLETED, NpcActionSession.Status.FAILED]:
		return false
	var cleared_target := active_action.get_live_target()
	_set_legacy_action_target(active_action.action_kind, null)
	if move_target == cleared_target:
		move_target = null
	if target == cleared_target:
		target = null
	active_action = null
	_publish_active_action()
	_action_state_reconciliation_requested = true
	_action_state_reconciliation_force_reentry = false
	return true


func restore_action_descriptor(descriptor: Dictionary) -> bool:
	var restored_kind := StringName(String(descriptor.get(
		"action_kind", descriptor.get("state_name", "")
	)))
	if not _scripted_control_request_is_allowed(restored_kind, {}):
		return _reject_claimed_autonomous_request(
			restored_kind, StringName(String(descriptor.get("source", "world_simulation")))
		)
	if descriptor.is_empty():
		return false
	var session := NpcActionSessionModel.create(
		_get_action_owner_id(),
		StringName(String(descriptor.get("action_kind", descriptor.get("state_name", "")))),
		StringName(String(descriptor.get("source", "schedule"))),
		null,
		descriptor
	)
	if session == null or session.action_kind == &"":
		return false
	if session.status in [
		NpcActionSession.Status.CANCELLING,
		NpcActionSession.Status.COMPLETED,
		NpcActionSession.Status.FAILED,
	]:
		if active_action != null and active_action.session_id != session.session_id:
			cancel_active_action(
				active_action.session_id,
				"restore_terminal_action",
				&"lifecycle_cleanup"
			)
		active_action = session
		_mirror_active_action_to_legacy_fields()
		_publish_active_action()
		_action_state_reconciliation_requested = true
		_action_state_reconciliation_force_reentry = false
		return true
	return replace_active_action(session, "restore_persisted_action")


func get_active_action_descriptor() -> Dictionary:
	return active_action.to_descriptor() if active_action != null else {}


func get_active_action_session_id() -> String:
	return active_action.session_id if active_action != null else ""


func is_action_session_current_for_execution(
	session_id: String,
	state_name: StringName = &""
) -> bool:
	var session_matches := (
		_active_action_id_matches(session_id)
		and active_action.status == NpcActionSession.Status.ACTIVE
	)
	if not session_matches or state_name == &"":
		return session_matches
	return String(_get_active_action_execution_state_name()) == String(state_name)


func is_interaction_session_current_for_execution(session_id: String) -> bool:
	return (
		active_interaction_session != null
		and not session_id.is_empty()
		and active_interaction_session.session_id == session_id
		and active_interaction_session.status == NpcActionSession.Status.ACTIVE
	)


func is_active_action_executable_in_state(state_name: StringName) -> bool:
	return (
		active_action != null
		and active_action.status == NpcActionSession.Status.ACTIVE
		and String(_get_active_action_execution_state_name()) == String(state_name)
	)


func is_interaction_session_executable_for_state(state_name: StringName) -> bool:
	return (
		active_interaction_session != null
		and active_interaction_session.status == NpcActionSession.Status.ACTIVE
		and String(active_interaction_session.action_kind) == String(state_name)
	)


func reconcile_invalid_action_state_session(
	stale_state: NpcState,
	stale_session_id: String
) -> NpcState:
	var destination_name := _get_active_action_execution_state_name()
	var destination := get_state(destination_name)
	if destination == null or destination_name == &"Talk":
		destination_name = &"Idle"
		destination = get_state(destination_name)
	if destination == null:
		return null

	_pending_stale_state_reconciliation = {
		"state_instance_id": stale_state.get_instance_id() if stale_state != null else 0,
		"stale_session_id": stale_session_id,
		"active_session_id": get_active_action_session_id(),
		"destination_name": String(destination_name),
	}
	_log_stale_state_reconciliation_once(stale_state, stale_session_id, destination_name)
	return destination


func _get_active_action_execution_state_name() -> StringName:
	if active_action == null or active_action.status != NpcActionSession.Status.ACTIVE:
		return &"Idle"
	if active_action.phase == &"route_retry_wait":
		return &"Idle"
	if active_action.phase == &"moving_to_target":
		return &"MoveToTarget"
	if active_action.action_kind in [&"", &"MoveToTarget"]:
		return &"Idle"
	return active_action.action_kind


func _reconcile_current_state_action_session_if_needed() -> bool:
	var stale_state := current_state
	if stale_state == null or stale_state.action_session_id.is_empty():
		return false
	if is_action_session_current_for_execution(
		stale_state.action_session_id,
		StringName(stale_state.name)
	):
		return false
	var destination := reconcile_invalid_action_state_session(
		stale_state,
		stale_state.action_session_id
	)
	if destination == null:
		return false
	return _commit_stale_state_reconciliation(stale_state, destination)


func _reconcile_requested_active_action_state() -> bool:
	if not _action_state_reconciliation_requested or current_state == null:
		return false
	var destination_name := _get_active_action_execution_state_name()
	if destination_name == &"Talk":
		destination_name = &"Idle"
	var destination := get_state(destination_name)
	if destination == null:
		destination = get_state(&"Idle")
	if destination == null:
		return false

	var current_matches := current_state == destination
	if (
		current_matches
		and destination_name == &"Idle"
		and not _action_state_reconciliation_force_reentry
	):
		_action_state_reconciliation_requested = false
		return false
	if (
		current_matches
		and not _action_state_reconciliation_force_reentry
		and is_action_session_current_for_execution(
		current_state.action_session_id,
		StringName(current_state.name)
		)
	):
		_action_state_reconciliation_requested = false
		return false
	if (
		current_matches
		and active_action != null
		and current_state.action_session_id == active_action.session_id
	):
		_action_state_reconciliation_requested = false
		_action_state_reconciliation_force_reentry = false
		current_state.refresh_action_session_binding()
		_breadcrumb(
			"npc_state:refresh_session",
			"%s state=%s session=%s" % [
				_get_npc_label(), String(current_state.name), active_action.session_id
			]
		)
		return false

	var state_to_replace := current_state
	if (
		not state_to_replace.action_session_id.is_empty()
		and not is_action_session_current_for_execution(
			state_to_replace.action_session_id,
			StringName(state_to_replace.name)
		)
	):
		destination = reconcile_invalid_action_state_session(
			state_to_replace,
			state_to_replace.action_session_id
		)
		if destination == null:
			return false
	_action_state_reconciliation_requested = false
	_action_state_reconciliation_force_reentry = false
	return _commit_action_state_reconciliation(
		state_to_replace,
		destination,
		"active_action_state_reconcile"
	)


func _pending_stale_reconciliation_matches(
	stale_state: NpcState,
	destination: NpcState
) -> bool:
	return (
		not _pending_stale_state_reconciliation.is_empty()
		and stale_state != null
		and destination != null
		and int(_pending_stale_state_reconciliation.get("state_instance_id", 0)) == stale_state.get_instance_id()
		and String(_pending_stale_state_reconciliation.get("destination_name", "")) == String(destination.name)
	)


func _commit_stale_state_reconciliation(
	stale_state: NpcState,
	destination: NpcState
) -> bool:
	if stale_state == null or destination == null or stale_state != current_state:
		_pending_stale_state_reconciliation.clear()
		return false
	_pending_stale_state_reconciliation.clear()
	return _commit_action_state_reconciliation(
		stale_state,
		destination,
		"stale_action_session_reconcile"
	)


func _commit_action_state_reconciliation(
	state_to_replace: NpcState,
	destination: NpcState,
	reason: String
) -> bool:
	if state_to_replace == null or destination == null or state_to_replace != current_state:
		return false
	if _has_scripted_control_claim() and String(destination.name) != "ScriptedHold":
		if not (
			scripted_control_allows_emergencies
			and _is_scripted_control_emergency_state(StringName(destination.name))
		):
			return _reconcile_to_scripted_hold("scripted_control_action_reconcile")
	var priority := active_action.priority if active_action != null else 0
	if destination == state_to_replace:
		return _commit_current_state_reentry(reason, priority)
	return _commit_state_change(destination, reason, priority)


func _log_stale_state_reconciliation_once(
	stale_state: NpcState,
	stale_session_id: String,
	destination_name: StringName
) -> void:
	if not OS.is_debug_build():
		return
	var state_name := String(stale_state.name) if stale_state != null else ""
	var log_key := "%s|%s|%s" % [state_name, stale_session_id, get_active_action_session_id()]
	if _logged_stale_state_reconciliations.has(log_key):
		return
	_logged_stale_state_reconciliations[log_key] = true
	print("NPC action stale state: npc=%s state=%s old_session=%s active_session=%s destination=%s" % [
		_get_npc_label(), state_name, stale_session_id,
		get_active_action_session_id(), String(destination_name),
	])


func get_active_action_target() -> Node2D:
	if active_action == null:
		return null
	var live_target := active_action.get_live_target()
	if live_target != null:
		return live_target
	if active_action.target_persistent_id.is_empty():
		return null
	var resolved := _resolve_persistent_action_target(active_action.target_persistent_id)
	if resolved != null:
		active_action.set_live_target(resolved)
	return resolved


func get_active_action_target_id() -> StringName:
	return StringName(active_action.target_persistent_id) if active_action != null else &""


func get_active_action_spot_id() -> StringName:
	return active_action.spot_id if active_action != null else &""


func update_active_action_metadata(
	expected_session_id: String,
	metadata_updates: Dictionary,
	scene_path: String = "",
	publish_change: bool = true
) -> bool:
	if not _active_action_id_matches(expected_session_id):
		_log_stale_action_callback("update_metadata", expected_session_id)
		return false
	if active_action.status != NpcActionSession.Status.ACTIVE:
		return false
	for key in metadata_updates.keys():
		active_action.metadata[String(key)] = metadata_updates[key]
	if not scene_path.is_empty():
		active_action.scene_path = scene_path
	if publish_change:
		_publish_active_action()
	return true


func get_action_target(action_kind: StringName, legacy_target = null) -> Node2D:
	if active_action != null and String(active_action.action_kind) == String(action_kind):
		var session_target := get_active_action_target()
		if session_target != null:
			return session_target
	return legacy_target as Node2D if is_instance_valid(legacy_target) else null


func get_move_target() -> Node2D:
	var session_target := get_active_action_target()
	return session_target if session_target != null else (
		move_target if move_target != null and is_instance_valid(move_target) else null
	)
func get_work_target() -> Node2D: return get_action_target(&"Work", work_target)
func get_eat_target() -> Node2D: return get_action_target(&"Eat", eat_target)
func get_rest_target() -> Node2D: return get_action_target(&"Rest", rest_target)
func get_recreation_target() -> Node2D: return get_action_target(&"Recreation", recreation_target)
func get_routine_task_target() -> Node2D: return get_action_target(&"RoutineTask", routine_task_target)
func get_sleep_target() -> Node2D: return get_action_target(&"Sleep", sleep_target)
func get_invitation_spot() -> Node2D: return get_action_target(&"InvitePlayer", invitation_spot)
func get_talk_target() -> Node2D:
	if active_interaction_session != null:
		var session_target := active_interaction_session.get_live_target()
		if session_target != null:
			return session_target
	return talk_target if talk_target != null and is_instance_valid(talk_target) else null


func set_action_target(
	action_kind: StringName,
	live_target: Node2D,
	expected_session_id: String = ""
) -> bool:
	if active_action == null:
		if not expected_session_id.is_empty():
			_log_stale_action_callback("set_target", expected_session_id)
			return false
		_set_legacy_action_target(action_kind, live_target)
		return true
	if String(active_action.action_kind) != String(action_kind):
		_log_stale_action_callback("set_target_kind_%s" % String(action_kind), expected_session_id)
		return false
	if not expected_session_id.is_empty() and active_action.session_id != expected_session_id:
		_log_stale_action_callback("set_target", expected_session_id)
		return false
	if active_action.status != NpcActionSession.Status.ACTIVE:
		_log_stale_action_callback("set_target_terminal", expected_session_id)
		return false
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	var old_spot_id := active_action.spot_id
	var new_spot_id := _get_stable_spot_id(live_target)
	var purpose := StringName(String(active_action.metadata.get(
		"reservation_purpose", "activity"
	)))
	var old_reservation_id := ""
	if old_spot_id != &"" and simulator != null and simulator.has_method("make_spot_reservation_id"):
		old_reservation_id = String(simulator.call(
			"make_spot_reservation_id", active_action.session_id, old_spot_id, purpose
		))
	var new_reservation_id := ""
	if new_spot_id != &"" and new_spot_id != old_spot_id:
		if simulator == null or not simulator.has_method("try_claim_spot"):
			return false
		var claim_result: Dictionary = simulator.call(
			"try_claim_spot",
			StringName(_get_action_owner_id()),
			active_action.session_id,
			new_spot_id,
			purpose
		)
		if not bool(claim_result.get("accepted", false)):
			last_state_request_failure_reason = String(claim_result.get(
				"status", "spot_transfer_rejected"
			))
			return false
		new_reservation_id = String(claim_result.get("reservation_id", ""))
	_set_legacy_action_target(action_kind, live_target)
	active_action.set_live_target(live_target)
	active_action.target_persistent_id = NpcActionSessionModel.get_persistent_id(live_target)
	active_action.spot_id = new_spot_id
	if not new_reservation_id.is_empty():
		active_action.add_reservation_id(new_reservation_id)
	if (
		not old_reservation_id.is_empty()
		and old_reservation_id != new_reservation_id
		and simulator != null
		and simulator.has_method("release_spot_reservation")
	):
		if bool(simulator.call(
			"release_spot_reservation",
			old_reservation_id,
			StringName(_get_action_owner_id()),
			active_action.session_id
		)):
			active_action.remove_reservation_id(old_reservation_id)
	_publish_active_action()
	return true


func _set_legacy_action_target(action_kind: StringName, live_target: Node2D) -> void:
	match String(action_kind):
		"Work": work_target = live_target
		"Eat": eat_target = live_target
		"Rest": rest_target = live_target
		"Recreation": recreation_target = live_target
		"RoutineTask": routine_task_target = live_target
		"Sleep": sleep_target = live_target
		"InvitePlayer": invitation_spot = live_target
		"Talk": talk_target = live_target
		"MoveToTarget": move_target = live_target


func _mirror_active_action_to_legacy_fields() -> void:
	if active_action == null:
		return
	var live_target := active_action.get_live_target()
	_set_legacy_action_target(active_action.action_kind, live_target)
	move_target = live_target
	if active_action.phase == &"moving_to_target":
		state_after_move = (
			active_action.arrival_state
			if active_action.arrival_state != &""
			else active_action.action_kind
		)
		state_after_move_priority = active_action.priority


func _resolve_persistent_action_target(target_id: String) -> Node2D:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("get_live_npc"):
		var live_npc = locations.call("get_live_npc", target_id)
		if live_npc is Node2D and is_instance_valid(live_npc):
			return live_npc
	if not is_inside_tree():
		return null
	for group_name in [&"npc_need_spot", &"npc_casual_spot", &"npc_activity_spot"]:
		for candidate in get_tree().get_nodes_in_group(group_name):
			var node := candidate as Node2D
			if node != null and NpcActionSessionModel.get_persistent_id(node) == target_id:
				return node
	return null


func begin_active_action_approach(expected_session_id: String) -> bool:
	if not is_action_session_current_for_execution(expected_session_id):
		_log_stale_action_callback("begin_approach", expected_session_id)
		return false
	if get_active_action_target() == null:
		fail_active_action(expected_session_id, "missing_action_target")
		return false
	active_action.phase = &"moving_to_target"
	if active_action.arrival_state == &"":
		active_action.arrival_state = (
			active_action.action_kind
			if active_action.action_kind != &"MoveToTarget"
			else &"Idle"
		)
	_publish_active_action()
	_action_state_reconciliation_requested = true
	_action_state_reconciliation_force_reentry = false
	return true


func request_active_action_approach(
	expected_session_id: String,
	reason: String = "move_to_action_target",
	request_priority: int = -1
) -> bool:
	if not begin_active_action_approach(expected_session_id):
		return false
	var priority := active_action.priority if request_priority < 0 else request_priority
	return _request_state_direct(
		&"MoveToTarget",
		get_active_action_target(),
		reason,
		priority,
		{
			"destination_action_kind": active_action.action_kind,
			"arrival_state": active_action.arrival_state,
			"internal_lifecycle_transition": true,
		}
	)


func finish_active_action_approach(
	expected_session_id: String,
	fallback_state_name: StringName = &"Idle"
) -> StringName:
	if not is_action_session_current_for_execution(expected_session_id):
		_log_stale_action_callback("finish_approach", expected_session_id)
		return fallback_state_name
	if active_action.phase != &"moving_to_target":
		_log_stale_action_callback("finish_approach_phase", expected_session_id)
		return fallback_state_name
	if get_active_action_target() == null:
		fail_active_action(expected_session_id, "missing_action_target")
		return fallback_state_name
	var arrival_state := active_action.arrival_state
	if arrival_state in [&"", &"MoveToTarget"]:
		arrival_state = (
			active_action.action_kind
			if active_action.action_kind != &"MoveToTarget"
			else fallback_state_name
		)
	if arrival_state in [&"", &"MoveToTarget"]:
		arrival_state = &"Idle"
	pending_state_priority = maxi(current_state_priority, active_action.priority)
	if active_action.action_kind == &"MoveToTarget":
		complete_active_action(expected_session_id, "movement_arrived")
		return arrival_state
	active_action.phase = &"executing"
	_publish_active_action()
	_action_state_reconciliation_requested = true
	_action_state_reconciliation_force_reentry = false
	return arrival_state


func register_active_action_reservation(
	reservation_id: String,
	session_id: String = ""
) -> bool:
	if active_action == null or active_action.status != NpcActionSession.Status.ACTIVE:
		return false
	if not session_id.is_empty() and active_action.session_id != session_id:
		_log_stale_action_callback("register_reservation", session_id)
		return false
	active_action.add_reservation_id(reservation_id)
	_publish_active_action()
	return true


func claim_active_action_reservation_release(
	reservation_id: String,
	session_id: String = ""
) -> bool:
	if active_action == null:
		return true
	if not session_id.is_empty() and active_action.session_id != session_id:
		_log_stale_action_callback("release_reservation", session_id)
		if active_action.reservation_ids.has(reservation_id):
			return false
		return true
	return active_action.claim_reservation_release(reservation_id)


func _consume_or_build_action_session(
	action_kind: StringName,
	actor: Node2D,
	reason: String,
	request_priority: int,
	request_context: Dictionary
) -> NpcActionSession:
	# Idle and TravelFollow belong outside the activity transaction lane. The
	# travel context coordinator reconciles the previous activity once when the
	# session becomes live, not every time Follow is entered.
	if action_kind == &"" or String(action_kind) in ["Idle", "TravelFollow"]:
		return null
	if (
		String(action_kind) == "MoveToTarget"
		and active_action != null
		and _proposed_action == null
	):
		if active_action.phase == &"moving_to_target":
			return null
	if _proposed_action != null:
		var proposed := _proposed_action
		_proposed_action = null
		return proposed
	var logical_kind := action_kind
	if String(action_kind) == "MoveToTarget":
		logical_kind = StringName(String(request_context.get(
			"destination_action_kind",
			state_after_move if state_after_move != &"" else &"MoveToTarget"
		)))
	var session_source := StringName(String(request_context.get("request_source", "")))
	if session_source == &"":
		session_source = _get_action_source(reason, actor, logical_kind)
	var descriptor := {
		"priority": request_priority,
		"source": String(session_source),
		"start_world_time": _get_world_total_hours(),
	}
	var requested_session_id := String(request_context.get(
		"action_session_id", request_context.get("session_id", "")
	)).strip_edges()
	if not requested_session_id.is_empty():
		descriptor["session_id"] = requested_session_id
	var behavior_metadata: Dictionary = {}
	for behavior_key in [
		"behavior_source",
		"behavior_reason_code",
		"behavior_feedback_text",
		"behavior_origin_value",
		"autonomous_in_place_target",
	]:
		if request_context.has(behavior_key):
			behavior_metadata[behavior_key] = request_context[behavior_key]
	for request_key in request_context:
		var request_key_text := String(request_key)
		if (
			request_key_text.begins_with("shared_activity_")
			or request_key_text.begins_with("activity_social_")
		):
			behavior_metadata[request_key_text] = request_context[request_key]
	if request_context.has("scripted_claim_token"):
		behavior_metadata["scripted_claim_token"] = int(
			request_context["scripted_claim_token"]
		)
	if not behavior_metadata.is_empty():
		descriptor["metadata"] = behavior_metadata
	if String(action_kind) == "MoveToTarget":
		descriptor["phase"] = "moving_to_target"
		var arrival_state := StringName(String(request_context.get(
			"arrival_state",
			request_context.get("destination_action_kind", "Idle")
		)))
		if logical_kind != &"MoveToTarget" and arrival_state in [&"", &"Idle", &"MoveToTarget"]:
			arrival_state = logical_kind
		elif arrival_state in [&"", &"MoveToTarget"]:
			arrival_state = logical_kind if logical_kind != &"MoveToTarget" else &"Idle"
		descriptor["arrival_state"] = String(arrival_state)
	var target_id := String(request_context.get(
		"target_persistent_id",
		NpcActionSessionModel.get_persistent_id(actor)
	)).strip_edges()
	if not target_id.is_empty():
		descriptor["target_persistent_id"] = target_id
	return NpcActionSessionModel.create(
		_get_action_owner_id(), logical_kind, StringName(descriptor["source"]), actor, descriptor
	)


func _ensure_action_session_spot_reservation(session: NpcActionSession) -> Dictionary:
	if session == null:
		return {"accepted": true, "status": "not_required"}
	var spot_id := session.spot_id
	if spot_id == &"":
		spot_id = _get_stable_spot_id(session.get_live_target())
		if spot_id == &"":
			return {"accepted": true, "status": "not_required"}
		session.spot_id = spot_id
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("try_claim_spot"):
		return {"accepted": false, "status": "spot_reservation_service_missing"}
	var purpose := StringName(String(session.metadata.get("reservation_purpose", "activity")))
	var result: Dictionary = simulator.call(
		"try_claim_spot",
		StringName(_get_action_owner_id()),
		session.session_id,
		spot_id,
		purpose
	)
	if bool(result.get("accepted", false)):
		session.add_reservation_id(String(result.get("reservation_id", "")))
	return result


func _get_stable_spot_id(candidate: Node) -> StringName:
	return StringName(NpcIdentity.get_spot_id(candidate))


func _release_replaced_spot_reservations(
	previous_ids: PackedStringArray,
	retained_ids: PackedStringArray,
	session_id: String
) -> void:
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("release_spot_reservation"):
		return
	for reservation_id in previous_ids:
		if retained_ids.has(reservation_id):
			continue
		simulator.call(
			"release_spot_reservation",
			String(reservation_id),
			StringName(_get_action_owner_id()),
			session_id
		)


func _active_action_id_matches(session_id: String) -> bool:
	return active_action != null and not session_id.is_empty() and active_action.session_id == session_id


func _release_active_action_reservations_once(
	reason: String,
	preserve_persistent_activity_reservations: bool = false
) -> void:
	if active_action == null:
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	var persistent_activity_reservation_ids := PackedStringArray()
	if preserve_persistent_activity_reservations:
		# A scheduled activity outlives individual live execution cycles and remains
		# responsible for releasing its own spot when the persistent record finishes.
		persistent_activity_reservation_ids = _get_persistent_activity_reservation_ids()
	for reservation_id in active_action.reservation_ids:
		var reservation_text := String(reservation_id)
		if persistent_activity_reservation_ids.has(reservation_text):
			continue
		if active_action.released_reservation_ids.has(reservation_text):
			continue
		var released := false
		if simulator != null and simulator.has_method("release_spot_reservation"):
			released = bool(simulator.call(
				"release_spot_reservation",
				reservation_text,
				StringName(_get_action_owner_id()),
				active_action.session_id
			))
		elif reservation_text.begins_with("spot:") and simulator != null:
			released = bool(simulator.call(
				"release_scheduled_activity_claim",
				StringName(reservation_text.trim_prefix("spot:")),
				reason,
				active_action.session_id,
				StringName(_get_action_owner_id())
			))
		if released:
			active_action.claim_reservation_release(reservation_text)
	if (
		persistent_activity_reservation_ids.is_empty()
		and simulator != null
		and simulator.has_method("release_session_spot_reservations")
	):
		simulator.call(
			"release_session_spot_reservations",
			StringName(_get_action_owner_id()),
			active_action.session_id
		)


func _get_persistent_activity_reservation_ids() -> PackedStringArray:
	var retained := PackedStringArray()
	if active_action == null or active_action.session_id.is_empty():
		return retained
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_record_snapshot"):
		return retained
	var record: Dictionary = locations.call(
		"get_record_snapshot", _get_action_owner_id()
	)
	var activity_value = record.get("activity", {})
	if not (activity_value is Dictionary) or activity_value.is_empty():
		return retained
	var activity: Dictionary = activity_value
	if NpcActionSessionModel._descriptor_session_id(activity) != active_action.session_id:
		return retained
	if String(activity.get("status", "active")) in [
		"completed", "failed", "cancelled", "cancelling",
	]:
		return retained
	var reservation_values = activity.get("reservation_ids", [])
	if not (reservation_values is Array or reservation_values is PackedStringArray):
		return retained
	for reservation_value in reservation_values:
		var reservation_id := String(reservation_value).strip_edges()
		if not reservation_id.is_empty() and active_action.reservation_ids.has(reservation_id):
			retained.append(reservation_id)
	return retained


func _get_action_source(reason: String, actor: Node2D, action_kind: StringName) -> StringName:
	var lower_reason := reason.to_lower()
	if String(action_kind) in ["Fight", "Flee", "Downed", "Collapse", "DisabledDead", "LookForMonster"]:
		return NpcBehaviorIntentModel.SOURCE_EMERGENCY
	if lower_reason.contains("world_activity") or lower_reason.contains("schedule"):
		return NpcBehaviorIntentModel.SOURCE_SCHEDULE
	if lower_reason.contains("social") or action_kind == &"LookForTalkTarget":
		return NpcBehaviorIntentModel.SOURCE_SOCIAL_AI
	if action_kind == &"Talk":
		return (
			NpcBehaviorIntentModel.SOURCE_PLAYER
			if actor != null and actor.is_in_group("player")
			else NpcBehaviorIntentModel.SOURCE_SOCIAL_AI
		)
	if (
		lower_reason.contains("value")
		or lower_reason.contains("need")
		or (
			lower_reason.ends_with("_target")
			and String(action_kind) in ["Work", "Eat", "Rest", "Recreation", "Sleep"]
		)
		or String(action_kind) in ["Eat", "Rest", "Sleep"]
	):
		return NpcBehaviorIntentModel.SOURCE_NEED
	if actor != null and actor.is_in_group("player"):
		return NpcBehaviorIntentModel.SOURCE_PLAYER
	return NpcBehaviorIntentModel.SOURCE_MANUAL


func _get_action_owner_id() -> String:
	# Action/session ownership still supports identity-free live legacy NPCs.
	# Use the centralized resolver so their fallback remains the same path-based
	# key used before canonical identity was introduced.
	var npc_id := NpcIdentity.get_actor_id(npc, true, false)
	if not npc_id.is_empty():
		return npc_id
	return _get_npc_label()


func _get_world_total_hours() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_total_hours"):
		return float(world_time.call("get_total_hours"))
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		return float(snapshot.get("total_hours", 0.0))
	return 0.0


func _publish_active_action(sync_record: bool = true) -> void:
	var descriptor := get_active_action_descriptor()
	action_session_changed.emit(descriptor.duplicate(true))
	if not sync_record:
		return
	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("sync_live_action_descriptor"):
		locations.call("sync_live_action_descriptor", _get_action_owner_id(), npc, descriptor)


func _log_action_session(result: String, reason: String) -> void:
	if not OS.is_debug_build() or active_action == null:
		return
	var diagnostics: Dictionary = {}
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("inspect_action_spot_reservations"):
		diagnostics = simulator.call(
			"inspect_action_spot_reservations",
			StringName(_get_action_owner_id()),
			active_action.session_id,
			active_action.spot_id,
			active_action.reservation_ids,
			StringName(String(active_action.metadata.get("reservation_purpose", "activity")))
		)
	if _verbose_npc_logging_enabled():
		print("NPC action: npc=%s session=%s action=%s source=%s status=%s spot=%s reservations=%s owned=%s missing=%s orphaned=%s reason=%s" % [
			_get_npc_label(), active_action.session_id, String(active_action.action_kind),
			String(active_action.source), result, String(active_action.spot_id),
			str(diagnostics.get("actual_reservation_ids", Array(active_action.reservation_ids))),
			str(diagnostics.get("owns_named_spot", active_action.spot_id == &"")),
			str(diagnostics.get("missing_reservation_ids", [])),
			str(diagnostics.get("ledger_ids_absent_from_action", [])),
			reason,
		])
	if result == "active" and active_action.spot_id != &"" and not bool(
		diagnostics.get("owns_named_spot", false)
	):
		push_warning("NPC action names a spot without owning it: npc=%s session=%s spot=%s" % [
			_get_npc_label(), active_action.session_id, String(active_action.spot_id)
		])


func _log_stale_action_callback(callback_name: String, session_id: String) -> void:
	if OS.is_debug_build():
		print("NPC action stale callback: npc=%s callback=%s session=%s active=%s" % [
			_get_npc_label(), callback_name, session_id, get_active_action_session_id(),
		])


func get_current_activity_descriptor() -> Dictionary:
	return _get_state_activity_descriptor(current_state)


func is_following_activity_descriptor(requested_descriptor: Dictionary) -> bool:
	if NpcActivityIdentity.matches(get_current_activity_descriptor(), requested_descriptor):
		return true

	# The primary descriptor remains the scheduled activity; compare Talk separately
	# so a social plan only matches its actual overlay partner.
	if interaction_overlay != null:
		return NpcActivityIdentity.matches(
			_get_state_activity_descriptor(interaction_overlay),
			requested_descriptor
		)

	return false


func _get_state_activity_descriptor(state: NpcState) -> Dictionary:
	if state == null:
		return {}

	var action_kind := StringName(state.name)
	var activity_target: Node2D
	if String(action_kind) == "MoveToTarget":
		action_kind = active_action.action_kind if active_action != null else &"MoveToTarget"
		activity_target = get_move_target()
	else:
		match String(action_kind):
			"Work": activity_target = get_work_target()
			"Eat": activity_target = get_eat_target()
			"Rest": activity_target = get_rest_target()
			"Recreation": activity_target = get_recreation_target()
			"RoutineTask": activity_target = get_routine_task_target()
			"Sleep": activity_target = get_sleep_target()
			"InvitePlayer": activity_target = get_invitation_spot()
			"Talk":
				activity_target = get_talk_target()
				var active_talk_partner = _get_property_if_present(state, &"talk_partner", null)
				if active_talk_partner is Node2D and is_instance_valid(active_talk_partner):
					activity_target = active_talk_partner
			"LookForTalkTarget":
				activity_target = get_action_target(&"LookForTalkTarget", target)
				var active_search_target = _get_property_if_present(state, &"talk_target", null)
				if active_search_target is Node2D and is_instance_valid(active_search_target):
					activity_target = active_search_target
			_:
				activity_target = get_active_action_target()
				if activity_target == null:
					activity_target = target

	if not is_instance_valid(activity_target):
		activity_target = null
	var descriptor := NpcActivityIdentity.describe(action_kind, activity_target)
	if state == interaction_overlay and active_interaction_session != null:
		descriptor.merge(active_interaction_session.to_descriptor(), true)
	elif active_action != null and String(active_action.action_kind) == String(action_kind):
		var action_descriptor := active_action.to_descriptor()
		descriptor.merge(action_descriptor, true)
		# Activity matching distinguishes NPC targets from spots. The session stores one
		# stable target ID, so expose it under the appropriate compatibility key too.
		if not active_action.target_persistent_id.is_empty():
			if String(action_kind) in ["Talk", "LookForTalkTarget"]:
				descriptor["target_npc_id"] = active_action.target_persistent_id
			elif active_action.spot_id == &"":
				descriptor["spot_id"] = active_action.target_persistent_id
	return descriptor


func _get_state_request_activity_descriptor(
	requested_state: NpcState,
	actor: Node2D,
	request_context: Dictionary
) -> Dictionary:
	if requested_state == null:
		return {}
	var action_kind := StringName(requested_state.name)
	var activity_target := actor
	if String(action_kind) == "MoveToTarget":
		action_kind = StringName(request_context.get("destination_action_kind", &"MoveToTarget"))
	else:
		var target_key := _activity_target_context_key(action_kind)
		if target_key != &"" and request_context.has(target_key):
			activity_target = request_context[target_key] as Node2D
	if not is_instance_valid(activity_target):
		activity_target = null
	return NpcActivityIdentity.describe(action_kind, activity_target)


func _state_request_supports_identity_reentry(requested_state: NpcState) -> bool:
	if requested_state == null:
		return false
	return String(requested_state.name) in [
		"MoveToTarget",
		"Work",
		"Eat",
		"Rest",
		"Recreation",
		"RoutineTask",
		"Sleep",
		"LookForTalkTarget",
		"InvitePlayer",
	]


func _activity_target_context_key(action_kind: StringName) -> StringName:
	match String(action_kind):
		"Work":
			return &"work_target"
		"Eat":
			return &"eat_target"
		"Rest":
			return &"rest_target"
		"Recreation":
			return &"recreation_target"
		"RoutineTask":
			return &"routine_task_target"
		"Sleep":
			return &"sleep_target"
		"Talk":
			return &"talk_target"
		"InvitePlayer":
			return &"invitation_spot"
	return &""


func _get_property_if_present(object: Object, property_name: StringName, fallback):
	if object == null:
		return fallback
	for property in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return object.get(property_name)
	return fallback


func _reject_state_request(state_name: StringName, rejection_reason: String) -> bool:
	last_state_request_failure_reason = rejection_reason
	_breadcrumb(
		"npc_state:request_reject",
		"%s state=%s reason=%s" % [_get_npc_label(), String(state_name), rejection_reason]
	)
	if OS.is_debug_build():
		var session_id := (
			_proposed_action.session_id
			if _proposed_action != null
			else get_active_action_session_id()
		)
		print(
			"NPC state rejected: npc=%s session=%s state=%s reason=%s" % [
				_get_npc_label(),
				session_id,
				String(state_name),
				rejection_reason,
			]
		)
	state_request_failed.emit(state_name, rejection_reason)
	return false


func get_last_state_request_failure_reason() -> String:
	return last_state_request_failure_reason


func notify_target_seen(seen_target: Node2D) -> void:
	if not active or seen_target == null or not is_instance_valid(seen_target):
		return
	if seen_target == npc:
		return
	if is_ignoring_player_interaction(seen_target):
		return
	if not perceived_targets.has(seen_target):
		perceived_targets.append(seen_target)

	if current_state != null:
		var requested_state := current_state.target_seen(seen_target)
		if requested_state != null and change_state(requested_state, "target_seen"):
			return

	if _maybe_react_to_seen_monster(seen_target):
		return
	if _maybe_fight_from_seen_target(seen_target):
		return
	if _maybe_flee_from_seen_player(seen_target):
		return
	if _maybe_flee_from_seen_npc(seen_target):
		return

	if evaluate_value_reactions(seen_target, {}):
		return

	if react_to_player_on_seen and seen_target.is_in_group("player"):
		request_state(player_seen_state_name, seen_target, "player_seen", 10)


func _maybe_react_to_seen_monster(seen_target: Node2D) -> bool:
	if not react_to_seen_monsters:
		return false
	if not is_monster_target(seen_target):
		return false

	return request_monster_reaction(
		seen_target,
		"monster_seen",
		seen_monster_reaction_priority
	)


func request_monster_reaction(
	monster: Node2D,
	reason: String = "monster_reaction",
	request_priority: int = -1
) -> bool:
	if not active or not react_to_seen_monsters:
		return false
	if monster == null or not is_instance_valid(monster):
		return false
	if monster == npc:
		return false
	if not is_monster_target(monster):
		return false

	var applied_priority := seen_monster_reaction_priority
	if request_priority >= 0:
		applied_priority = request_priority

	match seen_monster_reaction:
		MonsterSightReaction.NONE:
			return false
		MonsterSightReaction.FIGHT:
			return _request_monster_fight(monster, reason, applied_priority)
		MonsterSightReaction.FLEE:
			if seen_monster_flee_state_name == &"":
				return false
			return request_state(seen_monster_flee_state_name, monster, reason, applied_priority)
		MonsterSightReaction.SCREAM:
			if seen_monster_scream_state_name == &"":
				return false
			return request_state(seen_monster_scream_state_name, monster, reason, applied_priority)

	return false


func _request_monster_fight(monster: Node2D, reason: String, request_priority: int) -> bool:
	if seen_monster_fight_state_name == &"":
		return false

	if not can_start_fight_with(monster):
		return false
	if is_primary_state(&"Fight"):
		return true

	return request_state(seen_monster_fight_state_name, monster, reason, request_priority)


func can_start_fight_with(candidate: Node2D) -> bool:
	var fight_state := get_state(&"Fight")
	if fight_state == null:
		return false
	if fight_state.has_method("can_start_fight_with"):
		return bool(fight_state.call("can_start_fight_with", candidate))
	return true


func is_monster_target(candidate: Node) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false

	for group_name in monster_target_groups:
		if candidate.is_in_group(String(group_name)):
			return true

	return false


func should_look_for_monster_after_fight() -> bool:
	return (
		react_to_seen_monsters
		and look_for_monster_after_fight
		and look_for_monster_state_name != &""
		and get_state(look_for_monster_state_name) != null
		and seen_monster_reaction != MonsterSightReaction.NONE
	)


func _maybe_fight_from_seen_target(seen_target: Node2D) -> bool:
	if seen_target == null or not is_instance_valid(seen_target):
		return false

	var relationship_anger_requires_fight := false
	if npc != null and npc.has_method("should_fight_actor"):
		relationship_anger_requires_fight = bool(
			npc.call("should_fight_actor", seen_target)
		)
	elif (
		seen_target.is_in_group("npc")
		and npc != null
		and npc.has_method("should_fight_npc")
	):
		# Compatibility for NPC implementations that predate the generic actor API.
		relationship_anger_requires_fight = bool(
			npc.call("should_fight_npc", seen_target)
		)
	if relationship_anger_requires_fight:
		var fight_priority := _get_anger_fight_priority()
		if _higher_priority_value_reaction_blocks_combat(seen_target, fight_priority):
			return false
		if not can_start_fight_with(seen_target):
			return false
		if is_primary_state(&"Fight"):
			return true

		return request_state(
			&"Fight",
			seen_target,
			"relationship_anger_seen",
			fight_priority
		)

	return false


func _maybe_flee_from_seen_player(seen_target: Node2D) -> bool:
	# Player fear is directed relationship data, never a generic NPC value.
	if not flee_from_seen_player_when_afraid:
		return false

	if seen_target == null or not seen_target.is_in_group("player"):
		return false

	if seen_player_flee_state_name == &"":
		return false

	if (
		npc == null
		or not npc.has_method("should_flee_from_actor")
		or not bool(npc.call("should_flee_from_actor", seen_target))
	):
		return false

	return request_state(
		seen_player_flee_state_name,
		seen_target,
		"fear_seen_player",
		seen_player_flee_priority
	)


func _maybe_flee_from_seen_npc(seen_target: Node2D) -> bool:
	if seen_target == null or not seen_target.is_in_group("npc"):
		return false
	if npc == null or not npc.has_method("should_flee_from_npc"):
		return false
	if npc.has_method("should_fight_npc") and bool(npc.call("should_fight_npc", seen_target)):
		return false
	if not bool(npc.call("should_flee_from_npc", seen_target)):
		return false

	return request_state(
		seen_player_flee_state_name,
		seen_target,
		"fear_seen_npc",
		seen_player_flee_priority
	)


func notify_target_lost(lost_target: Node2D) -> void:
	if not active or lost_target == null:
		return

	if current_state != null:
		var requested_state := current_state.target_lost(lost_target)
		if requested_state != null:
			var action_descriptor := get_active_action_descriptor()
			var intent_descriptor := (
				behavior_controller.get_current_intent_descriptor()
				if behavior_controller != null
				else {}
			)
			if (
				change_state(requested_state, "target_lost")
				and memory_observer != null
			):
				memory_observer.observe_intention_target_lost(
					action_descriptor,
					intent_descriptor,
					lost_target
				)

	perceived_targets.erase(lost_target)


func select_combat_target(new_target: Node2D) -> void:
	if new_target != null and not is_instance_valid(new_target):
		new_target = null
	if new_target == npc:
		new_target = null
	selected_threat = new_target
	target_changed.emit(selected_threat)


func get_selected_threat() -> Node2D:
	if selected_threat != null and is_instance_valid(selected_threat) and selected_threat != npc:
		return selected_threat
	selected_threat = null
	return null


func get_perceived_targets() -> Array[Node2D]:
	var live_targets: Array[Node2D] = []
	for candidate in perceived_targets:
		if candidate != null and is_instance_valid(candidate) and candidate != npc:
			live_targets.append(candidate)
	perceived_targets = live_targets
	return live_targets.duplicate()


func get_active_target() -> Node2D:
	# Compatibility name: intentional target only. There is deliberately no player fallback.
	var action_target := get_active_action_target()
	if action_target != null:
		return action_target
	return target if target != null and is_instance_valid(target) else null


func is_in_state(state_name: StringName) -> bool:
	if interaction_overlay != null and String(interaction_overlay.name) == String(state_name):
		return true
	return is_primary_state(state_name)


func is_primary_state(state_name: StringName) -> bool:
	return current_state != null and String(current_state.name) == String(state_name)


func can_transition_to_state(
	state_name: StringName,
	request_priority: int = 0
) -> bool:
	var next_state := get_state(state_name)
	if next_state == null or current_state == next_state:
		return false
	if current_state == null:
		return true
	return current_state.can_exit_to(next_state, request_priority)


func get_pending_primary_state_name() -> StringName:
	if _pending_primary_state == null:
		return &""
	return StringName(_pending_primary_state.name)


func get_flee_fear_threshold() -> float:
	return _get_flee_fear_threshold()


func get_fight_anger_threshold() -> float:
	return _get_anger_fight_threshold()


func evaluate_persistent_combat_reactions(actor: Node2D = null) -> bool:
	if not active or not _value_reactions_enabled():
		return false

	var fight_actor := actor
	if fight_actor == null:
		fight_actor = get_selected_threat()
	if fight_actor == null or not is_instance_valid(fight_actor):
		return false

	return _maybe_fight_from_seen_target(fight_actor)


func assign_move_target(new_target: Node2D, arrive_state_name: StringName = &"Idle") -> bool:
	# Compatibility wrapper: creates one destination action and starts its movement phase.
	if new_target == null or not is_instance_valid(new_target):
		return false
	var arrival_state := arrive_state_name if arrive_state_name != &"" else &"Idle"
	if arrival_state == &"MoveToTarget":
		arrival_state = &"Idle"
	var destination_kind := arrival_state if arrival_state != &"Idle" else &"MoveToTarget"
	var session := NpcActionSessionModel.create(
		_get_action_owner_id(), destination_kind, &"manual", new_target,
		{
			"priority": 20,
			"phase": "moving_to_target",
			"arrival_state": String(arrival_state),
		}
	)
	_proposed_action = session
	var accepted := _request_state_direct(
		&"MoveToTarget",
		new_target,
		"move_target",
		20,
		{
			"destination_action_kind": destination_kind,
			"arrival_state": arrival_state,
		}
	)
	if _proposed_action == session:
		_proposed_action = null
	return accepted


func assign_work_target(new_target: Node2D, request_priority: int = 20) -> bool:
	# Stores a work spot so Work can walk there before clearing its work_needed.
	if new_target == null or not is_instance_valid(new_target):
		return false

	return _request_state_direct(
		&"Work",
		new_target,
		"work_target",
		request_priority,
		{}
	)


func assign_eat_target(new_target: Node2D, request_priority: int = 20) -> bool:
	# Stores an eat spot so Eat can walk there before lowering hunger.
	if not _can_assign_eat_target(new_target):
		return _reject_state_request(&"Eat", "invalid_eat_target")

	return _request_state_direct(
		&"Eat",
		new_target,
		"eat_target",
		request_priority,
		{}
	)


func _can_assign_eat_target(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	# Self is used only by Eat's inventory-food path. All other assignments must
	# prove that they are authored Eat spots before an action session is created.
	if candidate == npc:
		return true
	var requested_value_name := &"hunger"
	var eat_state := get_state(&"Eat") as NpcStateEat
	if eat_state != null:
		requested_value_name = eat_state.eat_value_name
	return (
		candidate.has_method("can_serve_npc_need")
		and bool(candidate.call(
			"can_serve_npc_need", npc, &"Eat", requested_value_name
		))
	)


func assign_rest_target(new_target: Node2D, request_priority: int = 20) -> bool:
	# Stores a fatigue-rest spot without changing the NPC's sleep need.
	if not _can_assign_casual_activity_target(new_target, &"Rest"):
		return false

	return _request_state_direct(
		&"Rest",
		new_target,
		"rest_target",
		request_priority,
		{}
	)


func assign_recreation_target(new_target: Node2D, request_priority: int = 20) -> bool:
	# Stores a recreation spot so the NPC can walk there before lowering boredom.
	if not _can_assign_casual_activity_target(new_target, &"Recreation"):
		return false

	return _request_state_direct(
		&"Recreation",
		new_target,
		"recreation_target",
		request_priority,
		{}
	)


func _can_assign_casual_activity_target(
	candidate: Node2D,
	activity_state: StringName
) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and candidate.has_method("can_serve_npc_casual_activity")
		and bool(candidate.call("can_serve_npc_casual_activity", npc, activity_state))
	)


func assign_routine_task_target(new_target: Node2D, request_priority: int = 20) -> bool:
	# Stores a generic routine spot, such as shower or other non-work tasks.
	if new_target == null or not is_instance_valid(new_target):
		return false

	return _request_state_direct(
		&"RoutineTask",
		new_target,
		"routine_task_target",
		request_priority,
		{}
	)


func assign_sleep_target(new_target: Node2D, request_priority: int = 20) -> bool:
	# Stores a sleep spot so Sleep can walk there before starting the long timer.
	if new_target == null or not is_instance_valid(new_target):
		return false

	return _request_state_direct(
		&"Sleep",
		new_target,
		"sleep_target",
		request_priority,
		{}
	)


func assign_invitation_spot(new_target: Node2D, request_priority: int = 75) -> bool:
	# Stores a cooperative prompt spot; InvitePlayer will find the live player itself.
	if (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_MAGIC_LESSON_ACTIVITY
	):
		_breadcrumb("npc_state:invitation_disabled", _get_npc_label())
		return false
	if new_target == null or not is_instance_valid(new_target):
		return false

	return _request_state_direct(
		&"InvitePlayer",
		new_target,
		"invitation_spot",
		request_priority,
		{}
	)


func request_talk(
	new_target: Node2D,
	request_priority: int = -1,
	require_mutual_handshake: bool = true,
	initiating_source: StringName = &"",
	talk_context: Dictionary = {}
) -> bool:
	# Starts Talk with a known partner, using a two-sided handshake for NPC partners.
	var priority := request_priority
	if priority < 0:
		priority = npc_talk_handshake_priority

	var source := _resolve_talk_initiating_source(initiating_source, new_target, "talk")
	return _request_talk_state(
		new_target, "talk", priority, require_mutual_handshake, source,
		talk_context
	)


func begin_player_interaction_hold(
	actor: Node2D,
	hold_seconds: float = -1.0,
	bypass_social_refusal: bool = false
) -> bool:
	var gate := can_begin_player_interaction(actor, bypass_social_refusal)
	if not bool(gate.get("accepted", false)):
		return false

	var duration := default_player_interaction_hold_seconds if hold_seconds < 0.0 else hold_seconds
	player_interaction_hold_timer = maxf(duration, 0.0)
	player_interaction_hold_actor = actor
	last_event_actor = actor
	_process_player_interaction_hold()
	return true


func can_begin_player_interaction(
	actor: Node2D = null,
	bypass_social_refusal: bool = false
) -> Dictionary:
	_last_player_interaction_memory_policy = {}
	if actor != null and not _is_player_interaction_actor(actor):
		return {"accepted": false, "reason": "invalid_player"}
	if not active or npc == null or not is_instance_valid(npc):
		return {"accepted": false, "reason": "npc_inactive"}
	var directed_favor := _get_player_interaction_directed_favor(actor)
	if _player_interaction_bypasses_all_refusals(actor, directed_favor):
		return {
			"accepted": true,
			"reason": "",
			"favor_bypass": &"all",
			"directed_favor": directed_favor,
		}
	if _has_scripted_control_claim():
		return {"accepted": false, "reason": "npc_scripted_controlled"}
	if (
		actor != null
		and is_ignoring_player_interaction(actor)
		and not _player_interaction_bypasses_repeat_limits(actor)
	):
		return {"accepted": false, "reason": "npc_ignoring_player"}
	if get_value(&"hp", 1.0) <= 0.0:
		return {"accepted": false, "reason": "npc_dead"}
	if get_value(&"disabled", 0.0) >= 1.0:
		return {"accepted": false, "reason": "npc_disabled"}

	var scene_handoff_reason := _get_scene_handoff_interaction_block_reason()
	if not scene_handoff_reason.is_empty():
		return {"accepted": false, "reason": scene_handoff_reason}

	var state_reason := _get_current_state_interaction_block_reason(actor)
	if not state_reason.is_empty():
		return {"accepted": false, "reason": state_reason}
	if _npc_is_knocked_out():
		return {"accepted": false, "reason": "npc_knocked_out"}

	var actor_id := NpcPlayerInteractionMemoryPolicyModel.get_stable_actor_id(
		actor
	)
	var remembering_npc_id := (
		NpcPlayerInteractionMemoryPolicyModel.get_stable_actor_id(npc)
	)
	var memory_decision := _player_interaction_memory_policy.evaluate_actor(
		short_term_memory,
		actor_id,
		_get_world_total_hours(),
		{
			"remembering_npc_id": remembering_npc_id,
			"recent_harm_interaction_delay_game_hours": (
				recent_harm_interaction_delay_game_hours
			),
		}
	)
	_last_player_interaction_memory_policy = memory_decision.duplicate(true)
	if not bool(memory_decision.get("allowed", true)):
		return {
			"accepted": false,
			"reason": "npc_recently_harmed_by_player",
			"memory_policy": memory_decision.duplicate(true),
		}

	if not bypass_social_refusal:
		var social_decision := _evaluate_player_interaction_social_acceptance(
			actor,
			StringName(actor_id),
			StringName(remembering_npc_id)
		)
		if not bool(social_decision.get("accepted", true)):
			return {
				"accepted": false,
				"reason": String(social_decision.get(
					"reason_code",
					&"player_social_request_rejected"
				)),
				"social_acceptance": social_decision.duplicate(true),
			}

	var accepted_result := {"accepted": true, "reason": ""}
	if bypass_social_refusal:
		accepted_result["social_refusal_bypassed"] = true
	if (
		directed_favor
		>= player_interaction_repeat_bypass_minimum_favor
	):
		accepted_result["favor_bypass"] = &"repeat"
		accepted_result["directed_favor"] = directed_favor
	return accepted_result


func _evaluate_player_interaction_social_acceptance(
	actor: Node2D,
	actor_id: StringName,
	remembering_npc_id: StringName
) -> Dictionary:
	if actor == null or actor_id == &"" or remembering_npc_id == &"":
		return {"accepted": true, "reason_code": &""}
	var conversation_memory := _social_memory_policy.evaluate_candidate(
		short_term_memory,
		actor_id,
		_get_world_total_hours(),
		{
			"remembering_npc_id": remembering_npc_id,
			"recent_refusal_retry_delay_game_hours": 0.0,
			"recent_harm_social_delay_game_hours": 0.0,
			"recent_conversation_repeat_delay_game_hours": (
				0.0
				if _player_interaction_bypasses_repeat_limits(actor)
				else recent_conversation_repeat_delay_game_hours
			),
		}
	)
	var relationships := get_node_or_null("/root/Relationships")
	var npc_relationship_id := _get_relationship_id_for_actor(
		relationships,
		npc,
		String(remembering_npc_id)
	)
	var actor_relationship_id := _get_relationship_id_for_actor(
		relationships,
		actor,
		String(actor_id)
	)
	return _social_acceptance_policy.evaluate(
		actor_id,
		remembering_npc_id,
		{
			"social_memory_decision": conversation_memory,
			"relationship": _get_directed_relationship_snapshot(
				relationships,
				npc_relationship_id,
				actor_relationship_id
			),
			"minimum_favor": npc_social_acceptance_minimum_favor,
			"maximum_anger": npc_social_acceptance_maximum_anger,
			"maximum_fear": npc_social_acceptance_maximum_fear,
		}
	)


func present_player_interaction_refusal(
	reason_code: StringName,
	actor: Node2D = null
) -> Dictionary:
	if (
		get_value(&"hp", 1.0) <= 0.0
		or get_value(&"disabled", 0.0) >= 1.0
		or _npc_is_knocked_out()
		or _current_state_is(&"Collapse")
	):
		return {"accepted": false, "reason": &"npc_cannot_speak"}
	if (
		feedback_adapter == null
		or not feedback_adapter.has_method("present_player_interaction_refusal")
	):
		return {"accepted": false, "reason": &"feedback_adapter_missing"}
	var directed_favor := _get_player_interaction_directed_favor(actor)
	return feedback_adapter.call(
		"present_player_interaction_refusal",
		reason_code,
		{
			"softened": (
				directed_favor
				>= player_interaction_soft_refusal_minimum_favor
			),
			"directed_favor": directed_favor,
		}
	)


func get_player_interaction_memory_debug_descriptor() -> Dictionary:
	if _last_player_interaction_memory_policy.is_empty():
		return {}
	var descriptor := _last_player_interaction_memory_policy.duplicate(true)
	var details = descriptor.get("details", {})
	if details is Dictionary and details.has("retry_game_hours"):
		var remaining := maxf(
			float(details.get("retry_game_hours", 0.0))
				- _get_world_total_hours(),
			0.0
		)
		descriptor["remaining_retry_hours"] = remaining
		if remaining <= 0.0:
			return {}
	return descriptor


func end_player_interaction_hold(actor: Node2D = null) -> void:
	if actor != null and player_interaction_hold_actor != actor:
		return

	player_interaction_hold_timer = 0.0
	player_interaction_hold_actor = null
	if npc != null:
		npc.velocity.x = 0.0


func _invalidate_player_interaction_hold(reason: String) -> void:
	player_interaction_hold_timer = 0.0
	player_interaction_hold_actor = null
	if npc != null:
		npc.velocity.x = 0.0
	player_interaction_invalidated.emit(reason)


func _invalidate_player_interaction_for_current_state() -> void:
	var state_reason := _get_current_state_interaction_block_reason(player_interaction_hold_actor)
	if state_reason.is_empty():
		return

	_invalidate_player_interaction_hold(state_reason)


func _get_current_state_interaction_block_reason(actor: Node2D = null) -> String:
	if current_state == null:
		return "npc_state_unavailable"
	if current_state.has_method("get_player_interaction_block_reason"):
		var custom_reason := String(current_state.call("get_player_interaction_block_reason", actor))
		if not custom_reason.is_empty():
			return custom_reason

	return String(PLAYER_INTERACTION_BLOCKED_STATE_REASONS.get(String(current_state.name), ""))


func _npc_is_knocked_out() -> bool:
	if _current_state_is(&"Downed"):
		return true
	if npc != null:
		var downed_value = _get_npc_property_if_exists(&"is_downed", false)
		if typeof(downed_value) == TYPE_BOOL and bool(downed_value):
			return true

	return get_value(&"knockout", 0.0) >= 100.0


func _get_scene_handoff_interaction_block_reason() -> String:
	if not is_inside_tree():
		return "npc_scene_handoff"

	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and bool(scene_loader.get("loading_in_progress")):
		return "npc_scene_handoff"

	var runtime := get_node_or_null("/root/PlayerRuntime")
	if runtime != null and runtime.has_method("has_pending_player_data"):
		if bool(runtime.call("has_pending_player_data")):
			return "npc_scene_handoff"

	return ""


func start_player_interaction_cooldown(actor: Node2D, cooldown_seconds: float = -1.0) -> bool:
	if not _is_player_interaction_actor(actor):
		return false

	var duration := (
		default_player_interaction_cooldown_seconds
		if cooldown_seconds < 0.0
		else cooldown_seconds
	)
	player_interaction_cooldown_timer = maxf(
		player_interaction_cooldown_timer,
		maxf(duration, 0.0)
	)
	player_interaction_cooldown_actor = actor
	end_player_interaction_hold(actor)

	return true


func is_ignoring_player_interaction(actor: Node2D = null) -> bool:
	if player_interaction_cooldown_timer <= 0.0:
		return false
	if actor == null:
		return true

	return _is_player_interaction_actor(actor)


func can_accept_talk_request(candidate: Node2D, request_priority: int = -1) -> bool:
	return bool(evaluate_npc_talk_request(candidate, {
		"request_priority": request_priority,
		"record_debug_descriptor": false,
	}).get("accepted", false))


func evaluate_npc_talk_request(
	requester: Node2D,
	request_context: Dictionary = {}
) -> Dictionary:
	var requester_id := _get_social_candidate_id(requester)
	var candidate_id := _get_social_candidate_id(npc)
	var priority := int(request_context.get(
		"request_priority",
		npc_talk_handshake_priority
	))
	if priority < 0:
		priority = npc_talk_handshake_priority
	var availability := _evaluate_npc_talk_availability(
		requester,
		StringName(requester_id),
		StringName(candidate_id),
		priority,
		request_context
	)
	var relationships := get_node_or_null("/root/Relationships")
	var candidate_relationship_id := _get_relationship_id_for_actor(
		relationships,
		npc,
		candidate_id
	)
	var requester_relationship_id := _get_relationship_id_for_actor(
		relationships,
		requester,
		requester_id
	)
	var decision := _social_acceptance_policy.evaluate(
		StringName(requester_id),
		StringName(candidate_id),
		{
			"availability": availability,
			"social_memory_decision": (
				get_autonomous_social_memory_decision(requester)
				if bool(availability.get("available", false))
				else {}
			),
			"relationship": _get_directed_relationship_snapshot(
				relationships,
				candidate_relationship_id,
				requester_relationship_id
			),
			"minimum_favor": npc_social_acceptance_minimum_favor,
			"maximum_anger": npc_social_acceptance_maximum_anger,
			"maximum_fear": npc_social_acceptance_maximum_fear,
		}
	)
	decision["availability"] = availability.duplicate(true)
	decision["evaluated_game_hours"] = _get_world_total_hours()
	decision["evaluated_at_usec"] = Time.get_ticks_usec()
	if bool(request_context.get("record_debug_descriptor", true)):
		_last_social_acceptance_descriptor = decision.duplicate(true)
	return decision.duplicate(true)


func get_social_acceptance_debug_descriptor() -> Dictionary:
	return _last_social_acceptance_descriptor.duplicate(true)


func _evaluate_npc_talk_availability(
	requester: Node2D,
	requester_id: StringName,
	candidate_id: StringName,
	request_priority: int,
	request_context: Dictionary
) -> Dictionary:
	if requester == null or not is_instance_valid(requester):
		return _social_availability(false, &"invalid_request", &"invalid_requester")
	if not requester.is_in_group("npc"):
		return _social_availability(false, &"invalid_request", &"requester_not_npc")
	if requester == npc or requester_id == candidate_id:
		return _social_availability(false, &"invalid_request", &"self_request")
	if requester_id == &"" or candidate_id == &"":
		return _social_availability(false, &"invalid_request", &"invalid_social_identity")
	if bool(request_context.get("require_current_session", false)):
		var expected_session_id := String(request_context.get("session_id", "")).strip_edges()
		var request_source := StringName(String(request_context.get("source", &"social_ai")))
		var requester_machine := _get_talk_machine_for_target(requester)
		if (
			expected_session_id.is_empty()
			or requester_machine == null
			or requester_machine._get_talk_request_session_id(request_source) != expected_session_id
		):
			return _social_availability(false, &"invalid_request", &"stale_social_session")
	if _has_scripted_control_claim():
		return _social_availability(false, &"temporarily_unavailable", &"scripted_control")
	if (
		_current_state_is(&"DisabledDead")
		or get_value(&"hp", 100.0) <= 0.0
		or get_value(&"disabled", 0.0) > 0.0
	):
		return _social_availability(false, &"temporarily_unavailable", &"candidate_disabled")
	if _npc_is_knocked_out():
		return _social_availability(false, &"temporarily_unavailable", &"candidate_downed")
	if current_state != null and SCRIPTED_CONTROL_EMERGENCY_STATES.has(String(current_state.name)):
		return _social_availability(false, &"temporarily_unavailable", &"emergency_state")
	var scene_handoff_reason := _get_scene_handoff_interaction_block_reason()
	if not scene_handoff_reason.is_empty():
		return _social_availability(false, &"temporarily_unavailable", StringName(scene_handoff_reason))
	if interaction_overlay != null:
		return _social_availability(false, &"temporarily_unavailable", &"active_interaction")
	if is_socially_engaged():
		return _social_availability(false, &"temporarily_unavailable", &"existing_social_session")
	if get_state(&"Talk") == null:
		return _social_availability(false, &"temporarily_unavailable", &"talk_state_unavailable")
	if _should_refuse_talk_for_priority(request_priority):
		return _social_availability(false, &"temporarily_unavailable", &"protected_primary_activity")
	if not primary_state_continues_under_talk():
		return _social_availability(false, &"temporarily_unavailable", &"talk_incompatible_primary_state")
	if not _can_enter_talk_with(requester, request_priority):
		return _social_availability(false, &"temporarily_unavailable", &"talk_state_incompatible")
	return _social_availability(true, &"accepted", &"")


static func _social_availability(
	available: bool,
	decision_kind: StringName,
	reason_code: StringName
) -> Dictionary:
	return {
		"available": available,
		"decision_kind": decision_kind,
		"reason_code": reason_code,
	}


func is_talking_with(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	if interaction_overlay == null or String(interaction_overlay.name) != "Talk":
		return false
	if interaction_overlay.has_method("is_talking_with"):
		return bool(interaction_overlay.call("is_talking_with", candidate))

	return get_talk_target() == candidate


func has_active_talk_overlay() -> bool:
	return (
		interaction_overlay != null
		and String(interaction_overlay.name) == "Talk"
		and active_interaction_session != null
		and active_interaction_session.status == NpcActionSession.Status.ACTIVE
		and active_interaction_session.action_kind == &"Talk"
	)


func is_socially_engaged() -> bool:
	# This is the authoritative live gate for both the planner and direct state requests.
	if has_active_talk_overlay():
		return true
	if (
		_proposed_action != null
		and _proposed_action.action_kind == &"Talk"
		and _proposed_action.status in [
			NpcActionSession.Status.PROPOSED,
			NpcActionSession.Status.ACTIVE,
		]
	):
		return true
	if (
		active_action != null
		and active_action.status == NpcActionSession.Status.ACTIVE
		and active_action.action_kind in [&"Talk", &"LookForTalkTarget"]
	):
		return true
	return false


func is_handling_talk_request_with(candidate: Node2D) -> bool:
	return _talk_request_is_already_being_handled(candidate)


func cancel_talk_with(candidate: Node2D, reason: String = "cancelled") -> void:
	if candidate == null or not is_instance_valid(candidate):
		return

	if is_talking_with(candidate) and interaction_overlay != null:
		var overlay_to_cancel := interaction_overlay
		if overlay_to_cancel.has_method("cancel_talk_with"):
			overlay_to_cancel.call("cancel_talk_with", candidate, reason)
		if interaction_overlay == overlay_to_cancel:
			_remove_interaction_overlay(reason)

func _request_talk_state(
	new_target: Node2D,
	reason: String,
	request_priority: int,
	require_mutual_handshake: bool,
	initiating_source: StringName,
	talk_context: Dictionary = {}
) -> bool:
	var talk_source := _resolve_talk_initiating_source(
		initiating_source, new_target, reason
	)
	var is_player_request := talk_source == &"player"
	var bypass_social_talk_refusal := bool(talk_context.get(
		"bypass_social_talk_refusal", false
	))
	var bypass_all_refusals := (
		is_player_request
		and _player_interaction_bypasses_all_refusals(new_target)
	)
	if _has_scripted_control_claim() and not bypass_all_refusals:
		return _reject_claimed_autonomous_request(&"Talk", initiating_source)
	if new_target == null or not is_instance_valid(new_target) or new_target == npc:
		return _reject_state_request(&"Talk", "invalid_talk_target")
	if _current_state_is(&"LookForTalkTarget") and not bypass_all_refusals:
		if not _current_look_for_talk_target_matches(new_target):
			return _reject_state_request(&"Talk", "talk_search_partner_mismatch")
		var idle_state := get_state(&"Idle")
		if idle_state == null or not current_state.can_exit_to(idle_state, request_priority):
			return _reject_state_request(&"Talk", "talk_search_handoff_rejected")
		if not _commit_state_change(idle_state, "talk_overlay_handoff_search", request_priority):
			return false

	if _talk_request_is_already_being_handled(new_target):
		return true

	if (
		is_ignoring_player_interaction(new_target)
		and not is_talking_with(new_target)
		and not bypass_social_talk_refusal
		and not (
			is_player_request
			and _player_interaction_bypasses_repeat_limits(new_target)
		)
	):
		return _reject_state_request(&"Talk", "player_interaction_cooldown")

	var partner_machine := _get_talk_machine_for_target(new_target)
	var is_npc_partner := (
		new_target.is_in_group("npc")
		and partner_machine != null
		and partner_machine != self
	)
	var priority := request_priority
	if priority < 0:
		priority = 0
	if not is_npc_partner:
		if (
			not bypass_all_refusals
			and not _can_enter_talk_with(new_target, priority)
		):
			return _reject_state_request(&"Talk", "talker_cannot_enter_talk")
		return _accept_talk_request(
			new_target, priority, reason, "", talk_source, talk_context
		)

	if (
		require_mutual_handshake
		and npc_talk_requires_mutual_favor
		and not _mutual_talk_favor_allows(new_target, partner_machine)
	):
		_reject_state_request(&"Talk", "mutual_favor_too_low")
		_start_talk_refusal_cooldown(new_target)
		return false

	if not _can_enter_talk_with(new_target, priority):
		return _reject_state_request(&"Talk", "talker_cannot_enter_talk")

	var requester_session_id := _get_talk_request_session_id(talk_source)
	var shared_talk_session_id := (
		requester_session_id
		if not requester_session_id.is_empty()
		else NpcActionSessionModel.make_session_id(
			_get_action_owner_id(),
			talk_source,
			&"Talk"
		)
	)
	var acceptance_decision := partner_machine.evaluate_npc_talk_request(npc, {
		"request_priority": priority,
		"session_id": shared_talk_session_id,
		"source": talk_source,
		"require_current_session": not requester_session_id.is_empty(),
	})
	if not bool(acceptance_decision.get("accepted", false)):
		var decision_kind := StringName(String(acceptance_decision.get(
			"decision_kind",
			&"invalid_request"
		)))
		var reason_code := StringName(String(acceptance_decision.get(
			"reason_code",
			&"candidate_rejected"
		)))
		# The candidate descriptor is the diagnostic authority for this normal
		# social outcome. Avoid turning planner cadence into state-rejection spam.
		last_state_request_failure_reason = "partner_%s:%s" % [
			String(decision_kind),
			String(reason_code),
		]
		if decision_kind == NpcSocialAcceptancePolicyModel.DECISION_SOCIAL_DECLINE:
			if memory_observer != null:
				memory_observer.observe_conversation_refused(
					new_target,
					shared_talk_session_id,
					reason_code,
					talk_source,
					{
						"refusal_reason_code": reason_code,
						"decision_kind": decision_kind,
					}
				)
			_start_talk_refusal_cooldown(new_target)
		return false

	var partner_started := partner_machine._accept_talk_request(
		npc, priority, "talk_handshake", shared_talk_session_id, talk_source,
		talk_context
	)
	if not partner_started:
		_reject_state_request(&"Talk", "partner_talk_start_failed")
		return false

	var self_started := _accept_talk_request(
		new_target, priority, reason, shared_talk_session_id, talk_source,
		talk_context
	)
	if not self_started:
		_reject_state_request(&"Talk", "talker_start_failed")
		partner_machine.cancel_talk_with(npc, "handshake_failed")
		return false
	_validate_talk_partner_session(new_target)
	partner_machine._validate_talk_partner_session(npc)

	return true


func _accept_talk_request(
	new_target: Node2D,
	request_priority: int,
	reason: String,
	requested_session_id: String = "",
	initiating_source: StringName = &"",
	talk_context: Dictionary = {}
) -> bool:
	var bypass_all_refusals := (
		initiating_source == &"player"
		and _player_interaction_bypasses_all_refusals(new_target)
	)
	if _has_scripted_control_claim() and not bypass_all_refusals:
		return _reject_claimed_autonomous_request(&"Talk", initiating_source)
	if _talk_request_is_already_being_handled(new_target):
		return true

	var talk_state := get_state(&"Talk")
	if talk_state == null:
		return _reject_state_request(&"Talk", "missing_talk_overlay")
	if bypass_all_refusals and interaction_overlay != null:
		_cancel_interaction_overlay("exceptional_player_favor_override")
	if interaction_overlay != null:
		return _reject_state_request(&"Talk", "interaction_overlay_cleanup_failed")
	if (
		not bypass_all_refusals
		and not _can_enter_talk_with(new_target, request_priority)
	):
		return _reject_state_request(&"Talk", "talk_overlay_rejected")

	# Commit the separate interaction session only after the primary and handshake accept.
	last_event_actor = new_target
	last_actor = new_target
	talk_target = new_target
	interaction_overlay = talk_state
	interaction_overlay_priority = maxi(request_priority, 0)
	var talk_source := _resolve_talk_initiating_source(
		initiating_source, new_target, reason
	)
	var session_id := requested_session_id
	if not requested_session_id.is_empty():
		session_id = requested_session_id
	elif (
		_proposed_action != null
		and _proposed_action.action_kind == &"Talk"
		and _proposed_action.source == talk_source
	):
		session_id = _proposed_action.session_id
	elif active_action != null and active_action.source == talk_source:
		session_id = active_action.session_id
	else:
		session_id = NpcActionSessionModel.make_session_id(
			_get_action_owner_id(),
			talk_source,
			&"Talk"
		)
	var interaction_metadata := {
		"primary_session_id": get_active_action_session_id(),
		"initiating_source": String(talk_source),
	}
	if not talk_context.is_empty():
		interaction_metadata["talk_context"] = talk_context.duplicate(true)
	active_interaction_session = NpcActionSessionModel.create(
		_get_action_owner_id(),
		&"Talk",
		talk_source,
		new_target,
		{
			"session_id": session_id,
			"priority": interaction_overlay_priority,
			"status": "active",
			"phase": "executing",
			"metadata": interaction_metadata,
		}
	)
	talk_state.next_state = null
	talk_state.enter()
	_refresh_interaction_animation_presentation()
	last_state_request_failure_reason = ""
	_update_debug_label()
	_breadcrumb(
		"npc_state:overlay_enter",
		"%s primary=%s overlay=Talk reason=%s priority=%d" % [
			_get_npc_label(),
			String(current_state.name) if current_state != null else "",
			reason,
			interaction_overlay_priority,
		]
	)
	if OS.is_debug_build() and _verbose_npc_logging_enabled():
		print("NPC interaction action: npc=%s session=%s action=Talk status=active" % [
			_get_npc_label(), get_active_interaction_session_id(),
		])
	state_changed.emit(&"Talk", StringName(current_state.name) if current_state != null else &"")
	return true


func _can_enter_talk_with(candidate: Node2D, request_priority: int) -> bool:
	if candidate == null or not is_instance_valid(candidate) or candidate == npc:
		return false

	if is_talking_with(candidate):
		return true

	if _talk_request_is_already_being_handled(candidate):
		return true

	if interaction_overlay != null:
		return false

	var talk_state := get_state(&"Talk")
	if talk_state == null:
		return false

	if _should_refuse_talk_for_priority(request_priority):
		return false

	if not primary_state_continues_under_talk():
		return false

	return true


func _talk_request_is_already_being_handled(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate) or candidate == npc:
		return false

	if is_talking_with(candidate):
		return true
	if (
		_current_state_is(&"MoveToTarget")
		and active_action != null
		and active_action.action_kind == &"Talk"
		and get_active_action_target() == candidate
	):
		return true

	return false


func _current_look_for_talk_target_matches(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate) or candidate == npc:
		return false
	if not _current_state_is(&"LookForTalkTarget"):
		return false
	if current_state != null and current_state.has_method("is_searching_for_talk_target"):
		return bool(current_state.call("is_searching_for_talk_target", candidate))

	return false


func _should_refuse_talk_for_priority(request_priority: int) -> bool:
	if not npc_talk_refuse_lower_priority_tasks:
		return false
	if current_state == null:
		return false
	if _current_state_is(&"Idle"):
		return false
	if _current_state_can_continue_during_talk():
		return false

	var task_priority := get_effective_task_priority()
	if _current_state_is(&"MoveToTarget"):
		task_priority += npc_talk_moving_task_priority_bonus
	if task_priority <= 0:
		return false

	return request_priority < task_priority


func _current_state_can_continue_during_talk() -> bool:
	return primary_state_continues_under_talk()


func primary_state_continues_under_talk() -> bool:
	# Only stationary, lifecycle-safe primaries opt in. Eat, Work, Rest, passive
	# Recreation, and Idle may continue. Sleep, Fight, Flee, Downed/death, movement,
	# scene travel, invitations, and other non-interruptible states reject Talk.
	return current_state != null and current_state.can_continue_during_talk()


func _refresh_interaction_animation_presentation() -> void:
	if interaction_overlay == null:
		return

	# A compatible non-idle activity keeps its authored animation while Talk uses
	# only the interaction lane. Idle has no activity presentation to preserve, so
	# normal Talk remains visible and continues facing its partner.
	if (
		current_state != null
		and not _current_state_is(&"Idle")
		and primary_state_continues_under_talk()
	):
		current_state.resume_presentation_after_talk_overlay()
		return

	if interaction_overlay.has_method("refresh_overlay_presentation"):
		interaction_overlay.call("refresh_overlay_presentation")


func _overlay_survives_primary_transition(new_state: NpcState) -> bool:
	# An activity completing into Idle does not invalidate the conversation. All other
	# primary transitions conservatively cancel Talk before the old primary exits.
	return new_state != null and String(new_state.name) == "Idle"


func _cancel_interaction_overlay(reason: String) -> void:
	var overlay_to_cancel := interaction_overlay
	if overlay_to_cancel == null:
		return
	var partner_value = _get_property_if_present(overlay_to_cancel, &"talk_partner", null)
	var partner := partner_value as Node2D if partner_value != null and is_instance_valid(partner_value) else null
	if overlay_to_cancel.has_method("cancel_talk_session"):
		overlay_to_cancel.call("cancel_talk_session", reason)
	elif partner != null and is_instance_valid(partner) and overlay_to_cancel.has_method("cancel_talk_with"):
		overlay_to_cancel.call("cancel_talk_with", partner, reason)
	if interaction_overlay == overlay_to_cancel:
		_remove_interaction_overlay(reason)


func _complete_interaction_overlay(reason: String, synchronize_partner: bool) -> void:
	var completed_overlay := interaction_overlay
	if completed_overlay == null:
		return
	var partner_value = _get_property_if_present(completed_overlay, &"talk_partner", null)
	var partner := partner_value as Node2D if partner_value != null and is_instance_valid(partner_value) else null
	# Finish the linked side while this overlay is still visible. Each Talk then sees
	# the other as active and applies its own completion payout exactly once.
	if synchronize_partner and partner != null:
		var partner_machine := _get_talk_machine_for_target(partner)
		if partner_machine != null and partner_machine != self:
			partner_machine._finish_talk_overlay_from_partner(npc)
	if interaction_overlay == completed_overlay:
		_remove_interaction_overlay(reason)


func _finish_talk_overlay_from_partner(candidate: Node2D) -> void:
	if not is_talking_with(candidate) or interaction_overlay == null:
		return
	var completed_overlay := interaction_overlay
	if completed_overlay.has_method("complete_talk_with"):
		completed_overlay.call("complete_talk_with", candidate, "partner_completed")
	if interaction_overlay == completed_overlay:
		_remove_interaction_overlay("partner_completed")


func _remove_interaction_overlay(reason: String) -> void:
	var removed_overlay := interaction_overlay
	if removed_overlay == null:
		return

	# Clear the slot first so partner callbacks cannot recursively clean it twice.
	interaction_overlay = null
	interaction_overlay_priority = 0
	var removed_interaction_session := active_interaction_session
	var removed_interaction_descriptor := (
		removed_interaction_session.to_descriptor()
		if removed_interaction_session != null
		else {}
	)
	var removed_interaction_session_id := (
		removed_interaction_session.session_id if removed_interaction_session != null else ""
	)
	var removed_talk_partner := (
		removed_interaction_session.get_live_target() if removed_interaction_session != null else null
	)
	active_interaction_session = null
	if pending_player_talk_payout_session_id == removed_interaction_session_id:
		pending_player_talk_payout_session_id = ""
	if prepaid_talk_session_id == removed_interaction_session_id:
		prepaid_talk_session_id = ""
	if talk_target == removed_talk_partner:
		talk_target = null
	removed_overlay.exit()
	if (
		active_action != null
		and active_action.status == NpcActionSession.Status.ACTIVE
		and active_action.session_id == removed_interaction_session_id
	):
		if reason in ["completed", "partner_completed"]:
			complete_active_action(removed_interaction_session_id, reason)
		else:
			cancel_active_action(
				removed_interaction_session_id,
				reason,
				_classify_neutral_action_cancellation(StringName(reason))
			)
	if (
		reason in ["completed", "partner_completed"]
		and memory_observer != null
		and removed_talk_partner != null
		and is_instance_valid(removed_talk_partner)
	):
		memory_observer.observe_conversation_completed(
			removed_talk_partner,
			removed_interaction_descriptor
		)
	if current_state != null:
		current_state.resume_presentation_after_talk_overlay()
	if String(removed_overlay.name) == "Talk":
		_last_social_acceptance_descriptor.clear()
		_social_scoring_descriptor.clear()
		set_social_selection_feedback({})
	_update_debug_label()
	_breadcrumb(
		"npc_state:overlay_exit",
		"%s overlay=%s primary=%s reason=%s" % [
			_get_npc_label(),
			String(removed_overlay.name),
			String(current_state.name) if current_state != null else "",
			reason,
		]
	)
	state_changed.emit(
		StringName(current_state.name) if current_state != null else &"",
		StringName(removed_overlay.name)
	)


func get_effective_task_priority() -> int:
	var priority := current_state_priority
	if current_state != null and String(current_state.name) == "MoveToTarget" and active_action != null:
		priority = max(priority, active_action.priority)

	return priority


func get_active_interaction_session_id() -> String:
	return active_interaction_session.session_id if active_interaction_session != null else ""


func get_active_interaction_source() -> StringName:
	return active_interaction_session.source if active_interaction_session != null else &""


func get_active_talk_context() -> Dictionary:
	if (
		active_interaction_session == null
		or active_interaction_session.action_kind != &"Talk"
	):
		return {}
	var context = active_interaction_session.metadata.get("talk_context", {})
	return context.duplicate(true) if context is Dictionary else {}


func _validate_talk_partner_session(partner: Node2D) -> void:
	if not OS.is_debug_build() or partner == null or not partner.is_in_group("npc"):
		return
	var partner_machine := _get_talk_machine_for_target(partner)
	if partner_machine == null:
		return
	if partner_machine.get_active_interaction_session_id() != get_active_interaction_session_id():
		push_warning("Talk overlay session mismatch for %s and %s." % [_get_npc_label(), partner.name])


func _mutual_talk_favor_allows(candidate: Node2D, partner_machine: NpcStateMachine) -> bool:
	if candidate == null or partner_machine == null:
		return false

	var threshold := maxf(
		npc_talk_handshake_minimum_favor,
		partner_machine.npc_talk_handshake_minimum_favor
	)
	var own_favor := _get_relationship_favor_for_target(candidate)
	var partner_favor := partner_machine._get_relationship_favor_for_target(npc)
	return own_favor > threshold and partner_favor > threshold


func _get_talk_machine_for_target(candidate: Node) -> NpcStateMachine:
	if candidate == null or not is_instance_valid(candidate):
		return null

	var machine_candidate := candidate as NpcStateMachine
	if machine_candidate != null:
		return machine_candidate

	return candidate.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _update_player_interaction_timers(delta: float) -> void:
	if player_interaction_hold_timer > 0.0:
		player_interaction_hold_timer = maxf(player_interaction_hold_timer - delta, 0.0)
		if player_interaction_hold_timer <= 0.0:
			player_interaction_hold_actor = null

	if player_interaction_cooldown_timer > 0.0:
		player_interaction_cooldown_timer = maxf(player_interaction_cooldown_timer - delta, 0.0)
		if player_interaction_cooldown_timer <= 0.0:
			player_interaction_cooldown_actor = null


func _update_talk_refusal_cooldowns(delta: float) -> void:
	if talk_refusal_cooldowns.is_empty():
		return

	for key in talk_refusal_cooldowns.keys():
		var next_time := float(talk_refusal_cooldowns[key]) - delta
		if next_time <= 0.0:
			talk_refusal_cooldowns.erase(key)
		else:
			talk_refusal_cooldowns[key] = next_time


func _start_talk_refusal_cooldown(refused_target: Node2D) -> void:
	if npc_talk_refusal_cooldown_seconds <= 0.0:
		return

	var key := _get_talk_refusal_cooldown_key(refused_target)
	if key.is_empty():
		return

	talk_refusal_cooldowns[key] = maxf(
		float(talk_refusal_cooldowns.get(key, 0.0)),
		npc_talk_refusal_cooldown_seconds
	)


func _get_talk_refusal_cooldown_key(candidate: Node2D) -> String:
	return NpcIdentity.get_actor_id(candidate, true)


func _player_interaction_hold_is_active() -> bool:
	if player_interaction_hold_timer <= 0.0:
		return false
	if player_interaction_hold_actor == null or not is_instance_valid(player_interaction_hold_actor):
		player_interaction_hold_timer = 0.0
		player_interaction_hold_actor = null
		return false

	return true


func _process_player_interaction_hold() -> void:
	if npc == null:
		return

	npc.velocity.x = 0.0
	if player_interaction_hold_actor != null and is_instance_valid(player_interaction_hold_actor):
		face_x_direction(player_interaction_hold_actor.global_position.x - npc.global_position.x)


func _is_player_interaction_actor(actor: Node2D) -> bool:
	return actor != null and is_instance_valid(actor) and actor.is_in_group("player")


func _get_player_interaction_directed_favor(actor: Node2D) -> float:
	if not _is_player_interaction_actor(actor):
		return -1.0
	return clampf(_get_relationship_favor_for_target(actor), 0.0, 100.0)


func _player_interaction_bypasses_repeat_limits(actor: Node2D) -> bool:
	return (
		_get_player_interaction_directed_favor(actor)
		>= player_interaction_repeat_bypass_minimum_favor
	)


func _player_interaction_bypasses_all_refusals(
	actor: Node2D,
	directed_favor: float = -1.0
) -> bool:
	var favor := (
		directed_favor
		if directed_favor >= 0.0
		else _get_player_interaction_directed_favor(actor)
	)
	return favor > player_interaction_all_refusal_bypass_above_favor


func suppress_next_idle_value_reaction() -> void:
	suppress_next_idle_value_reaction_check = true


func can_talk_to_target(
	candidate: Node2D,
	minimum_npc_favor: float = 10.0,
	require_npc_favor: bool = true
) -> bool:
	# Shared gate for autonomous talk choices; direct scripted/player talk can still call request_talk.
	if candidate == null or not is_instance_valid(candidate):
		return false

	if candidate == npc:
		return false

	if is_ignoring_player_interaction(candidate):
		return false
	if is_talk_refusal_on_cooldown(candidate):
		return false

	if not candidate.is_in_group("npc"):
		return true

	if not require_npc_favor:
		return true

	return _get_relationship_favor_for_target(candidate) > minimum_npc_favor


func is_talk_refusal_on_cooldown(candidate: Node2D) -> bool:
	var key := _get_talk_refusal_cooldown_key(candidate)
	if key.is_empty():
		return false

	return float(talk_refusal_cooldowns.get(key, 0.0)) > 0.0


func defer_talk_retry(candidate: Node2D) -> void:
	_start_talk_refusal_cooldown(candidate)


func mark_next_talk_need_payout_applied(expected_session_id: String = "") -> bool:
	# The player UI calls this before applying its effects. Keep it pending until a
	# player-authored value change confirms that effects reached this exact session.
	var active_session_id := get_active_interaction_session_id()
	if expected_session_id.is_empty():
		expected_session_id = active_session_id
	if (
		not has_active_talk_overlay()
		or active_session_id.is_empty()
		or active_session_id != expected_session_id
		or get_active_interaction_source() != &"player"
	):
		return false
	pending_player_talk_payout_session_id = active_session_id
	return true


func consume_next_talk_need_payout_already_applied(expected_session_id: String = "") -> bool:
	var active_session_id := get_active_interaction_session_id()
	var exact_match := (
		not expected_session_id.is_empty()
		and expected_session_id == active_session_id
		and prepaid_talk_session_id == expected_session_id
		and get_active_interaction_source() == &"player"
	)
	if exact_match:
		prepaid_talk_session_id = ""
		pending_player_talk_payout_session_id = ""
	return exact_match


func is_active_talk_payout_prepaid() -> bool:
	var active_session_id := get_active_interaction_session_id()
	return (
		not active_session_id.is_empty()
		and prepaid_talk_session_id == active_session_id
		and get_active_interaction_source() == &"player"
	)


func _confirm_pending_player_talk_payout(actor: Node2D) -> void:
	if actor == null or not is_instance_valid(actor) or not actor.is_in_group("player"):
		return
	var active_session_id := get_active_interaction_session_id()
	if (
		not active_session_id.is_empty()
		and pending_player_talk_payout_session_id == active_session_id
		and get_active_interaction_source() == &"player"
	):
		prepaid_talk_session_id = active_session_id
		pending_player_talk_payout_session_id = ""


func disable(reason: String = "disabled") -> void:
	set_value(&"disabled", 1.0, null, false)
	if is_primary_state(&"DisabledDead"):
		return
	request_state(&"DisabledDead", null, reason, 100)


func enable() -> void:
	set_value(&"disabled", 0.0, null, false)
	request_state(&"Idle", null, "enabled", 1000)


func die() -> void:
	set_value(&"hp", 0.0, null, false)
	if is_primary_state(&"DisabledDead"):
		return
	request_state(&"DisabledDead", null, "dead", 100)


func apply_social_event(
	stat_delta: Dictionary,
	actor: Node2D = null,
	requires_actor_visibility: bool = true,
	event_reason: String = "social_event",
	event_context: Dictionary = {}
) -> bool:
	if requires_actor_visibility and actor != null and npc != null:
		if npc.has_method("can_see") and not bool(npc.call("can_see", actor)):
			return false

	var route_context := event_context.duplicate(true)
	if not route_context.has("source"):
		route_context["source"] = "npc_state_machine"
	var routed := SocialWriteRouter.route_delta(
		npc,
		actor,
		stat_delta,
		get_node_or_null("/root/Relationships"),
		event_reason,
		route_context
	)
	return bool(_apply_routed_social_event(routed, actor).get("applied", false))


## Applies caller-scoped local values and explicitly actor-directed opinion values
## through the same reaction transaction. This avoids forcing authored directed
## anger/fear through the legacy mixed-value schema while retaining one signal and
## one value-reaction pass.
func apply_explicit_directed_social_event(
	local_stat_delta: Dictionary,
	directed_opinion: Dictionary,
	actor: Node2D,
	requires_actor_visibility: bool = true,
	event_reason: String = "social_event",
	event_context: Dictionary = {},
	evaluate_reactions: bool = true
) -> Dictionary:
	if requires_actor_visibility and actor != null and npc != null:
		if npc.has_method("can_see") and not bool(npc.call("can_see", actor)):
			return {"applied": false, "relationship": {}}
	var route_context := event_context.duplicate(true)
	if not route_context.has("source"):
		route_context["source"] = "npc_state_machine"
	var routed := SocialWriteRouter.route_explicit_directed_delta(
		npc,
		actor,
		local_stat_delta,
		directed_opinion,
		get_node_or_null("/root/Relationships"),
		event_reason,
		route_context
	)
	return _apply_routed_social_event(routed, actor, evaluate_reactions)


func _apply_routed_social_event(
	routed: Dictionary,
	actor: Node2D,
	evaluate_reactions: bool = true
) -> Dictionary:
	var local_values: Dictionary = routed.get("local_values", {})
	var local_applied := (
		apply_value_delta(local_values, actor, false)
		if not local_values.is_empty()
		else false
	)
	var directed_applied := bool(routed.get("directed_applied", false))
	var event_eligible_for_talk_payout := (
		bool(routed.get("directed_eligible", false))
		or _has_eligible_local_social_delta(local_values)
	)
	var directed_changes: Dictionary = routed.get("directed_changes", {})
	var directed_favor_delta := float(
		directed_changes.get("favor", 0.0)
	)
	var reaction_changes: Dictionary = (
		last_changed_values.duplicate(true) if local_applied else {}
	)
	if not is_zero_approx(directed_favor_delta):
		reaction_changes["favor"] = float(
			reaction_changes.get("favor", 0.0)
		) + directed_favor_delta
	if event_eligible_for_talk_payout:
		# The interaction choice itself succeeded even when its valid values were
		# already at a clamp boundary. Pending exists only when the player UI opted
		# into prepaid Talk completion, so ordinary/autonomous Talk is unchanged.
		_confirm_pending_player_talk_payout(actor)
	if local_applied or directed_applied:
		# Keep reactions as one priority-arbitrated pass. This transient snapshot
		# lets ReactToEvent inspect the directed favor delta without storing favor
		# in the machine's owner-only value dictionary.
		last_event_actor = actor
		last_changed_values = reaction_changes.duplicate(true)
		if (
			evaluate_reactions
			and not reaction_changes.is_empty()
			and _value_reactions_enabled()
		):
			evaluate_value_reactions(actor, reaction_changes)
	return {
		"applied": local_applied or directed_applied,
		"local_applied": local_applied,
		"directed_applied": directed_applied,
		"directed_changes": directed_changes,
		"relationship": routed.get("relationship", {}),
	}


func _has_eligible_local_social_delta(local_values: Dictionary) -> bool:
	var normalized_delta := _normalize_value_delta(local_values)
	_remove_stored_only_values(normalized_delta)
	for value in normalized_delta.values():
		if not is_zero_approx(_variant_to_float(value)):
			return true
	return false


func replace_values(
	new_values: Dictionary,
	actor: Node2D = null,
	changed_values: Dictionary = {},
	evaluate_reactions: bool = true
) -> void:
	var previous_values := values.duplicate(true)
	var normalized_values := _normalize_value_dictionary(new_values)
	for value_key in values.keys():
		if not normalized_values.has(value_key):
			values.erase(value_key)
	for value_key in normalized_values.keys():
		values[value_key] = normalized_values[value_key]
	last_event_actor = actor
	last_changed_values = _normalize_value_delta(changed_values)
	_remove_stored_only_values(last_changed_values)
	_record_value_threshold_crossings(previous_values, values, last_changed_values)
	values_replaced.emit(values.duplicate(true), actor)

	if not last_changed_values.is_empty():
		_notify_current_state_values_changed(actor)

	if evaluate_reactions and _value_reactions_enabled():
		evaluate_value_reactions(actor, last_changed_values)


func apply_value_delta(
	value_delta: Dictionary,
	actor: Node2D = null,
	evaluate_reactions: bool = true
) -> bool:
	# Use deltas for undirected NPC values. Directed fear belongs to Relationships.
	_normalize_values_in_place(values)
	var previous_values := values.duplicate(true)
	var normalized_delta := _normalize_value_delta(value_delta)
	_remove_stored_only_values(normalized_delta)
	var changed_values: Dictionary = {}

	for value_key in normalized_delta.keys():
		var key := String(value_key)
		var previous_value := _variant_to_float(values.get(key, 0.0))
		var next_value := previous_value + _variant_to_float(normalized_delta[value_key])

		if clamp_percent_values:
			next_value = clampf(next_value, 0.0, 100.0)

		values[key] = next_value

		var actual_delta := next_value - previous_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_values[key] = actual_delta

	_apply_threshold_effects(changed_values)

	if changed_values.is_empty():
		return false
	_confirm_pending_player_talk_payout(actor)

	last_event_actor = actor
	last_changed_values = changed_values.duplicate(true)
	_record_value_threshold_crossings(previous_values, values, changed_values)
	values_changed.emit(_get_changed_values_snapshot(changed_values), actor)
	_notify_current_state_values_changed(actor)

	if evaluate_reactions and _value_reactions_enabled():
		evaluate_value_reactions(actor, changed_values)

	return true


func set_value(
	value_name: StringName,
	value: float,
	actor: Node2D = null,
	evaluate_reactions: bool = true
) -> void:
	_normalize_values_in_place(values)
	var previous_values := values.duplicate(true)
	var key := _canonical_value_key(value_name)
	if _is_stored_only_value(key):
		return
	var previous_value := _variant_to_float(values.get(key, 0.0))
	var next_value := value

	if clamp_percent_values:
		next_value = clampf(next_value, 0.0, 100.0)

	values[key] = next_value

	var changed_values: Dictionary = {}
	var actual_delta := next_value - previous_value
	if not is_equal_approx(actual_delta, 0.0):
		changed_values[key] = actual_delta

	_apply_threshold_effects(changed_values)
	if changed_values.is_empty():
		return
	_confirm_pending_player_talk_payout(actor)

	last_event_actor = actor
	last_changed_values = changed_values.duplicate(true)
	_record_value_threshold_crossings(previous_values, values, changed_values)
	values_changed.emit(_get_changed_values_snapshot(changed_values), actor)
	_notify_current_state_values_changed(actor)

	if evaluate_reactions and _value_reactions_enabled():
		evaluate_value_reactions(actor, changed_values)


func get_value(value_name: StringName, default_value: float = 0.0) -> float:
	_normalize_values_in_place(values)
	return _variant_to_float(values.get(_canonical_value_key(value_name), default_value))


func _get_changed_values_snapshot(changed_values: Dictionary) -> Dictionary:
	var snapshot: Dictionary = {}
	for value_key in changed_values.keys():
		if values.has(value_key):
			snapshot[value_key] = values[value_key]

	return snapshot


func get_fatigue_speed_multiplier() -> float:
	if not fatigue_affects_movement:
		return 1.0
	if not tired_enabled:
		return 1.0
	if tired_value_name == &"":
		return 1.0

	var tired := clampf(get_value(tired_value_name), 0.0, 100.0)
	var normalized := tired / 100.0
	var curved := pow(normalized, maxf(fatigue_speed_curve, 0.001))
	return lerpf(1.0, minimum_fatigue_speed_multiplier, curved)


func get_effective_walk_speed() -> float:
	return maxf(walk_speed * get_fatigue_speed_multiplier(), 0.0)


func get_effective_run_speed() -> float:
	return maxf(run_speed * get_fatigue_speed_multiplier(), 0.0)


func get_debug_movement_speed_text() -> String:
	return "tired=%.1f speed=%.2f walk=%.1f" % [
		get_value(tired_value_name),
		get_fatigue_speed_multiplier(),
		get_effective_walk_speed(),
	]


func get_last_delta(value_name: StringName, default_value: float = 0.0) -> float:
	return _variant_to_float(last_changed_values.get(_canonical_value_key(value_name), default_value))


func evaluate_value_reactions(
	actor = null,
	changed_values: Dictionary = {}
) -> bool:
	# Picks the highest-priority matching rule, so Dead/Flee can outrank Talk/Work.
	if not _value_reactions_enabled():
		_breadcrumb("npc_state:value_reactions_skip", _get_npc_label())
		return false

	var safe_actor: Node2D = null
	if actor != null and is_instance_valid(actor):
		safe_actor = actor as Node2D
	elif actor != null:
		last_event_actor = null

	var matching_rule := _find_best_matching_rule(changed_values, safe_actor)
	_breadcrumb(
		"npc_state:value_reaction_check",
		"%s -> %s" % [_get_npc_label(), String(matching_rule.get("state", "none"))]
	)
	if matching_rule.is_empty():
		set_target_selection_feedback({})
		return false

	var state_name := StringName(String(matching_rule.get("state", "")))
	var priority := int(matching_rule.get("priority", 0))
	var request_actor := _get_rule_request_actor(safe_actor, matching_rule)
	if bool(matching_rule.get("requires_target", false)) and request_actor == null:
		return false
	if current_state == get_state(state_name):
		set_target_selection_feedback({})
		return true
	var requested_state := get_state(state_name)
	if (
		requested_state == null
		or (
			current_state != null
			and not current_state.can_exit_to(requested_state, priority)
		)
	):
		# Value changes remain committed even when the current primary owns control.
		# Preflight the state's existing interruption contract before constructing an
		# intention, action session, feedback update, and guaranteed rejection. This is
		# especially important for repeated favor-loss events during Fight.
		set_target_selection_feedback({})
		_breadcrumb(
			"npc_state:value_reaction_blocked",
			"%s %s->%s priority=%d" % [
				_get_npc_label(),
				String(current_state.name) if current_state != null else "none",
				String(state_name),
				priority,
			]
		)
		return false
	var request_context: Dictionary = {}
	var selection_descriptor: Dictionary = {}
	var target_selection := _prepare_memory_informed_rule_target(
		matching_rule,
		state_name
	)
	if bool(target_selection.get("handled", false)):
		selection_descriptor = target_selection.get(
			"descriptor",
			{}
		)
		set_target_selection_feedback(selection_descriptor)
		if not bool(target_selection.get("selected", false)):
			return false
		request_actor = target_selection.get("target_node", null) as Node2D
		var selected_target_id := String(selection_descriptor.get(
			"selected_target_id",
			""
		)).strip_edges()
		if not selected_target_id.is_empty():
			request_context["target_persistent_id"] = selected_target_id
		var selected_activity_metadata = target_selection.get(
			"activity_metadata",
			{}
		)
		if selected_activity_metadata is Dictionary:
			request_context.merge(selected_activity_metadata, true)
		if bool(target_selection.get("in_place", false)):
			request_context["autonomous_in_place_target"] = true
	else:
		set_target_selection_feedback({})

	if (
		matching_rule.has("behavior_source")
		and matching_rule.has("behavior_reason_code")
	):
		var accepted := request_behavior_intent(
			_build_value_rule_behavior_intent(
				matching_rule, state_name, priority, request_actor
			),
			request_actor,
			request_context
		)
		if accepted:
			_emit_committed_activity_target_selection(
				selection_descriptor,
				request_actor
			)
		return accepted
	return request_state(
		state_name,
		request_actor,
		String(matching_rule.get("reason", "value_rule")),
		priority
	)


func _build_value_rule_behavior_intent(
	rule: Dictionary,
	state_name: StringName,
	priority: int,
	request_actor: Node2D
) -> NpcBehaviorIntent:
	var value_key := _canonical_value_key(rule.get(
		"behavior_origin_value", rule.get("value", "")
	))
	var rule_key := String(rule.get("reason", "")).strip_edges()
	var snapshots := {
		"rule_key": rule_key,
		"value_name": value_key,
		"current_value": values.get(value_key, rule.get("default", 0.0)),
		"requires_target": bool(rule.get("requires_target", false)),
	}
	for threshold_key in ["at_least", "at_most", "truthy", "delta_at_most", "delta_at_least"]:
		if rule.has(threshold_key):
			snapshots[threshold_key] = rule[threshold_key]
	var target_id := NpcActionSessionModel.get_persistent_id(request_actor)
	if not target_id.is_empty():
		snapshots["target_persistent_id"] = target_id
	return NpcBehaviorIntentModel.create(
		state_name,
		state_name,
		StringName(String(rule.get("behavior_source", "manual"))),
		rule_key,
		priority,
		target_id,
		"",
		0.0,
		0,
		snapshots,
		StringName(String(rule.get("behavior_reason_code", rule_key))),
		String(rule.get("behavior_feedback_text", "")),
		StringName(String(rule.get("behavior_origin_value", value_key))),
		false
	)


func play_animation(state_animation_name: StringName) -> bool:
	if _animation_controller != null and _animation_controller.has_method("request_animation"):
		return bool(_animation_controller.call("request_animation", state_animation_name, true))

	# Legacy compatibility for NPCs that have not adopted NpcAnimationController yet.
	if npc != null:
		if npc.has_method("_play_animation"):
			var private_result = npc.call("_play_animation", state_animation_name)
			return bool(private_result) if typeof(private_result) == TYPE_BOOL else true

		if npc.has_method("play_animation"):
			var public_result = npc.call("play_animation", state_animation_name)
			return bool(public_result) if typeof(public_result) == TYPE_BOOL else true

	if _animation_player == null:
		return false

	if _animation_player.current_animation == state_animation_name:
		return true

	if _animation_player.has_animation(state_animation_name):
		_animation_player.play(state_animation_name)
		return true
	return false


func play_fixed_animation(state_animation_name: StringName) -> bool:
	if (
		_animation_controller != null
		and _animation_controller.has_method(&"request_fixed_animation")
	):
		return bool(_animation_controller.call(
			&"request_fixed_animation", state_animation_name, true
		))
	return play_animation(state_animation_name)


func face_x_direction(x_direction: float) -> void:
	if npc == null or x_direction == 0.0:
		return
	if _animation_controller != null and _animation_controller.has_method("face_x_direction"):
		_animation_controller.call("face_x_direction", x_direction)
		return

	if npc.has_method("_face_x_direction"):
		npc.call("_face_x_direction", x_direction)
		return

	if npc.has_method("face_x_direction"):
		npc.call("face_x_direction", x_direction)
		return

	if npc.has_method("update_direction"):
		npc.call("update_direction", float(signf(x_direction)))
		return

	var direction := int(signf(x_direction))
	_set_npc_property_if_exists("direction", direction)

	if _sprite_2d != null:
		_sprite_2d.flip_h = direction < 0

	if npc.has_method("_update_facing"):
		npc.call("_update_facing")


func apply_gravity(delta: float) -> void:
	if npc == null:
		return

	if npc.has_method("apply_gravity"):
		npc.call("apply_gravity", delta)
		return

	if npc.has_method("_apply_gravity"):
		npc.call("_apply_gravity", delta)
		return

	var npc_gravity := gravity
	var custom_gravity = npc.get("gravity")
	if typeof(custom_gravity) == TYPE_FLOAT or typeof(custom_gravity) == TYPE_INT:
		npc_gravity = float(custom_gravity)

	if not npc.is_on_floor():
		npc.velocity.y += npc_gravity * delta
	elif npc.velocity.y > 0.0:
		npc.velocity.y = 0.0


func consume_state_after_move(default_state_name: StringName = &"Idle") -> StringName:
	# Deprecated compatibility wrapper; destination state and priority live in the session.
	return finish_active_action_approach(get_active_action_session_id(), default_state_name)


func preserve_next_state_priority(priority: int) -> void:
	pending_state_priority = maxi(pending_state_priority, priority)


func get_real_seconds_for_game_hours(game_hours: float, fallback_seconds: float) -> float:
	# Converts in-game hours into real seconds using the WorldTime day length.
	if game_hours <= 0.0:
		return fallback_seconds

	var real_seconds_per_day := _get_real_seconds_per_day()
	if real_seconds_per_day <= 0.0:
		return fallback_seconds

	return real_seconds_per_day * (game_hours / 24.0)


func get_real_seconds_for_game_minutes(game_minutes: float, fallback_seconds: float) -> float:
	# Convenience wrapper for short actions like talk/eat that are tuned in minutes.
	return get_real_seconds_for_game_hours(game_minutes / 60.0, fallback_seconds)


func get_game_hours_for_real_seconds(real_seconds: float, fallback_game_hours: float = 0.0) -> float:
	# Converts real elapsed seconds back into game hours for passive need growth.
	if real_seconds <= 0.0:
		return 0.0

	var real_seconds_per_day := _get_real_seconds_per_day()
	if real_seconds_per_day <= 0.0:
		return fallback_game_hours

	return (real_seconds / real_seconds_per_day) * 24.0


func _update_passive_needs(delta: float) -> void:
	# Raises background needs in game-time chunks instead of every physics frame.
	if _has_scripted_control_claim():
		return
	if _is_world_progression_locked():
		return
	if (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_PASSIVE_NEEDS
	):
		passive_need_elapsed_seconds = 0.0
		if not passive_need_skip_logged:
			_breadcrumb("npc_state:passive_needs_skip", _get_npc_label())
			passive_need_skip_logged = true
		return

	if not passive_needs_enabled:
		passive_need_elapsed_seconds = 0.0
		return

	passive_need_elapsed_seconds += delta
	var tick_seconds := maxf(passive_needs_tick_seconds, 0.0)
	if tick_seconds > 0.0 and passive_need_elapsed_seconds < tick_seconds:
		return

	var elapsed_seconds := passive_need_elapsed_seconds
	passive_need_elapsed_seconds = 0.0
	_apply_passive_need_growth(elapsed_seconds)


func _apply_passive_need_growth(real_seconds: float) -> void:
	# Passive needs rise in shared 10-second batches so time-driven changes stay cheap.
	var game_hours := get_game_hours_for_real_seconds(real_seconds)
	if game_hours <= 0.0:
		return

	var value_delta := {}
	var travel_multipliers := _get_travel_need_multipliers()
	if (
		sleep_need_growth_per_game_hour > 0.0
		and not _current_state_matches_any(sleep_need_paused_states)
	):
		value_delta["sleep_need"] = sleep_need_growth_per_game_hour * game_hours * float(travel_multipliers.get("sleep_need", 1.0))

	if (
		hunger_growth_per_game_hour > 0.0
		and not _current_state_matches_any(hunger_paused_states)
	):
		value_delta["hunger"] = hunger_growth_per_game_hour * game_hours * float(travel_multipliers.get("hunger", 1.0))

	if (
		boredom_growth_per_game_hour > 0.0
		and not _current_state_matches_any(boredom_paused_states)
	):
		value_delta["boredom"] = boredom_growth_per_game_hour * game_hours * float(travel_multipliers.get("boredom", 1.0))

	if (
		talk_need_growth_per_interval > 0.0
		and talk_need_growth_interval_game_minutes > 0.0
		and not _current_state_matches_any(talk_need_paused_states)
	):
		var game_minutes := game_hours * 60.0
		value_delta["talk_need"] = (
			talk_need_growth_per_interval
			* (game_minutes / talk_need_growth_interval_game_minutes)
			* float(travel_multipliers.get("talk_need", 1.0))
		)

	var starvation_delta := _get_starvation_damage_delta(game_hours)
	if starvation_delta < 0.0:
		value_delta["hp"] = starvation_delta
	else:
		var healing_delta := _get_passive_healing_delta(game_hours)
		if healing_delta > 0.0:
			value_delta["hp"] = healing_delta

	var tired_delta := _get_tired_delta(game_hours)
	if not is_equal_approx(tired_delta, 0.0):
		value_delta[String(tired_value_name)] = tired_delta

	if (
		not _is_active_travel_companion()
		and
		loneliness_recovery_enabled
		and loneliness_value_name != &""
		and get_value(&"talk_need") < loneliness_recovery_talk_need_below
	):
		var current_loneliness := get_value(loneliness_value_name)
		var recovery_game_hours := game_hours
		if value_delta.has("talk_need"):
			var talk_growth_per_hour := float(value_delta["talk_need"]) / game_hours
			if talk_growth_per_hour > 0.0:
				recovery_game_hours = minf(
					recovery_game_hours,
					maxf(
						(loneliness_recovery_talk_need_below - get_value(&"talk_need"))
							/ talk_growth_per_hour,
						0.0
					)
				)
		var loneliness_decay_per_hour := 100.0 / maxf(
			loneliness_full_recovery_game_hours,
			0.001
		)
		value_delta[String(loneliness_value_name)] = -minf(
			current_loneliness,
			loneliness_decay_per_hour * recovery_game_hours
		)

	if not _is_active_travel_companion() and fear_decay_enabled and npc != null and npc.has_method("decay_relationship_fear"):
		var flee_threshold := _get_flee_fear_threshold()
		var fear_stop_value := maxf(
			flee_threshold - fear_decay_stop_below_flee_threshold_by,
			0.0
		)
		npc.call(
			"decay_relationship_fear",
			game_hours,
			fear_panic_floor,
			fear_panic_cooldown_game_minutes / 60.0,
			fear_slow_decay_per_game_hour,
			fear_stop_value
		)

	var anger_delta := _get_anger_decay_delta(game_hours)
	if not _is_active_travel_companion() and not is_equal_approx(anger_delta, 0.0):
		value_delta[String(anger_decay_value_name)] = anger_delta
	if not _is_active_travel_companion() and anger_decay_enabled and npc != null and npc.has_method("decay_relationship_anger"):
		npc.call("decay_relationship_anger", game_hours, anger_full_decay_game_hours)

	if value_delta.is_empty():
		return

	apply_value_delta(value_delta, null, true)


func _is_active_travel_companion() -> bool:
	if npc == null:
		return false
	var runtime := get_node_or_null("/root/PlayerRuntime")
	return runtime != null and runtime.has_method("is_active_companion") and bool(runtime.call("is_active_companion", npc))


func is_state_allowed_for_active_travel_companion(state_name: StringName) -> bool:
	return not ACTIVE_TRAVEL_BLOCKED_STATES.has(String(state_name))


func _get_travel_need_multipliers() -> Dictionary:
	if not _is_active_travel_companion():
		return {}
	var runtime := get_node_or_null("/root/PlayerRuntime")
	var policy := runtime.call("get_active_travel_policy") as TravelPolicy
	return policy.get_need_multipliers() if policy != null else {}


func _get_passive_healing_delta(game_hours: float) -> float:
	if passive_healing_per_game_day <= 0.0 or game_hours <= 0.0:
		return 0.0
	if get_value(&"hunger") >= 100.0:
		return 0.0

	var current_hp := get_value(&"hp")
	if current_hp <= 0.0 or current_hp >= 100.0:
		return 0.0
	if get_value(&"disabled") >= 1.0:
		return 0.0

	return minf(100.0 - current_hp, (passive_healing_per_game_day / 24.0) * game_hours)


func _get_starvation_damage_delta(game_hours: float) -> float:
	if starvation_damage_per_game_day <= 0.0 or game_hours <= 0.0:
		return 0.0
	if _current_state_matches_any(hunger_paused_states):
		return 0.0
	if get_value(&"disabled") >= 1.0:
		return 0.0

	var current_hp := get_value(&"hp")
	if current_hp <= 0.0:
		return 0.0

	var starvation_hours := _get_starvation_game_hours(game_hours)
	if starvation_hours <= 0.0:
		return 0.0

	var damage := (starvation_damage_per_game_day / 24.0) * starvation_hours
	return -minf(current_hp, damage)


func _get_starvation_game_hours(game_hours: float) -> float:
	var current_hunger := get_value(&"hunger")
	if current_hunger >= 100.0:
		return game_hours
	if hunger_growth_per_game_hour <= 0.0:
		return 0.0

	var remaining_hunger := maxf(100.0 - current_hunger, 0.0)
	var hours_to_starvation := remaining_hunger / hunger_growth_per_game_hour
	return maxf(game_hours - hours_to_starvation, 0.0)


func _get_tired_delta(game_hours: float) -> float:
	# Actions build short-term fatigue; Rest clears it quickly while Sleep handles it on completion.
	if not tired_enabled or tired_value_name == &"" or game_hours <= 0.0:
		return 0.0
	if current_state == null:
		return 0.0

	if _current_state_is(&"Rest"):
		var recovery_floor := 0.0
		var rest_state := get_state(&"Rest")
		if rest_state != null and rest_state.has_method("get_tired_floor"):
			recovery_floor = float(rest_state.call("get_tired_floor"))
		return -minf(
			maxf(get_value(tired_value_name) - recovery_floor, 0.0),
			tired_recovery_per_rest_game_hour * game_hours
		)
	if _current_state_is(&"Fight"):
		return tired_growth_per_fight_game_hour * game_hours
	if _current_state_matches_any(tired_inactive_states):
		return 0.0

	return tired_growth_per_action_game_hour * game_hours


func _get_anger_decay_delta(game_hours: float) -> float:
	# Anger cools on the same passive tick as needs: 100 -> 0 over the configured game hours.
	if not anger_decay_enabled or anger_decay_value_name == &"" or game_hours <= 0.0:
		return 0.0

	var current_anger := get_value(anger_decay_value_name)
	if current_anger <= 0.0:
		return 0.0

	var decay_per_hour := 100.0 / maxf(anger_full_decay_game_hours, 0.001)
	return -minf(current_anger, decay_per_hour * game_hours)


func _get_flee_fear_threshold() -> float:
	if npc != null and npc.has_method("get_relationship_flee_fear_threshold"):
		return float(npc.call("get_relationship_flee_fear_threshold"))
	return 70.0


func _get_anger_fight_threshold() -> float:
	var rule := _get_anger_fight_rule()
	return _variant_to_float(rule.get("at_least", 100.0))


func _get_anger_fight_priority() -> int:
	var rule := _get_anger_fight_rule()
	return int(rule.get("priority", 94))


func _higher_priority_value_reaction_blocks_combat(actor: Node2D, combat_priority: int) -> bool:
	var matching_rule := _find_best_matching_rule({}, actor)
	if matching_rule.is_empty():
		return false
	if String(matching_rule.get("state", "")) == "Fight":
		return false

	return int(matching_rule.get("priority", 0)) > combat_priority


func _get_anger_fight_rule() -> Dictionary:
	var fallback_rule := {
		"value": String(anger_decay_value_name),
		"state": "Fight",
		"at_least": 100.0,
		"priority": 94,
	}
	for rule_name in value_state_rules.keys():
		var rule = value_state_rules[rule_name]
		if not (rule is Dictionary):
			continue

		var rule_dictionary: Dictionary = rule
		if String(rule_dictionary.get("state", "")) != "Fight":
			continue
		if _canonical_value_key(rule_dictionary.get("value", "")) != _canonical_value_key(anger_decay_value_name):
			continue

		return rule_dictionary

	return fallback_rule


func _stagger_passive_need_tick() -> void:
	if not stagger_passive_need_ticks:
		return

	var tick_seconds := maxf(passive_needs_tick_seconds, 0.0)
	if tick_seconds <= 0.0:
		return

	var offset_ratio := float(int(get_instance_id()) % 1000) / 1000.0
	passive_need_elapsed_seconds = -tick_seconds * offset_ratio


func _current_state_matches_any(state_names: Array[StringName]) -> bool:
	for state_name in state_names:
		if _current_state_is(state_name):
			return true
		if interaction_overlay != null and String(interaction_overlay.name) == String(state_name):
			return true

	return false


func _get_real_seconds_per_day() -> float:
	# Reads the current global day length. A missing clock falls back to old timers.
	if not is_inside_tree() or get_tree() == null:
		return 0.0

	var world_time := get_tree().root.get_node_or_null("WorldTime")
	if world_time == null:
		return 0.0

	var value = world_time.get("real_seconds_per_day")
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)

	return 0.0


func _queue_idle_value_reaction_check() -> void:
	# Defers the idle rule check so the state stack finishes changing first.
	if _has_scripted_control_claim():
		return
	if idle_value_reaction_queued:
		return

	idle_value_reaction_queued = true
	call_deferred("_run_idle_value_reaction_check")


func resume_ordinary_planning_if_idle() -> void:
	if current_state != null and String(current_state.name) == "Idle":
		_queue_idle_value_reaction_check()


func _run_idle_value_reaction_check() -> void:
	# Runs need reactions that were waiting for the NPC to become idle again.
	idle_value_reaction_queued = false
	if _has_scripted_control_claim():
		return
	if suppress_next_idle_value_reaction_check:
		suppress_next_idle_value_reaction_check = false
		if is_inside_tree() and active and _value_reactions_enabled():
			evaluate_persistent_combat_reactions(last_event_actor)
		return
	if _is_world_progression_locked():
		return

	if not is_inside_tree() or not active or not _value_reactions_enabled() or current_state == null:
		return

	if String(current_state.name) != "Idle":
		return

	evaluate_value_reactions(last_event_actor, {})


func _is_world_progression_locked() -> bool:
	if not is_inside_tree() or get_tree() == null:
		return false
	var gameplay_flow := get_tree().root.get_node_or_null("GameplayFlow")
	return (
		gameplay_flow != null
		and gameplay_flow.has_method("is_world_progression_locked")
		and bool(gameplay_flow.call("is_world_progression_locked"))
	)


func _resolve_npc() -> void:
	if String(npc_path) != "":
		npc = get_node_or_null(npc_path) as CharacterBody2D

	if npc == null:
		npc = get_parent() as CharacterBody2D

	if npc == null and owner != null:
		npc = owner as CharacterBody2D


func _cache_optional_nodes() -> void:
	if npc == null:
		return

	_animation_controller = _get_optional_npc_node(
		animation_controller_path,
		"NpcAnimationController"
	)
	if _animation_controller != null and _animation_controller.has_method("bind_npc"):
		_animation_controller.call("bind_npc", npc)
	_animation_player = _get_optional_npc_node(animation_player_path, "AnimationPlayer") as AnimationPlayer
	_sprite_2d = _get_optional_npc_node(sprite_path, "Sprite2D") as Sprite2D
	_debug_label = _get_optional_npc_node(debug_label_path, "Label") as Label
	if _debug_label != null:
		_debug_label.visible = developer_state_label_enabled


func _cache_behavior_controller() -> void:
	behavior_controller = get_node_or_null("NpcBehaviorController") as NpcBehaviorController
	if behavior_controller == null:
		return
	if not behavior_controller.intention_accepted.is_connected(
		_on_behavior_intention_accepted
	):
		behavior_controller.intention_accepted.connect(_on_behavior_intention_accepted)
	if not behavior_controller.intention_replaced.is_connected(
		_on_behavior_intention_replaced
	):
		behavior_controller.intention_replaced.connect(_on_behavior_intention_replaced)
	if not behavior_controller.intention_refreshed.is_connected(
		_on_behavior_intention_refreshed
	):
		behavior_controller.intention_refreshed.connect(_on_behavior_intention_refreshed)
	if not behavior_controller.intention_cleared.is_connected(
		_on_behavior_intention_cleared
	):
		behavior_controller.intention_cleared.connect(_on_behavior_intention_cleared)
	if not behavior_controller.intention_rejected.is_connected(
		_on_behavior_intention_rejected
	):
		behavior_controller.intention_rejected.connect(_on_behavior_intention_rejected)
	if not behavior_controller.commitment_changed.is_connected(
		_on_behavior_commitment_changed
	):
		behavior_controller.commitment_changed.connect(_on_behavior_commitment_changed)
	if not behavior_controller.feedback_refresh_requested.is_connected(
		_on_behavior_feedback_refresh_requested
	):
		behavior_controller.feedback_refresh_requested.connect(
			_on_behavior_feedback_refresh_requested
		)
	if not behavior_controller.rejection_feedback_cleared.is_connected(
		_on_behavior_rejection_feedback_cleared
	):
		behavior_controller.rejection_feedback_cleared.connect(
			_on_behavior_rejection_feedback_cleared
		)


func _cache_memory_components() -> void:
	short_term_memory = get_node_or_null("NpcShortTermMemory") as NpcShortTermMemory
	memory_observer = get_node_or_null("NpcMemoryObserver") as NpcMemoryObserver
	memory_runtime_binding = get_node_or_null(
		"NpcMemoryRuntimeBinding"
	) as NpcMemoryRuntimeBinding
	if memory_observer != null:
		memory_observer.bind(self, short_term_memory)
	if (
		short_term_memory != null
		and not short_term_memory.memory_changed.is_connected(_on_memory_changed)
	):
		short_term_memory.memory_changed.connect(_on_memory_changed)
	if memory_runtime_binding != null:
		memory_runtime_binding.bind(self, short_term_memory)


func _cache_feedback_components() -> void:
	feedback_presenter = get_node_or_null(
		"NpcFeedbackPresenter"
	)
	feedback_adapter = get_node_or_null(
		"NpcFeedbackAdapter"
	)
	if feedback_presenter != null:
		feedback_presenter.set(
			"player_feedback_enabled",
			player_feedback_enabled
		)
		feedback_presenter.call("bind_npc", npc)
	if feedback_adapter != null:
		feedback_adapter.call(
			"bind",
			self,
			behavior_controller,
			short_term_memory,
			feedback_presenter
		)


func _on_memory_changed() -> void:
	# A merge, resolution, removal, or expiry changes policy eligibility. Do not
	# retain policy or social-choice descriptors across that revision.
	set_target_selection_feedback({})
	set_social_selection_feedback({})
	_social_scoring_descriptor.clear()
	_last_social_acceptance_descriptor.clear()
	_last_player_interaction_memory_policy = {}
	_update_debug_label()


func _on_behavior_intention_accepted(_intent: NpcBehaviorIntent) -> void:
	_update_debug_label()


func _on_behavior_intention_replaced(
	_previous: NpcBehaviorIntent,
	_current: NpcBehaviorIntent
) -> void:
	_update_debug_label()


func _on_behavior_intention_refreshed(_intent: NpcBehaviorIntent) -> void:
	_update_debug_label()


func _on_behavior_intention_cleared(
	_intent: NpcBehaviorIntent,
	_reason: StringName
) -> void:
	_update_debug_label()


func _on_behavior_intention_rejected(
	_candidate: NpcBehaviorIntent,
	_reason: StringName
) -> void:
	_update_debug_label()


func _on_behavior_commitment_changed(_remaining_seconds: float) -> void:
	_update_debug_label()


func _on_behavior_feedback_refresh_requested() -> void:
	_update_debug_label()


func _on_behavior_rejection_feedback_cleared() -> void:
	_update_debug_label()


func _get_optional_npc_node(configured_path: NodePath, fallback_name: String) -> Node:
	if npc == null:
		return null

	if String(configured_path) != "":
		return npc.get_node_or_null(configured_path)

	var fallback_node := npc.get_node_or_null(fallback_name)
	if fallback_node != null:
		return fallback_node

	return npc.get_node_or_null("%%%s" % fallback_name)


func _notify_current_state_values_changed(actor: Node2D) -> void:
	if current_state == null:
		return

	var requested_state := current_state.values_changed(
		values,
		last_changed_values,
		actor
	)

	if requested_state != null:
		change_state(requested_state, "state_values_changed")


func _find_best_matching_rule(changed_values: Dictionary, actor: Node2D = null) -> Dictionary:
	# Picks the highest-priority rule that can actually run right now.
	if not _value_reactions_enabled():
		return {}

	var best_rule: Dictionary = {}
	var best_priority := -999999

	for rule_name in value_state_rules.keys():
		var rule = value_state_rules[rule_name]
		if not (rule is Dictionary):
			continue

		var rule_dictionary: Dictionary = rule
		var value_key := _canonical_value_key(rule_dictionary.get("value", rule_name))
		if _is_stored_only_value(value_key):
			continue
		var value = values.get(value_key, rule_dictionary.get("default", 0.0))
		var value_changed := changed_values.has(value_key)
		var value_delta = changed_values.get(value_key, 0.0)

		if not _rule_matches(rule_dictionary, value, value_delta, value_changed):
			continue

		var state_name := StringName(String(rule_dictionary.get("state", "")))
		var configured_state := get_state(state_name)
		if state_name == &"" or configured_state == null:
			continue
		if (
			state_name == &"Fight"
			and configured_state.has_method("can_start_fight")
			and not bool(configured_state.call("can_start_fight"))
		):
			continue
		if (
			state_name == &"LookForTalkTarget"
			and DebugToolsConfig.TROUBLESHOOTING_MODE
			and DebugToolsConfig.DEBUG_DISABLE_TALK_SEARCH
		):
			continue
		if state_name == &"LookForTalkTarget":
			if is_socially_engaged():
				continue
			if not _can_start_look_for_talk_target():
				continue
			if not _has_available_autonomous_talk_target(rule_dictionary):
				continue
		if (
			bool(rule_dictionary.get("requires_casual_spot", false))
			and not _has_available_casual_spot(state_name)
		):
			continue
		if (
			bool(rule_dictionary.get("requires_need_spot", false))
			and not _has_available_need_source(state_name, StringName(value_key))
		):
			continue

		if bool(rule_dictionary.get("requires_target", false)):
			if _get_rule_request_actor(actor, rule_dictionary) == null:
				continue

		var priority := int(rule_dictionary.get("priority", 0))
		if priority <= best_priority:
			continue

		best_priority = priority
		best_rule = rule_dictionary.duplicate(true)
		best_rule["reason"] = String(rule_name)

	return best_rule


func _has_available_need_spot(state_name: StringName, value_name: StringName = &"") -> bool:
	if npc == null or not npc.is_inside_tree():
		return false
	for candidate in npc.get_tree().get_nodes_in_group("npc_need_spot"):
		var spot := candidate as Node2D
		if spot == null or not is_instance_valid(spot):
			continue
		if not spot.has_method("can_serve_npc_need"):
			continue
		if bool(spot.call("can_serve_npc_need", npc, state_name, value_name)):
			return true

	return false


func _has_available_need_source(state_name: StringName, value_name: StringName = &"") -> bool:
	if _has_available_need_spot(state_name, value_name):
		return true
	return (
		state_name == &"Eat"
		and npc != null
		and npc.has_method("has_available_inventory_food")
		and bool(npc.call("has_available_inventory_food"))
	)


func _has_available_casual_spot(state_name: StringName) -> bool:
	if npc == null or not npc.is_inside_tree():
		return false
	for candidate in npc.get_tree().get_nodes_in_group("npc_casual_spot"):
		var spot := candidate as Node2D
		if spot == null or not is_instance_valid(spot):
			continue
		if not spot.has_method("can_serve_npc_casual_activity"):
			continue
		if bool(spot.call("can_serve_npc_casual_activity", npc, state_name)):
			return true

	return false


func select_memory_informed_activity_target(
	logical_action: StringName,
	candidates: Array,
	now_game_hours: float = -1.0,
	context: Dictionary = {}
) -> Dictionary:
	var evaluated_at := (
		_get_world_total_hours()
		if now_game_hours < 0.0
		else maxf(now_game_hours, 0.0)
	)
	var suppressed_candidates: Array[Dictionary] = []
	var earliest_retry_game_hours := 0.0
	var selected_target: Node2D
	var selected_target_id := ""
	var selected_in_place := false
	var selected := false
	var remembering_id := _get_action_owner_id()
	var policy_context := {
		"remembering_npc_id": remembering_id,
		"target_unavailable_retry_hours": (
			target_unavailable_retry_game_hours
		),
		"movement_failed_retry_hours": movement_failed_retry_game_hours,
		"intention_target_lost_retry_hours": (
			intention_target_lost_retry_game_hours
		),
	}
	policy_context.merge(context, true)

	for candidate_value in candidates:
		var candidate: Dictionary = (
			candidate_value
			if candidate_value is Dictionary
			else {"target_node": candidate_value}
		)
		var candidate_node = candidate.get("target_node", null) as Node2D
		var candidate_id := String(candidate.get(
			"target_id",
			_get_stable_activity_target_id(candidate_node, logical_action)
		)).strip_edges()
		var candidate_place_id := String(candidate.get(
			"place_id",
			candidate_id
		)).strip_edges()
		var decision := _target_memory_policy.evaluate_candidate(
			short_term_memory,
			logical_action,
			StringName(candidate_id),
			StringName(candidate_place_id),
			evaluated_at,
			policy_context
		)
		if bool(decision.get("allowed", true)):
			selected = true
			selected_target = candidate_node
			selected_target_id = candidate_id
			selected_in_place = bool(candidate.get("in_place", false))
			break
		var retry_game_hours := float(decision.get(
			"retry_game_hours",
			evaluated_at
		))
		if (
			earliest_retry_game_hours <= 0.0
			or retry_game_hours < earliest_retry_game_hours
		):
			earliest_retry_game_hours = retry_game_hours
		suppressed_candidates.append({
			"target_id": StringName(candidate_id),
			"reason_code": _target_suppression_reason_code(decision),
			"memory_event_type": decision.get("memory_event_type", &""),
			"remaining_retry_hours": float(decision.get(
				"remaining_retry_hours",
				0.0
			)),
		})

	var descriptor := {
		"logical_action": logical_action,
		"candidate_count": candidates.size(),
		"suppressed_count": suppressed_candidates.size(),
		"selected_target_id": StringName(selected_target_id),
		"all_suppressed": (
			not selected
			and not candidates.is_empty()
			and suppressed_candidates.size() == candidates.size()
		),
		"earliest_retry_game_hours": earliest_retry_game_hours,
		"remaining_retry_hours": maxf(
			earliest_retry_game_hours - evaluated_at,
			0.0
		),
		"reason_code": (
			&"all_targets_recently_failed"
			if (
				not selected
				and not candidates.is_empty()
				and suppressed_candidates.size() == candidates.size()
			)
			else &""
		),
		"suppressed_candidates": suppressed_candidates,
	}
	return {
		"selected": selected,
		"target_node": selected_target,
		"target_id": StringName(selected_target_id),
		"in_place": selected_in_place,
		"descriptor": descriptor,
	}


func _prepare_memory_informed_rule_target(
	rule: Dictionary,
	state_name: StringName
) -> Dictionary:
	if (
		not MEMORY_FILTERED_LIVE_ACTIVITY_ACTIONS.has(String(state_name))
		or StringName(String(rule.get("behavior_source", ""))) != &"need"
	):
		return {"handled": false}
	var candidates := _enumerate_live_activity_candidates(state_name)
	if candidates.is_empty():
		return {"handled": false}
	var selection := select_memory_informed_activity_target(
		state_name,
		candidates
	)
	if bool(selection.get("selected", false)) and state_name in [&"Rest", &"Recreation"]:
		var selected_spot := selection.get("target_node", null) as Node2D
		var affinity := get_activity_spot_social_affinity(selected_spot, state_name)
		var descriptor: Dictionary = selection.get("descriptor", {})
		var social_context := NpcActivitySocialAffinityPolicy.build_selected_activity_context(
			affinity,
			StringName(_get_action_owner_id()),
			_get_stable_spot_id(selected_spot),
			state_name
		)
		descriptor.merge(social_context.get("debug", {}), true)
		selection["activity_metadata"] = social_context.get("metadata", {})
		selection["descriptor"] = descriptor
	selection["handled"] = true
	return selection


func _emit_committed_activity_target_selection(
	selection_descriptor: Dictionary,
	selected_target: Node2D
) -> void:
	if (
		selection_descriptor.is_empty()
		or int(selection_descriptor.get("suppressed_count", 0)) <= 0
		or bool(selection_descriptor.get("all_suppressed", false))
		or behavior_controller == null
		or behavior_controller.current_intent == null
		or active_action == null
		or active_action.status != NpcActionSession.Status.ACTIVE
	):
		return
	var selected_target_id := String(selection_descriptor.get(
		"selected_target_id",
		""
	)).strip_edges()
	var logical_action := StringName(String(selection_descriptor.get(
		"logical_action",
		""
	)))
	if (
		selected_target_id.is_empty()
		or not MEMORY_FILTERED_LIVE_ACTIVITY_ACTIONS.has(
			String(logical_action)
		)
	):
		return
	var accepted_intent := behavior_controller.current_intent
	if (
		accepted_intent.lifecycle_only
		or accepted_intent.source != NpcBehaviorIntentModel.SOURCE_NEED
		or accepted_intent.logical_action_kind != logical_action
		or accepted_intent.action_session_id.is_empty()
		or accepted_intent.action_session_id != active_action.session_id
		or accepted_intent.target_persistent_id != selected_target_id
		or active_action.action_kind != logical_action
		or active_action.source != NpcBehaviorIntentModel.SOURCE_NEED
		or active_action.target_persistent_id != selected_target_id
		or active_action.get_live_target() != selected_target
	):
		return
	var commit_key := "%s|%s|%s" % [
		accepted_intent.action_session_id,
		String(logical_action),
		selected_target_id,
	]
	if commit_key == _last_activity_target_selection_commit_key:
		return
	_last_activity_target_selection_commit_key = commit_key
	var committed := selection_descriptor.duplicate(true)
	committed["reason_code"] = &"alternative_target_selected"
	committed["logical_action"] = logical_action
	committed["selected_target_id"] = StringName(selected_target_id)
	committed["action_session_id"] = accepted_intent.action_session_id
	committed["intent_id"] = accepted_intent.intent_id
	activity_target_selection_committed.emit(committed)


func _enumerate_live_activity_candidates(
	logical_action: StringName
) -> Array[Dictionary]:
	var ordered: Array[Dictionary] = []
	var seen_instances: Dictionary = {}
	var assigned := get_action_target(logical_action)
	_append_activity_candidate(
		ordered,
		seen_instances,
		assigned,
		logical_action
	)
	var state := get_state(logical_action)
	var configured_path := _get_activity_configured_target_path(
		state,
		logical_action
	)
	if String(configured_path) != "" and npc != null:
		_append_activity_candidate(
			ordered,
			seen_instances,
			npc.get_node_or_null(configured_path) as Node2D,
			logical_action
		)

	if logical_action in [&"Rest", &"Recreation"]:
		if logical_action == &"Rest":
			var rest_state := state as NpcStateRest
			if (
				rest_state != null
				and rest_state.choice_rng.randf()
					< clampf(rest_state.rest_in_place_chance, 0.0, 1.0)
			):
				ordered.append({"target_node": null, "in_place": true})
				return ordered
		var casual_candidates := _get_weighted_casual_candidate_order(
			logical_action,
			state
		)
		for casual in casual_candidates:
			_append_activity_candidate(
				ordered,
				seen_instances,
				casual,
				logical_action
			)
		if logical_action == &"Rest":
			ordered.append({"target_node": null, "in_place": true})
		return ordered

	var value_name := _get_activity_value_name(state, logical_action)
	var need_candidates: Array[Dictionary] = []
	var source_index := 0
	if npc != null and npc.is_inside_tree():
		for candidate in npc.get_tree().get_nodes_in_group("npc_need_spot"):
			var spot := candidate as Node2D
			if not _activity_candidate_is_valid(
				spot,
				logical_action,
				value_name
			):
				continue
			need_candidates.append({
				"target_node": spot,
				"distance": npc.global_position.distance_to(
					spot.global_position
				),
				"source_index": source_index,
			})
			source_index += 1
	need_candidates.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var a_distance := float(a.get("distance", INF))
			var b_distance := float(b.get("distance", INF))
			if not is_equal_approx(a_distance, b_distance):
				return a_distance < b_distance
			return int(a.get("source_index", 0)) < int(
				b.get("source_index", 0)
			)
	)
	for candidate in need_candidates:
		_append_activity_candidate(
			ordered,
			seen_instances,
			candidate.get("target_node", null) as Node2D,
			logical_action
		)
	if (
		logical_action == &"Eat"
		and npc != null
		and npc.has_method("has_available_inventory_food")
		and bool(npc.call("has_available_inventory_food"))
	):
		ordered.append({"target_node": npc})
	return ordered


func _append_activity_candidate(
	ordered: Array[Dictionary],
	seen_instances: Dictionary,
	candidate: Node2D,
	logical_action: StringName
) -> void:
	if not _activity_candidate_is_valid(
		candidate,
		logical_action,
		_get_activity_value_name(get_state(logical_action), logical_action)
	):
		return
	var instance_key := candidate.get_instance_id()
	if seen_instances.has(instance_key):
		return
	seen_instances[instance_key] = true
	var target_id := _get_stable_activity_target_id(
		candidate,
		logical_action
	)
	ordered.append({
		"target_node": candidate,
		"target_id": target_id,
		"place_id": target_id,
	})


func _activity_candidate_is_valid(
	candidate: Node2D,
	logical_action: StringName,
	value_name: StringName
) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	if logical_action == &"Eat" and candidate == npc:
		return true
	if logical_action in [&"Rest", &"Recreation"]:
		return (
			candidate.has_method("can_serve_npc_casual_activity")
			and bool(candidate.call(
				"can_serve_npc_casual_activity",
				npc,
				logical_action
			))
		)
	return (
		candidate.has_method("can_serve_npc_need")
		and bool(candidate.call(
			"can_serve_npc_need",
			npc,
			logical_action,
			value_name
		))
	)


func _get_weighted_casual_candidate_order(
	logical_action: StringName,
	state: NpcState
) -> Array[Node2D]:
	var candidates: Array[Node2D] = []
	var weights: Array[float] = []
	if npc == null or not npc.is_inside_tree():
		return candidates
	for candidate in npc.get_tree().get_nodes_in_group("npc_casual_spot"):
		var spot := candidate as Node2D
		if not _activity_candidate_is_valid(spot, logical_action, &""):
			continue
		var weight := 1.0
		if spot.has_method("get_npc_preference_weight"):
			weight = maxf(float(spot.call(
				"get_npc_preference_weight",
				npc
			)), 0.0)
		var social_affinity := get_activity_spot_social_affinity(
			spot,
			logical_action
		)
		if not bool(social_affinity.get("group_compatible", true)):
			continue
		weight += float(social_affinity.get("social_bonus", 0.0))
		if weight <= 0.0:
			continue
		candidates.append(spot)
		weights.append(weight)
	var rng: RandomNumberGenerator
	if state is NpcStateRest:
		rng = (state as NpcStateRest).choice_rng
	elif state is NpcStateRecreation:
		rng = (state as NpcStateRecreation).choice_rng
	if rng == null:
		return candidates
	var ordered: Array[Node2D] = []
	while not candidates.is_empty():
		var total_weight := 0.0
		for weight in weights:
			total_weight += weight
		var roll := rng.randf_range(0.0, total_weight)
		var selected_index := weights.size() - 1
		for index in weights.size():
			roll -= weights[index]
			if roll <= 0.0:
				selected_index = index
				break
		ordered.append(candidates[selected_index])
		candidates.remove_at(selected_index)
		weights.remove_at(selected_index)
	return ordered


func get_activity_spot_social_bonus(
	spot: Node2D,
	logical_action: StringName
) -> float:
	return maxf(float(get_activity_spot_social_affinity(
		spot,
		logical_action
	).get("social_bonus", 0.0)), 0.0)


func get_activity_spot_social_affinity(
	spot: Node2D,
	logical_action: StringName
) -> Dictionary:
	if spot == null or logical_action not in [&"Rest", &"Recreation"]:
		return {}
	var spot_id := _get_stable_spot_id(spot)
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if (
		spot_id == &""
		or simulator == null
		or not simulator.has_method("score_activity_spot_social_affinity")
	):
		return {}
	var score: Dictionary = simulator.call(
		"score_activity_spot_social_affinity",
		StringName(_get_action_owner_id()),
		spot_id,
		logical_action,
		short_term_memory,
		_get_world_total_hours()
	)
	return score


func _get_activity_configured_target_path(
	state: NpcState,
	logical_action: StringName
) -> NodePath:
	match logical_action:
		&"Eat":
			return (state as NpcStateEat).eat_target_path if state is NpcStateEat else NodePath()
		&"Rest":
			return (state as NpcStateRest).rest_target_path if state is NpcStateRest else NodePath()
		&"Recreation":
			return (state as NpcStateRecreation).recreation_target_path if state is NpcStateRecreation else NodePath()
		&"Sleep":
			return (state as NpcStateSleep).sleep_target_path if state is NpcStateSleep else NodePath()
		&"Work":
			return (state as NpcStateWork).work_target_path if state is NpcStateWork else NodePath()
	return NodePath()


func _get_activity_value_name(
	state: NpcState,
	logical_action: StringName
) -> StringName:
	match logical_action:
		&"Eat":
			return (state as NpcStateEat).eat_value_name if state is NpcStateEat else &"hunger"
		&"Rest":
			return (state as NpcStateRest).rest_value_name if state is NpcStateRest else &"tired"
		&"Recreation":
			return (state as NpcStateRecreation).recreation_value_name if state is NpcStateRecreation else &"boredom"
		&"Sleep":
			return (state as NpcStateSleep).sleep_value_name if state is NpcStateSleep else &"sleep_need"
		&"Work":
			return (state as NpcStateWork).work_value_name if state is NpcStateWork else &"boredom"
	return &""


func _get_stable_activity_target_id(
	candidate: Node,
	logical_action: StringName
) -> String:
	return NpcActivityIdentity.get_persistent_spot_id(
		candidate,
		logical_action
	).strip_edges()


func _target_suppression_reason_code(decision: Dictionary) -> StringName:
	match StringName(String(decision.get("memory_event_type", ""))):
		&"target_unavailable":
			return &"recent_target_unavailable"
		&"movement_failed":
			return &"recent_movement_failure"
		&"intention_target_lost":
			return &"recent_intention_target_lost"
	return &"recent_target_failure"


func _can_start_look_for_talk_target() -> bool:
	if not block_talk_search_while_moving_to_target:
		return true
	if not _current_state_is(&"MoveToTarget"):
		return true

	return active_action != null and active_action.action_kind == &"LookForTalkTarget"


func _resolve_talk_initiating_source(
	requested_source: StringName,
	partner: Node2D,
	reason: String
) -> StringName:
	if requested_source != &"":
		return requested_source
	if _proposed_action != null and _proposed_action.action_kind == &"Talk":
		return _proposed_action.source
	if (
		active_action != null
		and active_action.status == NpcActionSession.Status.ACTIVE
		and active_action.action_kind in [&"Talk", &"LookForTalkTarget"]
	):
		return active_action.source
	var lower_reason := reason.to_lower()
	if lower_reason.contains("schedule"):
		return &"schedule"
	if lower_reason.contains("script"):
		return &"scripted"
	if lower_reason.contains("social"):
		return &"social_ai"
	if lower_reason.contains("player"):
		return &"player"
	# Compatibility: direct legacy calls used the partner type as their only signal.
	if partner != null and is_instance_valid(partner) and partner.is_in_group("player"):
		return &"player"
	if partner != null and is_instance_valid(partner) and partner.is_in_group("npc"):
		return &"social_ai"
	return &"manual"


func _get_talk_request_session_id(talk_source: StringName) -> String:
	if (
		_proposed_action != null
		and _proposed_action.action_kind in [&"Talk", &"LookForTalkTarget"]
		and _proposed_action.source == talk_source
	):
		return _proposed_action.session_id
	if (
		active_action != null
		and active_action.status == NpcActionSession.Status.ACTIVE
		and active_action.action_kind in [&"Talk", &"LookForTalkTarget"]
		and active_action.source == talk_source
	):
		return active_action.session_id
	return ""


func _has_available_autonomous_talk_target(rule: Dictionary) -> bool:
	if npc == null or not npc.is_inside_tree():
		return false

	var allowed_groups = rule.get("target_groups", [&"npc", &"player"])
	if not (allowed_groups is Array) or allowed_groups.is_empty():
		allowed_groups = [&"npc", &"player"]

	for group_name in allowed_groups:
		for candidate in npc.get_tree().get_nodes_in_group(String(group_name)):
			var candidate_node := candidate as Node2D
			if _rule_allows_target(rule, candidate_node):
				return true

	return false


func _apply_threshold_effects(changed_values: Dictionary) -> void:
	# Applies one-shot side effects, such as talk_need 100 adding lonely.
	if changed_values.is_empty():
		return

	var effect_delta := _collect_threshold_effect_delta(changed_values)
	if effect_delta.is_empty():
		return

	var normalized_delta := _normalize_value_delta(effect_delta)
	_remove_stored_only_values(normalized_delta)
	for value_key in normalized_delta.keys():
		var key := String(value_key)
		var previous_value := _variant_to_float(values.get(key, 0.0))
		var next_value := previous_value + _variant_to_float(normalized_delta[value_key])

		if clamp_percent_values:
			next_value = clampf(next_value, 0.0, 100.0)

		values[key] = next_value

		var actual_delta := next_value - previous_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_values[key] = _variant_to_float(changed_values.get(key, 0.0)) + actual_delta


func _collect_threshold_effect_delta(changed_values: Dictionary) -> Dictionary:
	# Builds a combined delta from every threshold effect crossed this value change.
	var effect_delta := {}

	for effect_name in value_threshold_effects.keys():
		var effect = value_threshold_effects[effect_name]
		if not (effect is Dictionary):
			continue

		var effect_dictionary: Dictionary = effect
		var value_key := _canonical_value_key(effect_dictionary.get("value", effect_name))
		if _is_stored_only_value(value_key):
			continue
		if not changed_values.has(value_key):
			continue

		var current_value := _variant_to_float(values.get(value_key, 0.0))
		var changed_delta := _variant_to_float(changed_values.get(value_key, 0.0))
		var previous_value := current_value - changed_delta

		if not _threshold_effect_matches(effect_dictionary, previous_value, current_value):
			continue

		var delta = effect_dictionary.get("delta", {})
		if not (delta is Dictionary):
			continue

		var normalized_delta := _normalize_value_delta(delta)
		for delta_key in normalized_delta.keys():
			var key := String(delta_key)
			effect_delta[key] = (
				_variant_to_float(effect_delta.get(key, 0.0))
				+ _variant_to_float(normalized_delta[delta_key])
			)

	return effect_delta


func _threshold_effect_matches(effect: Dictionary, previous_value: float, current_value: float) -> bool:
	# Returns true only when a value crosses into the configured cap/threshold.
	var has_condition := false

	if effect.has("at_least"):
		has_condition = true
		var threshold := _variant_to_float(effect["at_least"])
		if previous_value >= threshold or current_value < threshold:
			return false

	if effect.has("at_most"):
		has_condition = true
		var threshold := _variant_to_float(effect["at_most"])
		if previous_value <= threshold or current_value > threshold:
			return false

	return has_condition


func _get_rule_request_actor(actor: Node2D, rule: Dictionary) -> Node2D:
	# Chooses only explicit event/perception candidates; it never borrows another action's target.
	# Passive location activities resolve their own authored spot and must not turn the
	# most recent social actor into a destination.
	var requested_state := StringName(String(rule.get("state", "")))
	if requested_state in [&"Eat", &"Rest", &"Recreation"]:
		return null
	if (
		requested_state == &"Talk"
		and StringName(String(rule.get("behavior_source", ""))) == &"social_ai"
	):
		var social_candidates: Array[Node2D] = []
		var seen_social_candidates: Dictionary = {}
		_append_social_rule_candidate(
			social_candidates,
			seen_social_candidates,
			actor,
			rule
		)
		_append_social_rule_candidate(
			social_candidates,
			seen_social_candidates,
			get_selected_threat(),
			rule
		)
		for perceived_target in get_perceived_targets():
			_append_social_rule_candidate(
				social_candidates,
				seen_social_candidates,
				perceived_target,
				rule
			)
		return select_ranked_autonomous_social_target(
			social_candidates
		).get("target_node", null) as Node2D
	if _rule_allows_target(rule, actor):
		return actor

	var threat := get_selected_threat()
	if _rule_allows_target(rule, threat):
		return threat

	for perceived_target in get_perceived_targets():
		if _rule_allows_target(rule, perceived_target):
			return perceived_target

	if bool(rule.get("requires_target", false)):
		return null

	return null


func _append_social_rule_candidate(
	candidates: Array[Node2D],
	seen_candidates: Dictionary,
	candidate: Node2D,
	rule: Dictionary
) -> void:
	if not _rule_allows_target(rule, candidate):
		return
	var instance_id := candidate.get_instance_id()
	if seen_candidates.has(instance_id):
		return
	seen_candidates[instance_id] = true
	candidates.append(candidate)


func _rule_allows_target(rule: Dictionary, candidate: Node2D) -> bool:
	# Checks whether a candidate target belongs to any group allowed by the rule.
	if candidate == null or not is_instance_valid(candidate):
		return false
	if candidate == npc:
		return false
	if is_ignoring_player_interaction(candidate):
		return false
	if is_talk_refusal_on_cooldown(candidate):
		return false

	var allowed_groups = rule.get("target_groups", [])
	if not (allowed_groups is Array) or allowed_groups.is_empty():
		return (
			_rule_allows_target_relationship(rule, candidate)
			and _social_memory_allows_rule_target(rule, candidate)
		)

	for group_name in allowed_groups:
		if candidate.is_in_group(String(group_name)):
			return (
				_rule_allows_target_relationship(rule, candidate)
				and _social_memory_allows_rule_target(rule, candidate)
			)

	return false


func _rule_allows_target_relationship(rule: Dictionary, candidate: Node2D) -> bool:
	# Optional rule gate for NPC targets: avoid social talk with characters this NPC dislikes.
	if not candidate.is_in_group("npc"):
		return true
	if not rule.has("min_relationship_favor"):
		return true

	return _get_relationship_favor_for_target(candidate) > _variant_to_float(rule["min_relationship_favor"])


func _social_memory_allows_rule_target(
	rule: Dictionary,
	candidate: Node2D
) -> bool:
	if (
		String(rule.get("behavior_source", "")) != "social_ai"
		or String(rule.get("state", "")) != "Talk"
	):
		return true
	return bool(get_autonomous_social_memory_decision(candidate).get(
		"allowed",
		true
	))


func get_autonomous_social_memory_decision(candidate: Node2D) -> Dictionary:
	# Memory is persisted, so unlike the live handshake it must never use a
	# transient scene-tree path as an actor identity.
	var candidate_id := NpcIdentity.get_stable_actor_id(candidate)
	var remembering_npc_id := NpcIdentity.get_stable_actor_id(npc)
	if (
		short_term_memory == null
		or candidate_id.is_empty()
		or remembering_npc_id.is_empty()
	):
		return {
			"allowed": true,
			"candidate_id": StringName(candidate_id),
			"reason_code": &"",
			"memory_event_type": &"",
			"memory_id": "",
			"remaining_retry_hours": 0.0,
			"retry_game_hours": 0.0,
		}
	return _social_memory_policy.evaluate_candidate(
		short_term_memory,
		StringName(candidate_id),
		_get_world_total_hours(),
		{
			"remembering_npc_id": remembering_npc_id,
			"recent_refusal_retry_delay_game_hours": (
				recent_refusal_retry_delay_game_hours
			),
			"recent_harm_social_delay_game_hours": (
				recent_harm_social_delay_game_hours
			),
			"recent_conversation_repeat_delay_game_hours": (
				recent_conversation_repeat_delay_game_hours
			),
		}
	)


func select_ranked_autonomous_social_target(candidates: Array[Node2D]) -> Dictionary:
	var requester_id := _get_action_owner_id()
	var preferred_target_id := _get_authored_social_preference_target_id()
	var relationships := get_node_or_null("/root/Relationships")
	var requester_relationship_id := _get_relationship_id_for_actor(
		relationships,
		npc,
		requester_id
	)
	var scored: Array[Dictionary] = []
	for candidate in candidates:
		var candidate_id := _get_social_candidate_id(candidate)
		if candidate_id.is_empty():
			continue
		var candidate_relationship_id := _get_relationship_id_for_actor(
			relationships,
			candidate,
			candidate_id
		)
		var relationship := _get_directed_relationship_snapshot(
			relationships,
			requester_relationship_id,
			candidate_relationship_id
		)
		var live_distance := (
			npc.global_position.distance_to(candidate.global_position)
			if npc != null and is_instance_valid(npc)
			else 0.0
		)
		var score := _social_candidate_scorer.score_candidate(
			StringName(requester_id),
			StringName(candidate_id),
			{
				"relationship": relationship,
				"is_authored_preference": (
					preferred_target_id == candidate_id
				),
				"has_live_distance": npc != null,
				"live_distance": live_distance,
			}
		)
		scored.append({
			"target_node": candidate,
			"candidate_id": candidate_id,
			"score": score,
		})
	scored.sort_custom(_live_social_candidate_precedes)
	var diagnostics: Array[Dictionary] = []
	for entry in scored:
		var score_descriptor: Dictionary = entry.score.duplicate(true)
		score_descriptor["allowed"] = true
		diagnostics.append(score_descriptor)
	var selected_target: Node2D
	var selected_candidate_id := ""
	if not scored.is_empty():
		selected_target = scored[0].target_node as Node2D
		selected_candidate_id = String(scored[0].candidate_id)
	_social_scoring_descriptor = {
		"requester_id": StringName(requester_id),
		"evaluated_game_hours": _get_world_total_hours(),
		"evaluated_at_usec": Time.get_ticks_usec(),
		"candidate_count": scored.size(),
		"selected_candidate_id": StringName(selected_candidate_id),
		"candidates": diagnostics,
	}
	return {
		"target_node": selected_target,
		"descriptor": _social_scoring_descriptor.duplicate(true),
	}


func get_social_scoring_debug_descriptor() -> Dictionary:
	return _social_scoring_descriptor.duplicate(true)


func clear_social_scoring_debug_descriptor() -> void:
	_social_scoring_descriptor.clear()


func _get_social_candidate_id(candidate: Node2D) -> String:
	if candidate == null or not is_instance_valid(candidate):
		return ""
	if not candidate.is_in_group("player") and not candidate.is_in_group("npc"):
		return ""
	# Live handshakes and session matching still support identity-free legacy
	# actors. Memory-writing and memory-query paths resolve stable IDs separately.
	return NpcIdentity.get_actor_id(candidate, true, false)


func _get_authored_social_preference_target_id() -> String:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_record_snapshot"):
		return ""
	var record = locations.call("get_record_snapshot", _get_action_owner_id())
	if not (record is Dictionary):
		return ""
	return String(record.get("social_visit_target_id", "")).strip_edges()


func _get_relationship_id_for_actor(
	relationships: Node,
	actor: Node,
	fallback: String
) -> String:
	if (
		relationships != null
		and actor != null
		and relationships.has_method("get_relationship_id")
	):
		var relationship_id := String(relationships.call(
			"get_relationship_id",
			actor
		)).strip_edges()
		if not relationship_id.is_empty():
			return relationship_id
	var stable_actor_id := NpcIdentity.get_stable_actor_id(actor)
	if not stable_actor_id.is_empty():
		return stable_actor_id
	return fallback.strip_edges()


func _get_directed_relationship_snapshot(
	relationships: Node,
	requester_id: String,
	candidate_id: String
) -> Dictionary:
	if (
		relationships == null
		or not relationships.has_method("get_relationship_by_id")
		or requester_id.is_empty()
		or candidate_id.is_empty()
	):
		return {}
	var snapshot = relationships.call(
		"get_relationship_by_id",
		requester_id,
		candidate_id
	)
	return snapshot.duplicate(true) if snapshot is Dictionary else {}


static func _live_social_candidate_precedes(a: Dictionary, b: Dictionary) -> bool:
	var a_score: Dictionary = a.get("score", {})
	var b_score: Dictionary = b.get("score", {})
	var a_total := float(a_score.get("total_score", 0.0))
	var b_total := float(b_score.get("total_score", 0.0))
	if not is_equal_approx(a_total, b_total):
		return a_total > b_total
	var a_distance := float(a_score.get("live_distance", 0.0))
	var b_distance := float(b_score.get("live_distance", 0.0))
	if not is_equal_approx(a_distance, b_distance):
		return a_distance < b_distance
	return String(a.get("candidate_id", "")) < String(
		b.get("candidate_id", "")
	)


func _get_relationship_favor_for_target(candidate: Node) -> float:
	if npc != null and npc.has_method("get_relationship_favor_for"):
		return float(npc.call("get_relationship_favor_for", candidate, 50.0))

	var relationships := get_node_or_null("/root/Relationships")
	if relationships != null and relationships.has_method("get_favor"):
		return float(relationships.call("get_favor", npc, candidate, 50.0))

	return 50.0


func _rule_matches(
	rule: Dictionary,
	value,
	value_delta,
	value_changed: bool
) -> bool:
	# Checks numeric, idle, delta, and time conditions for one value-state rule.
	var has_condition := false

	if bool(rule.get("requires_idle", false)) and not _current_state_is(&"Idle"):
		return false

	if not _rule_time_matches(rule):
		return false

	if bool(rule.get("only_when_changed", false)) and not value_changed:
		return false

	if rule.has("truthy"):
		has_condition = true
		if _variant_is_truthy(value) != bool(rule["truthy"]):
			return false

	if rule.has("at_least"):
		has_condition = true
		if _variant_to_float(value) < _variant_to_float(rule["at_least"]):
			return false

	if rule.has("at_most"):
		has_condition = true
		if _variant_to_float(value) > _variant_to_float(rule["at_most"]):
			return false

	if rule.has("equals"):
		has_condition = true
		if value != rule["equals"]:
			return false

	if rule.has("not_equals"):
		has_condition = true
		if value == rule["not_equals"]:
			return false

	if rule.has("delta_at_least"):
		has_condition = true
		if not value_changed:
			return false
		if _variant_to_float(value_delta) < _variant_to_float(rule["delta_at_least"]):
			return false

	if rule.has("delta_at_most"):
		has_condition = true
		if not value_changed:
			return false
		if _variant_to_float(value_delta) > _variant_to_float(rule["delta_at_most"]):
			return false

	return has_condition


func _current_state_is(state_name: StringName) -> bool:
	# Keeps idle-gated rules readable.
	return current_state != null and String(current_state.name) == String(state_name)


func _rule_time_matches(rule: Dictionary) -> bool:
	# Supports rules like "rest only before noon" using the WorldTime autoload.
	if not _rule_has_time_condition(rule):
		return true

	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_method("get_snapshot"):
		return false

	var snapshot: Dictionary = world_time.call("get_snapshot")
	var hour := _variant_to_float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))

	if rule.has("time_windows") and not _time_windows_match(rule["time_windows"], hour):
		return false

	if rule.has("before_hour") and hour >= _variant_to_float(rule["before_hour"]):
		return false

	if rule.has("after_hour") and hour < _variant_to_float(rule["after_hour"]):
		return false

	if rule.has("periods"):
		var periods = rule["periods"]
		if periods is Array:
			var current_period := String(snapshot.get("period", ""))
			var period_matches := false
			for period in periods:
				if String(period) == current_period:
					period_matches = true
					break
			if not period_matches:
				return false

	return true


func _rule_has_time_condition(rule: Dictionary) -> bool:
	# Fast check before asking WorldTime for a snapshot.
	return (
		rule.has("before_hour")
		or rule.has("after_hour")
		or rule.has("periods")
		or rule.has("time_windows")
	)


func _time_windows_match(windows, hour: float) -> bool:
	if not (windows is Array):
		return false

	for window in windows:
		if not (window is Dictionary):
			continue

		if _time_window_matches(window, hour):
			return true

	return false


func _time_window_matches(window: Dictionary, hour: float) -> bool:
	var start_hour := _variant_to_float(window.get("start_hour", window.get("start", 0.0)))
	var end_hour := _variant_to_float(window.get("end_hour", window.get("end", 24.0)))
	start_hour = fposmod(start_hour, 24.0)
	end_hour = fposmod(end_hour, 24.0)
	var normalized_hour := fposmod(hour, 24.0)

	if is_equal_approx(start_hour, end_hour):
		return true

	if start_hour < end_hour:
		return normalized_hour >= start_hour and normalized_hour < end_hour

	return normalized_hour >= start_hour or normalized_hour < end_hour


func _variant_to_float(value) -> float:
	match typeof(value):
		TYPE_BOOL:
			return 1.0 if bool(value) else 0.0
		TYPE_INT, TYPE_FLOAT:
			return float(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return float(String(value))
		_:
			return 0.0


func _variant_is_truthy(value) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return bool(value)
		TYPE_INT, TYPE_FLOAT:
			return not is_equal_approx(float(value), 0.0)
		TYPE_STRING, TYPE_STRING_NAME:
			return not String(value).is_empty()
		_:
			return value != null


func _normalize_value_dictionary(source_values: Dictionary) -> Dictionary:
	var normalized := source_values.duplicate(true)
	_normalize_values_in_place(normalized)
	return normalized


func _normalize_values_in_place(target_values: Dictionary) -> void:
	for old_key in VALUE_ALIASES.keys():
		if not target_values.has(old_key):
			continue

		var new_key := String(VALUE_ALIASES[old_key])
		if not target_values.has(new_key):
			target_values[new_key] = target_values[old_key]
		target_values.erase(old_key)
	for deprecated_key in DEPRECATED_GLOBAL_VALUE_KEYS:
		target_values.erase(deprecated_key)


func _normalize_value_delta(value_delta: Dictionary) -> Dictionary:
	var normalized := {}
	for value_key in value_delta.keys():
		var key := _canonical_value_key(value_key)
		if DEPRECATED_GLOBAL_VALUE_KEYS.has(key):
			continue
		normalized[key] = _variant_to_float(normalized.get(key, 0.0)) + _variant_to_float(value_delta[value_key])

	return normalized


func _canonical_value_key(value_key) -> String:
	var key := String(value_key)
	if VALUE_ALIASES.has(key):
		return String(VALUE_ALIASES[key])

	return key


func _is_stored_only_value(value_key) -> bool:
	return STORED_ONLY_VALUE_KEYS.has(_canonical_value_key(value_key))


func _remove_stored_only_values(value_changes: Dictionary) -> void:
	for value_key in value_changes.keys():
		if _is_stored_only_value(value_key):
			value_changes.erase(value_key)


func _canonical_state_key(state_name) -> String:
	var key := String(state_name)
	if STATE_ALIASES.has(key):
		return String(STATE_ALIASES[key])

	return key


func _set_npc_property_if_exists(property_name: String, value) -> void:
	if npc == null:
		return

	for property in npc.get_property_list():
		if String(property.get("name", "")) == property_name:
			npc.set(property_name, value)
			return


func _get_npc_property_if_exists(property_name: StringName, fallback):
	if npc == null:
		return fallback

	for property in npc.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return npc.get(property_name)

	return fallback


func _update_debug_label() -> void:
	if _debug_label == null or current_state == null:
		return
	_debug_label.visible = developer_state_label_enabled
	if not developer_state_label_enabled:
		return

	var formatted := _format_debug_label_text()
	if _debug_label.text != formatted:
		_debug_label.text = formatted


func _format_debug_label_text() -> String:
	if current_state == null:
		return ""
	var feedback := get_feedback_descriptor()
	return NpcBehaviorFeedbackFormatter.format_label(
		StringName(current_state.name),
		StringName(interaction_overlay.name) if interaction_overlay != null else &"",
		feedback
	)


func get_feedback_descriptor() -> Dictionary:
	var feedback := (
		behavior_controller.get_feedback_descriptor()
		if behavior_controller != null
		else {}
	)
	if short_term_memory != null:
		feedback["memory"] = short_term_memory.get_debug_descriptor(
			_get_world_total_hours()
		)
	var social_selection := _get_active_social_selection_feedback()
	if not social_selection.is_empty():
		feedback["social_selection"] = social_selection
	var target_selection := _get_active_target_selection_feedback()
	if not target_selection.is_empty():
		feedback["target_selection"] = target_selection
	var interaction_memory := get_player_interaction_memory_debug_descriptor()
	if not interaction_memory.is_empty():
		feedback["player_interaction_memory"] = interaction_memory
	return feedback


func set_target_selection_feedback(descriptor: Dictionary) -> void:
	var next_feedback: Dictionary = {}
	if float(descriptor.get("social_affinity_bonus", 0.0)) > 0.0:
		next_feedback = descriptor.duplicate(true)
	elif (
		bool(descriptor.get("all_suppressed", false))
		and String(descriptor.get("reason_code", ""))
			== "all_targets_recently_failed"
	):
		next_feedback = descriptor.duplicate(true)
	if _target_selection_feedback == next_feedback:
		return
	_target_selection_feedback = next_feedback
	policy_feedback_changed.emit(&"target", next_feedback.duplicate(true))
	_update_debug_label()


func get_target_selection_debug_descriptor() -> Dictionary:
	return _get_active_target_selection_feedback()


func _get_active_target_selection_feedback() -> Dictionary:
	if _target_selection_feedback.is_empty():
		return {}
	if float(_target_selection_feedback.get("social_affinity_bonus", 0.0)) > 0.0:
		return _target_selection_feedback.duplicate(true)
	var retry_game_hours := float(_target_selection_feedback.get(
		"earliest_retry_game_hours",
		0.0
	))
	var remaining_retry_hours := retry_game_hours - _get_world_total_hours()
	if remaining_retry_hours <= 0.0:
		return {}
	var active_feedback := _target_selection_feedback.duplicate(true)
	active_feedback["remaining_retry_hours"] = remaining_retry_hours
	return active_feedback


func set_social_selection_feedback(descriptor: Dictionary) -> void:
	var next_feedback: Dictionary = {}
	if (
		bool(descriptor.get("all_candidates_suppressed", false))
		and String(descriptor.get("reason_code", "")) in [
			"no_social_target_due_to_recent_refusal",
			"no_social_target_due_to_recent_memory",
		]
	):
		# The world retains the full candidate diagnostics. The live feedback path
		# only needs the aggregate retry data, so do not clone or retain the large
		# candidate arrays again for every NPC and signal emission.
		next_feedback = descriptor.duplicate(false)
		next_feedback.erase("candidate_decisions")
		next_feedback.erase("candidates")
		var suppressed_by_reason = next_feedback.get("suppressed_by_reason", {})
		if suppressed_by_reason is Dictionary:
			next_feedback["suppressed_by_reason"] = suppressed_by_reason.duplicate(true)
	var semantic_changed := (
		_get_social_feedback_semantic_snapshot(_social_selection_feedback)
		!= _get_social_feedback_semantic_snapshot(next_feedback)
	)
	# Retain the newest freshness envelope even when the player-facing outcome
	# has not changed. Debug readers stay current without another feedback cue.
	_social_selection_feedback = next_feedback
	if not semantic_changed:
		return
	policy_feedback_changed.emit(&"social", next_feedback.duplicate(true))
	_update_debug_label()


static func _get_social_feedback_semantic_snapshot(
	descriptor: Dictionary
) -> Dictionary:
	var semantic := descriptor.duplicate(true)
	for field_name in SOCIAL_FEEDBACK_VOLATILE_FIELDS:
		semantic.erase(field_name)
	return semantic


func _get_active_social_selection_feedback() -> Dictionary:
	if _social_selection_feedback.is_empty():
		return {}
	var retry_game_hours := float(_social_selection_feedback.get(
		"earliest_retry_game_hours",
		0.0
	))
	var remaining_retry_hours := retry_game_hours - _get_world_total_hours()
	if remaining_retry_hours <= 0.0:
		return {}
	var active_feedback := _social_selection_feedback.duplicate(true)
	active_feedback["remaining_retry_hours"] = remaining_retry_hours
	return active_feedback


func _value_reactions_enabled() -> bool:
	if not value_reactions_enabled:
		return false
	return not (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_VALUE_REACTIONS
	)


func _verbose_npc_logging_enabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_ENABLE_VERBOSE_NPC_LOGS
	)


func _record_value_threshold_crossings(
	previous_values: Dictionary,
	next_values: Dictionary,
	changed_values: Dictionary
) -> void:
	if not (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_ENABLE_VERBOSE_NPC_LOGS
	):
		return
	if changed_values.is_empty():
		return

	for changed_key in changed_values.keys():
		var value_key := _canonical_value_key(changed_key)
		var thresholds := _get_breadcrumb_thresholds(value_key)
		if thresholds.is_empty():
			continue

		var previous_value := _variant_to_float(previous_values.get(value_key, 0.0))
		var next_value := _variant_to_float(next_values.get(value_key, previous_value))
		if is_equal_approx(previous_value, next_value):
			continue

		for threshold in thresholds:
			var threshold_value := float(threshold)
			if previous_value < threshold_value and next_value >= threshold_value:
				_breadcrumb(
					"npc_state:value_cross_up",
					"%s %s %.2f->%.2f >= %.1f" % [
						_get_npc_label(),
						value_key,
						previous_value,
						next_value,
						threshold_value,
					]
				)
			elif previous_value > threshold_value and next_value <= threshold_value:
				_breadcrumb(
					"npc_state:value_cross_down",
					"%s %s %.2f->%.2f <= %.1f" % [
						_get_npc_label(),
						value_key,
						previous_value,
						next_value,
						threshold_value,
					]
				)


func _get_breadcrumb_thresholds(value_key: String) -> Array:
	match value_key:
		"hunger":
			return [100.0, 90.0, 75.0, 70.0, 0.0]
		"tired":
			return [100.0, 75.0, 50.0, 45.0]
		"sleep_need":
			return [100.0, 90.0]
		"talk_need":
			return [100.0, 70.0, 50.0]
		"boredom":
			return [100.0, 75.0, 50.0]
	return []


func _get_npc_label() -> String:
	if npc != null and is_instance_valid(npc):
		if npc.has_method("get_npc_location_id"):
			var npc_id := String(npc.call("get_npc_location_id")).strip_edges()
			if not npc_id.is_empty():
				return "%s(%s)" % [npc.name, npc_id]
		if npc.has_meta("npc_location_id"):
			var meta_id := String(npc.get_meta("npc_location_id")).strip_edges()
			if not meta_id.is_empty():
				return "%s(%s)" % [npc.name, meta_id]
		return npc.name

	return name


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
