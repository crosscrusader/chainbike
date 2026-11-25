extends CharacterBody3D
@onready var GM = $"../GameManager"
@onready var animator = $"AnimationTree"          # scripts/theta_animator.gd
@onready var pivot: Node3D = $"PivotPoint"
@onready var player_mesh: Node3D = $"PivotPoint/Model"   # spun by flips / rolls
@onready var player_collider: CollisionShape3D = $"CollisionShape3D"

## Controls
##   jump (hold)            : jump + front flip (stick sideways relative to the camera = side flip)
##   jump (tap)             : short hop; with a direction, a no-flip dive that lands on her hands
##   crouch                 : crouch; crouch + direction = roll
##   hold crouch in a flip  : finish the flip head-first and land on her hands
##   crouch on touch-down   : roll out of the landing (a hand landing without it handsprings back up)
## Whatever she lands on, the body is leaned along the velocity (feet or hands first).

# State Machine
enum playerState {IDLE, MOVING_GROUND, JUMPING, FALLING, CROUCHING, ROLLING, HAND_LANDING}
var currentState: playerState = playerState.IDLE
var stateHistory = []

## What the current airtime is doing.
enum AirMode {NONE, PENDING, FLIP, HOP, DIVE}
var air_mode: AirMode = AirMode.NONE

@export var debug_print_states := false
## How gently the spin slows into its final lean (rad/s²). Lower = keeps its speed longer.
@export var spin_brake_decel := 9.0
## How fast air steering turns the player around (rad/s).
@export var air_turn_speed := 5.0
## How far pushing forward / back in the air leans the body (radians).
@export var air_pitch_control := 0.6
## How fast that lean follows the stick (rad/s).
@export var air_pitch_rate := 3.0

@export_group("Jump")
## Releasing jump before this (seconds) counts as a tap: short hop / dive instead of a flip.
@export var short_press_time := 0.15
## Upward speed kept when jump is tapped (0..1).
@export var short_jump_factor := 0.5
## How much more sideways than forward the stick must be (camera-relative) to side flip.
@export var side_flip_ratio := 1.2
## While the spin is still under this many radians from a full turn the body stays tucked.
@export var untuck_before_full_turn := 0.9
## 0 = land upright, 1 = body fully lined up with the velocity (feet first).
@export var feet_first_amount := 0.7
## Seconds to stand back up straight after a feet-first landing.
@export var landing_recover_time := 0.15

@export_group("Roll")
@export var roll_time := 0.55
@export var roll_speed := 14.0
## Height of the spin centre while rolling (standing it's 1.0).
@export var roll_center_height := 0.5
@export var handspring_time := 0.4
## Distance from the lowest bone to the surface of the body (the floor contact while rolling).
@export var roll_skin := 0.12

@export_group("Shooting")
@export var bullet_speed := 60.0
@export var bullet_lifetime := 3.0
const BULLET_SCENE := preload("res://scenes/bullet.tscn")

# constants
const m_speed = 20
const flip_speed = 8
const airborne_multiplier = 80
const ground_friction_force = 20
const jump_speed = 20
const max_air_speed = 20

# movement variables
var ground_velocity: Vector3 = Vector3.ZERO
var ground_speed: float = m_speed
var air_velocity: Vector3 = Vector3.ZERO
var air_force: Vector3
var facing_dir: Vector3 = Vector3.BACK   # world-space horizontal direction the player faces

# body rotation (flip / dive / roll)
var flip_dir: Vector3 = Vector3.BACK  # world-space horizontal direction locked at take-off
## Side flip: 0 = forward rotation, 1 = rolling toward the character's right, -1 = toward the left.
var side_flip := 0
var flip_angle = 0.0
var flip_rate = 0.0
var air_pitch_offset := 0.0
var jump_timer := 0.0

# ground moves
var move_t := 0.0            # progress of a roll / handspring (seconds)
var move_from_angle := 0.0
var move_to_angle := 0.0
var move_velocity := Vector3.ZERO
var move_from_height := 1.0
var recover_t := 0.0         # landing lean recovery
var recover_angle := 0.0


func _ready() -> void:
	add_to_group("player")
	_ensure_crouch_action()
	currentState = playerState.IDLE
	stateHistory = [currentState]


func _physics_process(delta: float) -> void:
	if currentState != stateHistory[-1]:
		stateHistory.append(currentState)
		if debug_print_states:
			print("State: ", playerState.keys()[currentState])
		if stateHistory.size() > 16:
			stateHistory.pop_front()

	var crouch := Input.is_action_pressed("crouch")

	match currentState:
		playerState.IDLE, playerState.MOVING_GROUND, playerState.CROUCHING:
			var dir := get_move_direction()
			# De-accelerate to the ground speed after landing from a fast jump.
			ground_speed = maxf(ground_speed - ground_friction_force * delta, m_speed)
			if not is_on_floor():
				# Walked off a ledge (or the floor vanished): fall without flipping.
				air_velocity = Vector3(ground_velocity.x, minf(velocity.y, 0.0), ground_velocity.z)
				begin_air(AirMode.HOP)
				currentState = playerState.FALLING
			elif Input.is_action_pressed("jump"):
				ground_velocity = Vector3.ZERO if dir == Vector3.ZERO else dir * ground_speed
				currentState = playerState.JUMPING
				start_jump()
			elif crouch and dir != Vector3.ZERO:
				start_roll(dir, 0.0)
			elif crouch:
				ground_velocity = Vector3.ZERO
				velocity = Vector3(0, -0.1, 0)
				currentState = playerState.CROUCHING
			elif dir == Vector3.ZERO:
				# No input: stand still.
				ground_velocity = Vector3.ZERO
				velocity = Vector3(0, -0.1, 0)  # tiny push so floor detection stays stable
				currentState = playerState.IDLE
			else:
				ground_velocity = dir * ground_speed
				set_facing(dir)  # turns PivotPoint only, never the body
				velocity = Vector3(ground_velocity.x, -0.1, ground_velocity.z)
				currentState = playerState.MOVING_GROUND
			update_landing_recover(delta)

		playerState.JUMPING, playerState.FALLING:
			if is_on_floor() and (currentState == playerState.FALLING or air_velocity.y <= 0.0):
				land(crouch)
			else:
				update_air_mode(delta)
				rotate_body_in_air(delta)
				move_air(delta)
				if currentState == playerState.JUMPING and (is_on_ceiling() or air_velocity.y <= 0.0):
					air_velocity.y = minf(air_velocity.y, 0.0)
					velocity = air_velocity
					currentState = playerState.FALLING

		playerState.ROLLING, playerState.HAND_LANDING:
			update_ground_move(delta)

	move_and_slide()
	update_animation(delta)

	if Input.is_action_just_pressed("fire"):
		fire()

	# Keep air_velocity in sync with what physics actually did (walls, ceilings).
	if currentState == playerState.JUMPING or currentState == playerState.FALLING:
		air_velocity = velocity


## Input turned into a world-space direction relative to the camera (length 0..1).
func get_move_direction() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	if input == Vector2.ZERO:
		return Vector3.ZERO
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3(input.x, 0, input.y).limit_length(1.0)
	var right := cam.global_basis.x
	var back := cam.global_basis.z
	right.y = 0
	back.y = 0
	var dir := right.normalized() * input.x + back.normalized() * input.y
	return dir.limit_length(1.0)


func set_facing(dir: Vector3) -> void:
	var flat := Vector3(dir.x, 0, dir.z)
	if flat.length_squared() < 0.0001:
		return
	facing_dir = flat.normalized()
	# Only the visual pivot turns. The body itself never rotates, so the flip axis
	# below can't get mixed up with the facing rotation.
	pivot.rotation.y = atan2(facing_dir.x, facing_dir.z)


func move_air(delta: float) -> void:
	air_velocity.y -= GM.gravity * delta
	air_force = get_move_direction() * airborne_multiplier
	air_velocity.x += air_force.x * delta
	air_velocity.z += air_force.z * delta
	var horizontal := Vector2(air_velocity.x, air_velocity.z).limit_length(maxf(max_air_speed, ground_speed))
	air_velocity.x = horizontal.x
	air_velocity.z = horizontal.y
	velocity = air_velocity


# ---------------------------------------------------------------- jumping

func start_jump() -> void:
	air_velocity = Vector3(ground_velocity.x, jump_speed, ground_velocity.z)
	velocity = air_velocity
	var ground_flat := Vector3(ground_velocity.x, 0, ground_velocity.z)
	var dir := ground_flat.normalized() if ground_flat.length_squared() > 0.01 else facing_dir
	begin_air(AirMode.PENDING)
	flip_dir = dir
	set_facing(flip_dir)
	# Stick pushed left/right (relative to the camera) -> side flip: face away from the
	# camera and cartwheel sideways in the air instead of somersaulting forward.
	var stick := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var cam := get_viewport().get_camera_3d()
	if cam and absf(stick.x) > 0.3 and absf(stick.x) > absf(stick.y) * side_flip_ratio:
		var cam_fwd := -cam.global_basis.z
		cam_fwd.y = 0
		if cam_fwd.length_squared() > 0.0001:
			set_facing(cam_fwd.normalized())
			side_flip = 1 if stick.x > 0.0 else -1


func begin_air(mode: AirMode) -> void:
	reset_flip_rotation()
	air_mode = mode
	jump_timer = 0.0
	flip_angle = 0.0
	flip_rate = 0.0
	air_pitch_offset = 0.0
	recover_t = 0.0
	player_mesh.position.y = 1.0


## Decides tap vs hold right after take-off.
func update_air_mode(delta: float) -> void:
	if air_mode != AirMode.PENDING:
		return
	jump_timer += delta
	if not Input.is_action_pressed("jump") and jump_timer < short_press_time:
		# Tap: short hop. With a direction it becomes a no-flip dive onto her hands.
		if air_velocity.y > 0.0:
			air_velocity.y *= short_jump_factor
		var flat := Vector3(air_velocity.x, 0, air_velocity.z)
		side_flip = 0
		if flat.length() > 1.0:
			flip_dir = flat.normalized()
			set_facing(flip_dir)
			air_mode = AirMode.DIVE
		else:
			air_mode = AirMode.HOP
	elif jump_timer >= short_press_time:
		air_mode = AirMode.FLIP
		flip_rate = flip_speed


## Horizontal speed along the direction a positive body angle tips the head.
func get_lead_speed() -> float:
	var lead := flip_dir
	if side_flip != 0:
		lead = -pivot.global_basis.x * side_flip   # character's right (or left)
	return Vector2(air_velocity.x, air_velocity.z).dot(Vector2(lead.x, lead.z))


## True when this airtime ends head-first on her hands.
func lands_on_hands() -> bool:
	return air_mode == AirMode.DIVE or (air_mode == AirMode.FLIP and Input.is_action_pressed("crouch"))


## Lean that lines the body up with the velocity: head-first for hand landings,
## feet-first otherwise (0 = upright, positive = head tipped along the flip direction).
func get_settle_angle() -> float:
	var h := get_lead_speed()
	if lands_on_hands():
		h = maxf(h, 0.0)
		if h < 0.5:
			return 0.0
		return atan2(h, air_velocity.y)  # 0 = head up, PI/2 = horizontal, PI = straight down
	# Feet first: the head points away from the velocity. Softened near the apex so she
	# doesn't lean back while still rising.
	var down := maxf(-air_velocity.y, 0.0) + 4.0
	return atan2(-h, down) * feet_first_amount


func steer_air_rotation(delta: float) -> void:
	if side_flip != 0:
		return  # keep facing the camera's forward for the whole side flip
	# Air input actively rotates the player:
	#  - sideways steering turns (yaws) the player toward where the air velocity is heading
	#  - pushing forward / back along the facing direction pitches the body further / back
	var input_dir := get_move_direction()
	if input_dir != Vector3.ZERO:
		var vel_flat := Vector3(air_velocity.x, 0, air_velocity.z)
		if vel_flat.length() > 1.0:
			var current_yaw := atan2(flip_dir.x, flip_dir.z)
			var target_yaw := atan2(vel_flat.x, vel_flat.z)
			var new_yaw := rotate_toward(current_yaw, target_yaw, air_turn_speed * delta)
			flip_dir = Vector3(sin(new_yaw), 0, cos(new_yaw))
			set_facing(flip_dir)
	var push := input_dir.dot(flip_dir)   # -1 (pulling back) .. 1 (pushing forward)
	air_pitch_offset = move_toward(air_pitch_offset, push * air_pitch_control, air_pitch_rate * delta)


func rotate_body_in_air(delta: float) -> void:
	if air_mode == AirMode.PENDING or air_mode == AirMode.NONE:
		return
	steer_air_rotation(delta)

	# Final resting angle: one full spin (flips only) plus the lean along the velocity.
	var target_angle: float = get_settle_angle() + air_pitch_offset
	if air_mode == AirMode.FLIP:
		target_angle = maxf(TAU + target_angle, TAU - 0.8)  # the flip always (nearly) completes
	var error: float = target_angle - flip_angle

	# Keep the full spin speed for as long as possible, and only start braking once a
	# gentle, constant deceleration would bring it to rest exactly on the target.
	var brake_limit := sqrt(2.0 * spin_brake_decel * absf(error))
	var desired_rate := signf(error) * minf(flip_speed, brake_limit)
	var braking := absf(desired_rate) < absf(flip_rate) and signf(desired_rate) == signf(flip_rate)
	var rate_change := spin_brake_decel if braking else spin_brake_decel * 2.0
	flip_rate = move_toward(flip_rate, desired_rate, rate_change * delta)
	# Don't step past the target in a single frame
	if absf(error) > 0.0 and absf(flip_rate * delta) > absf(error) and signf(flip_rate) == signf(error):
		flip_rate = error / delta

	flip_angle += flip_rate * delta
	set_body_angle(flip_angle)
	# Head-first: drop the spin centre as the body tips over so the hands reach the ground.
	player_mesh.position.y = hands_center_height(flip_angle) if lands_on_hands() else 1.0


## Spin-centre height that keeps the outstretched hands near the floor (1.0 = standing).
func hands_center_height(angle: float) -> float:
	return 1.0 - 0.5 * maxf(sin(wrapf(angle, 0.0, TAU)), 0.0)


## Rotates the model about its centre. PivotPoint already faces flip_dir (local +Z):
## a front flip pitches around local X, a side flip rolls around local Z.
func set_body_angle(angle: float) -> void:
	if side_flip != 0:
		# Positive angle tips the head toward local -X, which is the character's right.
		player_mesh.basis = Basis(Vector3.BACK, angle * side_flip)
	else:
		player_mesh.basis = Basis(Vector3.RIGHT, angle)


func reset_flip_rotation() -> void:
	player_mesh.basis = Basis.IDENTITY
	side_flip = 0


# ---------------------------------------------------------------- landing / ground moves

func land(crouch: bool) -> void:
	var horizontal := Vector3(air_velocity.x, 0, air_velocity.z)
	ground_speed = maxf(horizontal.length(), m_speed)
	var lean := wrapf(flip_angle, -PI, PI)
	var on_hands := lands_on_hands() and lean > 0.5
	air_mode = AirMode.NONE
	flip_rate = 0.0
	if on_hands or (crouch and horizontal.length() > 2.0):
		var dir := horizontal.normalized() if horizontal.length() > 0.5 else facing_dir
		if crouch:
			start_roll(dir, lean)                # tuck and roll out of the landing
		else:
			start_handspring(dir, horizontal.length())
		return
	# Feet landing: keep the lean she landed with and straighten up over a moment.
	recover_angle = lean
	recover_t = landing_recover_time if absf(recover_angle) > 0.01 else 0.0
	flip_angle = 0.0
	if recover_t <= 0.0:
		reset_flip_rotation()
	if get_move_direction() != Vector3.ZERO:
		ground_velocity = horizontal
		currentState = playerState.MOVING_GROUND
	else:
		ground_velocity = Vector3.ZERO
		currentState = playerState.IDLE


func update_landing_recover(delta: float) -> void:
	if recover_t <= 0.0:
		return
	recover_t = maxf(recover_t - delta, 0.0)
	var k := recover_t / landing_recover_time
	set_body_angle(recover_angle * k * k)
	if recover_t <= 0.0:
		reset_flip_rotation()


## Tucked roll. from_angle lets a landing roll carry on the rotation it already has
## (a side flip keeps rolling sideways).
func start_roll(dir: Vector3, from_angle: float) -> void:
	if side_flip == 0:
		flip_dir = dir
		set_facing(dir)
	move_from_angle = from_angle
	move_to_angle = TAU
	move_from_height = player_mesh.position.y
	var speed := maxf(Vector3(velocity.x, 0, velocity.z).length(), roll_speed)
	move_velocity = dir * speed
	move_t = 0.0
	recover_t = 0.0
	currentState = playerState.ROLLING


## Lands on her hands and flips over onto her feet.
func start_handspring(dir: Vector3, speed: float) -> void:
	move_from_angle = wrapf(flip_angle, -PI, PI)
	move_to_angle = TAU
	move_velocity = dir * maxf(speed * 0.6, 6.0)
	move_t = 0.0
	recover_t = 0.0
	currentState = playerState.HAND_LANDING


func update_ground_move(delta: float) -> void:
	var length := roll_time if currentState == playerState.ROLLING else handspring_time
	move_t += delta
	var k := clampf(move_t / length, 0.0, 1.0)
	var eased := k * k * (3.0 - 2.0 * k)
	flip_angle = lerpf(move_from_angle, move_to_angle, eased)
	set_body_angle(flip_angle)
	if currentState == playerState.ROLLING:
		player_mesh.position.y = minf(lerpf(move_from_height, 1.0, k), 1.0 - (1.0 - roll_center_height) * sin(PI * k))
		# Snap the ball onto the floor: shift it so the lowest bone sits one body-thickness
		# above the ground, so she is always in contact while rolling.
		var lowest: float = animator.get_lowest_bone_height() - global_position.y
		player_mesh.position.y -= lowest - roll_skin
		player_mesh.position.y = clampf(player_mesh.position.y, 0.2, 1.0)
	else:
		player_mesh.position.y = hands_center_height(flip_angle)
	var slow := 1.0 - 0.4 * k
	velocity = Vector3(move_velocity.x * slow, -0.1, move_velocity.z * slow)

	if not is_on_floor() and k > 0.1:
		# Rolled off a ledge.
		air_velocity = Vector3(velocity.x, 0.0, velocity.z)
		begin_air(AirMode.HOP)
		currentState = playerState.FALLING
		return
	if k >= 1.0:
		reset_flip_rotation()
		player_mesh.position.y = 1.0
		flip_angle = 0.0
		ground_velocity = Vector3(velocity.x, 0, velocity.z)
		ground_speed = maxf(ground_velocity.length(), m_speed)
		currentState = playerState.MOVING_GROUND if get_move_direction() != Vector3.ZERO else playerState.IDLE


func _ensure_crouch_action() -> void:
	# Fallback binding if the project doesn't define "crouch": C / left Ctrl / gamepad B.
	if InputMap.has_action("crouch"):
		return
	InputMap.add_action("crouch", 0.2)
	for key in [KEY_C, KEY_CTRL]:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		InputMap.action_add_event("crouch", ev)
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_B
	InputMap.action_add_event("crouch", pad)


# ---------------------------------------------------------------- animation

func update_animation(delta: float) -> void:
	match currentState:
		playerState.IDLE, playerState.MOVING_GROUND:
			animator.set_state("ground")
			var stick := Input.get_vector("move_left", "move_right", "move_forward", "move_backward").length()
			animator.set_locomotion(stick if currentState == playerState.MOVING_GROUND else 0.0, delta)
		playerState.CROUCHING:
			animator.set_state("crouch")
		playerState.ROLLING:
			animator.set_state("roll")
		playerState.HAND_LANDING:
			animator.set_state("dive")              # arms planted overhead
		playerState.JUMPING, playerState.FALLING:
			match air_mode:
				AirMode.PENDING:
					animator.set_state("tuck")      # starts with the take-off pose
				AirMode.FLIP:
					if flip_angle < TAU - untuck_before_full_turn:
						animator.set_state("tuck")
					elif lands_on_hands():
						animator.set_state("dive")  # reaching for the ground head-first
					else:
						animator.set_state("fall")
				AirMode.DIVE:
					animator.set_state("dive")
				_:
					animator.set_state("fall")


func fire() -> void:
	var bullet: RigidBody3D = BULLET_SCENE.instantiate()
	# Add to the level (not the player) so the bullet doesn't move with the player.
	get_tree().current_scene.add_child(bullet)
	var dir := facing_dir
	animator.shoot()
	var muzzle = animator.get_muzzle_position()
	bullet.global_position = muzzle if muzzle != null else pivot.global_position + Vector3.UP * 1.4 + dir * 1.0
	bullet.add_collision_exception_with(self)  # the hand can be inside the capsule
	bullet.look_at(bullet.global_position + dir)
	bullet.gravity_scale = 0.0
	bullet.linear_velocity = dir * bullet_speed
	# Clean up after a few seconds so bullets don't pile up forever.
	get_tree().create_timer(bullet_lifetime).timeout.connect(bullet.queue_free)
