class_name NpcSocialWriteRouter extends RefCounted

const SocialStateSchema = preload(
	"res://scripts/systems/npc_social_state_schema.gd"
)
const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")
const LEGACY_ACTORLESS_LOCAL_OPINION_KEYS := {
	"favor": true,
	"love": true,
	"trust": true,
	"suspicion": true,
}


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
	return _route_split_values(
		owner,
		actor,
		local_values,
		directed_opinion,
		relationships,
		reason,
		context
	)


## Routes an explicitly actor-directed opinion dictionary without applying the
## legacy mixed-value split. Use this only when the caller already owns the scope
## decision, such as damage-derived anger/fear toward one known attacker.
static func route_explicit_directed_delta(
	owner: Node,
	actor: Node,
	local_values: Dictionary,
	directed_opinion: Dictionary,
	relationships: Node = null,
	reason: String = "social_event",
	context: Dictionary = {}
) -> Dictionary:
	return _route_split_values(
		owner,
		actor,
		_dictionary_copy(local_values),
		_dictionary_copy(directed_opinion),
		relationships,
		reason,
		context
	)


static func _route_split_values(
	owner: Node,
	actor: Node,
	local_values_input: Dictionary,
	directed_opinion_input: Dictionary,
	relationships: Node,
	reason: String,
	context: Dictionary
) -> Dictionary:
	var local_values := local_values_input.duplicate(true)
	var directed_opinion := directed_opinion_input.duplicate(true)
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
	var can_batch := (
		has_explicit_subject
		and relationships != null
		and relationships.has_method("apply_opinion_deltas_by_id")
	)
	var can_route_legacy := (
		has_explicit_subject
		and relationships != null
		and relationships.has_method("change_opinion_metric")
		and relationships.has_method("get_opinion_metric")
	)

	var directed_applied := false
	var directed_eligible := false
	var directed_changes: Dictionary = {}
	var relationship_snapshot: Dictionary = {}
	if can_batch:
		var runtime_context := context.duplicate()
		runtime_context["relationship_owner"] = owner
		runtime_context["other"] = actor
		var batch_result = relationships.call(
			"apply_opinion_deltas_by_id",
			owner_id,
			actor_id,
			directed_opinion,
			reason,
			runtime_context
		)
		if batch_result is Dictionary:
			directed_eligible = bool(
				batch_result.get("eligible", false)
			)
			var batch_changes = batch_result.get("changed_values", {})
			if batch_changes is Dictionary:
				directed_changes = batch_changes
			var batch_relationship = batch_result.get("relationship", {})
			if batch_relationship is Dictionary:
				relationship_snapshot = batch_relationship
			directed_applied = (
				bool(batch_result.get("changed", false))
				and not directed_changes.is_empty()
			)
	elif can_route_legacy:
		# Compatibility for relationship substitutes that have not adopted the
		# ID-based batch contract. The project autoload always uses the branch above.
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
		# New directed-only schema metrics are not converted into local NPC values.
		for metric_id in directed_opinion.keys():
			if not LEGACY_ACTORLESS_LOCAL_OPINION_KEYS.has(String(metric_id)):
				continue
			local_values[metric_id] = _finite_float(
				local_values.get(metric_id, 0.0)
			) + _finite_float(directed_opinion[metric_id])

	return {
		"local_values": local_values,
		"directed_opinion": directed_opinion,
		"directed_changes": directed_changes,
		"directed_eligible": directed_eligible,
		"directed_applied": directed_applied,
		"relationship": relationship_snapshot,
	}


static func _dictionary_copy(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}


static func _finite_float(value: Variant) -> float:
	var number := float(value)
	return number if is_finite(number) else 0.0
