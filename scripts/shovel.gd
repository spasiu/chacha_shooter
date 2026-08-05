class_name Shovel
extends Equipment

## Trench shovel. Swinging it hurts whatever is in reach and takes earth apart;
## raising it turns the same swing into building, packing a fresh earth block
## onto whatever face you are looking at.
##
## Not a Weapon: there is no magazine, no spread and no projectile, and the
## whole point of it is the terrain rather than the shooting.

## Reach of a swing, in metres. Point blank by design.
@export var reach := 2.0
## How far away a block can be placed.
@export var build_reach := 3.4
## Damage a swing does to anything that is not earth.
@export var swing_damage := 100.0
@export var swing_time := 0.55
## Fraction of the swing at which the blade actually lands.
@export var strike_at := 0.4
@export var raise_time := 0.18
## Blocks this close to the player are refused, so you cannot wall yourself in.
@export var self_clearance := 0.75
## Blocks across one spadeful, per side, laid flat in the face you are aiming
## at and centred on it. Four is a metre square of earth a swing -- sixteen
## blocks -- which is what makes filling a crater or throwing up a parapet
## something you would actually attempt. One puts it back to a single block and
## makes building the exact mirror of digging.
@export var build_span := 4

const DIG: AudioStream = preload("res://assets/audio/shovel_dig.wav")
const PACK: AudioStream = preload("res://assets/audio/shovel_pack.wav")

@onready var work_sound: AudioStreamPlayer = $WorkSound

var _aim := 0.0
var _aim_held := false
var _swinging := false
var _building := false
var _swing_tween: Tween
var _rest_position := Vector3.ZERO
var _rest_rotation := Vector3.ZERO
var _aim_position := Vector3.ZERO
var _aim_rotation := Vector3.ZERO
var _anim_offset := Vector3.ZERO
var _anim_tilt := Vector3.ZERO
var _world: Node


func _ready() -> void:
	_rest_position = position
	_rest_rotation = rotation
	_world = get_tree().get_first_node_in_group("voxel_world")


func try_fire() -> bool:
	if _swinging:
		return false
	# Which job this swing does is decided as it starts, so letting go of aim
	# mid-swing cannot turn a build into a dig.
	_building = _aim > 0.5
	_swinging = true
	_run_swing()
	return true


func set_aiming(aiming: bool) -> void:
	_aim_held = aiming


func aim_ratio() -> float:
	return _aim


func is_busy() -> bool:
	return _swinging


func status_text() -> String:
	return "SHOVEL  ·  BUILD" if _aim > 0.5 else "SHOVEL  ·  DIG"


## Opens out as the shovel comes up, so the square is the footprint of what the
## next swing actually does: tight on the one block a dig takes out, and the
## width of the whole spadeful once it is raised to build. Tied to `_aim` rather
## than switched at the halfway point, so the marker grows with the swing
## instead of jumping the moment the mode flips.
func reticule_size() -> float:
	return lerpf(1.0, maxf(float(build_span), 1.0) * 0.55, _aim)


## No sights on a shovel: raising it just brings the blade up and inboard,
## ready to pat earth into place.
func sight_transform(_relief: float) -> Transform3D:
	return Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-18.0)), Vector3(0.06, -0.1, -0.4))


func set_aim_pose(pose: Transform3D) -> void:
	_aim_position = pose.origin
	_aim_rotation = pose.basis.get_euler()


func on_holstered() -> void:
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	_swinging = false
	_anim_offset = Vector3.ZERO
	_anim_tilt = Vector3.ZERO


func _process(delta: float) -> void:
	var target := 1.0 if (_aim_held and not _swinging) else 0.0
	_aim = move_toward(_aim, target, delta / maxf(raise_time, 0.001))
	position = _rest_position.lerp(_aim_position, _aim) + _anim_offset
	rotation = _rest_rotation.lerp(_aim_rotation, _aim) + _anim_tilt


## Up and back, then down and across; the blade lands partway through.
func _run_swing() -> void:
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	var t := swing_time
	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_swing_tween = tween

	tween.tween_property(self, "_anim_offset", Vector3(0.05, 0.09, 0.1), t * strike_at * 0.55)
	tween.tween_property(self, "_anim_tilt", Vector3(deg_to_rad(-34.0), 0.0, 0.0),
		t * strike_at * 0.55)
	tween.tween_property(self, "_anim_offset", Vector3(-0.03, -0.12, -0.16), t * 0.2) \
		.set_delay(t * strike_at * 0.55)
	tween.tween_property(self, "_anim_tilt", Vector3(deg_to_rad(30.0), 0.0, 0.0), t * 0.2) \
		.set_delay(t * strike_at * 0.55)

	tween.tween_callback(_strike).set_delay(t * strike_at)
	tween.tween_property(self, "_anim_offset", Vector3.ZERO, t * 0.4).set_delay(t * 0.6)
	tween.tween_property(self, "_anim_tilt", Vector3.ZERO, t * 0.4).set_delay(t * 0.6)
	tween.tween_callback(_finish).set_delay(t)


func _finish() -> void:
	_swinging = false
	_anim_offset = Vector3.ZERO
	_anim_tilt = Vector3.ZERO


func _strike() -> void:
	if _building:
		_place_earth()
	else:
		_dig()


func _dig() -> void:
	var hit := _look(reach)
	if hit.is_empty():
		return

	# Earth comes apart whatever its remaining health; anything else just takes
	# the hit, so concrete and characters go through the normal damage path.
	var into: Vector3 = hit["direction"]
	if _world != null:
		var g: Vector3i = _world.world_to_grid(hit["position"] + into * (VoxelWorld.BLOCK * 0.25))
		var type: int = _world.block_at(g.x, g.y, g.z)
		if type == VoxelWorld.GRASS or type == VoxelWorld.DIRT:
			_world.damage_grid_block(g.x, g.y, g.z, 1e9)
			_play(DIG, randf_range(0.94, 1.08))
			return

	var target: Object = hit["collider"]
	if target != null and Lethality.friendly(Net.my_team(), target):
		return
	if target != null and target.has_method("take_damage"):
		target.take_damage(swing_damage, hit["position"], -into, Lethality.MELEE)
	_play(DIG, randf_range(0.9, 1.0))


## Packs a spadeful of earth onto whatever you are looking at.
##
## Deliberately not the mirror of digging. A swing that takes one block out and
## a swing that puts one block back makes filling a crater in take as many
## swings as blowing it open did, and a bazooka opens several hundred at once.
## A spadeful is `build_span` square in the plane of the face you hit -- sixteen
## blocks by default, a metre each way -- so earthworks go up at a pace worth
## attempting, while digging stays one block at a time and fine enough to cut a
## firing slit with.
func _place_earth() -> void:
	if _world == null:
		return
	var hit := _look(build_reach)
	if hit.is_empty():
		return

	# One block out along the face that was struck, the way a block goes onto a
	# wall rather than into it.
	var normal: Vector3 = hit["normal"]
	var spot: Vector3 = hit["position"] + normal * (VoxelWorld.BLOCK * 0.5)
	var g: Vector3i = _world.world_to_grid(spot)

	var body := _find_ancestor_body()
	var eyes := Vector3.ZERO
	if body != null:
		eyes = body.global_position + Vector3.UP * 0.9

	var laid := false
	for cell: Vector3i in _spadeful(g, normal, hit["position"]):
		# Tested per block rather than once for the patch: a spadeful reaches
		# further than a single block did, and the far corner of it being clear
		# says nothing about the corner next to your boots.
		var centre: Vector3 = (
			_world.grid_to_world(cell.x, cell.y, cell.z)
			+ Vector3.ONE * (VoxelWorld.BLOCK * 0.5)
		)
		if body != null and centre.distance_to(eyes) < self_clearance:
			continue
		if _world.place_block(cell.x, cell.y, cell.z, VoxelWorld.DIRT):
			laid = true
	if laid:
		_play(PACK, randf_range(0.95, 1.05))


## The cells one spadeful covers: a square patch lying in the face that was
## struck, so earth goes onto a wall flat against it and onto the ground flat
## along it rather than as a tower sticking out of either.
##
## Which way the patch grows is decided by where in the block the ray actually
## landed, so it spreads around the point you are aiming at instead of always
## reaching off in whichever direction the axes happen to be numbered.
func _spadeful(g: Vector3i, normal: Vector3, at: Vector3) -> Array[Vector3i]:
	var cells: Array[Vector3i] = [g]
	if build_span <= 1:
		return cells

	# The two axes that lie in the face: everything except the one the normal
	# points along.
	var facing := normal.abs()
	var along := 0
	if facing.y >= facing.x and facing.y >= facing.z:
		along = 1
	elif facing.z >= facing.x:
		along = 2
	var axes: Array[int] = [0, 1, 2]
	axes.erase(along)

	# The patch is laid around the block you hit rather than out from it. An
	# even span cannot sit exactly on centre, so which half of the block the ray
	# came down in breaks the tie -- which is also what makes a two-wide spadeful
	# grow toward where you are pointing.
	var corner: Vector3 = _world.grid_to_world(g.x, g.y, g.z)
	var low := Vector3i.ZERO
	for axis: int in axes:
		var into := (at[axis] - corner[axis]) / VoxelWorld.BLOCK
		@warning_ignore("integer_division")
		low[axis] = -(build_span / 2) + (1 if into >= 0.5 else 0)

	cells.clear()
	for a in build_span:
		for b in build_span:
			var cell := g
			cell[axes[0]] += low[axes[0]] + a
			cell[axes[1]] += low[axes[1]] + b
			cells.append(cell)
	return cells


## Ray from the camera, so the shovel works where you are looking rather than
## where the model happens to be pointing.
func _look(distance: float) -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var origin := camera.global_position
	var direction := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * distance)
	var body := _find_ancestor_body()
	if body != null:
		query.exclude = [body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	hit["direction"] = direction
	return hit


func _play(stream: AudioStream, pitch: float) -> void:
	work_sound.stream = stream
	work_sound.pitch_scale = pitch
	work_sound.play()


func _find_ancestor_body() -> CollisionObject3D:
	var node := get_parent()
	while node != null:
		if node is CollisionObject3D:
			return node
		node = node.get_parent()
	return null
