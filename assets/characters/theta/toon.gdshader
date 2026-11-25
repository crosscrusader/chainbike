// Cel shader that mirrors THETA's Blender node setup:
//   Principled/Diffuse -> Shader to RGB -> Separate HSV -> constant Color Ramp on V -> Combine HSV
//   (+ optional grey "diffuse toon" mixed in, a centre sheen and a fresnel rim, both from Layer Weight > Facing)
// All the shading happens in light(), so ALBEDO is left at 1 and DIFFUSE_LIGHT carries the final colour.
// Colour uniforms are LINEAR values (same numbers you see in Blender), not sRGB.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled;

uniform vec3 base_color = vec3(0.8);
uniform sampler2D base_texture : source_color, filter_linear_mipmap, hint_default_white;

group_uniforms ramp;
// Constant colour ramp on the shaded brightness (V). Band i wins when V >= band_pos[i].
// band_pos.x is normally 0. Put an unused stop at 9.0.
uniform vec3 band_pos = vec3(0.0, 0.2, 9.0);
uniform vec3 band_val = vec3(0.2, 1.0, 1.0);
// Per-band colour multiplier (e.g. the reddish skin shadow).
uniform vec3 band_tint0 = vec3(1.0);
uniform vec3 band_tint1 = vec3(1.0);
uniform vec3 band_tint2 = vec3(1.0);

group_uniforms lighting;
uniform float light_strength = 1.0;   // Blender sun strength
uniform float ambient = 0.125;        // Blender world strength * colour
uniform float spec_strength = 0.0;    // Principled specular pushing V into the next band
uniform float spec_power = 200.0;

group_uniforms grey_toon;
// Second toon pass on a 0.8 grey Diffuse BSDF, mixed in by grey_mix (suit 0.104, jacket 0.275).
uniform float grey_mix = 0.0;
uniform vec3 grey_pos = vec3(0.0, 0.123, 0.48);
uniform vec3 grey_val = vec3(0.011, 0.014, 0.505);

group_uniforms sheen_rim;
// Layer Weight "Facing" (0 = facing the camera, 1 = grazing).
uniform vec3 sheen_color = vec3(0.0);   // emission colour * strength
uniform float sheen_width = 0.0;        // 0 disables
uniform vec3 rim_color = vec3(0.0);     // emission colour * strength
uniform vec2 rim_range = vec2(2.0, 3.0);// ramp from 0 at x to 1 at y
// Only show sheen/rim on the brightest band (the jacket's node tree does this).
uniform bool sheen_rim_lit_only = false;

varying vec3 v_albedo;

void fragment() {
	v_albedo = base_color * texture(base_texture, UV).rgb;
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
}

float ramp3(float v, vec3 p, vec3 val, out int band) {
	band = 0;
	float o = val.x;
	if (v >= p.y) { o = val.y; band = 1; }
	if (v >= p.z) { o = val.z; band = 2; }
	return o;
}

void light() {
	float energy = max(max(LIGHT_COLOR.r, LIGHT_COLOR.g), LIGHT_COLOR.b) / PI;
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION;
	// Blender: a strength-1 sun on a white Diffuse BSDF gives 1/PI; the world adds albedo * colour.
	float lit = ndl * light_strength * energy / PI + ambient;
	vec3 h = normalize(LIGHT + VIEW);
	float spec = pow(clamp(dot(NORMAL, h), 0.0, 1.0), spec_power) * spec_strength * ATTENUATION * energy;

	float v_alb = max(max(v_albedo.r, v_albedo.g), v_albedo.b);
	float v = v_alb * lit + spec;
	int band;
	float vout = ramp3(v, band_pos, band_val, band);
	vec3 tint = band == 0 ? band_tint0 : (band == 1 ? band_tint1 : band_tint2);
	// keep hue/saturation, replace value
	vec3 col = v_albedo * (vout / max(v_alb, 1e-4)) * tint;

	if (grey_mix > 0.0) {
		int gb;
		float g = ramp3(0.8 * lit + spec, grey_pos, grey_val, gb);
		col = mix(col, vec3(g), grey_mix);
	}

	bool fx = !sheen_rim_lit_only || band == 2 || (band == 1 && band_pos.z > 1.0);
	if (fx) {
		float facing = 1.0 - abs(dot(NORMAL, VIEW));
		if (sheen_width > 0.0) {
			float s = clamp(1.0 - facing / sheen_width, 0.0, 1.0);
			col = mix(col, sheen_color, s);
		}
		float r = clamp((facing - rim_range.x) / max(rim_range.y - rim_range.x, 1e-4), 0.0, 1.0);
		col = mix(col, rim_color, r);
	}
	// max() instead of += so extra lights don't blow out the flat bands
	DIFFUSE_LIGHT = max(DIFFUSE_LIGHT, col);
}
