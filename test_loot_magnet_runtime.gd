extends Node

class PlayerReceiverStub extends CharacterBody2D:
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
		return "magnet_test"


func _ready() -> void:
	await get_tree().process_frame
	var failures: PackedStringArray = []
	var world := Node2D.new()
	add_child(world)
	var near_player := PlayerReceiverStub.new()
	near_player.name = "NearPlayer"
	near_player.global_position = Vector2(55, 0)
	world.add_child(near_player)
	var far_player := PlayerReceiverStub.new()
	far_player.name = "FarPlayer"
	far_player.global_position = Vector2(120, 0)
	far_player.set_meta("receiver_suffix", "far")
	world.add_child(far_player)
	var loot := preload("res://scenes/items/world_loot_container.tscn").instantiate() as WorldLootContainer
	world.add_child(loot)
	var source := InventoryModel.new()
	source.add(&"slime_gel", 3)
	_expect(loot.initialize_from_inventory(source, &"dead_source").success, "loot initializes", failures)
	loot.call("_on_body_entered", far_player)
	loot.call("_on_body_entered", near_player)
	_expect(loot.get_current_receiver_id() == &"player:magnet_test", "nearest eligible receiver is selected", failures)
	for index in 40:
		await get_tree().physics_frame
		if loot.is_queued_for_deletion():
			break
	_expect(near_player.get_inventory().get_quantity(&"slime_gel") == 3, "nearest receiver gets the complete loot stack", failures)
	_expect(far_player.get_inventory().get_quantity(&"slime_gel") == 0, "farther receiver does not receive nearest-target loot", failures)
	_finish(failures, "LOOT_MAGNET_RUNTIME_OK")


func _expect(condition: bool, message: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(message)


func _finish(failures: PackedStringArray, success_text: String) -> void:
	if failures.is_empty():
		print(success_text)
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
