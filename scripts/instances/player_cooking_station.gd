class_name PlayerCookingStation
extends Area2D

@export var recipe: ProcessingRecipeDefinition = preload("res://data/recipes/cook_slime_meat.tres")
@export var interaction_action: StringName = &"up"
@export var close_action: StringName = &"inventory"
@export var player_group: StringName = &"player"
@export var interaction_priority: int = 90

@onready var prompt_label: Label = %PromptLabel

var _nearby_players: Array[Node2D] = []
var _active_player: Node2D
var _inventory: InventoryModel
var _previous_pause_state: bool = false
var _panel_layer: CanvasLayer
var _quantity: SpinBox
var _maximum_label: Label
var _process_button: Button
var _feedback: Label
var _processing_service := InventoryProcessingService.new()
var _catalog := ItemCatalog.new()
var _interaction_focused: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_catalog.load_definitions()
	set_process_unhandled_input(true)
	_update_prompt()


func _unhandled_input(event: InputEvent) -> void:
	if _panel_layer != null:
		if event.is_action_pressed(&"ui_cancel") or (close_action != &"" and event.is_action_pressed(close_action)):
			get_viewport().set_input_as_handled()
			close_panel()


func can_interact(actor: Node) -> bool:
	var player := actor as Node2D
	return (
		player != null
		and _nearby_players.has(player)
		and _panel_layer == null
		and recipe != null
		and player.has_method("get_inventory")
	)


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	return open_panel(actor as Node2D)


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return "Cook"


func open_panel(player: Node2D) -> bool:
	if player == null or not is_instance_valid(player) or not player.has_method("get_inventory"):
		return false
	var inventory := player.call("get_inventory") as InventoryModel
	if inventory == null or recipe == null:
		return false
	_active_player = player
	_inventory = inventory
	_previous_pause_state = get_tree().paused
	_build_panel()
	_update_prompt()
	_connect_inventory_signals()
	_refresh_panel()
	_set_paused(true)
	_process_button.grab_focus.call_deferred()
	return true


func close_panel() -> void:
	_disconnect_inventory_signals()
	if _panel_layer != null and is_instance_valid(_panel_layer):
		_panel_layer.queue_free()
	_panel_layer = null
	_quantity = null
	_maximum_label = null
	_process_button = null
	_feedback = null
	_inventory = null
	_active_player = null
	_set_paused(_previous_pause_state)
	_update_prompt()


func _build_panel() -> void:
	_panel_layer = CanvasLayer.new()
	_panel_layer.layer = 90
	_panel_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_panel_layer)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	_panel_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_layer.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 390)
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 24)
	panel.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)
	var title := Label.new()
	title.text = recipe.display_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	root.add_child(title)
	root.add_child(_make_recipe_flow())
	_maximum_label = Label.new()
	_maximum_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_maximum_label)
	var quantity_row := HBoxContainer.new()
	root.add_child(quantity_row)
	var quantity_label := Label.new()
	quantity_label.text = "Quantity"
	quantity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quantity_row.add_child(quantity_label)
	_quantity = SpinBox.new()
	_quantity.min_value = 1
	_quantity.value = 1
	_quantity.value_changed.connect(func(_value: float) -> void: _refresh_controls())
	quantity_row.add_child(_quantity)
	_process_button = Button.new()
	_process_button.text = "Process"
	_process_button.pressed.connect(_on_process_pressed)
	root.add_child(_process_button)
	_feedback = Label.new()
	_feedback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_feedback)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(close_panel)
	root.add_child(close_button)


func _make_recipe_flow() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var input_id := StringName(String(recipe.input_items.keys()[0]))
	var output_id := StringName(String(recipe.output_items.keys()[0]))
	row.add_child(_make_item_preview(input_id, int(recipe.input_items[input_id])))
	var arrow := Label.new()
	arrow.text = "  →  "
	arrow.add_theme_font_size_override("font_size", 24)
	row.add_child(arrow)
	row.add_child(_make_item_preview(output_id, int(recipe.output_items[output_id])))
	return row


func _make_item_preview(item_id: StringName, quantity_value: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	var definition := _catalog.get_definition(item_id)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(72, 72)
	icon.texture = definition.icon if definition != null else null
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(icon)
	var label := Label.new()
	label.text = "%s ×%d" % [definition.display_name if definition != null else String(item_id), quantity_value]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label)
	return box


func _on_process_pressed() -> void:
	var batches := int(_quantity.value)
	var result := _processing_service.process(_inventory, recipe, batches)
	_feedback.text = "Cooked %d Slime Meat." % batches if result.success else result.message
	_refresh_panel()


func _refresh_panel() -> void:
	if _inventory == null or _quantity == null:
		return
	var maximum := _processing_service.get_maximum_batches(_inventory, recipe)
	_maximum_label.text = "Maximum available: %d" % maximum
	_quantity.max_value = maxi(1, maximum)
	_quantity.value = clampi(int(_quantity.value), 1, maxi(1, maximum))
	_refresh_controls()


func _refresh_controls() -> void:
	if _process_button == null:
		return
	var maximum := _processing_service.get_maximum_batches(_inventory, recipe)
	_process_button.disabled = maximum <= 0 or int(_quantity.value) > maximum


func _connect_inventory_signals() -> void:
	_inventory.item_quantity_changed.connect(_on_inventory_changed)
	_inventory.reservation_changed.connect(_on_reservation_changed)
	_inventory.inventory_reset.connect(_on_inventory_reset)


func _disconnect_inventory_signals() -> void:
	if _inventory == null:
		return
	for pair: Array in [[&"item_quantity_changed", _on_inventory_changed], [&"reservation_changed", _on_reservation_changed], [&"inventory_reset", _on_inventory_reset]]:
		if _inventory.is_connected(pair[0], pair[1]):
			_inventory.disconnect(pair[0], pair[1])


func _on_inventory_changed(_id: StringName, _total: int, _available: int, _reason: StringName) -> void:
	_refresh_panel()


func _on_reservation_changed(_id: StringName, _reason: StringName) -> void:
	_refresh_panel()


func _on_inventory_reset() -> void:
	_refresh_panel()


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group(String(player_group)):
		if not _nearby_players.has(body):
			_nearby_players.append(body)
		if body.has_method("register_interaction_candidate"):
			body.call("register_interaction_candidate", self)
	_update_prompt()


func _on_body_exited(body: Node2D) -> void:
	_nearby_players.erase(body)
	if body.has_method("unregister_interaction_candidate"):
		body.call("unregister_interaction_candidate", self)
	_update_prompt()


func _update_prompt() -> void:
	if prompt_label != null:
		prompt_label.visible = _interaction_focused and _panel_layer == null
		prompt_label.text = "UP: Cook"


func set_interaction_focused(_actor: Node, focused: bool) -> void:
	_interaction_focused = focused
	_update_prompt()


func _set_paused(paused: bool) -> void:
	var pause_system := get_node_or_null("/root/PauseSystem")
	if pause_system != null and pause_system.has_method("set_paused"):
		pause_system.call("set_paused", paused, false)
	else:
		get_tree().paused = paused
