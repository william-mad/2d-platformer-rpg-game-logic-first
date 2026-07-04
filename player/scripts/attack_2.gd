class_name Attack_2 extends Area2D


@export var damage : float = 2
@export var knockout_damage: float = 35.0

# when scene starts, set monitoring and visible to false until further notice
func _ready() -> void:
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_body_entered)
	visible =false
	monitorable = false
	monitoring = false
	pass 


#if meet damage_area (area that can be damaged) do something.
func _on_body_entered (body : Node2D) ->void:
	if body is Damage_Area:
		body.take_damage(self)
	pass
	

#setting active by passing attack duration into this as a float
func activate(duration:float=0.1) ->void:
	set_active()
	await get_tree().create_timer(duration).timeout
	set_active(false)
	pass
	
	
func get_damage_source() -> Node:
	var damage_source := get_parent()
	return damage_source if damage_source != null else self



#making the area visible and monitorable.
func set_active(value: bool = true) -> void:
	monitoring = value
	visible = value
	pass
	
#flip attack when facing left.
func flip(direction_x: float) -> void:
	if direction_x >0:
		scale.x = 1
	elif direction_x <0:
		scale.x = -1
	
	pass
	
