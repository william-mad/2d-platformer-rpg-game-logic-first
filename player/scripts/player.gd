class_name Player extends CharacterBody2D

# Emitted when hp hits 0. GameOverScreen (autoload) listens and shows the game-over flow.
signal player_defeated
signal hunger_changed(current_hunger: float, changed_by: float)

const MOVEMENT_ANIMATIONS: Array[StringName] = [&"walk", &"run"]
const GAMEPLAY_CONTROL_UI_ONLY: StringName = &"ui_only"
const DamageFlash := preload("res://scripts/visual/character_damage_flash.gd")
const CLAIM_SUPPRESSED_ACTIONS: Array[StringName] = [
	&"attack",
	&"jump",
	&"crouch",
	&"charm",
	&"attach_rope",
	&"attach_rope_npc",
]

#region //onready variables:
@onready var sprite_2d: Sprite2D = $Sprite2D
@onready var movement_sprite: Sprite2D = $MovementSprite
@onready var colider_stand: CollisionShape2D = $colider_stand
@onready var colider_crouch: CollisionShape2D = $colider_crouch
@onready var ongrounddetection: ShapeCast2D = $ongrounddetection
@onready var small_platform_detection: RayCast2D = $"small platform detection"
@onready var ledgegrabcolider: CollisionShape2D = %ledgegrabcolider
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var attack_hitbox: PlayerAttackHitbox = %AttackHitbox
@onready var ledgedetec: RayCast2D = %ledgedetec
@onready var player_inventory: PlayerInventoryComponent = get_node_or_null("PlayerInventory") as PlayerInventoryComponent
@onready var player_equipment: PlayerEquipmentComponent = get_node_or_null("PlayerEquipment") as PlayerEquipmentComponent
@onready var interaction_router: InteractionRouter = get_node_or_null("InteractionRouter") as InteractionRouter
@onready var progression_system: GameProgressionSystem = get_node_or_null("/root/ProgressionSystem") as GameProgressionSystem

#endregion


#region //rope mechanics:
@onready var rope: Rope = $rope
@onready var rope_detector: Area2D = %RopeDetector
@onready var rope_origin: Marker2D = %RopeOrigin
@export_range(0.01, 1000.0, 0.01) var rope_weight: float = 1.0
#endregion

#region //export variables
@export var move_speed : float = 520
@export var level_one_run_speed: float = 260.0
@export_range(1, 999, 1) var run_speed_max_level: int = 10
@export var knockback_force: Vector2 = Vector2(220, -160)
@export var knockback_time: float = 0.15
@export_group("Run Animation Playback")
@export_range(0.01, 4.0, 0.01) var run_animation_start_speed_scale: float = 0.65
@export_range(0.01, 4.0, 0.01) var run_animation_min_speed_scale: float = 0.55
@export_range(0.01, 4.0, 0.01) var run_animation_max_speed_scale: float = 1.65
@export_range(0.01, 10.0, 0.01, "suffix:scale/s") var run_animation_acceleration: float = 1.8
@export_range(0.01, 10.0, 0.01, "suffix:scale/s") var run_animation_deceleration: float = 3.5
@export_group("Damage Feedback")
@export var damage_flash_enabled: bool = true
@export var damage_flash_peak_color: Color = Color(1.0, 0.86, 0.72, 1.0)
@export var damage_flash_fade_color: Color = Color(1.0, 0.12, 0.06, 1.0)
@export_range(0.01, 0.5, 0.01, "suffix:s") var damage_flash_peak_seconds: float = 0.04
@export_range(0.01, 1.0, 0.01, "suffix:s") var damage_flash_fade_seconds: float = 0.16
@export_group("Knockout")
@export var max_knockout: float = 100.0
@export var knockout_decay_per_second: float = 55.0
@export var downed_decay_per_second: float = 32.0
@export var charged_mana_damage_causes_knockout: bool = true
@export_range(0.0, 1.0, 0.01) var charged_mana_knockout_threshold_ratio: float = 0.3334
@export_group("Defeat")
@export_range(0.0, 5.0, 0.05, "suffix:s") var defeat_game_over_delay_seconds: float = 1.15
@export_range(0.05, 5.0, 0.05, "suffix:s") var defeat_screen_fade_seconds: float = 0.9
@export_range(0, 200, 1) var defeat_screen_fade_layer: int = 110
@export var defeat_screen_fade_color: Color = Color(0.0, 0.0, 0.0, 1.0)
@export_range(0, 256, 1) var defeat_particle_amount: int = 42
@export var defeat_particle_color: Color = Color(0.9, 0.04, 0.02, 0.9)
#endregion

#region //playerstats:
@export var max_hp : float = 20
@export_range(1.0, 100.0, 0.1, "suffix:hp/day") var passive_healing_per_game_day: float = 10.0
var hp : float = 20
var mana_charge_rate : float = 100
var max_mana : float = 300
var mana_amount: float = 0.0
@export var mana_2_starts_full: bool = true
@export var mana_2_charge_rate: float = 50.0
var mana_2_amount: float = 0.0
@export_group("Needs")
@export var player_needs_enabled: bool = true
@export_range(0.0, 100.0, 0.1) var hunger: float = 20.0
@export_range(0.0, 100.0, 0.1) var sleep_need: float = 10.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var hunger_growth_per_game_hour: float = 7.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var sleep_need_growth_per_game_hour: float = 5.1
var dash: bool = false
var double_jump: bool = false
var ground_slam: bool = false
var transformation: bool = false
# Set to true once hp reaches 0 so the player stops acting and take_damage becomes a no-op.
var dead: bool = false
var knockout_amount: float = 0.0
var knockout_active: bool = false
var is_downed: bool = false
var active_spot_action: StringName = &""
var active_spot: Node
var movement_lock_source: Node
var movement_lock_action: StringName = &""
#endregion

#region //save system:
@export var save_id: String = "player"
# Add variable names here in the Inspector when a new simple player value should save automatically.
@export var extra_saved_value_names: Array[StringName] = []
#endregion





#state machine variables
var states : Array[ PlayerState ]
var current_state : PlayerState : 
	get : return states.front()
var previous_state : PlayerState:
	get : return states [ 1 ]

#standard variables
var direction : Vector2 = Vector2.ZERO
var gravity : float = 1500.0
var gravity_multiplier : float = 1.0
var knockback_timer: float = 0.0
var gameplay_control_claim_token: int = 0
var gameplay_control_claim_owner: WeakRef
var gameplay_control_claim_reason: StringName = &""
var gameplay_control_mode: StringName = &""
var _gameplay_input_resume_frame: int = 0
var _claim_suppressed_actions: Dictionary = {}
var _damage_flash := DamageFlash.new()
var player_hud

func _ready() -> void:
	add_to_group(&"saveable")
	_register_relationship_identity()
	player_hud = get_node_or_null("/root/PlayerHud")
	var animation_callback := Callable(self, "_on_player_animation_started")
	if not animation_player.animation_started.is_connected(animation_callback):
		animation_player.animation_started.connect(animation_callback)
	_sync_player_animation_visual(animation_player.current_animation)
	rope.configure(self, rope_origin, rope_detector)
	if player_hud != null:
		player_hud.visible = true
	hp = max_hp
	knockout_amount = 0.0
	knockout_active = false
	is_downed = false
	mana_amount = 0.0
	mana_2_amount = max_mana if mana_2_starts_full else 0.0
	sync_stats_to_hud()
	#initialize states
	initialize_states()
	if player_equipment != null:
		player_equipment.bind_inventory(get_inventory())
	_apply_pending_runtime_state()
	_bind_gameplay_control_claim_notifications()
	if player_hud != null and player_hud.has_method("bind_player_inventory"):
		player_hud.call("bind_player_inventory", get_inventory(), self)
	pass


func _register_relationship_identity() -> void:
	var relationships := get_node_or_null("/root/Relationships")
	if (
		relationships != null
		and relationships.has_method("register_actor_identity")
	):
		relationships.call("register_actor_identity", self)


func _exit_tree() -> void:
	_stop_damage_flash()
	if player_hud != null and player_hud.has_method("unbind_player_inventory"):
		player_hud.call("unbind_player_inventory", get_inventory())


func get_save_id() -> String:
	return save_id


func get_save_data() -> Dictionary:
	# SaveSystem calls this when SaveSystem.save_game() runs.
	# Add stable keys here for important player data that needs special restore behavior.
	var data := {
		"global_position": global_position,
		"hp": hp,
		"max_hp": max_hp,
		"mana_amount": mana_amount,
		"mana_2_amount": mana_2_amount,
		"max_mana": max_mana,
		"hunger": hunger,
		"sleep_need": sleep_need,
		"dash": dash,
		"double_jump": double_jump,
		"ground_slam": ground_slam,
		"transformation": transformation,
		"facing_left": sprite_2d.flip_h,
		"extra_values": _collect_extra_save_values(),
	}
	data["inventory"] = get_inventory_save_data()
	data["equipment"] = player_equipment.get_save_data() if player_equipment != null else {}
	return data


func apply_save_data(data: Dictionary) -> void:
	# SaveSystem calls this after the saved scene finishes loading.
	# Keep this forgiving so older save files can still load after you add new values.
	if data.has("global_position") and data["global_position"] is Vector2:
		global_position = data["global_position"]

	max_hp = float(data.get("max_hp", max_hp))
	hp = clampf(float(data.get("hp", hp)), 0.0, max_hp)

	max_mana = float(data.get("max_mana", max_mana))
	mana_amount = clampf(float(data.get("mana_amount", mana_amount)), 0.0, max_mana)
	mana_2_amount = clampf(float(data.get("mana_2_amount", mana_2_amount)), 0.0, max_mana)
	hunger = clampf(float(data.get("hunger", hunger)), 0.0, 100.0)
	sleep_need = clampf(float(data.get("sleep_need", sleep_need)), 0.0, 100.0)

	dash = bool(data.get("dash", dash))
	double_jump = bool(data.get("double_jump", double_jump))
	ground_slam = bool(data.get("ground_slam", ground_slam))
	transformation = bool(data.get("transformation", transformation))

	if data.has("facing_left"):
		apply_facing_left(bool(data["facing_left"]))

	if data.has("inventory"):
		var inventory_data = data["inventory"]
		var inventory_result: InventoryResult
		if inventory_data is Dictionary:
			inventory_result = apply_inventory_save_data(inventory_data)
		else:
			inventory_result = InventoryResult.failed(
				InventoryResult.Code.INVALID_SAVE_DATA,
				"Player inventory save data must be a dictionary."
			)
		if not inventory_result.success:
			push_warning(
				"Player inventory restore failed (code %s): %s Existing live inventory was preserved."
				% [str(inventory_result.code), inventory_result.message]
			)
	else:
		# Inventory was optional in older player save blocks.
		reset_inventory()

	if player_equipment != null:
		var equipment_data = data.get("equipment", {})
		var equipment_result := player_equipment.apply_save_data(
			equipment_data if equipment_data is Dictionary else {}
		)
		if not bool(equipment_result.get("success", false)):
			push_warning("Player equipment restore failed: %s" % String(equipment_result.get("message", "Unknown error.")))

	var extra_values = data.get("extra_values", {})
	if extra_values is Dictionary:
		_apply_extra_save_values(extra_values)

	velocity = Vector2.ZERO
	knockback_timer = 0.0
	knockout_amount = 0.0
	knockout_active = false
	is_downed = false
	# A freshly loaded player is alive and responsive even if the previous run ended in defeat.
	dead = false
	set_physics_process(true)
	set_process(true)
	set_process_unhandled_input(true)
	sync_stats_to_hud()


func get_inventory() -> InventoryModel:
	if player_inventory == null:
		push_error("Player is missing its required PlayerInventory component.")
		return null
	return player_inventory.get_inventory()


func get_inventory_save_data() -> Dictionary:
	if player_inventory == null:
		push_error("Player cannot serialize inventory: PlayerInventory component is missing.")
		return InventoryModel.get_empty_save_data()
	return player_inventory.get_save_data()


func apply_inventory_save_data(data: Dictionary) -> InventoryResult:
	if player_inventory == null:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"Player is missing its required PlayerInventory component."
		)
	return player_inventory.apply_save_data(data)


func reset_inventory() -> void:
	if player_inventory == null:
		push_error("Player cannot reset inventory: PlayerInventory component is missing.")
		return
	player_inventory.reset_inventory()


func get_equipped_item_id(slot_id: StringName) -> StringName:
	return player_equipment.get_equipped_item_id(slot_id) if player_equipment != null else &""


func get_player_level() -> int:
	if progression_system == null:
		return 1
	return maxi(progression_system.get_global_level(), 1)


func is_player_ability_unlocked(ability_id: StringName) -> bool:
	if progression_system == null:
		return false
	return progression_system.is_ability_unlocked(ability_id)


func get_run_speed() -> float:
	var maximum_speed := maxf(move_speed, 0.0)
	var starting_speed := clampf(level_one_run_speed, 0.0, maximum_speed)
	var maximum_speed_level := maxi(run_speed_max_level, 1)
	if maximum_speed_level == 1:
		return maximum_speed

	var speed_level := clampi(get_player_level(), 1, maximum_speed_level)
	var level_progress := float(speed_level - 1) / float(maximum_speed_level - 1)
	return lerpf(starting_speed, maximum_speed, level_progress)


func get_level_damage_multiplier() -> float:
	if progression_system == null:
		return 1.0
	var multiplier := progression_system.get_damage_multiplier()
	return multiplier if is_finite(multiplier) and multiplier >= 0.0 else 1.0


func get_scaled_attack_damage(base_damage: float) -> float:
	return maxf(base_damage, 0.0) * get_level_damage_multiplier()


func get_attack_equipment_modifiers(attack_definition: AttackDefinition) -> Dictionary:
	var modifiers := {
		"damage_multiplier": get_level_damage_multiplier(),
		"knockout_multiplier": 1.0,
	}
	if attack_definition == null or player_equipment == null:
		return modifiers
	var profile := player_equipment.get_equipped_profile(&"weapon")
	if profile == null or not profile.is_valid_profile():
		return modifiers
	if not profile.applies_to_attack(attack_definition.tags):
		return modifiers
	modifiers["damage_multiplier"] = (
		float(modifiers["damage_multiplier"]) * profile.damage_multiplier
	)
	modifiers["knockout_multiplier"] = profile.knockout_multiplier
	return modifiers


func _apply_pending_runtime_state() -> void:
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if runtime != null and runtime.has_method("apply_to_player"):
		runtime.call("apply_to_player", self)


func sync_stats_to_hud() -> void:
	hp = clampf(hp, 0.0, max_hp)
	mana_amount = clampf(mana_amount, 0.0, max_mana)
	mana_2_amount = clampf(mana_2_amount, 0.0, max_mana)
	hunger = clampf(hunger, 0.0, 100.0)
	sleep_need = clampf(sleep_need, 0.0, 100.0)

	if player_hud == null:
		return
	player_hud.setup_hp(max_hp, hp)
	player_hud.setup_mana(max_mana, mana_amount, mana_2_amount)
	if player_hud.has_method("setup_knockout"):
		player_hud.call(
			"setup_knockout",
			max_knockout,
			knockout_amount,
			knockout_active,
			is_downed
		)
	if player_hud.has_method("setup_needs"):
		player_hud.call("setup_needs", 100.0, hunger, sleep_need)


func _collect_extra_save_values() -> Dictionary:
	var values := {}
	for value_name in extra_saved_value_names:
		# This keeps experimentation safe: a typo is skipped instead of breaking the save.
		if _has_player_property(value_name):
			values[String(value_name)] = get(value_name)

	return values


func _apply_extra_save_values(values: Dictionary) -> void:
	for value_name in extra_saved_value_names:
		var key := String(value_name)
		if values.has(key) and _has_player_property(value_name):
			set(value_name, values[key])


func _has_player_property(property_name: StringName) -> bool:
	for property in get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return true

	return false
	
func _unhandled_input( event: InputEvent) -> void:
	if _consume_claim_suppressed_action(event):
		return
	if interaction_router != null and interaction_router.route_input(event):
		get_viewport().set_input_as_handled()
		return
	if is_gameplay_control_claimed() or _gameplay_input_release_is_pending():
		return
	if is_downed or is_movement_locked():
		return

	if _consume_rope_pay_out_input(event):
		return
	if _handle_rope_input(event):
		return
	change_state(current_state.handle_input( event ))

	
	pass


func _process(_delta: float) -> void:
	if is_gameplay_control_claimed() or _gameplay_input_release_is_pending():
		direction = Vector2.ZERO
		velocity.x = 0.0
		update_knockout(_delta)
		update_mana_2_charge(_delta)
		update_player_needs(_delta)
		update_passive_healing(_delta)
		return

	_refresh_claim_suppressed_actions()
	if is_movement_locked():
		direction = Vector2.ZERO
		velocity.x = 0.0
		update_knockout(_delta)
		update_mana_2_charge(_delta)
		update_player_needs(_delta)
		update_passive_healing(_delta)
		return

	update_direction()
	update_knockout(_delta)
	update_mana_2_charge(_delta)
	if not _claim_suppressed_actions.has(&"attack"):
		update_mana_charge(_delta)
	update_player_needs(_delta)
	update_passive_healing(_delta)
	change_state(current_state.process(_delta))
	
	
func _physics_process(_delta: float) -> void:
	if rope != null and (dead or is_downed):
		rope.cancel_pending_throw()
	if rope != null and rope.is_throw_charging():
		rope.set_throw_facing(_get_rope_facing_direction())
	velocity.y += gravity * _delta * gravity_multiplier
	var velocity_before_state_update := velocity

	if is_gameplay_control_claimed() or _gameplay_input_release_is_pending():
		rope.cancel_pending_throw()
		velocity.x = 0.0
		if knockback_timer > 0.0:
			knockback_timer = maxf(knockback_timer - _delta, 0.0)
		_move_and_slide_with_rope(_delta)
		return

	if is_movement_locked():
		rope.cancel_pending_throw()
		velocity.x = 0.0
		if knockback_timer > 0.0:
			knockback_timer = maxf(knockback_timer - _delta, 0.0)
		_move_and_slide_with_rope(_delta)
		return

	if knockback_timer > 0.0:
		rope.cancel_pending_throw()
		knockback_timer -= _delta
		_move_and_slide_with_rope(_delta)
		return

	if rope.active:
		# Up always reels in. Down pays out only while the player holds one end.
		var reel_input := Input.is_action_pressed("up")
		if (
			reel_input
			and interaction_router != null
			and interaction_router.is_interaction_action_held(&"up")
		):
			reel_input = false
		rope.adjust_length(
			reel_input,
			Input.is_action_pressed("crouch"),
			_delta
		)
	current_state.physics_update_before_move(_delta)
	if (
		current_state is PlayerStateJump
		or current_state is PlayerStateFall
	):
		velocity = rope.apply_anchored_swing_control(
			self,
			velocity,
			velocity_before_state_update,
			direction.x,
			_delta
		)
	_move_and_slide_with_rope(_delta)
	change_state(current_state.physics_update_after_move(_delta))
	pass


func _move_and_slide_with_rope(delta: float) -> void:
	velocity = Rope.constrain_attached_velocity(self, velocity, delta)
	move_and_slide()
	_update_run_animation_playback(delta)


func initialize_states () -> void:
	states = []
	for c in $States.get_children():
		if c is PlayerState:
			states.append(c)
			c.player = self
			
		pass
	if states.size() == 0:
		return
		
	
	
	for state in states:
		state.init()
		
	change_state(current_state)
	current_state.enter()
	$Label.text = current_state.name
	pass
	

func change_state( new_state : PlayerState ) -> void:
	if new_state == null:
		return

	elif new_state == current_state:
		return

	if current_state:
		current_state.exit()

	states.push_front(new_state)
	current_state.enter()
	states.resize( 3 )
	$Label.text = current_state.name
	pass
		


func update_direction()->void:
	
	var previous_direction: Vector2 = direction
	
	
	var x_axis= Input.get_axis("left", "right")
	var y_axis= Input.get_axis("jump", "crouch")
	direction = Vector2(x_axis, y_axis)
	
	if previous_direction.x != direction.x:
		if direction.x < 0:
			apply_facing_left(true)
		elif direction.x > 0:
			apply_facing_left(false)
			
	pass
	

func apply_facing_left(is_facing_left: bool) -> void:
	var direction_x := -1.0 if is_facing_left else 1.0

	sprite_2d.flip_h = is_facing_left
	movement_sprite.flip_h = is_facing_left
	ledgedetec.position.x = abs(ledgedetec.position.x) * direction_x
	ledgedetec.target_position.x = abs(ledgedetec.target_position.x) * direction_x
	ledgegrabcolider.scale.x = direction_x


func get_active_visual_sprite() -> Sprite2D:
	if movement_sprite != null and movement_sprite.visible:
		return movement_sprite
	return sprite_2d


func _on_player_animation_started(animation_name: StringName) -> void:
	_sync_player_animation_visual(animation_name)
	if animation_name == &"run":
		animation_player.speed_scale = clampf(
			run_animation_start_speed_scale,
			minf(run_animation_min_speed_scale, run_animation_max_speed_scale),
			maxf(run_animation_min_speed_scale, run_animation_max_speed_scale)
		)
	else:
		animation_player.speed_scale = 1.0


func _update_run_animation_playback(delta: float) -> void:
	if animation_player == null or animation_player.current_animation != &"run":
		return
	var target_scale := _get_run_animation_target_scale(absf(get_real_velocity().x))
	var adjustment_rate := (
		run_animation_acceleration
		if target_scale > animation_player.speed_scale
		else run_animation_deceleration
	)
	animation_player.speed_scale = move_toward(
		animation_player.speed_scale,
		target_scale,
		maxf(adjustment_rate, 0.01) * maxf(delta, 0.0)
	)


func _get_run_animation_target_scale(actual_horizontal_speed: float) -> float:
	var minimum_scale := minf(run_animation_min_speed_scale, run_animation_max_speed_scale)
	var maximum_scale := maxf(run_animation_min_speed_scale, run_animation_max_speed_scale)
	return clampf(
		maxf(actual_horizontal_speed, 0.0) / maxf(level_one_run_speed, 0.001),
		minimum_scale,
		maximum_scale
	)


func _sync_player_animation_visual(animation_name: StringName) -> void:
	var uses_movement_sprite := MOVEMENT_ANIMATIONS.has(animation_name)
	movement_sprite.visible = uses_movement_sprite
	sprite_2d.visible = not uses_movement_sprite and not _player_visual_is_hidden()


func _player_visual_is_hidden() -> bool:
	return not states.is_empty() and current_state is PlayerStateHidden


func _handle_rope_input(event: InputEvent) -> bool:
	var end_id: StringName = &""
	if (
		event.is_action_pressed("attach_rope")
		or event.is_action_released("attach_rope")
	):
		end_id = Rope.END_X
	elif (
		event.is_action_pressed("attach_rope_npc")
		or event.is_action_released("attach_rope_npc")
	):
		end_id = Rope.END_S
	else:
		return false

	if (
		not event.is_action_pressed(
			"attach_rope" if end_id == Rope.END_X else "attach_rope_npc"
		)
		and not event.is_action_released(
			"attach_rope" if end_id == Rope.END_X else "attach_rope_npc"
		)
	):
		return false
	if event is InputEventKey and (event as InputEventKey).echo:
		return true
	if (
		rope.has_pending_throw()
		and rope.get_pending_endpoint() != end_id
	):
		return true

	var action_name := (
		&"attach_rope" if end_id == Rope.END_X else &"attach_rope_npc"
	)
	if event.is_action_pressed(action_name):
		if rope.endpoint_is_attached(end_id):
			rope.undo_from_endpoint_input(end_id)
		elif rope.has_pending_throw():
			rope.cancel_pending_throw()
		else:
			rope.begin_endpoint_gesture(
				end_id,
				_get_rope_facing_direction()
			)
		return true

	rope.set_throw_facing(_get_rope_facing_direction())
	rope.release_endpoint_gesture(end_id)
	return true


func _consume_rope_pay_out_input(event: InputEvent) -> bool:
	return (
		rope != null
		and rope.can_pay_out()
		and event.is_action_pressed("crouch")
	)


func is_rope_pay_out_control_active() -> bool:
	return rope != null and rope.can_pay_out()


func _get_rope_facing_direction() -> float:
	return -1.0 if sprite_2d.flip_h else 1.0


func prepare_for_external_activity(_reason: StringName) -> Dictionary:
	rope.cancel_pending_throw()
	if rope != null and rope.active:
		rope.detach()
	clear_mana_charge()
	direction = Vector2.ZERO
	velocity.x = 0.0
	return {"accepted": true, "reason": ""}


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	knockout_damage: float = 0.0
) -> void:
	# A defeated player ignores further damage so the death overlay is the only reaction.
	if dead:
		return

	var previous_hp := hp
	hp = maxf(hp - amount, 0.0)
	var damage_taken := previous_hp - hp
	var damage_events := get_node_or_null("/root/DamageEvents")
	if damage_events != null and damage_events.has_method("emit_damage_dealt"):
		damage_events.call("emit_damage_dealt", damage_taken, damage_source, self)
	if player_hud != null:
		player_hud.set_hp(hp)
	if damage_taken > 0.0:
		_play_damage_feedback()

	if hp <= 0:
		_defeat()
		return

	if damage_taken > 0.0 and apply_charged_mana_damage_penalty():
		return

	apply_knockout(knockout_damage)
	if not is_downed:
		apply_knockback(damage_source_position)


func _play_damage_feedback() -> void:
	if not damage_flash_enabled:
		return
	var visuals: Array[CanvasItem] = [sprite_2d, movement_sprite]
	_damage_flash.play(
		self,
		visuals,
		damage_flash_peak_color,
		damage_flash_fade_color,
		damage_flash_peak_seconds,
		damage_flash_fade_seconds
	)


func _stop_damage_flash() -> void:
	_damage_flash.stop()


func _defeat() -> void:
	# Called once when hp hits 0. Stops movement, freezes input, then lets GameOverScreen react.
	if dead:
		return

	dead = true
	if rope != null:
		rope.cancel_pending_throw()
	velocity = Vector2.ZERO
	knockback_timer = 0.0
	set_physics_process(false)
	set_process(false)
	set_process_unhandled_input(false)
	_start_defeat_transition()


func _start_defeat_transition() -> void:
	_spawn_defeat_particles()
	_fade_defeat_screen()

	if not is_inside_tree() or defeat_game_over_delay_seconds <= 0.0:
		player_defeated.emit()
		return

	await get_tree().create_timer(defeat_game_over_delay_seconds).timeout
	player_defeated.emit()


func heal(amount: float) -> void:
	if dead or amount <= 0.0:
		return
	hp = minf(hp + amount, max_hp)
	if player_hud != null:
		player_hud.set_hp(hp)


func restore_full_health() -> void:
	if dead:
		return
	heal(max_hp - hp)


func apply_knockout(amount: float) -> void:
	if dead or amount <= 0.0 or max_knockout <= 0.0:
		return

	knockout_amount = clampf(knockout_amount + amount, 0.0, max_knockout)
	knockout_active = knockout_amount > 0.0
	sync_knockout_bar()

	if knockout_amount >= max_knockout:
		enter_downed_state()


func has_dangerous_mana_charge() -> bool:
	if max_mana <= 0.0:
		return false

	return mana_amount > max_mana * charged_mana_knockout_threshold_ratio


func apply_charged_mana_damage_penalty() -> bool:
	if not charged_mana_damage_causes_knockout:
		return false
	if not has_dangerous_mana_charge():
		return false

	var charged_mana_lost := mana_amount
	clear_mana_charge()
	spend_mana_2(charged_mana_lost)

	if is_downed:
		return false

	knockout_amount = maxf(max_knockout, 0.0)
	knockout_active = knockout_amount > 0.0
	sync_knockout_bar()
	enter_downed_state()
	return true


func update_knockout(delta: float) -> void:
	if not knockout_active:
		return

	var decay_rate := downed_decay_per_second if is_downed else knockout_decay_per_second
	knockout_amount = move_toward(knockout_amount, 0.0, maxf(decay_rate, 0.0) * maxf(delta, 0.0))
	sync_knockout_bar()

	if knockout_amount > 0.0:
		return

	knockout_active = false
	if is_downed:
		exit_downed_state()
	sync_knockout_bar()


func enter_downed_state() -> void:
	if is_downed:
		return

	is_downed = true
	if rope != null:
		rope.cancel_pending_throw()
	knockback_timer = 0.0
	velocity.x = 0.0
	var downed_state := $States.get_node_or_null("Downed") as PlayerState
	if downed_state != null:
		change_state(downed_state)
	sync_knockout_bar()


func exit_downed_state() -> void:
	is_downed = false
	if current_state is PlayerStateDowned:
		if is_on_floor():
			change_state($States/Idle)
		else:
			change_state($States/Fall)


func sync_knockout_bar() -> void:
	if player_hud != null and player_hud.has_method("set_knockout"):
		player_hud.call("set_knockout", knockout_amount, knockout_active, is_downed)


func update_player_needs(delta: float) -> void:
	if _is_world_progression_locked():
		return
	if not player_needs_enabled:
		return

	var game_hours := _get_game_hours_for_real_seconds(delta)
	if game_hours <= 0.0:
		return

	if active_spot_action != &"eat":
		apply_hunger_delta(hunger_growth_per_game_hour * game_hours)
	if active_spot_action != &"sleep":
		apply_sleep_need_delta(sleep_need_growth_per_game_hour * game_hours)


func update_passive_healing(delta: float) -> void:
	if _is_world_progression_locked():
		return
	if passive_healing_per_game_day <= 0.0 or hp <= 0.0 or hp >= max_hp:
		return

	var game_hours := _get_game_hours_for_real_seconds(delta)
	if game_hours <= 0.0:
		return

	heal((passive_healing_per_game_day / 24.0) * game_hours)


func apply_hunger_delta(delta: float) -> float:
	var previous_value := hunger
	hunger = clampf(hunger + delta, 0.0, 100.0)
	var changed_by := hunger - previous_value
	if player_hud != null and player_hud.has_method("set_hunger"):
		player_hud.call("set_hunger", hunger)
	if not is_zero_approx(changed_by):
		hunger_changed.emit(hunger, changed_by)
	return changed_by


func apply_sleep_need_delta(delta: float) -> float:
	var previous_value := sleep_need
	sleep_need = clampf(sleep_need + delta, 0.0, 100.0)
	if player_hud != null and player_hud.has_method("set_sleep_need"):
		player_hud.call("set_sleep_need", sleep_need)
	return sleep_need - previous_value


func can_eat() -> bool:
	return hunger > 0.0


func can_sleep() -> bool:
	return sleep_need > 0.0


func begin_spot_action(spot: Node, action_name: StringName) -> void:
	active_spot = spot
	active_spot_action = action_name
	_on_spot_action_started(spot, action_name)


func end_spot_action(spot: Node, action_name: StringName, completed: bool) -> void:
	if active_spot != spot or active_spot_action != action_name:
		return

	_on_spot_action_finished(spot, action_name, completed)
	active_spot = null
	active_spot_action = &""


func begin_movement_lock(source: Node, action_name: StringName) -> void:
	if source == null or not is_instance_valid(source):
		return

	movement_lock_source = source
	movement_lock_action = action_name
	direction = Vector2.ZERO
	velocity.x = 0.0
	begin_spot_action(source, action_name)


func end_movement_lock(
	source: Node,
	action_name: StringName = &"",
	completed: bool = true
) -> void:
	if movement_lock_source != source:
		return
	if action_name != &"" and action_name != movement_lock_action:
		return

	var finished_action := movement_lock_action
	movement_lock_source = null
	movement_lock_action = &""
	direction = Vector2.ZERO
	velocity.x = 0.0
	end_spot_action(source, finished_action, completed)


func is_movement_locked() -> bool:
	if movement_lock_source != null and not is_instance_valid(movement_lock_source):
		movement_lock_source = null
		movement_lock_action = &""
		if active_spot_action == &"magic_lesson":
			active_spot = null
			active_spot_action = &""

	return movement_lock_source != null


func register_interaction_candidate(candidate: Node) -> bool:
	return interaction_router != null and interaction_router.register_candidate(candidate)


func unregister_interaction_candidate(candidate: Node) -> void:
	if interaction_router != null:
		interaction_router.unregister_candidate(candidate)


func refresh_interaction_candidate(candidate: Node = null) -> void:
	if interaction_router != null:
		interaction_router.notify_candidate_changed(candidate)


func get_focused_interactable() -> Node:
	return interaction_router.get_focused_interactable() if interaction_router != null else null


func get_interaction_prompt() -> String:
	return interaction_router.get_interaction_prompt() if interaction_router != null else ""


func get_interaction_debug_snapshot() -> Dictionary:
	return interaction_router.get_debug_snapshot() if interaction_router != null else {
		"enabled": false,
		"current_block_reason": &"interaction_router_missing",
	}


func is_interaction_action_pressed() -> bool:
	return interaction_router != null and interaction_router.is_interaction_action_pressed()


func consume_owned_interaction_input() -> bool:
	var talk_interactor := get_node_or_null("NpcTalkInteractor")
	if (
		talk_interactor != null
		and talk_interactor.has_method("consume_player_interaction_input")
		and bool(talk_interactor.call("consume_player_interaction_input", self))
	):
		return true

	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_method("get_player_control_claim"):
		return false
	var claim: Dictionary = gameplay_flow.call("get_player_control_claim", self)
	var owner_ref := claim.get("owner") as WeakRef
	var claim_owner: Object = owner_ref.get_ref() if owner_ref != null else null
	return (
		claim_owner != null
		and claim_owner.has_method("consume_player_interaction_input")
		and bool(claim_owner.call("consume_player_interaction_input", self))
	)


func get_world_interaction_block_reason() -> StringName:
	if is_gameplay_control_claimed():
		return &"player_control_claimed"
	if is_downed or (not states.is_empty() and current_state is PlayerStateDowned):
		return &"player_downed"
	if dead or _is_game_over_handling_active():
		return &"player_dead_or_game_over"
	if is_movement_locked():
		return &"player_movement_locked"
	if active_spot_action != &"" or active_spot != null:
		return &"player_spot_action_active"
	if _is_scene_transition_in_progress():
		return &"scene_transition_in_progress"
	var talk_interactor := get_node_or_null("NpcTalkInteractor")
	if (
		talk_interactor != null
		and talk_interactor.has_method("is_world_interaction_ui_open")
		and bool(talk_interactor.call("is_world_interaction_ui_open"))
	):
		return &"interaction_ui_open"
	if not is_on_floor():
		return &"player_not_grounded"
	return &""


func can_accept_player_control_claim(control_mode: StringName) -> Dictionary:
	if control_mode != GAMEPLAY_CONTROL_UI_ONLY:
		return {"accepted": false, "reason": "unknown_control_mode"}
	if is_gameplay_control_claimed():
		return {"accepted": false, "reason": "already_control_claimed"}
	if is_downed or (not states.is_empty() and current_state is PlayerStateDowned):
		return {"accepted": false, "reason": "player_downed"}
	if dead or _is_game_over_handling_active():
		return {"accepted": false, "reason": "player_dead_or_game_over"}
	if is_movement_locked():
		return {"accepted": false, "reason": "player_movement_locked"}
	if active_spot_action != &"" or active_spot != null:
		return {"accepted": false, "reason": "player_spot_action_active"}
	if _is_scene_transition_in_progress():
		return {"accepted": false, "reason": "scene_transition_in_progress"}
	if not is_on_floor():
		return {"accepted": false, "reason": "player_not_grounded"}
	return {"accepted": true, "reason": ""}


func is_gameplay_control_claimed() -> bool:
	return gameplay_control_claim_token != 0


func get_gameplay_control_mode() -> StringName:
	return gameplay_control_mode if is_gameplay_control_claimed() else &""


func _bind_gameplay_control_claim_notifications() -> void:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_signal(&"player_control_claim_changed"):
		return
	var callback := Callable(self, "_on_player_control_claim_changed")
	if not gameplay_flow.is_connected(&"player_control_claim_changed", callback):
		gameplay_flow.connect(&"player_control_claim_changed", callback)
	if gameplay_flow.has_method("get_player_control_claim"):
		var claim: Dictionary = gameplay_flow.call("get_player_control_claim", self)
		if not claim.is_empty():
			_apply_gameplay_control_claim(claim)


func _on_player_control_claim_changed(
	claimed_player: Node,
	claimed: bool,
	token_id: int
) -> void:
	if claimed_player != self:
		return
	if claimed:
		var gameplay_flow := get_node_or_null("/root/GameplayFlow")
		if gameplay_flow == null or not gameplay_flow.has_method("get_player_control_claim"):
			return
		var claim: Dictionary = gameplay_flow.call("get_player_control_claim", self)
		if int(claim.get("token_id", 0)) == token_id:
			_apply_gameplay_control_claim(claim)
		return
	_release_gameplay_control_claim(token_id)


func _apply_gameplay_control_claim(claim: Dictionary) -> void:
	var player_ref := claim.get("player") as WeakRef
	if player_ref == null or player_ref.get_ref() != self:
		return
	var token_id := int(claim.get("token_id", 0))
	var control_mode := StringName(claim.get("control_mode", &""))
	if token_id == 0 or control_mode != GAMEPLAY_CONTROL_UI_ONLY:
		return

	gameplay_control_claim_token = token_id
	gameplay_control_claim_owner = claim.get("owner") as WeakRef
	gameplay_control_claim_reason = StringName(claim.get("reason", &""))
	gameplay_control_mode = control_mode
	_gameplay_input_resume_frame = 0
	_claim_suppressed_actions.clear()
	direction = Vector2.ZERO
	velocity.x = 0.0
	_enter_idle_for_gameplay_control_claim()
	var talk_interactor := get_node_or_null("NpcTalkInteractor")
	if talk_interactor != null and talk_interactor.has_method("close_for_scripted_handoff"):
		talk_interactor.call("close_for_scripted_handoff")


func _release_gameplay_control_claim(token_id: int) -> void:
	if token_id == 0 or token_id != gameplay_control_claim_token:
		return
	_capture_claim_suppressed_actions()
	gameplay_control_claim_token = 0
	gameplay_control_claim_owner = null
	gameplay_control_claim_reason = &""
	gameplay_control_mode = &""
	_gameplay_input_resume_frame = Engine.get_process_frames() + 1
	direction = Vector2.ZERO
	velocity.x = 0.0
	_enter_idle_for_gameplay_control_claim()


func _enter_idle_for_gameplay_control_claim() -> void:
	if dead or is_downed or not is_on_floor() or states.is_empty():
		return
	var idle_state := $States.get_node_or_null("Idle") as PlayerState
	if idle_state != null and current_state != idle_state:
		change_state(idle_state)


func _gameplay_input_release_is_pending() -> bool:
	return Engine.get_process_frames() < _gameplay_input_resume_frame


func _capture_claim_suppressed_actions() -> void:
	_claim_suppressed_actions.clear()
	for action in CLAIM_SUPPRESSED_ACTIONS:
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			_claim_suppressed_actions[action] = true


func _refresh_claim_suppressed_actions() -> void:
	for action in _claim_suppressed_actions.keys():
		if not Input.is_action_pressed(StringName(action)):
			_claim_suppressed_actions.erase(action)


func _consume_claim_suppressed_action(event: InputEvent) -> bool:
	for action in _claim_suppressed_actions.keys():
		var action_name := StringName(action)
		if event.is_action_released(action_name):
			_claim_suppressed_actions.erase(action)
			return true
		if event.is_action_pressed(action_name):
			return true
	return false


func _is_scene_transition_in_progress() -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null:
		return false
	if scene_loader.has_method("is_scene_transition_in_progress"):
		return bool(scene_loader.call("is_scene_transition_in_progress"))
	return bool(scene_loader.get("loading_in_progress"))


func _is_game_over_handling_active() -> bool:
	var game_over_screen := get_node_or_null("/root/GameOverScreen")
	return (
		game_over_screen != null
		and game_over_screen.has_method("is_game_over_active")
		and bool(game_over_screen.call("is_game_over_active"))
	)


func _on_spot_action_started(_spot: Node, _action_name: StringName) -> void:
	# Animation hook: start player work/eat/sleep animations here.
	pass


func _on_spot_action_finished(_spot: Node, _action_name: StringName, _completed: bool) -> void:
	# Animation hook: stop or swap back from player work/eat/sleep animations here.
	pass


func _get_game_hours_for_real_seconds(real_seconds: float) -> float:
	var world_time := get_tree().root.get_node_or_null("WorldTime")
	if world_time == null:
		return 0.0

	var real_seconds_per_day := float(world_time.get("real_seconds_per_day"))
	if real_seconds_per_day <= 0.0:
		return 0.0

	return (maxf(real_seconds, 0.0) / real_seconds_per_day) * 24.0


func _is_world_progression_locked() -> bool:
	if not is_inside_tree() or get_tree() == null:
		return false
	var gameplay_flow := get_tree().root.get_node_or_null("GameplayFlow")
	return (
		gameplay_flow != null
		and gameplay_flow.has_method("is_world_progression_locked")
		and bool(gameplay_flow.call("is_world_progression_locked"))
	)


func update_mana_charge(delta: float) -> void:
	if is_downed:
		return

	if current_state is PlayerComboAttackState or current_state is PlayerSpecialAttack:
		return

	if Input.is_action_pressed("attack"):
		charge_mana(mana_charge_rate * delta)


func charge_mana(amount: float) -> void:
	mana_amount = minf(mana_amount + amount, mana_2_amount)
	if player_hud != null:
		player_hud.set_mana(mana_amount)


func update_mana_2_charge(delta: float) -> void:
	if mana_2_amount > max_mana:
		mana_2_amount = max_mana
		sync_mana_2_bar()
		return

	if is_equal_approx(mana_2_amount, max_mana):
		if mana_2_amount != max_mana:
			mana_2_amount = max_mana
			sync_mana_2_bar()
		return

	mana_2_amount = move_toward(mana_2_amount, max_mana, mana_2_charge_rate * delta)
	sync_mana_2_bar()


func sync_mana_2_bar() -> void:
	mana_2_amount = clampf(mana_2_amount, 0.0, max_mana)

	if mana_amount > mana_2_amount:
		mana_amount = mana_2_amount

	if player_hud != null:
		player_hud.set_mana_2(mana_2_amount)
		player_hud.set_mana(mana_amount)


func spend_mana_2(amount: float) -> void:
	mana_2_amount = maxf(mana_2_amount - amount, 0.0)
	sync_mana_2_bar()


func clear_mana_charge() -> void:
	mana_amount = 0.0
	if player_hud != null:
		player_hud.set_mana(mana_amount)


func _fade_defeat_screen() -> void:
	if not is_inside_tree():
		return

	var fade_layer := CanvasLayer.new()
	fade_layer.name = "DefeatScreenFade"
	fade_layer.layer = defeat_screen_fade_layer
	add_child(fade_layer)

	var fade_rect := ColorRect.new()
	fade_rect.name = "Fade"
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var start_color := defeat_screen_fade_color
	start_color.a = 0.0
	fade_rect.color = start_color
	fade_layer.add_child(fade_rect)

	var target_color := defeat_screen_fade_color
	target_color.a = clampf(target_color.a, 0.0, 1.0)
	var fade_seconds := maxf(defeat_screen_fade_seconds, 0.05)
	var tween := fade_rect.create_tween()
	tween.tween_property(fade_rect, "color", target_color, fade_seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _spawn_defeat_particles() -> void:
	if defeat_particle_amount <= 0 or sprite_2d == null or not is_inside_tree():
		return

	var particles := CPUParticles2D.new()
	particles.name = "DefeatParticles"
	particles.position = sprite_2d.position
	particles.z_index = sprite_2d.z_index + 2
	particles.amount = defeat_particle_amount
	particles.lifetime = maxf(defeat_game_over_delay_seconds, 0.4)
	particles.one_shot = true
	particles.explosiveness = 0.92
	particles.randomness = 0.48
	particles.direction = Vector2.UP
	particles.spread = 82.0
	particles.gravity = Vector2(0.0, -120.0)
	particles.initial_velocity_min = 55.0
	particles.initial_velocity_max = 180.0
	particles.scale_amount_min = 2.0
	particles.scale_amount_max = 5.0
	particles.color = defeat_particle_color
	particles.texture = _create_defeat_particle_texture()
	add_child(particles)
	particles.emitting = true

	var cleanup := particles.create_tween()
	cleanup.tween_interval(particles.lifetime + 0.1)
	cleanup.tween_callback(particles.queue_free)


func _create_defeat_particle_texture() -> Texture2D:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for y in range(8):
		for x in range(8):
			var point := Vector2(float(x) - 3.5, float(y) - 3.5)
			var distance := point.length()
			var alpha := clampf(1.0 - (distance / 4.0), 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))

	return ImageTexture.create_from_image(image)


func apply_knockback(damage_source_position: Vector2) -> void:
	var knockback_direction := signf(global_position.x - damage_source_position.x)
	if knockback_direction == 0.0:
		knockback_direction = -1.0 if sprite_2d.flip_h else 1.0

	velocity = Vector2(knockback_force.x * knockback_direction, knockback_force.y)
	knockback_timer = knockback_time


func force_flee_from(threat: Node2D, duration: float = 1.2, speed: float = 700.0) -> void:
	if dead:
		return

	var threat_position := global_position
	if threat != null and is_instance_valid(threat):
		threat_position = threat.global_position

	var flee_direction := signf(global_position.x - threat_position.x)
	if flee_direction == 0.0:
		flee_direction = -1.0 if sprite_2d.flip_h else 1.0

	apply_facing_left(flee_direction < 0.0)
	velocity.x = flee_direction * maxf(speed, 0.0)
	knockback_timer = maxf(knockback_timer, maxf(duration, 0.0))
