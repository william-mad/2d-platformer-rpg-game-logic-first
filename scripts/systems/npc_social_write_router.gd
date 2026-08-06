class_name NpcSocialWriteRouter extends RefCounted

const SocialStateSchema = preload(
	"res://scripts/systems/npc_social_state_schema.gd"
)
const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")


## Splits one legacy mixed value delta and applies only explicitly actor-directed
## opinion values to Relationships. The returned local delta remains compatible
## with existing NPC value processing. Actor-less legacy/story calls retain their
## old hidden local values, but an explicit actor is never silently discarded or
## replaced by an ambiguous global write.
static func route_delta(
	owner: Node,
	actor: Node,
	value_delta: Dictionary,
	relationships: Node = null,
	reason: String = "social_event",
	context: Dictionary = {}
) -> Dictionary:
	var split := SocialStateSchema.split_value_delta(value_delta)
	var local_values: Dictionary = _dictionary_copy(
		split.get("local_values", {})
	)
	var directed_opinion: Dictionary = _dictionary_copy(
		split.get("directed_opinion", {})
	)
	var owner_id := NpcIdentity.get_stable_actor_id(owner)
	var actor_id := NpcIdentity.get_stable_actor_id(actor)
	var has_explicit_subject := (
		owner != null
		and is_instance_valid(owner)
		and actor != null
		and is_instance_valid(actor)
		and owner != actor
		and NpcIdentity.is_stable_id(owner_id)
		and NpcIdentity.is_stable_id(actor_id)
		and owner_id != actor_id
	)
	if has_explicit_subject and relationships == null and owner.is_inside_tree():
		relationships = owner.get_node_or_null("/root/Relationships")
	var can_route := (
		has_explicit_subject
		and relationships != null
		and relationships.has_method("change_opinion_metric")
		and relationships.has_method("get_opinion_metric")
	)

	var directed_applied := false
	var directed_eligible := false
	var directed_changes: Dictionary = {}
	if can_route:
		var metric_ids: Array[String] = []
		for metric_id_value in directed_opinion.keys():
			metric_ids.append(String(metric_id_value))
		metric_ids.sort()
		for metric_id in metric_ids:
			var delta := _finite_float(
				directed_opinion.get(metric_id, 0.0)
			)
			if is_zero_approx(delta):
				continue
			directed_eligible = true
			var previous_value := float(relationships.call(
				"get_opinion_metric",
				owner,
				actor,
				StringName(metric_id)
			))
			var schema_bounded_value := clampf(
				previous_value + delta,
				SocialStateSchema.get_directed_opinion_minimum(
					StringName(metric_id)
				),
				SocialStateSchema.get_directed_opinion_maximum(
					StringName(metric_id)
				)
			)
			if is_equal_approx(previous_value, schema_bounded_value):
				continue
			var next_value := float(relationships.call(
				"change_opinion_metric",
				owner,
				actor,
				StringName(metric_id),
				delta,
				reason,
				context.duplicate(true)
			))
			var actual_delta := next_value - previous_value
			if is_zero_approx(actual_delta):
				continue
			directed_changes[metric_id] = actual_delta
			directed_applied = true
	elif actor == null or not is_instance_valid(actor):
		# Actor-less legacy/story calls retain their prior hidden local currencies.
		# This does not invent a Player subject. Deprecated keys are still removed by
		# SocialNpc/NpcStateMachine's established normalization boundary.
		for metric_id in directed_opinion.keys():
			local_values[metric_id] = _finite_float(
				local_values.get(metric_id, 0.0)
			) + _finite_float(directed_opinion[metric_id])

	return {
		"local_values": local_values,
		"directed_opinion": directed_opinion,
		"directed_changes": directed_changes,
		"directed_eligible": directed_eligible,
		"directed_applied": directed_applied,
	}


static func _dictionary_copy(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}


static func _finite_float(value: Variant) -> float:
	var number := float(value)
	return number if is_finite(number) else 0.0
