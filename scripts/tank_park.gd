extends Node3D

## Parks the map's armour.
##
## Same arrangement as the ammunition boxes and for the same reason: where the
## tanks sit is a property of the ground, so it belongs in the map file rather
## than in the world scene, and a map that wants none simply lists none.
##
## Names are assigned in the map's own order and never generated. A tank is
## referred to across the network by its path in the scene -- that is how one
## client says it has got into the driving seat -- so two clients that numbered
## their tanks differently would each be driving the other's.

@export var tank_scene: PackedScene


func _ready() -> void:
	var world: Node = get_tree().get_first_node_in_group("voxel_world")
	if world == null or tank_scene == null:
		return
	var spots: Array = world.tank_points
	for i in spots.size():
		var spot: Dictionary = spots[i]
		var at: Vector2 = spot["position"]
		var tank: Node3D = tank_scene.instantiate()
		tank.name = "Tank%d" % i
		add_child(tank)
		# A metre up, and let it settle: the hull is a body, and dropping it the
		# last few centimetres onto the ground is how it finds its own level on
		# terrain that is never quite flat.
		tank.global_position = Vector3(
			at.x, world.ground_height(at.x, at.y) + 1.0, at.y
		)
		tank.rotation.y = deg_to_rad(spot["yaw"])
