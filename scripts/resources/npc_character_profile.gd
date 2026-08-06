class_name NpcCharacterProfile extends Resource

## Authored presentation metadata for character browsers and other UI. Actor
## identity remains owned by NpcIdentity/SocialNpc and is deliberately absent.
@export var display_name: String = ""
@export var subtitle: String = ""
@export_multiline var description: String = ""
@export var portrait: Texture2D
@export var accent_color: Color = Color(0.31, 0.62, 0.72, 1.0)


func get_snapshot() -> Dictionary:
	return {
		"display_name": display_name.strip_edges(),
		"subtitle": subtitle.strip_edges(),
		"description": description.strip_edges(),
		"portrait_path": (
			String(portrait.resource_path).strip_edges()
			if portrait != null
			else ""
		),
		"accent_color": accent_color,
	}
