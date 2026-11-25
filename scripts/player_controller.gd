extends CharacterBody3D
@onready var GM = $"../GameManager"
@onready var anim: AnimationPlayer = $"AnimationPlayer"
@onready var pivot: Node3D = $"PivotPoint"
@onready var player_mesh: MeshInstance3D = $"PivotPoint/Box"
@onready var player_collider: CollisionShape3D = $"CollisionShape3D"


# State Machine
enum playerState {IDLE, MOVING_GROUND, JUMPING, FALLING}
var currentState: playerState = playerState.IDLE
var stateHistory = []

@export var debug_print_states := false
## true  = after the spin the TOP of the box points along the velocity (head-first dive).
## false = the box's forward face points along the velocity (old behaviour: upright at the apex).
@export var dive_head_first := true
## How gently the spin slows into the dive (rad/s²). Lower = keeps its speed longer and slows more gradually.
@export var spin_brake_decel := 9.0
## How fast air steering turns the player around (rad/s).
@export var air_turn_speed := 5.0
## How far pushing forward / back in the air leans the dive (radians).
@export var air_pitch_control := 0.6
## How fast that lean follows the stick (rad/s).
@export var air_pitch_rate := 3.0

## Bullet shooting
const BULLET_SCENE := preload("res://scenes/bullet.tscn")
@export var bullet_speed := 60.0
@export var bullet_lifetime := 3.0

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

# flip variables
var is_flipping := false          # only true for airtime that started with a jump
var flip_dir: Vector3 = Vector3.BACK  # world-space horizontal direction locked at take-off
var flip_angle = 0.0
var flip_rate = 0.0
var air_pitch_offset := 0.0


func _ready() -> void:
	currentState = playerState.IDLE
	stateHistory = [currentState]
	anim.play("Idle")


func _physics_process(delta: float) -> void:
	if currentState != stateHistory[-1]:
		stateHistory.append(currentState)
		if debug_print_states:
			print("State: ", playerState.keys()[currentState])
		if stateHistory.size() > 16:
			stateHistory.pop_front()

	match currentState:
		playerState.IDLE:
			if not is_on_floor():
				# Walked off a ledge (or the floor vanished): fall without flipping.
				air_velocity = Vector3(0, minf(velocity.y, 0.0), 0)
				is_flipping = false
				currentState = playerState.FALLING
			elif Input.is_action_pressed("jump"):
				ground_velocity = Vector3.ZERO
				currentState = playerState.JUMPING
				start_flip()
			elif get_move_direction() != Vector3.ZERO:
				currentState = playerState.MOVING_GROUND
			else:
				# No input: stand still. (Before, the old ground_velocity kept being
				# applied here, which is why the player slid with no keys pressed.)
				ground_velocity = Vector3.ZERO
				velocity = Vector3(0, -0.1, 0)  # tiny push so floor detection stays stable
				anim.play("Idle")

			# We want to de-accel the player to the ground speed if they land from a jump
			# This de-acceleration prevents the player from jerking to m_speed
			ground_speed = maxf(ground_speed - ground_friction_force * delta, m_speed)

		playerState.MOVING_GROUND:
			var dir := get_move_direction()
			if not is_on_floor():
				air_velocity = Vector3(ground_velocity.x, minf(velocity.y, 0.0), ground_velocity.z)
				is_flipping = false
				currentState = playerState.FALLING
			elif dir == Vector3.ZERO:
				ground_velocity = Vector3.ZERO
				velocity = Vector3(0, -0.1, 0)
				currentState = playerState.IDLE
			else:
				ground_speed = maxf(ground_speed - ground_friction_force * delta, m_speed)
				ground_velocity = dir * ground_speed
				set_facing(dir)  # turns PivotPoint only, never the body
				anim.play("Idle")

				if Input.is_action_pressed("jump"):
					currentState = playerState.JUMPING
					start_flip()
				else:
					velocity = Vector3(ground_velocity.x, -0.1, ground_velocity.z)

		playerState.JUMPING:
			if is_on_floor() and air_velocity.y <= 0.0:
				# Landed: stop the flip, carry horizontal speed into the ground
				# (IDLE/MOVING decay it back to m_speed).
				is_flipping = false
				flip_angle = 0.0
				flip_rate = 0.0
				reset_flip_rotation()
				ground_speed = maxf(Vector2(air_velocity.x, air_velocity.z).length(), m_speed)
				if get_move_direction() != Vector3.ZERO:
					ground_velocity = Vector3(air_velocity.x, 0, air_velocity.z)
					currentState = playerState.MOVING_GROUND
				else:
					ground_velocity = Vector3.ZERO
					currentState = playerState.IDLE
			else:
				if is_flipping:
					flip_player(delta)
				move_air(delta)
				if is_on_ceiling() or air_velocity.y <= 0.0:
					air_velocity.y = minf(air_velocity.y, 0.0)
					velocity = air_velocity
					currentState = playerState.FALLING

		playerState.FALLING:
			if is_on_floor():
				# Landed: stop the flip, carry horizontal speed into the ground
				# (IDLE/MOVING decay it back to m_speed).
				is_flipping = false
				flip_angle = 0.0
				flip_rate = 0.0
				reset_flip_rotation()
				ground_speed = maxf(Vector2(air_velocity.x, air_velocity.z).length(), m_speed)
				if get_move_direction() != Vector3.ZERO:
					ground_velocity = Vector3(air_velocity.x, 0, air_velocity.z)
					currentState = playerState.MOVING_GROUND
				else:
					ground_velocity = Vector3.ZERO
					currentState = playerState.IDLE
			else:
				if is_flipping:
					flip_player(delta)
				move_air(delta)

	move_and_slide()

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


# ---------------------------------------------------------------- flip

func start_flip() -> void:
	air_velocity = Vector3(ground_velocity.x, jump_speed, ground_velocity.z)
	velocity = air_velocity
	# Start the flip in the direction of the grounded velocity (or the facing
	# direction when jumping in place).
	var ground_flat := Vector3(ground_velocity.x, 0, ground_velocity.z)
	flip_dir = ground_flat.normalized() if ground_flat.length_squared() > 0.01 else facing_dir
	set_facing(flip_dir)
	flip_angle = 0.0
	flip_rate = flip_speed
	air_pitch_offset = 0.0
	is_flipping = true


func get_dive_angle() -> float:
	# How far past one full spin the box should end up so it lines up with the velocity.
	# Horizontal speed is measured along the flip direction and clamped to >= 0,
	# so steering backwards never makes it spin a whole extra loop.
	var h := maxf(Vector2(air_velocity.x, air_velocity.z).dot(Vector2(flip_dir.x, flip_dir.z)), 0.0)
	if h < 0.5:
		return 0.0  # jumping (almost) in place: finish the spin and land upright
	if dive_head_first:
		return atan2(h, air_velocity.y)     # 0 = head up, PI/2 = horizontal, PI = straight down
	return atan2(-air_velocity.y, h)         # forward face along velocity


func steer_air_rotation(delta: float) -> void:
	# Air input actively rotates the player:
	#  - sideways steering turns (yaws) the player toward where the air velocity is heading
	#  - pushing forward / back along the facing direction pitches the dive further / back
	var input_dir := get_move_direction()
	if input_dir != Vector3.ZERO:
		var vel_flat := Vector3(air_velocity.x	, 0, air_velocity.z)
		if vel_flat.length() > 1.0:
			var current_yaw := atan2(flip_dir.x, flip_dir.z)
			var target_yaw := atan2(vel_flat.x, vel_flat.z)
			var new_yaw := rotate_toward(current_yaw, target_yaw, air_turn_speed * delta)
			flip_dir = Vector3(sin(new_yaw), 0, cos(new_yaw))
			set_facing(flip_dir)
	var push := input_dir.dot(flip_dir)   # -1 (pulling back) .. 1 (pushing forward)
	air_pitch_offset = move_toward(air_pitch_offset, push * air_pitch_control, air_pitch_rate * delta)


func flip_player(delta: float) -> void:
	steer_air_rotation(delta)

	# Final resting angle: one full spin plus the dive angle (plus any lean from input).
	# Never less than one full spin, so the flip always completes.
	var target_angle := maxf(TAU + get_dive_angle() + air_pitch_offset, TAU)
	var error: float = target_angle - flip_angle

	# Keep the full spin speed for as long as possible, and only start braking once a
	# gentle, constant deceleration would bring it to rest exactly on the target.
	# The spin's momentum carries into the dive instead of stopping abruptly.
	var brake_limit := sqrt(2.0 * spin_brake_decel * absf(error))
	var desired_rate := signf(error) * minf(flip_speed, brake_limit)
	var braking := absf(desired_rate) < absf(flip_rate) and signf(desired_rate) == signf(flip_rate)
	var rate_change := spin_brake_decel if braking else spin_brake_decel * 2.0
	flip_rate = move_toward(flip_rate, desired_rate, rate_change * delta)
	# Don't step past the target in a single frame
	if absf(error) > 0.0 and absf(flip_rate * delta) > absf(error) and signf(flip_rate) == signf(error):
		flip_rate = error / delta

	flip_angle += flip_rate * delta

	# PivotPoint already faces flip_dir (local +Z), so the flip is a pitch around
	# PivotPoint's local X axis. Turning the pivot in the air turns the whole spin with it.
	player_mesh.basis = Basis(Vector3.RIGHT, flip_angle)


func reset_flip_rotation() -> void:
	player_mesh.basis = Basis.IDENTITY

func fire() -> void:
	var bullet: RigidBody3D = BULLET_SCENE.instantiate()
	# Add to the level (not the player) so the bullet doesn't move with the player.
	get_tree().current_scene.add_child(bullet)
	var dir := facing_dir
	bullet.global_position = pivot.global_position + dir * 1.0
	bullet.look_at(bullet.global_position + dir)
	bullet.gravity_scale = 0.0
	bullet.linear_velocity = dir * bullet_speed
	# Clean up after a few seconds so bullets don't pile up forever.
	get_tree().create_timer(bullet_lifetime).timeout.connect(bullet.queue_free)
