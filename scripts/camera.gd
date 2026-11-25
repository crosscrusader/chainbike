extends Camera3D
## Third-person orbit camera.
## Mouse: move to look (captured on start, Esc frees the cursor, click to capture again).
## Gamepad: right stick, with a response curve + flick/hold acceleration so small,
## slow stick movement turns slowly and quick flicks turn fast.
## A sphere is swept from the player to the camera every frame so it never clips into walls.

@export var target_path: NodePath = ^"../Player"
@export var pivot_offset := Vector3(0, 1.6, 0)   # point on the player the camera orbits around
@export var distance := 7.0
@export var min_pitch_deg := -75.0                # looking down
@export var max_pitch_deg := 35.0                 # looking up
@export var follow_sharpness := 18.0              # how tightly the orbit point follows the player

@export_group("Mouse")
@export var mouse_sensitivity := 0.0025           # radians per pixel
@export var invert_mouse_y := false

@export_group("Gamepad")
@export var stick_yaw_speed := 2.6                # rad/s at full tilt, before any boost
@export var stick_pitch_speed := 1.8
@export var invert_stick_y := false
## >1 makes small stick deflections much slower (2 = quadratic).
@export var stick_response_exponent := 2.2
## How fast the stick has to travel (deflection per second) to count as a flick.
## 6 means going from centre to edge in about 1/6 of a second.
@export var flick_threshold := 6.0
## Extra speed multiplier added for a hard flick (1.5 = up to 2.5x speed).
@export var flick_boost := 1.5
## How quickly the flick boost fades (multiplier units per second).
@export var flick_boost_decay := 2.5
## Extra speed added while the stick is held at the edge, ramping in over edge_ramp_time.
@export var edge_hold_boost := 1.0
@export var edge_ramp_time := 0.6
## How quickly the actual turn rate catches up to the stick (higher = snappier).
@export var stick_accel_sharpness := 14.0
@export var stick_decel_sharpness := 28.0

@export_group("Collision")
@export var collision_radius := 0.3               # keep > camera near plane
@export_flags_3d_physics var collision_mask := 1
## How quickly the camera moves back out after a wall stops blocking it (it always snaps in instantly).
@export var zoom_out_sharpness := 6.0

@onready var player: Node3D = get_node(target_path)

var yaw := 0.0
var pitch := deg_to_rad(-20.0)
var pivot_pos: Vector3
var current_distance: float

# gamepad state
var prev_stick_mag := 0.0
var flick_amount := 0.0
var edge_time := 0.0
var turn_rate := Vector2.ZERO

var _sphere := SphereShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()


func _ready() -> void:
	_ensure_look_actions()
	pivot_pos = player.global_position + pivot_offset
	current_distance = distance
	_sphere.radius = collision_radius
	_query.shape = _sphere
	_query.collision_mask = collision_mask
	if player is CollisionObject3D:
		_query.exclude = [player.get_rid()]
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var y_sign := -1.0 if invert_mouse_y else 1.0
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity * y_sign
		_clamp_pitch()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	_update_stick(delta)

	# Follow the player smoothly.
	var goal := player.global_position + pivot_offset
	pivot_pos = pivot_pos.lerp(goal, 1.0 - exp(-follow_sharpness * delta))

	var orbit_basis := Basis.from_euler(Vector3(pitch, yaw, 0))
	var offset_dir := orbit_basis * Vector3.BACK   # +Z = behind the pivot

	# Sweep a sphere from the pivot towards the wanted camera spot. If it hits
	# anything, pull the camera in to just before the hit.
	var allowed := distance
	var space := get_world_3d().direct_space_state
	_query.transform = Transform3D(Basis.IDENTITY, pivot_pos)
	_query.motion = offset_dir * distance
	var result := space.cast_motion(_query)
	if result.size() >= 1 and result[0] < 1.0:
		allowed = distance * result[0]

	if allowed < current_distance:
		current_distance = allowed                              # snap in: never clip
	else:
		current_distance = lerpf(current_distance, allowed, 1.0 - exp(-zoom_out_sharpness * delta))

	global_position = pivot_pos + offset_dir * current_distance
	look_at(pivot_pos, Vector3.UP)


func _update_stick(delta: float) -> void:
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	var mag := stick.length()

	# How fast the stick itself is moving outward = how hard the player flicked.
	var stick_speed := (mag - prev_stick_mag) / maxf(delta, 0.0001)
	prev_stick_mag = mag
	if stick_speed > flick_threshold:
		var strength := clampf((stick_speed - flick_threshold) / flick_threshold, 0.0, 1.0)
		flick_amount = maxf(flick_amount, lerpf(0.4, 1.0, strength) * flick_boost)
	flick_amount = maxf(flick_amount - flick_boost_decay * delta, 0.0)
	if mag < 0.3:
		flick_amount = 0.0   # let go / slow aim: no leftover boost

	# Holding the stick at the edge slowly ramps up extra speed (for big turns).
	edge_time = edge_time + delta if mag > 0.95 else 0.0
	var edge_boost := clampf(edge_time / edge_ramp_time, 0.0, 1.0) * edge_hold_boost

	var target_rate := Vector2.ZERO
	if mag > 0.0:
		var curved := pow(mag, stick_response_exponent)
		var multiplier := 1.0 + maxf(flick_amount, edge_boost)
		var dir := stick / mag
		target_rate = Vector2(dir.x * stick_yaw_speed, dir.y * stick_pitch_speed) * curved * multiplier

	var sharp := stick_accel_sharpness if target_rate.length() > turn_rate.length() else stick_decel_sharpness
	turn_rate = turn_rate.lerp(target_rate, 1.0 - exp(-sharp * delta))

	var y_sign := -1.0 if invert_stick_y else 1.0
	yaw -= turn_rate.x * delta
	pitch -= turn_rate.y * delta * y_sign
	_clamp_pitch()


func _clamp_pitch() -> void:
	pitch = clampf(pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))


## Makes sure the right-stick look actions exist even if they were never added
## in Project Settings > Input Map (they are added there too, so you can rebind them).
func _ensure_look_actions() -> void:
	var defs := {
		"look_left": [JOY_AXIS_RIGHT_X, -1.0],
		"look_right": [JOY_AXIS_RIGHT_X, 1.0],
		"look_up": [JOY_AXIS_RIGHT_Y, -1.0],
		"look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	}
	for action in defs:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.1)
		var ev := InputEventJoypadMotion.new()
		ev.axis = defs[action][0]
		ev.axis_value = defs[action][1]
		InputMap.action_add_event(action, ev)
