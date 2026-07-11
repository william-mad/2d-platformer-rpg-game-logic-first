class_name WorldLootContainer
extends Area2D

signal loot_collected(source_id: StringName)

@export var interaction_action: StringName = &"up"

@onready var count_label: Label = %CountLabel
@onready var prompt_label: Label = %PromptLabel

var source_id: StringName = &""
var _inventory: InventoryModel = InventoryModel.new()
var _initialized: bool = false
var _collection_in_progress: bool = false
var _nearby_player: Node2D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_inventory.item_quantity_changed.connect(_on_inventory_changed)
	_inventory.inventory_reset.connect(_on_inventory_reset)
	set_process_unhandled_input(true)
	_update_visuals()


func initialize_loot(inventory_data: Dictionary, loot_source_id: StringName = &"") -> InventoryResult:
	if _initialized:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"World loot container was already initialized."
		)
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
	var quantities := source.get_all_quantities()
	for raw_item_id: Variant in quantities:
		var item_id := StringName(String(raw_item_id))
		var add_result := unreserved_loot.add(item_id, int(quantities[raw_item_id]))
		if not add_result.success:
			return add_result
	return initialize_loot(unreserved_loot.get_save_data(), loot_source_id)


func get_inventory() -> InventoryModel:
	return _inventory


func get_loot_save_data() -> Dictionary:
	return _inventory.get_save_data()


func is_empty() -> bool:
	return _inventory.get_all_quantities().is_empty()


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
		var result := InventoryTransactionService.transfer_item(
			_inventory,
			destination,
			item_id,
			int(quantities[raw_item_id])
		)
		if not result.success and first_failure == null:
			first_failure = result
	_collection_in_progress = false
	_update_visuals()

	if is_empty():
		loot_collected.emit(source_id)
		queue_free()
		return InventoryResult.succeeded("All world loot collected.")
	if first_failure != null:
		push_warning("Some world loot remains uncollected: %s" % first_failure.message)
		return first_failure
	return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "Some world loot could not be collected.")


func _unhandled_input(event: InputEvent) -> void:
	if _nearby_player == null or not is_instance_valid(_nearby_player):
		_nearby_player = null
		return
	if interaction_action == &"" or not event.is_action_pressed(interaction_action):
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return
	if not _nearby_player.has_method("get_inventory"):
		return
	var player_inventory = _nearby_player.call("get_inventory") as InventoryModel
	if player_inventory == null:
		return
	get_viewport().set_input_as_handled()
	collect_into(player_inventory)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player") or not body.has_method("get_inventory"):
		return
	_nearby_player = body
	_update_visuals()


func _on_body_exited(body: Node2D) -> void:
	if body != _nearby_player:
		return
	_nearby_player = null
	_update_visuals()


func _on_inventory_changed(
	_item_id: StringName,
	_total_quantity: int,
	_available_quantity: int,
	_reason: StringName
) -> void:
	_update_visuals()


func _on_inventory_reset() -> void:
	_update_visuals()


func _update_visuals() -> void:
	if count_label == null or prompt_label == null:
		return
	var quantities := _inventory.get_all_quantities()
	var total_units := 0
	for quantity: Variant in quantities.values():
		total_units += int(quantity)
	count_label.text = "%d item%s" % [total_units, "" if total_units == 1 else "s"]
	prompt_label.visible = _nearby_player != null and total_units > 0
	prompt_label.text = "UP: Collect loot"
