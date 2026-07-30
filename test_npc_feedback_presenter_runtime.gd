extends "res://test/native_scene_tree_test.gd"

const Cue = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_cue.gd"
)
const Catalog = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_catalog.gd"
)
const Presenter = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_presenter.gd"
)
const Adapter = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_adapter.gd"
)
const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)


func test_cue_model_uses_structured_identity_and_copies_metadata() -> void:
	var source_metadata := {
		"identity_key": "hunger_high",
		"nested": {"value": 3},
	}
	var cue: Cue = Cue.create(&"hunger_high", {
		"fallback_text": "Hungry",
		"text_key": &"npc_feedback.hunger_high",
		"source_intent_id": "intent:one",
		"metadata": source_metadata,
	})
	source_metadata.nested.value = 99
	assert_false(cue.cue_id.is_empty(), "cue receives a stable runtime identity")
	assert_eq(cue.metadata.nested.value, 3, "cue metadata is deeply copied")
	var identity: String = cue.get_identity_key()
	cue.fallback_text = "Different rendering"
	assert_eq(
		cue.get_identity_key(),
		identity,
		"rendered text does not determine cue identity"
	)
	assert_true(
		cue.maximum_lifetime_seconds >= cue.duration_seconds,
		"absolute lifetime cannot be shorter than visible duration"
	)


func test_catalog_maps_codes_and_keeps_localization_separate() -> void:
	var known := Catalog.resolve(&"hunger_high")
	assert_true(bool(known.known), "known structured code resolves")
	assert_eq(known.fallback_text, "Hungry", "known code has concise fallback")
	assert_eq(
		known.text_key,
		&"npc_feedback.hunger_high",
		"localization key remains stable and separate"
	)
	var unknown := Catalog.resolve(&"future_status")
	assert_false(bool(unknown.known), "unknown code is marked safely")
	assert_false(
		String(unknown.fallback_text).is_empty(),
		"unknown code still has a safe fallback"
	)


func test_presenter_starts_expires_and_dismisses_idempotently() -> void:
	var fixture := _presenter_fixture()
	var presenter: Presenter = fixture.presenter
	var cue := Catalog.create_cue(&"hunger_high", {
		"duration_seconds": 0.1,
	})
	assert_true(bool(presenter.submit_cue(cue).accepted), "first cue starts")
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		&"hunger_high",
		"first cue becomes current"
	)
	presenter._process(0.11)
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"cue hides after its duration"
	)
	assert_false(presenter.dismiss_current(), "dismissal is idempotent when empty")


func test_presenter_deduplicates_and_prioritizes_problem_cues() -> void:
	var presenter: Presenter = _presenter_fixture().presenter
	var hunger := Catalog.create_cue(&"hunger_high")
	assert_true(bool(presenter.submit_cue(hunger).accepted), "hunger starts")
	assert_false(
		bool(presenter.submit_cue(Catalog.create_cue(
			&"hunger_high"
		)).accepted),
		"duplicate hunger is rejected during active cooldown"
	)
	assert_true(bool(presenter.submit_cue(Catalog.create_cue(
		&"movement_failed"
	)).accepted), "problem cue is accepted")
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		&"movement_failed",
		"higher-priority problem replaces need cue"
	)
	presenter.submit_cue(Catalog.create_cue(&"tired_high"))
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		&"movement_failed",
		"lower-priority need cannot replace a problem"
	)


func test_presenter_queue_is_bounded_and_deterministic() -> void:
	var presenter: Presenter = _presenter_fixture().presenter
	presenter.maximum_queue_size = 2
	presenter.submit_cue(_custom_cue("active", 100, Cue.QUEUE))
	presenter.submit_cue(_custom_cue("low", 10, Cue.QUEUE))
	presenter.submit_cue(_custom_cue("middle", 20, Cue.QUEUE))
	var rejected := presenter.submit_cue(
		_custom_cue("too_low", 5, Cue.QUEUE)
	)
	assert_false(bool(rejected.accepted), "full bounded queue rejects lower value")
	var queue := presenter.get_queue_descriptor()
	assert_eq(queue.size(), 2, "queue stays bounded")
	assert_eq(queue[0].cue_code, &"middle", "priority deterministically orders queue")
	assert_eq(queue[1].cue_code, &"low", "lower priority follows")
	presenter.submit_cue(_custom_cue(
		"problem",
		70,
		Cue.QUEUE,
		Cue.CATEGORY_PROBLEM
	))
	queue = presenter.get_queue_descriptor()
	assert_eq(queue[0].cue_code, &"problem", "problem displaces a lower queued cue")


func test_clear_stops_processing_and_visual_is_reused_without_icon() -> void:
	var fixture := _presenter_fixture()
	var presenter: Presenter = fixture.presenter
	var visual_id := int(presenter.get_debug_descriptor().visual_instance_id)
	presenter.submit_cue(Catalog.create_cue(&"hunger_high"))
	presenter.dismiss_current()
	presenter.submit_cue(Catalog.create_cue(&"movement_failed"))
	assert_eq(
		presenter.get_debug_descriptor().visual_instance_id,
		visual_id,
		"cue changes reuse the existing visual tree"
	)
	assert_true(
		presenter.get_current_cue_descriptor().cue_code == &"movement_failed",
		"missing icon does not prevent text cue"
	)
	presenter.clear_all(&"test")
	assert_false(presenter.is_processing(), "clear stops active processing")
	assert_eq(presenter.get_queue_descriptor().size(), 0, "clear empties queue")


func test_visibility_uses_distance_and_suppression_without_losing_cue() -> void:
	var fixture := _presenter_fixture(true)
	var presenter: Presenter = fixture.presenter
	var npc: Node2D = fixture.npc
	var player := Node2D.new()
	player.add_to_group("player")
	player.position = Vector2(500.0, 0.0)
	add_child_autofree(player)
	presenter.submit_cue(Catalog.create_cue(&"hunger_high"))
	presenter._process(0.21)
	assert_false(
		bool(presenter.get_debug_descriptor().visible),
		"distant NPC cue remains hidden"
	)
	player.position = npc.position + Vector2(20.0, 0.0)
	presenter._process(0.21)
	assert_true(
		bool(presenter.get_debug_descriptor().visible),
		"nearby player makes cue visible"
	)
	presenter.set_feedback_suppressed(&"modal_dialogue", true)
	assert_false(
		bool(presenter.get_debug_descriptor().visible),
		"suppression hides ordinary feedback"
	)
	assert_false(
		presenter.get_current_cue_descriptor().is_empty(),
		"suppression does not delete the timed cue"
	)
	presenter.set_feedback_suppressed(&"modal_dialogue", false)
	assert_true(
		bool(presenter.get_debug_descriptor().visible),
		"cue can become visible again while still current"
	)


func test_visible_timing_pauses_hidden_and_presents_only_once() -> void:
	var fixture := _presenter_fixture(true)
	var presenter: Presenter = fixture.presenter
	var npc: Node2D = fixture.npc
	var player := Node2D.new()
	player.add_to_group("player")
	player.position = npc.position + Vector2(20.0, 0.0)
	add_child_autofree(player)
	var presented := {"count": 0}
	var visibility_changes: Array[bool] = []
	presenter.cue_presented.connect(func(_descriptor: Dictionary) -> void:
		presented.count += 1
	)
	presenter.cue_visibility_changed.connect(
		func(_descriptor: Dictionary, visible: bool) -> void:
			visibility_changes.append(visible)
	)
	var cue: Cue = Cue.create(&"timed_visibility", {
		"fallback_text": "Timed",
		"duration_seconds": 1.0,
		"maximum_lifetime_seconds": 3.0,
		"cooldown_seconds": 5.0,
	})
	presenter.submit_cue(cue)
	var descriptor := presenter.get_current_cue_descriptor()
	assert_true(bool(descriptor.currently_visible), "nearby cue is visible immediately")
	assert_true(bool(descriptor.has_been_presented), "immediate visibility presents cue")
	assert_eq(presented.count, 1, "first visibility emits one presentation")
	assert_eq(visibility_changes, [true], "first visibility is one transition")
	assert_true(
		presenter.is_code_on_cooldown(&"timed_visibility"),
		"first actual presentation starts cooldown"
	)
	var cooldown_key: String = cue.get_cooldown_key()
	var first_cooldown_expiry := int(
		presenter._cooldown_expiry_usec_by_key.get(cooldown_key, 0)
	)
	presenter._process(0.2)
	descriptor = presenter.get_current_cue_descriptor()
	assert_true(
		float(descriptor.visible_elapsed_seconds) >= 0.19,
		"visible time advances while the visual is visible"
	)
	player.position = npc.position + Vector2(500.0, 0.0)
	presenter._update_visual_visibility()
	var visible_before_distance := float(
		presenter.get_current_cue_descriptor().visible_elapsed_seconds
	)
	var absolute_before_distance := float(
		presenter.get_current_cue_descriptor().absolute_elapsed_seconds
	)
	presenter._process(0.3)
	descriptor = presenter.get_current_cue_descriptor()
	assert_true(
		is_equal_approx(
			float(descriptor.visible_elapsed_seconds),
			visible_before_distance
		),
		"visible time pauses while the player is distant"
	)
	assert_true(
		float(descriptor.absolute_elapsed_seconds)
			> absolute_before_distance + 0.29,
		"absolute time continues while the cue is distant"
	)
	player.position = npc.position + Vector2(20.0, 0.0)
	presenter._update_visual_visibility()
	presenter._process(0.2)
	var visible_before_suppression := float(
		presenter.get_current_cue_descriptor().visible_elapsed_seconds
	)
	var absolute_before_suppression := float(
		presenter.get_current_cue_descriptor().absolute_elapsed_seconds
	)
	presenter.set_feedback_suppressed(&"test_modal", true)
	presenter._process(0.25)
	descriptor = presenter.get_current_cue_descriptor()
	assert_true(
		is_equal_approx(
			float(descriptor.visible_elapsed_seconds),
			visible_before_suppression
		),
		"visible time pauses during suppression"
	)
	assert_true(
		float(descriptor.absolute_elapsed_seconds)
			> absolute_before_suppression + 0.24,
		"absolute time continues during suppression"
	)
	presenter.set_feedback_suppressed(&"test_modal", false)
	assert_true(
		bool(presenter.get_current_cue_descriptor().currently_visible),
		"removing suppression resumes visibility immediately"
	)
	assert_eq(presented.count, 1, "repeated visibility does not present twice")
	assert_eq(
		int(presenter._cooldown_expiry_usec_by_key.get(cooldown_key, 0)),
		first_cooldown_expiry,
		"repeated visibility does not restart cooldown"
	)
	assert_eq(
		visibility_changes,
		[true, false, true, false, true],
		"visibility signal emits only real transitions"
	)
	presenter._process(0.7)
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"resumed cue finishes after its remaining visible duration"
	)


func test_unseen_lifetime_expires_without_cooldown() -> void:
	var presenter: Presenter = _presenter_fixture(true).presenter
	var finished: Array[Dictionary] = []
	presenter.cue_finished.connect(func(descriptor: Dictionary) -> void:
		finished.append(descriptor)
	)
	var cue: Cue = Cue.create(&"unseen", {
		"fallback_text": "Unseen",
		"duration_seconds": 0.2,
		"maximum_lifetime_seconds": 0.5,
		"cooldown_seconds": 5.0,
	})
	assert_true(bool(presenter.submit_cue(cue).accepted), "hidden cue is selected")
	assert_false(
		presenter.is_code_on_cooldown(&"unseen"),
		"selection alone creates no cooldown"
	)
	presenter._process(0.51)
	assert_eq(finished.size(), 1, "maximum lifetime finishes unseen cue")
	assert_eq(
		finished[0].finish_reason,
		&"unseen_lifetime_expired",
		"unseen expiry has a structured reason"
	)
	assert_false(
		bool(finished[0].has_been_presented),
		"unseen expiry records that presentation never happened"
	)
	assert_false(
		presenter.is_code_on_cooldown(&"unseen"),
		"unseen expiry still creates no cooldown"
	)
	assert_true(
		bool(presenter.submit_cue(Cue.create(&"unseen", {
			"fallback_text": "Unseen",
			"duration_seconds": 0.2,
			"maximum_lifetime_seconds": 0.5,
			"cooldown_seconds": 5.0,
		})).accepted),
		"same cue can be selected again after unseen expiry"
	)


func test_presented_hidden_cue_has_bounded_absolute_lifetime() -> void:
	var presenter: Presenter = _presenter_fixture().presenter
	var finished: Array[Dictionary] = []
	presenter.cue_finished.connect(func(descriptor: Dictionary) -> void:
		finished.append(descriptor)
	)
	presenter.submit_cue(Cue.create(&"bounded_hidden", {
		"fallback_text": "Bounded",
		"duration_seconds": 1.0,
		"maximum_lifetime_seconds": 1.2,
		"cooldown_seconds": 0.0,
	}))
	presenter._process(0.1)
	presenter.set_feedback_suppressed(&"test", true)
	presenter._process(1.11)
	assert_eq(finished.size(), 1, "hidden presented cue cannot wait indefinitely")
	assert_eq(
		finished[0].finish_reason,
		&"maximum_lifetime_elapsed",
		"presented maximum-lifetime expiry is distinct"
	)
	assert_true(bool(finished[0].has_been_presented), "presentation is retained")


func test_expired_queued_cue_is_rejected_before_becoming_current() -> void:
	var presenter: Presenter = _presenter_fixture().presenter
	var rejections: Array[Dictionary] = []
	presenter.cue_rejected.connect(func(descriptor: Dictionary) -> void:
		rejections.append(descriptor)
	)
	presenter.submit_cue(_custom_cue("active_queue_guard", 100, Cue.QUEUE))
	var expired: Cue = Cue.create(&"expired_queue", {
		"fallback_text": "Expired",
		"priority": 10,
		"duration_seconds": 0.1,
		"maximum_lifetime_seconds": 0.2,
		"cooldown_seconds": 0.0,
		"replace_policy": Cue.QUEUE,
		"created_at_usec": Time.get_ticks_usec() - 500000,
	})
	assert_true(bool(presenter.submit_cue(expired).accepted), "expired cue can enter queue")
	presenter.dismiss_current(&"test")
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"expired queued cue never becomes current"
	)
	assert_eq(presenter.get_queue_descriptor().size(), 0, "expired queue entry is pruned")
	assert_eq(rejections.size(), 1, "queue expiry is observable once")
	assert_eq(
		rejections[0].rejection_reason,
		&"queued_lifetime_expired",
		"queue expiry exposes a structured reason"
	)


func test_accepted_intention_submits_once_and_refresh_is_silent() -> void:
	var fixture := _adapter_fixture()
	var controller: NpcBehaviorController = fixture.controller
	var presenter: Presenter = fixture.presenter
	var starts := {"count": 0}
	presenter.cue_started.connect(func(_descriptor: Dictionary) -> void:
		starts.count += 1
	)
	var hunger := _intent(
		&"Eat",
		NpcBehaviorIntent.SOURCE_NEED,
		&"hunger_high",
		"session:hunger"
	)
	controller.commit_candidate(hunger)
	assert_eq(starts.count, 1, "accepted hunger submits one cue")
	var commitment_before := controller.get_remaining_commitment_seconds()
	assert_true(controller.refresh_current_intent(
		hunger.refreshed_copy({"requested_primary_state": &"MoveToTarget"}),
		"session:hunger"
	), "same session refresh succeeds")
	assert_eq(starts.count, 1, "same-session movement refresh submits no cue")
	assert_eq(
		controller.current_intent.action_session_id,
		"session:hunger",
		"presentation does not change session identity"
	)
	assert_true(
		controller.get_remaining_commitment_seconds()
		<= commitment_before,
		"presentation does not extend commitment"
	)


func test_internal_idle_is_silent_and_emergency_replaces_need() -> void:
	var fixture := _adapter_fixture()
	var controller: NpcBehaviorController = fixture.controller
	var presenter: Presenter = fixture.presenter
	controller.commit_candidate(_intent(
		&"Idle",
		NpcBehaviorIntent.SOURCE_INTERNAL,
		&"",
		""
	))
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"internal Idle produces no player cue"
	)
	controller.commit_candidate(_intent(
		&"Eat",
		NpcBehaviorIntent.SOURCE_NEED,
		&"hunger_high",
		"need"
	))
	controller.commit_candidate(_intent(
		&"Flee",
		NpcBehaviorIntent.SOURCE_EMERGENCY,
		&"danger_unknown",
		"emergency"
	))
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		&"emergency",
		"meaningful emergency replaces routine need cue"
	)


func test_new_memory_cues_merge_refresh_and_routine_memory_is_silent() -> void:
	var fixture := _adapter_fixture()
	var memory: NpcShortTermMemory = fixture.memory
	var presenter: Presenter = fixture.presenter
	var starts := {"count": 0}
	var updates := {"count": 0}
	presenter.cue_started.connect(func(_descriptor: Dictionary) -> void:
		starts.count += 1
	)
	presenter.cue_updated.connect(func(_descriptor: Dictionary) -> void:
		updates.count += 1
	)
	memory.remember(_memory_event(
		"refusal",
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.0
	))
	assert_eq(starts.count, 1, "new refusal submits one cue")
	memory.remember(_memory_event(
		"refusal_repeat",
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.1
	))
	assert_eq(starts.count, 1, "merged refusal does not start another cue")
	assert_eq(updates.count, 1, "active merged refusal refreshes existing cue")
	presenter.clear_all(&"test")
	memory.remember(_memory_event(
		"completed",
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED,
		10.2
	))
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"conversation completion is silent by default"
	)


func test_failure_memories_submit_but_import_and_expiry_are_silent() -> void:
	var fixture := _adapter_fixture()
	var memory: NpcShortTermMemory = fixture.memory
	var presenter: Presenter = fixture.presenter
	memory.remember(_memory_event(
		"target",
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		10.0
	))
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		"new target failure submits cue"
	)
	presenter.clear_all(&"test")
	var snapshot := [
		_memory_event(
			"restored",
			MemoryPolicy.EVENT_MOVEMENT_FAILED,
			10.0
		).to_dict(),
	]
	memory.import_snapshot(snapshot, 10.0)
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"snapshot restoration does not replay historical cue"
	)
	memory.prune_expired(12.0)
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"memory expiration is silent"
	)
	memory.remember(_memory_event(
		"new_after_restore",
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		12.0
	))
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		"new live event after restoration displays normally"
	)


func test_policy_final_outcomes_submit_once_and_candidate_inspection_is_silent() -> void:
	var fixture := _adapter_fixture()
	var machine: NpcStateMachine = fixture.machine
	var presenter: Presenter = fixture.presenter
	var starts := {"count": 0}
	presenter.cue_started.connect(func(_descriptor: Dictionary) -> void:
		starts.count += 1
	)
	var social := {
		"all_candidates_suppressed": true,
		"reason_code": &"no_social_target_due_to_recent_refusal",
		"earliest_retry_game_hours": 100.0,
	}
	machine.set_social_selection_feedback(social)
	machine.set_social_selection_feedback(social)
	assert_eq(starts.count, 1, "unchanged all-social-blocked result does not spam")
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		&"all_social_candidates_suppressed",
		"final social suppression submits one concise cue"
	)
	presenter.clear_all(&"test")
	machine.set_target_selection_feedback({
		"all_suppressed": false,
		"reason_code": &"",
	})
	assert_true(
		presenter.get_current_cue_descriptor().is_empty(),
		"successful alternative target creates no blocked-all cue"
	)
	machine.set_target_selection_feedback({
		"all_suppressed": true,
		"reason_code": &"all_targets_recently_failed",
		"logical_action": &"Eat",
		"earliest_retry_game_hours": 100.0,
	})
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		&"all_targets_recently_failed",
		"final target suppression submits one cue"
	)


func test_committed_alternative_target_submits_one_structured_cue() -> void:
	var fixture := _adapter_fixture()
	var machine: NpcStateMachine = fixture.machine
	var presenter: Presenter = fixture.presenter
	var starts := {"count": 0}
	presenter.cue_started.connect(func(_descriptor: Dictionary) -> void:
		starts.count += 1
	)
	var active_before = machine.active_action
	var state_before = machine.current_state
	var descriptor := {
		"reason_code": &"alternative_target_selected",
		"logical_action": &"Eat",
		"selected_target_id": &"second_table",
		"suppressed_count": 1,
		"suppressed_candidates": [{
			"target_id": &"first_table",
			"reason_code": &"recent_movement_failure",
		}],
		"action_session_id": "session:alternative",
		"intent_id": "intent:alternative",
	}
	machine.activity_target_selection_committed.emit(descriptor)
	var current := presenter.get_current_cue_descriptor()
	assert_eq(current.cue_code, &"trying_another_place", "committed outcome maps to cue")
	assert_eq(current.fallback_text, "Trying another place", "player text stays concise")
	assert_eq(
		current.metadata.logical_action,
		"Eat",
		"structured action remains metadata only"
	)
	assert_eq(
		current.metadata.selected_target_id,
		"second_table",
		"stable target participates in identity without being displayed"
	)
	machine.activity_target_selection_committed.emit(descriptor)
	assert_eq(starts.count, 1, "same committed outcome cannot duplicate active cue")
	assert_same(machine.active_action, active_before, "feedback cannot change action session")
	assert_same(machine.current_state, state_before, "feedback cannot request a state")


func test_alternative_target_cue_queues_behind_failure() -> void:
	var fixture := _adapter_fixture()
	var machine: NpcStateMachine = fixture.machine
	var presenter: Presenter = fixture.presenter
	presenter.submit_cue(Catalog.create_cue(&"movement_failed"))
	machine.activity_target_selection_committed.emit({
		"reason_code": &"alternative_target_selected",
		"logical_action": &"Eat",
		"selected_target_id": &"second_table",
		"suppressed_count": 1,
		"action_session_id": "session:queued_alternative",
		"intent_id": "intent:queued_alternative",
	})
	assert_eq(
		presenter.get_current_cue_descriptor().cue_code,
		&"movement_failed",
		"lower-priority alternative does not replace failure"
	)
	assert_eq(
		presenter.get_queue_descriptor()[0].cue_code,
		&"trying_another_place",
		"alternative queues behind the failure"
	)


func test_talk_scripted_and_incapacitated_states_suppress_without_mutation() -> void:
	var fixture := _adapter_fixture()
	var machine: NpcStateMachine = fixture.machine
	var presenter: Presenter = fixture.presenter
	var adapter: Adapter = fixture.adapter
	presenter.submit_cue(Catalog.create_cue(&"hunger_high"))
	var talk_overlay := NpcState.new()
	talk_overlay.name = "Talk"
	machine.add_child(talk_overlay)
	machine.interaction_overlay = talk_overlay
	machine.state_changed.emit(&"Talk", &"Idle")
	assert_true(
		presenter.get_debug_descriptor().suppression_sources.has(&"talk"),
		"ordinary Talk suppresses the panel"
	)
	assert_false(
		presenter.get_current_cue_descriptor().is_empty(),
		"Talk does not corrupt presenter state"
	)
	machine.interaction_overlay = null
	machine.state_changed.emit(&"Idle", &"Talk")
	adapter._on_npc_control_claim_changed(machine.npc, true, 1)
	assert_true(
		presenter.get_debug_descriptor().suppression_sources.has(
			&"scripted_control"
		),
		"scripted control suppresses feedback"
	)
	adapter._on_npc_control_claim_changed(machine.npc, false, 1)
	var downed := NpcState.new()
	downed.name = "Downed"
	machine.add_child(downed)
	machine.state_history = [downed]
	machine.state_changed.emit(&"Downed", &"Idle")
	assert_true(
		presenter.get_debug_descriptor().suppression_sources.has(
			&"incapacitated"
		),
		"downed presentation suppresses ordinary cue"
	)


func test_presenters_are_instance_local_and_repository_ignores_queue() -> void:
	var first := _adapter_fixture()
	var second := _adapter_fixture()
	var first_presenter: Presenter = first.presenter
	var second_presenter: Presenter = second.presenter
	first_presenter.submit_cue(Catalog.create_cue(&"hunger_high"))
	assert_true(
		second_presenter.get_current_cue_descriptor().is_empty(),
		"old-instance presenter cannot mutate replacement presenter"
	)
	var repository := NpcMemoryRuntimeRepositoryService.new()
	add_child_autofree(repository)
	repository.register_live_memory("feedback_test", second.memory, 10.0)
	var exported_text := JSON.stringify(repository.export_runtime_state(10.0))
	assert_false(
		exported_text.contains("cue_code"),
		"presenter queue is absent from runtime memory snapshots"
	)


func test_developer_label_control_is_independent_from_player_feedback() -> void:
	var fixture := _adapter_fixture(false, false)
	var machine: NpcStateMachine = fixture.machine
	var label: Label = fixture.label
	var controller: NpcBehaviorController = fixture.controller
	machine.developer_state_label_enabled = false
	machine._update_debug_label()
	controller.commit_candidate(_intent(
		&"Eat",
		NpcBehaviorIntent.SOURCE_NEED,
		&"hunger_high",
		"label_test"
	))
	assert_false(label.visible, "developer StateLabel can be independently hidden")
	assert_eq(
		fixture.presenter.get_current_cue_descriptor().cue_code,
		&"hunger_high",
		"player-facing feedback remains active independently"
	)


func _presenter_fixture(require_player: bool = false) -> Dictionary:
	var npc := CharacterBody2D.new()
	npc.name = "FeedbackNpc"
	add_child_autofree(npc)
	var presenter := Presenter.new()
	presenter.require_nearby_player = require_player
	add_child_autofree(presenter)
	presenter.bind_npc(npc)
	presenter._attach_visual_if_needed(npc.get_instance_id())
	return {"npc": npc, "presenter": presenter}


func _adapter_fixture(
	require_player: bool = false,
	developer_label_enabled: bool = true
) -> Dictionary:
	var npc := CharacterBody2D.new()
	npc.name = "FeedbackNpc"
	var label := Label.new()
	label.name = "StateLabel"
	npc.add_child(label)
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	machine.debug_label_path = NodePath("StateLabel")
	machine.developer_state_label_enabled = developer_label_enabled
	var controller := NpcBehaviorController.new()
	controller.name = "NpcBehaviorController"
	var memory := NpcShortTermMemory.new()
	memory.name = "NpcShortTermMemory"
	var presenter := Presenter.new()
	presenter.name = "NpcFeedbackPresenter"
	presenter.require_nearby_player = require_player
	var adapter := Adapter.new()
	adapter.name = "NpcFeedbackAdapter"
	machine.add_child(controller)
	machine.add_child(memory)
	machine.add_child(presenter)
	machine.add_child(adapter)
	npc.add_child(machine)
	add_child_autofree(npc)
	presenter._attach_visual_if_needed(npc.get_instance_id())
	return {
		"npc": npc,
		"label": label,
		"machine": machine,
		"controller": controller,
		"memory": memory,
		"presenter": presenter,
		"adapter": adapter,
	}


func _intent(
	logical_action: StringName,
	source: StringName,
	reason_code: StringName,
	session_id: String
) -> NpcBehaviorIntent:
	return NpcBehaviorIntent.create(
		logical_action,
		logical_action,
		source,
		String(reason_code),
		50,
		"",
		session_id,
		2.0,
		15,
		{},
		reason_code
	)


func _memory_event(
	memory_id: String,
	event_type: StringName,
	now_game_hours: float
) -> NpcMemoryEvent:
	var event := MemoryEvent.create(
		event_type,
		{
			"source": "feedback_test",
			"reason_code": "test",
			"subject_id": "partner",
			"target_id": "feedback_test",
			"place_id": "place",
			"logical_action": "Eat",
		},
		now_game_hours
	)
	event.memory_id = memory_id
	return event


func _custom_cue(
	code: String,
	priority: int,
	replace_policy: StringName,
	category: StringName = Cue.CATEGORY_INTENTION
) -> Cue:
	return Cue.create(StringName(code), {
		"fallback_text": code,
		"priority": priority,
		"duration_seconds": 5.0,
		"cooldown_seconds": 0.0,
		"replace_policy": replace_policy,
		"category": category,
		"metadata": {
			"identity_key": code,
			"cooldown_key": code,
		},
	})
