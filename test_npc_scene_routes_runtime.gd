extends SceneTree

const YARD_SCENE := "res://scenes/testscenes/realtest1.tscn"
const HOME_SCENE := "res://scenes/testscenes/realhometest.tscn"
const BEDROOM_SCENE := "res://scenes/testscenes/mom_bedroom.tscn"
const MOM_BED_DEFINITION := "res://data/npc_spots/mom_bed.tres"
const MOM_SHOWER_DEFINITION := "res://data/npc_spots/mom_shower.tres"

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var routes := root.get_node_or_null("NpcSceneRoutes")
	if routes == null:
		_fail("NpcSceneRoutes autoload is missing.")
		_finish()
		return

	_test_route_core_api(routes)
	_test_mom_routes(routes)
	_test_pending_route_progression(routes)
	_test_malformed_pending_bounds(routes)
	_test_route_copy_safety(routes)
	_test_route_kill_switch(routes)
	_test_reentrant_route_state_change_fails_closed(routes)
	_test_invalid_graph_fails_closed(routes)
	_test_authored_scene_contract(routes)
	_finish()


func _test_route_core_api(routes: Node) -> void:
	for method_name in [
		&"plan_route",
		&"attach_route_to_pending",
		&"get_current_hop",
		&"validate_edge_execution",
		&"advance_pending_route",
		&"set_enabled",
		&"is_enabled",
		&"get_debug_snapshot",
	]:
		_expect(routes.has_method(method_name), "route manager exposes %s" % String(method_name))


func _test_mom_routes(routes: Node) -> void:
	var outbound := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
	_expect(bool(outbound.get("accepted", false)), "Mom can plan the two-hop route to her bedroom")
	_expect(String(outbound.get("reason", "")) == "route_found", "outbound route reports route_found")
	_expect(int(outbound.get("hop_count", -1)) == 2, "Mom bedroom route has exactly two hops")
	_expect(
		_string_array(outbound.get("scene_paths", [])) == [YARD_SCENE, HOME_SCENE, BEDROOM_SCENE],
		"outbound route crosses the shared home"
	)
	_expect(
		_string_array(outbound.get("edge_ids", [])) == [
			"household.realtest1_to_realhometest",
			"household.realhometest_to_mom_bedroom",
		],
		"outbound route uses the authored directed edges"
	)

	var reverse := routes.call("plan_route", BEDROOM_SCENE, YARD_SCENE, &"mom") as Dictionary
	_expect(bool(reverse.get("accepted", false)), "Mom can plan the two-hop wake return route")
	_expect(int(reverse.get("hop_count", -1)) == 2, "Mom wake return has exactly two hops")
	_expect(
		_string_array(reverse.get("scene_paths", [])) == [BEDROOM_SCENE, HOME_SCENE, YARD_SCENE],
		"wake return crosses the shared home"
	)
	_expect(
		_string_array(reverse.get("edge_ids", [])) == [
			"household.mom_bedroom_to_realhometest",
			"household.realhometest_to_realtest1",
		],
		"wake return uses the authored directed edges"
	)

	var denied := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"stranger") as Dictionary
	_expect(not bool(denied.get("accepted", false)), "another NPC cannot use Mom's private route")
	_expect(String(denied.get("reason", "")) == "route_not_found", "private-route denial fails closed")

	# The authored household graph is deliberately bidirectional. An unreachable but
	# valid scene therefore exercises visited-set termination on a real cyclic graph.
	var cyclic_miss := routes.call(
		"plan_route", YARD_SCENE, "res://scenes/levels/main.tscn", &"mom"
	) as Dictionary
	_expect(not bool(cyclic_miss.get("accepted", false)), "cyclic graph search terminates for an unreachable scene")
	_expect(String(cyclic_miss.get("reason", "")) == "route_not_found", "cyclic miss reports route_not_found")


func _test_pending_route_progression(routes: Node) -> void:
	var plan := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
	if not bool(plan.get("accepted", false)):
		_fail("pending progression requires the outbound Mom route")
		return

	var base_pending := {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": Vector2(220.0, 420.0),
	}
	var pending := routes.call("attach_route_to_pending", base_pending, plan) as Dictionary
	_expect(String(pending.get("target_scene_path", "")) == BEDROOM_SCENE, "route attach preserves the top-level final scene")
	_expect(pending.get("target_position", Vector2.ZERO) == Vector2(220.0, 420.0), "route attach preserves the top-level final position")
	var persisted_route: Dictionary = pending.get("scene_route", {})
	_expect(
		String(persisted_route.get("route_map_id", "")) == "household_routes",
		"pending travel stores stable route-map identity"
	)
	routes.call("rebuild_graph")
	var after_rebuild := routes.call("get_current_hop", pending, YARD_SCENE, &"mom") as Dictionary
	_expect(
		bool(after_rebuild.get("accepted", false)),
		"a valid persisted route survives an equivalent runtime graph rebuild"
	)

	var wrong_scene := routes.call("get_current_hop", pending, HOME_SCENE, &"mom") as Dictionary
	_expect(not bool(wrong_scene.get("accepted", false)), "pending route rejects the wrong current scene")
	_expect(String(wrong_scene.get("reason", "")) == "route_current_scene_mismatch", "current-scene mismatch is diagnosable")

	var first_hop := routes.call("get_current_hop", pending, YARD_SCENE, &"mom") as Dictionary
	_expect(bool(first_hop.get("accepted", false)), "first outbound hop is ready")
	_expect(String(first_hop.get("target_scene_path", "")) == HOME_SCENE, "first outbound hop targets the shared home")
	_expect(first_hop.get("target_arrival_position", Vector2.ZERO) == Vector2(610.0, 368.0), "yard-to-home arrival is explicit")

	var mismatch := routes.call(
		"advance_pending_route",
		pending,
		StringName(String(first_hop.get("edge_id", ""))),
		BEDROOM_SCENE,
		&"mom"
	) as Dictionary
	_expect(not bool(mismatch.get("accepted", false)), "door callback cannot skip the current hop")
	_expect(String(mismatch.get("reason", "")) == "route_target_callback_mismatch", "skipped-hop callback reports its mismatch")
	var source_mismatch := routes.call(
		"advance_pending_route",
		pending,
		StringName(String(first_hop.get("edge_id", ""))),
		HOME_SCENE,
		&"mom",
		HOME_SCENE
	) as Dictionary
	_expect(
		not bool(source_mismatch.get("accepted", false)),
		"authoritative record scene overrides untrusted route metadata"
	)
	var unchanged_route = pending.get("scene_route", {})
	_expect(
		unchanged_route is Dictionary and int(unchanged_route.get("hop_index", -1)) == 0,
		"rejected callback does not mutate pending progress"
	)

	var first_advance := routes.call(
		"advance_pending_route",
		pending,
		StringName(String(first_hop.get("edge_id", ""))),
		HOME_SCENE,
		&"mom"
	) as Dictionary
	_expect(bool(first_advance.get("accepted", false)), "first outbound hop advances")
	_expect(not bool(first_advance.get("complete", true)), "first outbound hop does not finish the route")
	_expect(first_advance.get("arrival_position", Vector2.ZERO) == Vector2(610.0, 368.0), "first advance returns the home arrival")
	var after_first := _pending_from_advance(first_advance)
	_expect(String(after_first.get("target_scene_path", "")) == BEDROOM_SCENE, "intermediate progress retains the final scene")
	_expect(after_first.get("target_position", Vector2.ZERO) == Vector2(220.0, 420.0), "intermediate progress retains the bed position")

	var second_hop := routes.call("get_current_hop", after_first, HOME_SCENE, &"mom") as Dictionary
	_expect(bool(second_hop.get("accepted", false)), "second outbound hop is ready")
	_expect(String(second_hop.get("target_scene_path", "")) == BEDROOM_SCENE, "second outbound hop targets Mom's bedroom")
	_expect(second_hop.get("target_arrival_position", Vector2.ZERO) == Vector2(-320.0, 420.0), "home-to-bedroom arrival is explicit")

	var second_advance := routes.call(
		"advance_pending_route",
		after_first,
		StringName(String(second_hop.get("edge_id", ""))),
		BEDROOM_SCENE,
		&"mom"
	) as Dictionary
	_expect(bool(second_advance.get("accepted", false)), "second outbound hop advances")
	_expect(bool(second_advance.get("complete", false)), "second outbound hop completes the route")
	_expect(second_advance.get("arrival_position", Vector2.ZERO) == Vector2(-320.0, 420.0), "final door crossing uses the bedroom arrival")
	var after_second := _pending_from_advance(second_advance)
	_expect(String(after_second.get("target_scene_path", "")) == BEDROOM_SCENE, "completed progress retains the final target for activity commit")
	var completed_hop := routes.call("get_current_hop", after_second, BEDROOM_SCENE, &"mom") as Dictionary
	_expect(bool(completed_hop.get("accepted", false)) and bool(completed_hop.get("complete", false)), "completed pending route validates at its destination")

	var reverse_plan := routes.call("plan_route", BEDROOM_SCENE, YARD_SCENE, &"mom") as Dictionary
	var reverse_pending := routes.call("attach_route_to_pending", {
		"mode": "finish",
		"target_scene_path": YARD_SCENE,
		"target_position": Vector2(520.0, 368.0),
	}, reverse_plan) as Dictionary
	var reverse_first := routes.call("get_current_hop", reverse_pending, BEDROOM_SCENE, &"mom") as Dictionary
	_expect(reverse_first.get("target_arrival_position", Vector2.ZERO) == Vector2(-680.0, 368.0), "bedroom-to-home arrival is explicit")
	var reverse_first_result := routes.call(
		"advance_pending_route",
		reverse_pending,
		StringName(String(reverse_first.get("edge_id", ""))),
		HOME_SCENE,
		&"mom"
	) as Dictionary
	var reverse_after_first := _pending_from_advance(reverse_first_result)
	var reverse_second := routes.call("get_current_hop", reverse_after_first, HOME_SCENE, &"mom") as Dictionary
	_expect(reverse_second.get("target_arrival_position", Vector2.ZERO) == Vector2(-240.0, 368.0), "home-to-yard arrival is explicit")


func _test_route_copy_safety(routes: Node) -> void:
	var first := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
	var first_edges = first.get("edge_ids", [])
	var first_scenes = first.get("scene_paths", [])
	if first_edges is Array:
		first_edges.clear()
	if first_scenes is Array:
		first_scenes.clear()
	first["accepted"] = false

	var second := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
	_expect(bool(second.get("accepted", false)), "mutating a returned plan cannot poison the manager")
	_expect(int(second.get("hop_count", -1)) == 2, "cached plan keeps its hop count")
	_expect(_string_array(second.get("scene_paths", [])).size() == 3, "cached plan keeps an independent scene list")

	var snapshot := routes.call("get_debug_snapshot") as Dictionary
	var snapshot_edges = snapshot.get("edges", [])
	if snapshot_edges is Array:
		snapshot_edges.clear()
	var fresh_snapshot := routes.call("get_debug_snapshot") as Dictionary
	_expect(int(fresh_snapshot.get("edge_count", 0)) == 4, "mutating a debug snapshot cannot alter the graph")
	_expect((fresh_snapshot.get("edges", []) as Array).size() == 4, "debug edge descriptors are returned by copy")
	_expect((fresh_snapshot.get("validation_errors", []) as Array).is_empty(), "authored route graph validates cleanly")


func _test_malformed_pending_bounds(routes: Node) -> void:
	var plan := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
	var pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
	}, plan) as Dictionary
	var oversized_edges: Array[String] = []
	var oversized_scenes: Array[String] = []
	for index in range(33):
		oversized_edges.append("oversized.%d" % index)
		oversized_scenes.append(YARD_SCENE)
	oversized_scenes.append(BEDROOM_SCENE)
	var malformed_pending := pending.duplicate(true)
	var malformed_route: Dictionary = malformed_pending.get("scene_route", {})
	malformed_route["edge_ids"] = oversized_edges
	malformed_route["scene_paths"] = oversized_scenes
	malformed_pending["scene_route"] = malformed_route
	var rejected_hop := routes.call(
		"get_current_hop", malformed_pending, YARD_SCENE, &"mom"
	) as Dictionary
	_expect(
		String(rejected_hop.get("reason", "")) == "route_pending_size_invalid",
		"oversized persisted routes fail before unbounded conversion or traversal"
	)
	var rejected_advance := routes.call(
		"advance_pending_route",
		malformed_pending,
		&"household.realtest1_to_realhometest",
		HOME_SCENE,
		&"mom"
	) as Dictionary
	_expect(
		String(rejected_advance.get("reason", "")) == "route_pending_size_invalid",
		"oversized persisted routes also fail before route advancement copies them"
	)
	var oversized_plan := plan.duplicate(true)
	oversized_plan["edge_ids"] = oversized_edges
	oversized_plan["scene_paths"] = oversized_scenes
	oversized_plan["hop_count"] = oversized_edges.size()
	var rejected_attach := routes.call(
		"attach_route_to_pending", {"target_scene_path": BEDROOM_SCENE}, oversized_plan
	) as Dictionary
	_expect(
		(rejected_attach.get("scene_route", {}) as Dictionary).is_empty(),
		"oversized public plans cannot be attached to pending travel"
	)


func _test_route_kill_switch(routes: Node) -> void:
	if not routes.has_method("set_enabled") or not routes.has_method("is_enabled"):
		return
	var originally_enabled := bool(routes.call("is_enabled"))
	routes.call("set_enabled", false, "runtime_test")
	_expect(not bool(routes.call("is_enabled")), "route kill switch disables routing immediately")
	var disabled_plan := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
	_expect(not bool(disabled_plan.get("accepted", false)), "disabled routing refuses new plans")
	_expect(String(disabled_plan.get("reason", "")) == "route_manager_disabled", "kill-switch rejection is diagnosable")
	var disabled_edge := routes.call(
		"validate_edge_execution",
		&"household.realtest1_to_realhometest",
		YARD_SCENE,
		HOME_SCENE,
		&"mom"
	) as Dictionary
	_expect(
		not bool(disabled_edge.get("accepted", false))
		and String(disabled_edge.get("reason", "")) == "route_manager_disabled",
		"kill switch also blocks execution of a route-wired direct door"
	)
	var disabled_snapshot := routes.call("get_debug_snapshot") as Dictionary
	_expect(not bool(disabled_snapshot.get("runtime_enabled", true)), "debug snapshot exposes kill-switch state")
	routes.call("set_enabled", originally_enabled, "runtime_test_restore")
	_expect(bool(routes.call("is_enabled")) == originally_enabled, "route kill switch restores its original state")
	if originally_enabled:
		var restored := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
		_expect(bool(restored.get("accepted", false)), "routing works after kill-switch recovery")


func _test_reentrant_route_state_change_fails_closed(routes: Node) -> void:
	var originally_enabled := bool(routes.call("is_enabled"))
	routes.call("set_enabled", true, "reentrant_route_state_test_setup")
	var plan := routes.call("plan_route", YARD_SCENE, BEDROOM_SCENE, &"mom") as Dictionary
	if not bool(plan.get("accepted", false)):
		_fail("reentrant route-state test requires Mom's outbound route")
		routes.call("set_enabled", originally_enabled, "reentrant_route_state_test_restore")
		return
	var pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": Vector2(220.0, 420.0),
	}, plan) as Dictionary
	var pristine_pending := pending.duplicate(true)
	var diagnostic_signal: Signal = routes.route_diagnostic

	var edge_callback_state := {"disabled": false}
	var disable_during_edge_validation := func(event: Dictionary) -> void:
		if (
			not bool(edge_callback_state["disabled"])
			and String(event.get("event", "")) == "edge_execution_validated"
		):
			edge_callback_state["disabled"] = true
			routes.call("set_enabled", false, "edge_validation_listener")
	diagnostic_signal.connect(disable_during_edge_validation)
	var edge_result := routes.call(
		"validate_edge_execution",
		&"household.realtest1_to_realhometest",
		YARD_SCENE,
		HOME_SCENE,
		&"mom"
	) as Dictionary
	diagnostic_signal.disconnect(disable_during_edge_validation)
	_expect(bool(edge_callback_state["disabled"]), "edge-validation diagnostic listener disabled routing synchronously")
	_expect(
		not bool(edge_result.get("accepted", false))
		and String(edge_result.get("reason", "")) == "route_state_changed_during_validation",
		"edge execution fails closed when a listener changes route state after validation"
	)

	routes.call("set_enabled", true, "hop_validation_listener_setup")
	var hop_callback_state := {"disabled": false}
	var disable_during_hop_validation := func(event: Dictionary) -> void:
		if (
			not bool(hop_callback_state["disabled"])
			and String(event.get("event", "")) == "hop_advance_validated"
		):
			hop_callback_state["disabled"] = true
			routes.call("set_enabled", false, "hop_validation_listener")
	diagnostic_signal.connect(disable_during_hop_validation)
	var hop_result := routes.call(
		"advance_pending_route",
		pending,
		&"household.realtest1_to_realhometest",
		HOME_SCENE,
		&"mom",
		YARD_SCENE
	) as Dictionary
	diagnostic_signal.disconnect(disable_during_hop_validation)
	_expect(bool(hop_callback_state["disabled"]), "hop-validation diagnostic listener disabled routing synchronously")
	_expect(
		not bool(hop_result.get("accepted", false))
		and String(hop_result.get("reason", "")) == "route_state_changed_during_validation",
		"hop advancement fails closed when a listener changes route state after validation"
	)
	_expect(
		pending == pristine_pending
		and int((pending.get("scene_route", {}) as Dictionary).get("hop_index", -1)) == 0,
		"rejected reentrant hop validation cannot commit progress into pending travel"
	)
	routes.call("set_enabled", originally_enabled, "reentrant_route_state_test_restore")
	_expect(
		bool(routes.call("is_enabled")) == originally_enabled,
		"reentrant route-state test restores the original kill-switch state"
	)


func _test_invalid_graph_fails_closed(routes: Node) -> void:
	if not routes.has_method("set_route_map"):
		_fail("route manager exposes set_route_map for controlled graph rebuilds")
		return
	var original_map = routes.get("route_map") as NpcSceneRouteMap
	var first_edge := NpcSceneRouteEdge.new()
	first_edge.edge_id = &"duplicate.test_edge"
	first_edge.source_scene_path = YARD_SCENE
	first_edge.target_scene_path = HOME_SCENE
	first_edge.allowed_npc_ids = [&"mom"]
	first_edge.blocked_npc_ids = [&"mom"]
	_expect(not first_edge.allows_npc(&"mom"), "an explicit block wins over an allow entry")
	_expect(not first_edge.allows_npc(&""), "an empty NPC identity can never use a route")
	var whitespace_edge := first_edge.duplicate(true) as NpcSceneRouteEdge
	whitespace_edge.edge_id = &" whitespace.edge "
	_expect(
		not whitespace_edge.get_validation_errors().is_empty(),
		"route edge IDs with surrounding whitespace are rejected"
	)
	var whitespace_map := NpcSceneRouteMap.new()
	whitespace_map.map_id = &" whitespace.map "
	whitespace_map.edges = [first_edge]
	_expect(
		not whitespace_map.get_validation_errors().is_empty(),
		"route map IDs with surrounding whitespace are rejected"
	)

	var duplicate_edge := first_edge.duplicate(true) as NpcSceneRouteEdge
	var invalid_map := NpcSceneRouteMap.new()
	invalid_map.map_id = &"invalid_duplicate_test"
	invalid_map.edges = [first_edge, duplicate_edge]
	var rebuild := routes.call("set_route_map", invalid_map) as Dictionary
	_expect(not bool(rebuild.get("accepted", true)), "duplicate route IDs invalidate the graph")
	_expect(
		not (rebuild.get("validation_errors", []) as Array).is_empty(),
		"invalid graph rebuild exposes validation errors"
	)
	var rejected := routes.call("plan_route", YARD_SCENE, HOME_SCENE, &"mom") as Dictionary
	_expect(not bool(rejected.get("accepted", true)), "an invalid graph fails closed")
	_expect(String(rejected.get("reason", "")) == "route_map_invalid", "invalid graph rejection is diagnosable")

	var restored := routes.call("set_route_map", original_map) as Dictionary
	_expect(bool(restored.get("accepted", false)), "the canonical route graph restores after validation testing")


func _test_authored_scene_contract(routes: Node) -> void:
	var yard := _instantiate_scene(YARD_SCENE)
	var home := _instantiate_scene(HOME_SCENE)
	var bedroom := _instantiate_scene(BEDROOM_SCENE)
	if yard == null or home == null or bedroom == null:
		_free_if_valid(yard)
		_free_if_valid(home)
		_free_if_valid(bedroom)
		return

	var yard_to_home := yard.get_node_or_null("RealHomeDoor")
	var home_to_yard := home.get_node_or_null("OutsideDoor")
	var home_to_bedroom := home.get_node_or_null("MomBedroomDoor")
	var bedroom_to_home := bedroom.get_node_or_null("DoorToRealHome")
	_test_door_route_reference(
		routes,
		yard_to_home,
		"yard to home",
		YARD_SCENE,
		HOME_SCENE,
		&"household.realtest1_to_realhometest"
	)
	var initial_player := yard.get_node_or_null("Player") as Node2D
	var yard_door_2d := yard_to_home as Node2D
	_expect(
		initial_player != null
		and yard_door_2d != null
		and absf(initial_player.position.x - yard_door_2d.position.x) >= 64.0,
		"yard startup does not overlap the house door or preload the large home scene immediately"
	)
	var authoritative_door := NpcTravelDoor.new()
	authoritative_door.route_edge = routes.call(
		"get_edge_resource", &"household.realtest1_to_realhometest"
	) as NpcSceneRouteEdge
	authoritative_door.target_scene_path = HOME_SCENE
	authoritative_door.owner_ids = [&"stranger"]
	authoritative_door.blocked_npc_ids = [&"mom"]
	_expect(
		authoritative_door.can_npc_id_use(&"mom"),
		"route-wired doors use the route edge as their sole NPC authorization"
	)
	_expect(
		not authoritative_door.can_npc_id_use(&"stranger"),
		"live door authorization matches offscreen route denial"
	)
	authoritative_door.free()
	_test_door_route_reference(
		routes,
		home_to_yard,
		"home to yard",
		HOME_SCENE,
		YARD_SCENE,
		&"household.realhometest_to_realtest1"
	)
	_test_door_route_reference(
		routes,
		home_to_bedroom,
		"home to Mom bedroom",
		HOME_SCENE,
		BEDROOM_SCENE,
		&"household.realhometest_to_mom_bedroom"
	)
	_test_door_route_reference(
		routes,
		bedroom_to_home,
		"Mom bedroom to home",
		BEDROOM_SCENE,
		HOME_SCENE,
		&"household.mom_bedroom_to_realhometest"
	)
	var home_bedroom_owner_ids = _property_value(home_to_bedroom, &"owner_ids", [])
	_expect(
		_id_list_contains(home_bedroom_owner_ids, &"mom")
		and not _id_list_contains(home_bedroom_owner_ids, &"player"),
		"home-to-bedroom owner access permits Mom and rejects the Player"
	)
	var home_bedroom_door := home_to_bedroom as NpcTravelDoor
	var home_player := home.get_node_or_null("Player") as Node2D
	if home_bedroom_door != null and home_player != null:
		home_bedroom_door.active_player = home_player
		home_bedroom_door.player_inside = true
		_expect(
			not home_bedroom_door.can_interact(home_player),
			"home-to-bedroom door rejects live Player interaction"
		)
	_expect(
		home_bedroom_door != null and home_bedroom_door.can_npc_id_use(&"mom"),
		"Mom remains authorized by the bedroom route edge"
	)
	var bedroom_home_owner_ids = _property_value(bedroom_to_home, &"owner_ids", [])
	_expect(
		_id_list_contains(bedroom_home_owner_ids, &"mom")
		and _id_list_contains(bedroom_home_owner_ids, &"player"),
		"bedroom-to-home owner access still permits Mom and Player exit"
	)
	var bedroom_home_door := bedroom_to_home as NpcTravelDoor
	var bedroom_player := bedroom.get_node_or_null("Player") as Node2D
	if bedroom_home_door != null and bedroom_player != null:
		bedroom_home_door.active_player = bedroom_player
		bedroom_home_door.player_inside = true
		_expect(
			bedroom_home_door.can_interact(bedroom_player),
			"bedroom-to-home door allows live Player exit interaction"
		)
	var home_player_arrival := home.get_node_or_null("PlayerSpawnFromYard") as Node2D
	var yard_player_arrival := yard.get_node_or_null("PlayerSpawnFromHome") as Node2D
	_expect(
		home_player_arrival != null
		and home_to_yard is Node2D
		and absf(home_player_arrival.position.x - (home_to_yard as Node2D).position.x)
			>= 64.0,
		"yard-to-home player arrival stays outside the return door preload area"
	)
	_expect(
		yard_player_arrival != null
		and yard_to_home is Node2D
		and absf(yard_player_arrival.position.x - (yard_to_home as Node2D).position.x)
			>= 64.0,
		"home-to-yard player arrival stays outside the return door preload area"
	)

	var bed_spot := bedroom.get_node_or_null("MomSleepSpot") as Node2D
	var definition := load(MOM_BED_DEFINITION) as NpcSpotDefinition
	_expect(bed_spot != null, "Mom bedroom contains its live sleep spot")
	_expect(definition != null, "Mom bed definition loads")
	if bed_spot != null and definition != null:
		_expect(definition.is_valid_definition(), "Mom bed definition passes strict validation")
		var live_owner_ids = _property_value(bed_spot, &"owner_ids", [])
		_expect(_id_list_contains(live_owner_ids, &"mom"), "live Mom bed is owned by Mom")
		_expect(definition.allows_owner_id(&"mom"), "Mom bed definition is owned by Mom")
		_expect(not definition.allows_owner_id(&"stranger"), "Mom bed definition denies other NPCs")
		_expect(definition.scene_path == BEDROOM_SCENE, "Mom bed definition targets the bedroom")
		_expect(definition.position == Vector2(220.0, 420.0), "Mom bed definition keeps its authored coordinates")
		_expect(bed_spot.position == definition.position, "live Mom bed matches its definition coordinates")

	var shower_spot := home.get_node_or_null("MomShowerRoutineSpot") as Node2D
	var shower_definition := load(MOM_SHOWER_DEFINITION) as NpcSpotDefinition
	_expect(shower_spot != null and shower_definition != null, "Mom shower spot and definition load")
	if shower_spot != null and shower_definition != null:
		_expect(shower_definition.is_valid_definition(), "Mom shower definition passes strict validation")
		_expect(
			shower_spot.position == shower_definition.position,
			"Mom shower definition matches its live coordinates"
		)
	var bedroom_return_spawn := home.get_node_or_null("PlayerSpawnFromMomBedroom") as Node2D
	_expect(bedroom_return_spawn != null, "home has a player spawn for the bedroom return door")
	if bedroom_return_spawn != null:
		_expect(
			absf(bedroom_return_spawn.position.x - (-680.0)) >= 64.0,
			"player and routed NPC arrivals from the bedroom do not overlap"
		)

	yard.free()
	home.free()
	bedroom.free()


func _test_door_route_reference(
	routes: Node,
	door: Node,
	label: String,
	expected_source_scene: String,
	expected_target_scene: String,
	expected_edge_id: StringName
) -> void:
	_expect(door != null, "%s door exists" % label)
	if door == null:
		return
	var edge = _property_value(door, &"route_edge", null)
	_expect(edge != null, "%s door references a route edge" % label)
	_expect(
		String(_property_value(door, &"target_scene_path", "")) == expected_target_scene,
		"%s door keeps the expected target scene" % label
	)
	if edge == null:
		return
	var edge_id := StringName(String(_property_value(edge, &"edge_id", "")))
	_expect(
		edge_id == expected_edge_id,
		"%s edge has its stable ID" % label
	)
	_expect(
		door.has_method("get_route_edge_id")
		and StringName(String(door.call("get_route_edge_id"))) == expected_edge_id,
		"%s door exposes its route edge ID" % label
	)
	if routes.has_method("get_edge_resource"):
		_expect(
			routes.call("get_edge_resource", expected_edge_id) == edge,
			"%s door and planner share the same edge resource" % label
		)
	_expect(
		String(_property_value(edge, &"source_scene_path", "")) == expected_source_scene,
		"%s edge records its source scene" % label
	)
	_expect(
		String(_property_value(edge, &"target_scene_path", "")) == expected_target_scene,
		"%s edge records its target scene" % label
	)


func _instantiate_scene(scene_path: String) -> Node:
	var packed := load(scene_path) as PackedScene
	_expect(packed != null, "%s loads" % scene_path.get_file())
	if packed == null:
		return null
	var instance := packed.instantiate()
	_expect(instance != null, "%s instantiates" % scene_path.get_file())
	return instance


func _property_value(object: Object, property_name: StringName, fallback: Variant) -> Variant:
	if object == null:
		return fallback
	for property in object.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return object.get(property_name)
	return fallback


func _id_list_contains(values: Variant, expected: StringName) -> bool:
	if not (values is Array) and not (values is PackedStringArray):
		return false
	for value in values:
		if String(value) == String(expected):
			return true
	return false


func _string_array(values: Variant) -> Array[String]:
	var result: Array[String] = []
	if not (values is Array or values is PackedStringArray):
		return result
	for value in values:
		result.append(String(value))
	return result


func _pending_from_advance(result: Dictionary) -> Dictionary:
	var pending = result.get("pending_travel", result.get("pending", {}))
	if pending is Dictionary:
		return pending
	_fail("route advance returns its updated pending dictionary")
	return {}


func _free_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("NPC_SCENE_ROUTES_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
