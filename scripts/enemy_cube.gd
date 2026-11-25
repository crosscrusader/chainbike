extends CharacterBody3D
## Basic cube enemy: drifts toward the player, flashes when shot, pops after a few hits.

@export var max_health := 3
@export var move_speed := 3.0
@export var chase_range := 25.0
@export var stop_distance := 2.5
@export var gravity := 20.0
@export var knockback := 6.0

@onready var mesh: MeshInstance3D = $"MeshInstance3D"

var health: int
var _flash := 0.0
var _push := Vector3.ZERO
var _dying := false
var _mat: StandardMaterial3D
var _base_color: Color


func _ready() -> void:
	add_to_group("enemies")
	health = max_health
	# own copy of the material so each cube flashes on its own
	_mat = (mesh.get_active_material(0) as StandardMaterial3D).duplicate()
	mesh.material_override = _mat
	_base_color = _mat.albedo_color


func hit(amount: int, from_dir: Vector3 = Vector3.ZERO) -> void:
	if _dying:
		return
	health -= amount
	_flash = 0.12
	_push = Vector3(from_dir.x, 0, from_dir.z) * knockback
	if health <= 0:
		_die()


func _die() -> void:
	_dying = true
	$CollisionShape3D.set_deferred("disabled", true)
	var tw := create_tween()
	tw.tween_property(mesh, "scale", Vector3.ONE * 1.4, 0.08)
	tw.tween_property(mesh, "scale", Vector3.ZERO, 0.15)
	tw.tween_callback(queue_free)


func _physics_process(delta: float) -> void:
	_flash = maxf(_flash - delta, 0.0)
	_mat.albedo_color = Color.WHITE if _flash > 0.0 else _base_color
	_mat.emission_enabled = _flash > 0.0
	_mat.emission = Color.WHITE
	if _dying:
		return

	var move := Vector3.ZERO
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player:
		var to := player.global_position - global_position
		to.y = 0
		var d := to.length()
		if d < chase_range and d > stop_distance:
			move = to / d * move_speed
			look_at(global_position + to, Vector3.UP)

	_push = _push.move_toward(Vector3.ZERO, 20.0 * delta)
	velocity.x = move.x + _push.x
	velocity.z = move.z + _push.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - gravity * delta
	move_and_slide()
