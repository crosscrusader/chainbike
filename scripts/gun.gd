extends Node3D
var shoot_velocity = 150
@onready var cooldown_timer:Timer = $"Timer"

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if Input.is_action_pressed("fire") && cooldown_timer.is_stopped():
		fire_missile(delta)


func fire_missile(_delta):
	var missile = StaticBody3D.new()
	add_child(missile)
	
	var mesh = MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.size = Vector3(0.1, 0.1, 0.1)
	missile.add_child(mesh)

	var col = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = mesh.size              # same size as the mesh
	col.shape = shape
	missile.add_child(col)

	missile.position += Vector3(shoot_velocity * _delta, 0, 0)


	

