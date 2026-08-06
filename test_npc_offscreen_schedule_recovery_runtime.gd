extends SceneTree

const MOM_ID := "mom"
const MAIN_SCENE := "res://scenes/testscenes/realtest1.tscn"
const BEDROOM_SCENE := "res://scenes/testscenes/mom_bedroom.tscn"


func _initialize() -> void:
	await process_frame
	var world_time := root.get_node("WorldTime")
	var locations := root.get_node("NpcLocations")
	var simulator := root.get_node("NpcWorldSimulation")
	world_time.set("auto_advance", false)
	simulator.set("_social_planning_suppressed", true)
	simulator.set("spot_reservations", {})
	simulator.set("spot_claim_counts", {})
	locations.set("live_npcs", {})
	locations.set("npc_records", {})
	locations.set("active_scene_path", MAIN_SCENE)

	world_time.call("set_total_hours", 47.0)
	locations.npc_records[MOM_ID] = _record(46.0, 80.0, 20.0)
	simulator.call("simulate_now")
	var bedtime: Dictionary = locations.call("get_record_snapshot", MOM_ID)
	_print_record("bedtime", bedtime)
	if String((bedtime.get("activity", {}) as Dictionary).get("state_name", "")) != "Sleep":
		push_error("DIAG bedtime did not commit Sleep")
		quit(1)
		return

	world_time.call("set_total_hours", 48.0)
	simulator.call("simulate_now")
	var sleeping: Dictionary = locations.call("get_record_snapshot", MOM_ID)
	_print_record("one_hour_sleep", sleeping)
	var sleep_need := _sleep_need(sleeping)
	if not is_equal_approx(sleep_need, 72.6):
		push_error("DIAG offscreen sleep need expected 72.6, got %.3f" % sleep_need)
		quit(1)
		return

	simulator.set("spot_reservations", {})
	simulator.set("spot_claim_counts", {})
	world_time.call("set_total_hours", 57.0)
	locations.npc_records[MOM_ID] = _record(57.0, 20.0, 90.0)
	var work_state: Dictionary = simulator.spot_runtime_states.get("mom_work", {}).duplicate(true)
	work_state["value"] = 100.0
	simulator.spot_runtime_states["mom_work"] = work_state
	var source_record: Dictionary = locations.call("get_record_snapshot", MOM_ID)
	var selected = simulator.call("_find_best_definition", &"mom", source_record, 9.0)
	print("DIAG selected_at_09=", String(selected.spot_id) if selected != null else "none")
	simulator.call("simulate_now")
	var working: Dictionary = locations.call("get_record_snapshot", MOM_ID)
	_print_record("bedroom_to_main_work", working)
	if (
		String(working.get("scene_path", "")) != MAIN_SCENE
		or String((working.get("activity", {}) as Dictionary).get("spot_id", "")) != "mom_work"
	):
		push_error("DIAG bedroom-to-main scheduled work did not commit")
		quit(1)
		return

	simulator.set("spot_reservations", {})
	simulator.set("spot_claim_counts", {})
	world_time.call("set_total_hours", 47.0)
	var blocked_sleep_record := _record(47.0, 90.0, 20.0)
	blocked_sleep_record["scene_path"] = MAIN_SCENE
	blocked_sleep_record["last_position"] = Vector2(520.0, 368.0)
	blocked_sleep_record["action"] = _terminal_action("old-work", "Work")
	locations.npc_records[MOM_ID] = blocked_sleep_record
	simulator.call("simulate_now")
	var blocked_sleep: Dictionary = locations.call("get_record_snapshot", MOM_ID)
	_print_record("terminal_action_recovered_sleep_route", blocked_sleep)
	if String((blocked_sleep.get("activity", {}) as Dictionary).get("spot_id", "")) != "mom_bed":
		push_error("DIAG terminal action still blocks sleep")
		quit(1)
		return

	simulator.set("spot_reservations", {})
	simulator.set("spot_claim_counts", {})
	world_time.call("set_total_hours", 57.0)
	var blocked_work_record := _record(57.0, 20.0, 90.0)
	blocked_work_record["action"] = _terminal_action("old-sleep", "Sleep")
	locations.npc_records[MOM_ID] = blocked_work_record
	simulator.call("simulate_now")
	var blocked_work: Dictionary = locations.call("get_record_snapshot", MOM_ID)
	_print_record("terminal_action_recovered_main_route", blocked_work)
	if String((blocked_work.get("activity", {}) as Dictionary).get("spot_id", "")) != "mom_work":
		push_error("DIAG terminal action still blocks work")
		quit(1)
		return

	simulator.set("spot_reservations", {})
	simulator.set("spot_claim_counts", {})
	world_time.call("set_total_hours", 47.0)
	var active_record := _record(47.0, 90.0, 20.0)
	active_record["scene_path"] = MAIN_SCENE
	active_record["action"] = _active_action("active-work", "Work")
	locations.npc_records[MOM_ID] = active_record
	simulator.call("simulate_now")
	var protected_active: Dictionary = locations.call("get_record_snapshot", MOM_ID)
	_print_record("active_action_remains_protected", protected_active)
	if (
		not (protected_active.get("activity", {}) as Dictionary).is_empty()
		or not (protected_active.get("pending_travel", {}) as Dictionary).is_empty()
		or String((protected_active.get("action", {}) as Dictionary).get("session_id", ""))
			!= "active-work"
	):
		push_error("DIAG active action was incorrectly superseded")
		quit(1)
		return

	print("NPC_OFFSCREEN_SCHEDULE_RECOVERY_RUNTIME_OK")
	quit(0)


func _record(last_simulated: float, sleep_need: float, boredom: float) -> Dictionary:
	return {
		"npc_id": MOM_ID,
		"node_name": "MomNpc",
		"npc_scene_path": "res://scenes/creatures/mom_npc.tscn",
		"home_scene_path": MAIN_SCENE,
		"home_position": Vector2(520.0, 368.0),
		"scene_path": BEDROOM_SCENE,
		"previous_scene_path": "",
		"last_position": Vector2(220.0, 420.0),
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"sleep_need": sleep_need,
				"boredom": boredom,
				"hunger": 20.0,
				"talk_need": 0.0,
				"tired": 0.0,
			},
			"world_simulation_profile": {
				"passive_needs_enabled": true,
				"rates_per_game_hour": {
					"sleep_need": 5.1,
					"boredom": 8.0,
					"hunger": 7.0,
					"talk_need": 24.0,
				},
			},
		},
		"activity": {},
		"action": {},
		"pending_travel": {},
		"finish_route_replan": {},
		"last_simulated_total_hours": last_simulated,
		"spawn_random": false,
	}


func _sleep_need(record: Dictionary) -> float:
	return float(((record.get("node_state", {}) as Dictionary).get(
		"social_stats", {}
	) as Dictionary).get("sleep_need", -1.0))


func _terminal_action(session_id: String, action_kind: String) -> Dictionary:
	return {
		"session_id": session_id,
		"action_kind": action_kind,
		"source": "schedule",
		"priority": 20,
		"status": "completed",
		"phase": "executing",
	}


func _active_action(session_id: String, action_kind: String) -> Dictionary:
	var action := _terminal_action(session_id, action_kind)
	action["status"] = "active"
	return action


func _print_record(label: String, record: Dictionary) -> void:
	var activity: Dictionary = record.get("activity", {})
	var pending: Dictionary = record.get("pending_travel", {})
	print(
		"DIAG ", label,
		" scene=", String(record.get("scene_path", "")).get_file(),
		" state=", String(activity.get("state_name", "idle")),
		" spot=", String(activity.get("spot_id", "")),
		" pending=", String(pending.get("mode", "")),
		" sleep_need=", _sleep_need(record)
	)
