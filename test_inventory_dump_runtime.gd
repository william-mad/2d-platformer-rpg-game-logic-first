extends Node

class DumpPlayerStub extends CharacterBody2D:
	var dead: bool = false
	var inventory := InventoryModel.new()

	func _init() -> void:
		add_to_group(&"player")
		var receiver := InventoryPickupReceiver.new()
		receiver.name = "InventoryPickupReceiver"
		add_child(receiver)

	func get_inventory() -> InventoryModel:
		return inventory

	func get_save_id() -> String:
		return "dump_test"


func _ready() -> void:
	await get_tree().process_frame
	var failures: PackedStringArray = []
	var player := DumpPlayerStub.new()
	add_child(player)
	player.inventory.add(&"slime_gel", 5)
	player.inventory.reserve_items(&"keep", {&"slime_gel": 2})
	var screen := preload("res://ui/inventory/player_inventory_screen.tscn").instantiate() as PlayerInventoryScreen
	add_child(screen)
	screen.dump_source_exclusion_seconds = 0.02
	screen.bind_inventory(player.inventory, player)
	screen.open_screen()
	screen.get_node("%DumpQuantity").value = 3
	screen.call("_on_dump_pressed")
	_expect(player.inventory.get_quantity(&"slime_gel") == 2, "dump removes exactly the selected available quantity", failures)
	_expect(player.inventory.get_reserved_quantity(&"slime_gel") == 2, "dump preserves reserved quantity", failures)
	var loot: WorldLootContainer
	for child in get_children():
		if child is WorldLootContainer:
			loot = child
	_expect(loot != null and loot.get_inventory().get_quantity(&"slime_gel") == 3, "dump creates one ordinary loot container with exact quantity", failures)
	if loot != null:
		loot.call("_on_body_entered", player)
		loot.call("_physics_process", 0.016)
		_expect(loot.get_current_receiver_id() == &"", "dumping player is initially excluded", failures)
		await get_tree().create_timer(0.04).timeout
		loot.call("_physics_process", 0.016)
		_expect(loot.get_current_receiver_id() == &"player:dump_test", "dumping player becomes eligible after exclusion expires", failures)
	_finish(failures)


func _expect(condition: bool, message: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(message)


func _finish(failures: PackedStringArray) -> void:
	if failures.is_empty():
		print("INVENTORY_DUMP_RUNTIME_OK")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
