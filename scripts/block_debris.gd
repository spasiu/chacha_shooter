extends RigidBody3D

## A shard thrown out when a block breaks. Self-frees so nothing accumulates.

@export var lifetime := 2.4

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var on_expired: Callable


func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(_expire)


func tint(colour: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.95
	_mesh.material_override = mat


func _expire() -> void:
	if on_expired.is_valid():
		on_expired.call()
	queue_free()
