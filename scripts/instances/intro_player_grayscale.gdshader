shader_type canvas_item;

varying vec4 canvas_tint;

void vertex() {
	canvas_tint = COLOR;
}

void fragment() {
	vec4 source = texture(TEXTURE, UV) * canvas_tint;
	float luminance = dot(source.rgb, vec3(0.299, 0.587, 0.114));
	COLOR = vec4(vec3(luminance), source.a);
}
