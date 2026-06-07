extends Node

signal damage_dealt(amount: float, attacker: Node, target: Node)


func emit_damage_dealt(amount: float, attacker: Node, target: Node) -> void:
	if amount <= 0.0:
		return

	damage_dealt.emit(amount, attacker, target)
