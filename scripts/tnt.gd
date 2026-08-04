class_name TNT
extends Equipment

## Timed demolition charges. Plants one on whatever you are looking at, or at
## your feet if that is nothing, and walks away from it.
##
## Unlike the grenade there is no cooking and no throw: the charge goes down
## where you put it and runs its own fuse from there, so the interesting part
## is deciding how far away you want to be in fifteen seconds.

## Charges carried.
@export var charges := 3
## How far you can reach to stick one to something.
@export var plant_range := 4.0
## Seconds the planted charge counts down. Passed through to it.
@export var fuse_time := 15.0
## Seconds the pack is busy after planting one.
@export var plant_time := 0.7
@export var charge_scene: PackedScene

const PLANT: AudioStream = preload("res://assets/audio/mag_in.wav")

@onready var body: Node3D = $Body
@onready var sound: AudioStreamPlayer = $Sound

var _starting_charges := 0
var _busy := false
var _pulled := false
## The last one planted, so the readout can count it down.
var _live: Node3D


func _ready() -> void:
	_starting_charges = charges


func restock() -> void:
	charges = _starting_charges
	on_holstered()


func on_equipped() -> void:
	body.visible = charges > 0


func on_holstered() -> void:
	_pulled = false
	_busy = false
	body.visible = charges > 0


func is_busy() -> bool:
	return _busy


func try_fire() -> bool:
	var held := _pulled
	_pulled = true
	if held or _busy or charges <= 0 or charge_scene == null:
		return false

	var scene_root := get_tree().current_scene
	if scene_root == null:
		return false

	charges -= 1
	_busy = true
	body.visible = charges > 0

	var charge: Node3D = charge_scene.instantiate()
	charge.fuse_time = fuse_time
	scene_root.add_child(charge)
	charge.global_position = _plant_point()
	_live = charge
	# Planted where everyone can see it, and ticking on their screens too. Only
	# this copy works out what it destroys when the fuse runs out.
	Net.report_projectile(
		Net.PROJECTILE_TNT, charge.global_position, Vector3.ZERO, fuse_time
	)

	sound.stream = PLANT
	sound.pitch_scale = 0.85
	sound.volume_db = -3.0
	sound.play()

	var tween := create_tween()
	tween.tween_interval(plant_time)
	tween.tween_callback(_finish)
	return true


func release_trigger() -> void:
	_pulled = false


func status_text() -> String:
	if is_instance_valid(_live) and _live.has_method("fuse_remaining"):
		var left: float = _live.fuse_remaining()
		if left > 0.0:
			return "TNT  %d  ·  %0.1f" % [charges, left]
	if charges <= 0:
		return "TNT  NONE LEFT"
	return "TNT  %d" % charges


func is_empty() -> bool:
	return charges <= 0


func is_full() -> bool:
	return charges >= _starting_charges


## Nothing to line up; raising just brings it up ready to place.
func sight_transform(_relief: float) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.05, -0.12, -0.3))


## Where the charge ends up: stuck to whatever is in front of you, or dropped
## at your feet when that is open air.
func _plant_point() -> Vector3:
	var camera := get_viewport().get_camera_3d()
	var planter := _find_ancestor_body()
	if camera == null:
		return global_position

	var origin := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin - camera.global_basis.z * plant_range
	)
	if planter != null:
		query.exclude = [planter.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		# Just off the surface, so it is not half sunk into it.
		return hit.position + hit.normal * 0.04
	if planter != null:
		return planter.global_position
	return origin


func _finish() -> void:
	_busy = false


func _find_ancestor_body() -> CollisionObject3D:
	var node := get_parent()
	while node != null:
		if node is CollisionObject3D:
			return node
		node = node.get_parent()
	return null
