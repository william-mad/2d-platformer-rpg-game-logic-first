extends SceneTree

var _failures: Array[String] = []
var _autofree_nodes: Array[Node] = []
var _current_test: String = ""


func _initialize() -> void:
	await process_frame
	var test_names: Array[StringName] = []
	for method in get_method_list():
		var method_name := StringName(String(method.get("name", "")))
		if String(method_name).begins_with("test_"):
			test_names.append(method_name)
	test_names.sort()
	for test_name in test_names:
		_current_test = String(test_name)
		if has_method("before_each"):
			call("before_each")
		call(test_name)
		if has_method("after_each"):
			call("after_each")
		_free_test_nodes()
	await process_frame
	if _failures.is_empty():
		print("%s passed (%d tests)." % [
			String(get_script().resource_path).get_file(),
			test_names.size(),
		])
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func add_child_autofree(node: Node) -> Node:
	if node == null:
		return null
	root.add_child(node)
	_autofree_nodes.append(node)
	return node


func assert_true(condition: bool, message: String = "") -> void:
	if not condition:
		_record_failure(message if not message.is_empty() else "expected true")


func assert_false(condition: bool, message: String = "") -> void:
	if condition:
		_record_failure(message if not message.is_empty() else "expected false")


func assert_eq(actual, expected, message: String = "") -> void:
	if actual != expected:
		_record_failure(
			"%s (expected %s, got %s)" % [
				message if not message.is_empty() else "values differ",
				str(expected),
				str(actual),
			]
		)


func assert_same(actual, expected, message: String = "") -> void:
	if actual != expected:
		_record_failure(message if not message.is_empty() else "objects are not identical")


func assert_null(value, message: String = "") -> void:
	if value != null:
		_record_failure(message if not message.is_empty() else "expected null")


func assert_not_null(value, message: String = "") -> void:
	if value == null:
		_record_failure(message if not message.is_empty() else "expected a value")


func _record_failure(message: String) -> void:
	_failures.append("%s: %s" % [_current_test, message])


func _free_test_nodes() -> void:
	for node in _autofree_nodes:
		if node != null and is_instance_valid(node):
			node.free()
	_autofree_nodes.clear()
