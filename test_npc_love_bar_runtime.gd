extends SceneTree

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var relationships := root.get_node_or_null("Relationships")
	_expect(relationships != null, "Relationships autoload is available")
	var love_bar_scene := load(
		"res://scenes/creatures/npc/npc_love_bar.tscn"
	) as PackedScene
	_expect(love_bar_scene != null, "love bar scene loads")
	if relationships == null or love_bar_scene == null:
		_finish()
		return

	var npc := CharacterBody2D.new()
	npc.name = "LoveBarNpc"
	npc.set_meta(&"npc_location_id", "love_bar_test_npc")
	npc.add_to_group("npc")
	root.add_child(npc)
	var hp_bar := ProgressBar.new()
	hp_bar.name = "HPBar"
	hp_bar.position = Vector2(-36.0, -100.0)
	hp_bar.size = Vector2(72.0, 6.0)
	npc.add_child(hp_bar)
	var love_bar := love_bar_scene.instantiate() as Control
	love_bar.set("visible_duration", 0.01)
	love_bar.set("fade_duration", 0.01)
	npc.add_child(love_bar)

	var player := CharacterBody2D.new()
	player.name = "LoveBarPlayer"
	player.add_to_group("player")
	root.add_child(player)
	await process_frame

	var meter := love_bar.get_node("LoveMeterFrame/LoveMeter") as ProgressBar
	var meter_frame := love_bar.get_node("LoveMeterFrame") as Control
	var heart_slot := love_bar.get_node("HeartIconSlot") as TextureRect
	var dialogue_ui := root.get_node_or_null(
		"DialogueController/ModalDialogueUI"
	) as ModalDialogueUI
	var dialogue_cue := (
		dialogue_ui.get_node_or_null("RelationshipChangeCue") as Control
		if dialogue_ui != null
		else null
	)
	_expect(not love_bar.visible, "love bar starts hidden")
	_expect(
		is_equal_approx(love_bar.global_position.x, hp_bar.global_position.x),
		"love UI and NPC health bar start at the same horizontal position"
	)
	_expect(meter_frame.size.x < hp_bar.size.x, "love meter is shorter than the NPC health bar")
	_expect(
		is_equal_approx(
			meter_frame.global_position.x + meter_frame.size.x,
			hp_bar.global_position.x + hp_bar.size.x
		),
		"shorter love meter ends at the health bar's right edge"
	)
	_expect(
		meter.size.x < meter_frame.size.x and meter.size.y < meter_frame.size.y,
		"love color is inset inside its bordered frame"
	)
	_expect(heart_slot.size == Vector2(16.0, 16.0), "love bar uses the supplied 16px heart")
	_expect(
		heart_slot.global_position.x >= hp_bar.global_position.x
		and heart_slot.global_position.x + heart_slot.size.x
		<= hp_bar.global_position.x + hp_bar.size.x
		and heart_slot.global_position.y + heart_slot.size.y
		<= hp_bar.global_position.y,
		"16px heart sits fully above and within the health bar footprint"
	)
	_expect(
		heart_slot.texture != null
		and heart_slot.texture.resource_path.ends_with("heart_16px.png"),
		"love bar uses the new static heart texture"
	)
	_expect(dialogue_cue != null, "dialogue UI contains the relationship-change cue")
	_test_npc_scene_composition("res://scenes/creatures/social_npc.tscn", "shared SocialNpc")
	_test_npc_scene_composition("res://scenes/creatures/bob_npc.tscn", "inherited Bob NPC")
	_test_npc_scene_composition("res://scenes/creatures/mom_npc.tscn", "standalone Mom NPC")

	relationships.call(
		"set_opinion_metric", npc, player, &"love", 37.0, "love_bar_test"
	)
	_expect(love_bar.visible, "NPC love change toward Player reveals the bar")
	_expect(is_equal_approx(meter.value, 37.0), "love bar displays the directed love value")
	_expect(
		dialogue_cue == null or not bool(dialogue_cue.call("is_showing")),
		"non-dialogue love changes do not create a dialogue cue"
	)

	var visibility_tween := love_bar.get("_visibility_tween") as Tween
	_expect(visibility_tween != null, "love change starts the visibility tween")
	if visibility_tween != null:
		visibility_tween.custom_step(0.1)
	await process_frame
	_expect(not love_bar.visible, "love bar fades and hides after its brief display")
	relationships.call(
		"set_opinion_metric", player, npc, &"love", 62.0, "reverse_love_test"
	)
	_expect(not love_bar.visible, "Player love toward NPC does not reveal the NPC opinion bar")
	relationships.call(
		"set_opinion_metric", npc, player, &"favor", 60.0, "favor_only_test"
	)
	_expect(not love_bar.visible, "non-love relationship changes do not reveal the bar")
	_test_player_talk_love_effects(
		npc, player, love_bar, meter, relationships
	)

	npc.free()
	player.free()
	_finish()


func _test_npc_scene_composition(scene_path: String, label: String) -> void:
	var packed := load(scene_path) as PackedScene
	_expect(packed != null, "%s scene loads" % label)
	if packed == null:
		return
	var instance := packed.instantiate()
	_expect(instance.get_node_or_null("NpcLoveBar") != null, "%s contains the love bar" % label)
	instance.free()


func _test_player_talk_love_effects(
	npc: CharacterBody2D,
	player: CharacterBody2D,
	love_bar: Control,
	meter: ProgressBar,
	relationships: Node
) -> void:
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	npc.add_child(machine)
	machine.bind_npc(npc)
	var interactor := PlayerNpcTalkInteractor.new()
	player.add_child(interactor)

	relationships.call(
		"set_opinion_metric", npc, player, &"love", 59.0, "flirt_setup"
	)
	love_bar.call("_hide_after_fade")
	interactor.call(
		"_apply_interaction_effects",
		npc,
		interactor.talk_option_deltas[2].duplicate(true),
		{},
		&"talk_flirt"
	)
	_expect(
		is_equal_approx(float(relationships.call(
			"get_opinion_metric", npc, player, &"love", 0.0
		)), 60.0),
		"Flirt adds one directed love below 60"
	)
	_expect(love_bar.visible and is_equal_approx(meter.value, 60.0), "Flirt reveals the updated love bar")
	_test_dialogue_love_cue()

	love_bar.call("_hide_after_fade")
	interactor.call(
		"_apply_interaction_effects",
		npc,
		interactor.talk_option_deltas[2].duplicate(true),
		{},
		&"talk_flirt"
	)
	_expect(
		is_equal_approx(float(relationships.call(
			"get_opinion_metric", npc, player, &"love", 0.0
		)), 60.0),
		"Flirt grants no love at the limit"
	)
	_expect(not love_bar.visible, "a capped Flirt causes no false love-bar popup")

	interactor.call(
		"_apply_interaction_effects",
		npc,
		interactor.talk_option_deltas[3].duplicate(true),
		{},
		&"talk_insult"
	)
	_expect(
		is_equal_approx(float(relationships.call(
			"get_opinion_metric", npc, player, &"love", 0.0
		)), 59.0),
		"Insult removes one directed love"
	)
	_expect(love_bar.visible and is_equal_approx(meter.value, 59.0), "Insult reveals the updated love bar")
	var dialogue_cue := root.get_node(
		"DialogueController/ModalDialogueUI/RelationshipChangeCue"
	) as Control
	var delta_label := dialogue_cue.get_node("CueGroup/DeltaLabel") as Label
	_expect(delta_label.text == "-1", "dialogue love cue displays the actual signed decrease")


func _test_dialogue_love_cue() -> void:
	var dialogue_ui := root.get_node(
		"DialogueController/ModalDialogueUI"
	) as ModalDialogueUI
	var dialogue_cue := dialogue_ui.get_node(
		"RelationshipChangeCue"
	) as Control
	var heart_icon := dialogue_cue.get_node("CueGroup/HeartIcon") as TextureRect
	var delta_label := dialogue_cue.get_node("CueGroup/DeltaLabel") as Label
	_expect(dialogue_ui.visible and bool(dialogue_cue.call("is_showing")), "Player Talk love change reveals the dialogue cue")
	_expect(heart_icon.size == Vector2(64.0, 64.0), "dialogue cue uses the supplied 64px heart")
	_expect(delta_label.text == "+1", "dialogue love cue displays the actual signed increase")
	var first_frame: Texture2D = heart_icon.texture
	dialogue_cue.call("_process", 0.1)
	_expect(heart_icon.texture != first_frame, "dialogue heart animation advances")
	var start_y: float = heart_icon.position.y
	var cue_tween := dialogue_cue.get("_cue_tween") as Tween
	_expect(cue_tween != null, "dialogue love cue starts its rise-and-fade tween")
	if cue_tween != null:
		cue_tween.custom_step(0.5)
		_expect(heart_icon.position.y < start_y, "dialogue love cue moves upward")
		_expect(heart_icon.modulate.a < 1.0, "dialogue love cue fades while rising")
		cue_tween.custom_step(1.0)
		_expect(not bool(dialogue_cue.call("is_showing")), "dialogue love cue hides after fading")
		_expect(not dialogue_ui.visible, "idle modal layer hides after the cue finishes")
	_test_multi_heart_burst(dialogue_ui, dialogue_cue)


func _test_multi_heart_burst(dialogue_ui: ModalDialogueUI, dialogue_cue: Control) -> void:
	dialogue_cue.call("show_love_change", 3.0)
	var main := dialogue_cue.get_node("CueGroup/HeartIcon") as TextureRect
	var second := dialogue_cue.get_node("CueGroup/HeartEcho2") as TextureRect
	var third := dialogue_cue.get_node("CueGroup/HeartEcho3") as TextureRect
	var label := dialogue_cue.get_node("CueGroup/DeltaLabel") as Label
	_expect(main.visible and second.visible and third.visible, "+3 displays three beating hearts")
	_expect(
		main.modulate.a > second.modulate.a and second.modulate.a > third.modulate.a,
		"additional hearts use progressively lower alpha"
	)
	_expect(label.text == "+3", "multi-heart burst retains the actual signed delta")
	var start_positions := [main.position, second.position, third.position]
	var cue_tween := dialogue_cue.get("_cue_tween") as Tween
	if cue_tween != null:
		cue_tween.custom_step(0.5)
		var rises := [
			start_positions[0].y - main.position.y,
			start_positions[1].y - second.position.y,
			start_positions[2].y - third.position.y,
		]
		_expect(
			not is_equal_approx(float(rises[0]), float(rises[1]))
			and not is_equal_approx(float(rises[1]), float(rises[2])),
			"multi-heart echoes rise at different rates"
		)
		cue_tween.custom_step(2.0)
	_expect(not bool(dialogue_cue.call("is_showing")), "multi-heart burst finishes cleanly")
	_expect(not dialogue_ui.visible, "multi-heart burst releases the idle modal layer")


func _expect(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)


func _finish() -> void:
	if _failures.is_empty():
		print("NPC_LOVE_BAR_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
