extends MeshInstance3D

@export var lifetime := 25.0


func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
