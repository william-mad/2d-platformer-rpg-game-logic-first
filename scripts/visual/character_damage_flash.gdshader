shader_type canvas_item;
render_mode unshaded;

uniform vec4 flash_color : source_color = vec4(1.0, 0.14, 0.08, 1.0);
uniform float flash_strength : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 texture_color = texture(TEXTURE, UV);
	vec4 base_color = texture_color * COLOR;
	float texture_light = dot(texture_color.rgb, vec3(0.299, 0.587, 0.114));
	vec3 flash_detail = flash_color.rgb * mix(0.78, 1.18, texture_light);
	vec3 flash_rgb = flash_detail * texture_color.a;
	COLOR = vec4(
		mix(base_color.rgb, flash_rgb, flash_strength),
		base_color.a
	);
}
