class_name NpcSceneRouteMap extends Resource

@export var map_id: StringName = &"default"
@export_range(1, 100, 1) var schema_version: int = 1
@export var edges: Array[NpcSceneRouteEdge] = []


func get_validation_errors() -> Array[String]:
	var errors: Array[String] = []
	var raw_map_id := String(map_id)
	var normalized_map_id := raw_map_id.strip_edges()
	if normalized_map_id.is_empty():
		errors.append("map_id is empty")
	elif raw_map_id != normalized_map_id:
		errors.append("map_id must not have leading or trailing whitespace")
	if schema_version < 1:
		errors.append("schema_version must be at least 1")

	var edge_id_counts: Dictionary = {}
	for index in edges.size():
		var edge := edges[index]
		if edge == null:
			errors.append("edge at index %d is null" % index)
			continue
		var normalized_id := String(edge.edge_id).strip_edges()
		if not normalized_id.is_empty():
			edge_id_counts[normalized_id] = int(edge_id_counts.get(normalized_id, 0)) + 1
		for edge_error in edge.get_validation_errors():
			errors.append("edge[%d] '%s': %s" % [index, normalized_id, edge_error])

	var duplicate_ids: Array[String] = []
	for edge_id_value in edge_id_counts.keys():
		var edge_id := String(edge_id_value)
		if int(edge_id_counts[edge_id_value]) > 1:
			duplicate_ids.append(edge_id)
	duplicate_ids.sort()
	for duplicate_id in duplicate_ids:
		errors.append("duplicate edge_id '%s'" % duplicate_id)
	return errors


func to_debug_snapshot() -> Dictionary:
	var descriptors: Array[Dictionary] = []
	for edge in edges:
		if edge != null:
			descriptors.append(edge.to_descriptor())
	return {
		"map_id": String(map_id),
		"schema_version": schema_version,
		"edge_count": edges.size(),
		"edges": descriptors,
		"validation_errors": get_validation_errors(),
	}
