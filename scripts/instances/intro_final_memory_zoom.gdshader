shader_type canvas_item;

uniform float zoom : hint_range(1.0, 3.0) = 1.0;
uniform vec2 focus = vec2(0.5, 0.5);
varying vec4 canvas_tint;

void vertex() {
	canvas_tint = COLOR;
}

void fragment() {
	vec2 sample_uv = (UV - focus) / zoom + focus;
	COLOR = texture(TEXTURE, sample_uv) * canvas_tint;
}
