class_name NpcShowerSpot extends NpcNeedSpot

@export_range(1, 128, 1) var idle_particle_amount: int = 12
@export_range(1, 128, 1) var active_particle_amount: int = 34
@export_range(0.1, 20.0, 0.1) var pulse_speed: float = 4.5

@onready var water_particles: CPUParticles2D = get_node_or_null("%WaterParticles") as CPUParticles2D
@onready var steam_particles: CPUParticles2D = get_node_or_null("%SteamParticles") as CPUParticles2D
@onready var water_visual: CanvasItem = get_node_or_null("%WaterVisual") as CanvasItem

var shower_animation_time: float = 0.0


func _ready() -> void:
	super._ready()
	_set_particles_enabled(true)


func _process(delta: float) -> void:
	super._process(delta)
	_animate_shower_particles(delta)


func _set_particles_enabled(enabled: bool) -> void:
	if water_particles != null:
		water_particles.emitting = enabled
	if steam_particles != null:
		steam_particles.emitting = enabled


func _animate_shower_particles(delta: float) -> void:
	shower_animation_time += delta * pulse_speed
	var pulse := 0.5 + sin(shower_animation_time) * 0.5

	if water_particles != null:
		water_particles.amount = int(round(lerpf(
			float(idle_particle_amount),
			float(active_particle_amount),
			pulse
		)))
		water_particles.scale = Vector2.ONE * lerpf(0.9, 1.08, pulse)

	if steam_particles != null:
		steam_particles.modulate.a = lerpf(0.25, 0.72, pulse)

	if water_visual != null:
		water_visual.modulate.a = lerpf(0.45, 0.9, pulse)
