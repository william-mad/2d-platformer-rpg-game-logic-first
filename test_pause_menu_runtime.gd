extends "res://test/native_scene_tree_test.gd"

const MenuScene := preload("res://ui/pause/pause_menu.tscn")


class RelationshipStub:
	extends RefCounted

	var rows: Dictionary = {}
	var names: Dictionary = {}

	func get_relationships_for_id(owner_id: String) -> Dictionary:
		return (rows.get(owner_id, {}) as Dictionary).duplicate(true)

	func get_relationship_by_id(owner_id: String, subject_id: String) -> Dictionary:
		return (
			(rows.get(owner_id, {}) as Dictionary).get(subject_id, {})
			as Dictionary
		).duplicate(true)

	func get_known_character_ids_snapshot(
		viewer_id: String = "",
		include_player: bool = false
	) -> PackedStringArray:
		var result := PackedStringArray()
		for actor_id in names.keys():
			var id := String(actor_id)
			if id == viewer_id or (not include_player and id == "__player__"):
				continue
			if _is_met(viewer_id, id):
				result.append(id)
		result.sort()
		return result

	func get_known_actor_directory_snapshot(viewer_id: String = "") -> Dictionary:
		var result: Dictionary = {}
		for actor_id in names.keys():
			var id := String(actor_id)
			if id == viewer_id or _is_met(viewer_id, id):
				result[id] = {"actor_id": id, "display_name": names[actor_id]}
		return result

	func _is_met(viewer_id: String, actor_id: String) -> bool:
		var forward = (rows.get(viewer_id, {}) as Dictionary).get(actor_id, {})
		var reverse = (rows.get(actor_id, {}) as Dictionary).get(viewer_id, {})
		return (
			forward is Dictionary and bool(forward.get("met", false))
		) or (
			reverse is Dictionary and bool(reverse.get("met", false))
		)


class LocationStub:
	extends RefCounted

	var records: Dictionary = {}

	func synchronize_live_records() -> void:
		pass

	func get_records_snapshot() -> Dictionary:
		return records.duplicate(true)

	func get_record_snapshot(actor_id: String) -> Dictionary:
		return (records.get(actor_id, {}) as Dictionary).duplicate(true)

	func is_npc_live(_actor_id: String) -> bool:
		return false


class SaveStub:
	extends RefCounted

	var save_calls: Array[String] = []
	var summaries: Array[Dictionary] = [
		{"display_name": "File 1", "exists": false, "valid": false},
		{
			"display_name": "File 2",
			"exists": true,
			"valid": true,
			"scene_name": "Home",
		},
		{"display_name": "File 3", "exists": false, "valid": false},
	]

	func get_save_slots() -> Array[String]:
		return ["slot_1", "slot_2", "slot_3"]

	func get_save_summaries() -> Array[Dictionary]:
		return summaries.duplicate(true)

	func format_save_summary(summary: Dictionary, empty_label: String = "Empty") -> String:
		var label := String(summary.get("display_name", "File"))
		if not bool(summary.get("exists", false)):
			return "%s - %s" % [label, empty_label]
		return "%s - %s" % [label, String(summary.get("scene_name", "Unknown"))]

	func save_game(slot: String) -> bool:
		save_calls.append(slot)
		var index := get_save_slots().find(slot)
		if index >= 0:
			summaries[index] = {
				"display_name": "File %d" % [index + 1],
				"exists": true,
				"valid": true,
				"scene_name": "Saved Scene",
			}
		return true


class SettingsStub:
	extends RefCounted

	var volume := 0.75
	var fullscreen := false

	func get_master_volume() -> float:
		return volume

	func is_fullscreen() -> bool:
		return fullscreen

	func set_master_volume(value: float) -> void:
		volume = value

	func set_fullscreen(enabled: bool) -> void:
		fullscreen = enabled


func before_each() -> void:
	var pause_system := root.get_node_or_null("PauseSystem")
	if pause_system != null:
		pause_system.call("set_paused", false, false)
	paused = false


func after_each() -> void:
	var pause_system := root.get_node_or_null("PauseSystem")
	if pause_system != null:
		pause_system.call("set_paused", false, false)
	paused = false


func test_escape_toggles_real_menu_and_respects_other_modal_pause() -> void:
	var player := Node.new()
	player.name = "PauseMenuTestPlayer"
	player.add_to_group("player")
	add_child_autofree(player)
	var pause_system := root.get_node("PauseSystem")
	var pause_event := InputEventAction.new()
	pause_event.action = &"pause"
	pause_event.pressed = true

	pause_system.call("_unhandled_input", pause_event)
	assert_true(paused, "Escape pauses the SceneTree during gameplay")
	assert_true(bool(pause_system.call("is_pause_menu_open")), "Escape opens the actual pause menu")
	var legacy_overlay = pause_system.get("stats_overlay")
	assert_true(legacy_overlay != null, "legacy P-key inspector remains lazily available")
	assert_false(
		bool(legacy_overlay.get("pause_overlay_visible")),
		"legacy inspector is not used as the Escape presentation"
	)
	pause_system.call("_unhandled_input", pause_event)
	assert_false(paused, "second Escape resumes gameplay")
	assert_false(bool(pause_system.call("is_pause_menu_open")), "second Escape closes the pause menu")
	legacy_overlay.call("_set_overlay_visible", true)
	pause_system.call("_unhandled_input", pause_event)
	assert_true(
		bool(legacy_overlay.get("visible")),
		"an independently P-visible inspector is preserved beneath the menu"
	)
	pause_system.call("_unhandled_input", pause_event)
	legacy_overlay.call("_set_overlay_visible", false)

	pause_system.call("set_paused", true, false)
	pause_system.call("_unhandled_input", pause_event)
	assert_true(paused, "Escape does not unpause another modal owner")
	assert_false(bool(pause_system.call("is_pause_menu_open")), "manual menu stays hidden behind another modal")


func test_character_page_has_player_first_explicit_direction_and_no_opinion_state() -> void:
	var relationships := RelationshipStub.new()
	var mom_player := _row("mom", "__player__")
	mom_player.merge({
		"favor": 75.0,
		"trust": 80.0,
		"love": 70.0,
		"anger": 3.0,
		"fear": 1.0,
		"suspicion": 5.0,
	}, true)
	relationships.rows = {
		"mom": {"__player__": mom_player},
		"guard": {"__player__": _row("guard", "__player__")},
	}
	relationships.names = {
		"__player__": "Player",
		"mom": "Mom",
		"guard": "Guard",
	}
	var locations := LocationStub.new()
	locations.records = {
		"mom": _record("Mom"),
		"guard": _record("Guard"),
	}
	var menu := _menu(relationships, locations)
	menu.show_menu()
	menu.show_characters_page()
	menu.select_owner("mom")
	assert_eq(menu.get_subject_ids(), ["__player__", "guard"], "Player is the default first subject")
	assert_eq(menu.get_selected_subject_id(), "__player__", "character page opens on opinion of Player")
	assert_eq(menu.get_direction_text(), "MOM  ->  PLAYER", "UI makes opinion direction explicit")
	assert_eq(menu.get_opinion_status_text(), "Recorded opinion", "existing opinion is identified")
	assert_true(menu.opinion_metrics.get_child_count() > 0, "recorded schema metrics render as bars")

	menu.browse_subject(1)
	assert_eq(menu.get_selected_subject_id(), "guard", "right navigation advances one subject")
	assert_eq(menu.get_direction_text(), "MOM  ->  GUARD", "direction updates with subject")
	assert_eq(menu.get_opinion_status_text(), "No opinion recorded", "missing row has explicit empty state")
	assert_eq(menu.opinion_metrics.get_child_count(), 0, "missing opinion does not render neutral bars")

	relationships.rows["bard"] = {"__player__": _row("bard", "__player__")}
	relationships.names["bard"] = "Bard"
	locations.records["bard"] = _record("Bard")
	menu.show_characters_page()
	menu.select_owner("mom")
	assert_eq(
		menu.get_subject_ids(),
		["__player__", "bard", "guard"],
		"carousel grows deterministically with newly known characters"
	)


func test_save_and_load_slot_pages_refresh_from_save_system() -> void:
	var save_system := SaveStub.new()
	var menu := _menu(
		RelationshipStub.new(),
		LocationStub.new(),
		save_system
	)
	menu.show_menu()
	menu.show_save_page()
	assert_eq(menu.get_save_slot_button_count(), 3, "save page follows configured slot count")
	menu.save_slot_buttons[0].pressed.emit()
	assert_eq(save_system.save_calls, ["slot_1"], "save button uses the matching SaveSystem slot")
	assert_true("Saved Scene" in menu.save_slot_buttons[0].text, "slot summary refreshes after saving")

	menu.show_load_page()
	assert_eq(menu.get_load_slot_button_count(), 3, "load page follows configured slot count")
	assert_false(menu.load_slot_buttons[0].disabled, "freshly saved slot becomes loadable")
	assert_false(menu.load_slot_buttons[1].disabled, "existing valid slot remains loadable")
	assert_true(menu.load_slot_buttons[2].disabled, "empty slot cannot be loaded")


func _menu(
	relationships: Object,
	locations: Object,
	save_system: Object = null
) -> PauseMenu:
	var menu := MenuScene.instantiate() as PauseMenu
	add_child_autofree(menu)
	menu.set_services_for_testing(
		relationships,
		locations,
		save_system,
		SettingsStub.new()
	)
	return menu


func _row(owner_id: String, other_id: String) -> Dictionary:
	return {
		"owner_id": owner_id,
		"other_id": other_id,
		"owner_name": owner_id.capitalize(),
		"other_name": "Player" if other_id == "__player__" else other_id.capitalize(),
		"met": true,
	}


func _record(display_name: String) -> Dictionary:
	return {
		"node_name": display_name,
		"character_profile": {
			"display_name": display_name,
			"subtitle": "Known character",
			"description": "%s profile." % display_name,
			"portrait_path": "",
			"accent_color": Color(0.5, 0.8, 0.65),
		},
		"node_state": {
			"social_stats": {
				"hunger": 20.0,
				"sadness": 5.0,
				"anger": 2.0,
			},
		},
		"scene_path": "res://scenes/testscenes/realhometest.tscn",
	}
