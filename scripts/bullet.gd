extends RigidBody3D
## Damages whatever it hits (anything with a hit() method) and disappears.

@export var damage := 1


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 2
	continuous_cd = true
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if body.has_method("hit"):
		body.hit(damage, linear_velocity.normalized())
	queue_free()
