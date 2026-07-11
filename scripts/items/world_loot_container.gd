class_name WorldLootContainer
extends Area2D

signal loot_collected(source_id: StringName)

@export_group("Magnet")
@export var attraction_radius: float = 160.0
@export var collection_radius: float = 18.0
@export var initial_magnet_speed: float = 90.0
@export var maximum_magnet_speed: float = 420.0
@export var magnet_acceleration: float = 900.0
@export var target_switch_distance_margin: float = 12.0

@onready var count_label: Label = %CountLabel
@onready var prompt_label: Label = %PromptLabel

var source_id: StringName = &""
var source_type: StringName = &""
var _inventory: InventoryModel = InventoryModel.new()
var _initialized: bool = false
var _collection_in_progress: bool = false
var _nearby_receivers: Dictionary = {}
var _current_receiver: InventoryPickupReceiver
var _magnet_speed: float = 0.0
var _excluded_receiver_until_msec: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_inventory.item_quantity_changed.connect(_on_inventory_changed)
	_inventory.inventory_reset.connect(_on_inventory_reset)
	_configure_attraction_shape()
	set_physics_process(false)
	_update_visuals()


func initialize_loot(inventory_data: Dictionary, loot_source_id: StringName = &"") -> InventoryResult:
	if _initialized:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "World loot container was already initialized.")
	var result := _inventory.apply_save_data(inventory_data)
	if not result.success:
		return result
	source_id = loot_source_id
	_initialized = true
	_update_visuals()
	return InventoryResult.succeeded("World loot initialized.")


func initialize_from_inventory(source: InventoryModel, loot_source_id: StringName = &"") -> InventoryResult:
	if source == null:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "Loot source inventory is required.")
	var unreserved_loot := InventoryModel.new()
	for raw_item_id: Variant in source.get_all_quantities():
		var item_id := StringName(String(raw_item_id))
		# Death drops take ownership of complete totals; reservations themselves are not copied.
		var quantity := source.get_quantity(item_id)
		if quantity <= 0:
			continue
		var add_result := unreserved_loot.add(item_id, quantity)
		if not add_result.success:
			return add_result
	return initialize_loot(unreserved_loot.get_save_data(), loot_source_id)


func get_inventory() -> InventoryModel:
	return _inventory


func get_loot_save_data() -> Dictionary:
	return _inventory.get_save_data()


func is_empty() -> bool:
	return _inventory.get_all_quantities().is_empty()


func exclude_receiver(receiver_id: StringName, duration_seconds: float) -> void:
	if receiver_id == &"" or duration_seconds <= 0.0:
		return
	_excluded_receiver_until_msec[String(receiver_id)] = Time.get_ticks_msec() + int(duration_seconds * 1000.0)
	if _current_receiver != null and _current_receiver.get_receiver_id() == receiver_id:
		_clear_current_receiver()


func collect_into(destination: InventoryModel) -> InventoryResult:
	if _collection_in_progress:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "Loot collection is already in progress.")
	if not _initialized or is_empty():
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "World loot is empty or uninitialized.")
	if destination == null:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "Destination inventory is required.")
	_collection_in_progress = true
	var first_failure: InventoryResult
	var quantities := _inventory.get_all_quantities()
	var item_ids: Array = quantities.keys()
	item_ids.sort()
	for raw_item_id: Variant in item_ids:
		var item_id := StringName(String(raw_item_id))
		var result := InventoryTransactionService.transfer_item(_inventory, destination, item_id, int(quantities[raw_item_id]))
		if not result.success and first_failure == null:
			first_failure = result
	_collection_in_progress = false
	_update_visuals()
	if is_empty():
		loot_collected.emit(source_id)
		queue_free()
		return InventoryResult.succeeded("All world loot collected.")
	if first_failure != null:
		return first_failure
	return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "Some world loot could not be collected.")


func _physics_process(delta: float) -> void:
	_prune_and_select_receiver()
	if _current_receiver == null:
		set_physics_process(not _nearby_receivers.is_empty())
		return
	var destination := _current_receiver.get_receiver_world_position()
	var distance := global_position.distance_to(destination)
	if distance <= collection_radius:
		var receiver := _current_receiver
		var result := collect_into(receiver.get_inventory())
		if not result.success and is_instance_valid(self):
			_nearby_receivers.erase(receiver.get_instance_id())
			_clear_current_receiver()
			_prune_and_select_receiver()
		return
	_magnet_speed = move_toward(_magnet_speed, maximum_magnet_speed, magnet_acceleration * delta)
	global_position += global_position.direction_to(destination) * minf(_magnet_speed * delta, distance)


func _on_body_entered(body: Node2D) -> void:
	var receiver := body.get_node_or_null("InventoryPickupReceiver") as InventoryPickupReceiver
	if receiver == null:
		return
	_nearby_receivers[receiver.get_instance_id()] = receiver
	_prune_and_select_receiver()


func _on_body_exited(body: Node2D) -> void:
	var receiver := body.get_node_or_null("InventoryPickupReceiver") as InventoryPickupReceiver
	if receiver == null:
		return
	_nearby_receivers.erase(receiver.get_instance_id())
	if receiver == _current_receiver:
		_clear_current_receiver()
	_prune_and_select_receiver()


func _prune_and_select_receiver() -> void:
	var candidates: Array[InventoryPickupReceiver] = []
	for instance_id: Variant in _nearby_receivers.keys():
		var receiver := _nearby_receivers[instance_id] as InventoryPickupReceiver
		if receiver == null or not is_instance_valid(receiver) or not receiver.can_receive_world_loot():
			_nearby_receivers.erase(instance_id)
			continue
		if _receiver_is_temporarily_excluded(receiver):
			continue
		if receiver.get_receiver_id() == source_id and source_type != &"player_dump":
			_nearby_receivers.erase(instance_id)
			continue
		candidates.append(receiver)
	if candidates.is_empty():
		_clear_current_receiver()
		set_physics_process(not _nearby_receivers.is_empty())
		return
	candidates.sort_custom(func(left: InventoryPickupReceiver, right: InventoryPickupReceiver) -> bool:
		var left_distance := global_position.distance_squared_to(left.get_receiver_world_position())
		var right_distance := global_position.distance_squared_to(right.get_receiver_world_position())
		if is_equal_approx(left_distance, right_distance):
			return String(left.get_receiver_id()) < String(right.get_receiver_id())
		return left_distance < right_distance
	)
	var nearest := candidates[0]
	if _receiver_is_eligible(_current_receiver) and _current_receiver != nearest:
		var current_distance := global_position.distance_to(_current_receiver.get_receiver_world_position())
		var nearest_distance := global_position.distance_to(nearest.get_receiver_world_position())
		if nearest_distance + target_switch_distance_margin >= current_distance:
			nearest = _current_receiver
	if nearest != _current_receiver:
		_current_receiver = nearest
		_magnet_speed = initial_magnet_speed
	set_physics_process(true)
	_update_visuals()


func _receiver_is_eligible(receiver: InventoryPickupReceiver) -> bool:
	if receiver == null or not is_instance_valid(receiver) or not receiver.can_receive_world_loot():
		return false
	var receiver_id := receiver.get_receiver_id()
	if receiver_id == &"" or (receiver_id == source_id and source_type != &"player_dump"):
		return false
	return not _receiver_is_temporarily_excluded(receiver)


func _receiver_is_temporarily_excluded(receiver: InventoryPickupReceiver) -> bool:
	if receiver == null or not is_instance_valid(receiver):
		return false
	var receiver_id := receiver.get_receiver_id()
	var key := String(receiver_id)
	var excluded_until := int(_excluded_receiver_until_msec.get(key, 0))
	if excluded_until > Time.get_ticks_msec():
		return true
	_excluded_receiver_until_msec.erase(key)
	return false


func get_current_receiver_id() -> StringName:
	return _current_receiver.get_receiver_id() if _receiver_is_eligible(_current_receiver) else &""


func _clear_current_receiver() -> void:
	_current_receiver = null
	_magnet_speed = 0.0
	_update_visuals()


func _configure_attraction_shape() -> void:
	var collision_shape := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision_shape == null:
		return
	var circle := collision_shape.shape as CircleShape2D
	if circle != null:
		circle.radius = attraction_radius


func _on_inventory_changed(_item_id: StringName, _total: int, _available: int, _reason: StringName) -> void:
	_update_visuals()


func _on_inventory_reset() -> void:
	_update_visuals()


func _update_visuals() -> void:
	if count_label == null or prompt_label == null:
		return
	var total_units := 0
	for quantity: Variant in _inventory.get_all_quantities().values():
		total_units += int(quantity)
	count_label.text = "%d item%s" % [total_units, "" if total_units == 1 else "s"]
	prompt_label.visible = _current_receiver != null and total_units > 0
	prompt_label.text = "Attracting loot"
