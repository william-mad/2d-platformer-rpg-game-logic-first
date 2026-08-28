class_name NpcMealPhaseSpot extends NpcWorkSpot


func _apply_world_definition() -> void:
	super._apply_world_definition()
	if world_definition == null:
		return
	if String(world_definition.meal_cycle_stage) == MEAL_STAGE_FOOD:
		eat_world_definition = world_definition


func _setup_world_work_state() -> bool:
	# Linked meal spots mirror the controller; they must not register an independent work meter.
	return true


func apply_world_spot_value(changed_spot_id: StringName, new_value: float) -> void:
	if _configured_stage() != MEAL_STAGE_FOOD or changed_spot_id != spot_id:
		super.apply_world_spot_value(changed_spot_id, new_value)
		return
	food_available = clampf(new_value, _get_food_floor(), _get_food_ceiling())
	_sync_meal_cycle_state_from_world()
	_queue_visual_update()
	_queue_request_check()


func _publish_world_work_state() -> void:
	if _configured_stage() == MEAL_STAGE_FOOD:
		return
	super._publish_world_work_state()


func is_work_spot() -> bool:
	return _configured_stage() == MEAL_STAGE_CLEANUP_WORK


func has_work_needed() -> bool:
	return (
		_configured_stage() == MEAL_STAGE_CLEANUP_WORK
		and meal_cycle_stage == MEAL_STAGE_CLEANUP_WORK
		and super.has_work_needed()
	)


func can_player_work(player: Node2D) -> bool:
	if _configured_stage() != MEAL_STAGE_CLEANUP_WORK:
		return false
	return super.can_player_work(player)


func can_serve_npc_need(
	npc_node: Node2D,
	requested_state_name: StringName,
	requested_value_name: StringName = &""
) -> bool:
	var configured_stage := _configured_stage()
	if configured_stage == MEAL_STAGE_FOOD:
		if String(requested_state_name) != "Eat":
			return false
	elif configured_stage == MEAL_STAGE_CLEANUP_WORK:
		if String(requested_state_name) != "Work":
			return false
	else:
		return false
	return super.can_serve_npc_need(npc_node, requested_state_name, requested_value_name)


func _player_can_supply_meal_ingredients(_player: Node2D) -> bool:
	return false


func _update_meal_cycle_visual() -> void:
	var phase_is_active := _configured_stage() == meal_cycle_stage
	if zone_visual != null:
		zone_visual.visible = phase_is_active
	if label != null:
		label.visible = phase_is_active
	if phase_is_active:
		super._update_meal_cycle_visual()


func _configured_stage() -> String:
	if world_definition == null:
		return ""
	return String(world_definition.meal_cycle_stage)
