class_name CharacterMetricBar extends VBoxContainer

@onready var name_label: Label = %MetricName
@onready var value_label: Label = %MetricValue
@onready var bar: ProgressBar = %MetricBar

var metric_id: StringName = &""


func configure(metric: Dictionary, fill_color: Color) -> void:
	metric_id = StringName(metric.get("id", &""))
	name_label.text = String(metric.get("label", String(metric_id).capitalize()))
	var minimum := float(metric.get("minimum", 0.0))
	var maximum := maxf(float(metric.get("maximum", 100.0)), minimum + 0.001)
	var value := clampf(float(metric.get("value", minimum)), minimum, maximum)
	bar.min_value = minimum
	bar.max_value = maximum
	bar.value = value
	bar.show_percentage = false
	value_label.text = _format_metric_value(value, metric)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.corner_radius_top_left = 3
	fill.corner_radius_top_right = 3
	fill.corner_radius_bottom_left = 3
	fill.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override("fill", fill)


func _format_metric_value(value: float, metric: Dictionary) -> String:
	if String(metric.get("format", "")) == "boolean":
		return "YES" if value >= 0.5 else "NO"
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return "%.1f" % value
