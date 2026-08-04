extends Node3D

## Stands the map's ammunition boxes up on the ground.
##
## The positions come from the map file rather than from the scene, so a new map
## brings its own boxes with it and this node needs no editing to suit it. They
## are dropped onto the terrain's own column heights rather than raycast down,
## which means they land correctly on the frame the world loads, before any of
## the ground has been meshed.
##
## Names are assigned in the map's own order and never generated, because a box
## is referred to across the network by its path in the scene: two clients that
## numbered their boxes differently would empty each other's.

@export var box_scene: PackedScene


func _ready() -> void:
	var world: Node = get_tree().get_first_node_in_group("voxel_world")
	if world == null or box_scene == null:
		return
	var points: Array = world.ammo_points
	for i in points.size():
		var at: Vector2 = points[i]
		var box: Node3D = box_scene.instantiate()
		box.name = "Box%d" % i
		add_child(box)
		box.global_position = Vector3(at.x, world.ground_height(at.x, at.y), at.y)
		# Turned by an amount derived from where it stands, so the row of them
		# does not look stamped out -- and derived rather than random, because
		# every client has to arrive at the same crate sitting the same way.
		box.rotation.y = fposmod(at.x * 0.7 + at.y * 1.3, TAU)
