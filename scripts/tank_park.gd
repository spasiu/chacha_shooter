extends Node3D

## Parks the map's vehicles.
##
## Same arrangement as the ammunition boxes and for the same reason: where the
## tanks sit is a property of the ground, so it belongs in the map file rather
## than in the world scene, and a map that wants none simply lists none.
##
## Names are assigned in the map's own order and never generated. A vehicle is
## referred to across the network by its path in the scene -- that is how one
## client says it has got into the driving seat -- so two clients that numbered
## their tanks differently would each be driving the other's.
##
## One script, one node per kind of vehicle. The kind is two exported strings
## rather than two scripts, because the parking is identical and only the list
## read and the name written differ; the defaults are the tank's, so the node
## that was here before this was generalised needs no changes.

@export var tank_scene: PackedScene
## Which list on the world to park from: `tank_points`, `mech_points`.
@export var points_property := "tank_points"
## What each one is called in the scene tree. Part of the wire format in every
## sense that matters -- see above -- so it is changed at the cost of every
## client having to agree at once.
@export var name_prefix := "Tank"


func _ready() -> void:
	var world: Node = get_tree().get_first_node_in_group("voxel_world")
	if world == null or tank_scene == null:
		return
	var spots: Array = world.get(points_property)
	if spots == null:
		push_error("tank_park: the world has no %s to park from." % points_property)
		return
	for i in spots.size():
		var spot: Dictionary = spots[i]
		var at: Vector2 = spot["position"]
		var vehicle: Node3D = tank_scene.instantiate()
		vehicle.name = "%s%d" % [name_prefix, i]
		add_child(vehicle)
		# A metre up, and let it settle: the hull is a body, and dropping it the
		# last few centimetres onto the ground is how it finds its own level on
		# terrain that is never quite flat.
		vehicle.global_position = Vector3(
			at.x, world.ground_height(at.x, at.y) + 1.0, at.y
		)
		vehicle.rotation.y = deg_to_rad(spot["yaw"])
