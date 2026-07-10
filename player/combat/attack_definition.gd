class_name AttackDefinition
extends Resource

@export var attack_id: StringName = &""
@export var damage: float = 1.0
@export var knockout_damage: float = 0.0
@export var hitbox_size: Vector2 = Vector2(24.0, 24.0)
@export var hitbox_offset: Vector2 = Vector2(24.0, -32.0)
@export var active_seconds: float = 0.1
@export var state_duration: float = 0.4
@export var combo_window_seconds: float = 0.0
@export var animation_name: StringName = &"attack_1"
@export_range(0.0, 2.0, 0.01) var move_speed_multiplier: float = 0.5
@export_flags_2d_physics var collision_mask: int = 128
@export var tags: Array[StringName] = []
@export var allow_ground_jump_cancel: bool = false
@export var return_to_crouch_if_held: bool = false
