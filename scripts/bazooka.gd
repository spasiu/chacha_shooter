class_name Bazooka
extends Weapon

## Shoulder-fired rocket launcher.
##
## Every other weapon here hands its lethality to whatever the ray struck. This
## hands it to everything standing near where the rocket went off, falling away
## over its own much tighter set of bands. Blast is overpressure rather than
## fragments, so unlike a grenade it is not traced out along sightlines: ducking
## behind a wall does not spare you, though the wall itself may not survive
## either.

## How far out the blast still bothers the terrain. Only the innermost band by
## default, for two reasons: past it the numbers are noise against a block's
## thousand health, and the cell loop grows with the cube of the reach.
@export var crater_yards := 1.0
## Standing height a body is measured against, so a rocket into someone's chest
## reads as a direct hit rather than as one a yard from their feet.
@export var target_height := 1.8

const EXPLOSION: AudioStream = preload("res://assets/audio/explosion.wav")
## Trim on each voice of the burst. Loud on purpose -- it should carry across
## the map and be plainly the biggest thing in the mix.
const BURST_VOLUME_DB := 8.0

## Left-hand waypoints for the reload, as offsets from its rest on the foregrip.
const HAND_TO_BREECH := Vector3(0.0, -0.02, 0.42)
const HAND_OFF := Vector3(0.05, -0.32, 0.34)
## Where a fresh rocket waits before being slid down the tube.
const ROCKET_BACK := Vector3(0.0, -0.03, 0.34)

@onready var rocket: MeshInstance3D = $Rocket

var _rocket_rest := Vector3.ZERO


## Everything inside this is in reach of the blast. Taken from the last band
## edge, because past there the profile has nothing left to give anyway.
var blast_radius: float:
	get:
		if band_yards.is_empty():
			return 0.0
		return float(band_yards[band_yards.size() - 1]) * Lethality.YARD


func _ready() -> void:
	super()
	_rocket_rest = rocket.position


## One rocket: fly it out along the shot and set it off wherever it stops.
## Overrides the pellet loop outright -- a launcher fires one thing, and what
## matters is where it lands rather than what the ray happened to touch.
func _raycast() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var origin := camera.global_position
	var spread := deg_to_rad(lerpf(min_spread, max_spread, _bloom)) * lerpf(
		1.0, aim_spread_factor, _aim
	)
	var direction := _shot_direction(camera, spread)

	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_range)
	if _shooter != null:
		query.exclude = [_shooter.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# A rocket that finds nothing burns out at the end of its run.
	var burst: Vector3 = hit.position if not hit.is_empty() else origin + direction * max_range

	_blast_bodies(burst)
	_blast_terrain(burst)
	_show_burst(burst)


## Everything with a body in reach takes the blast, scaled by how far it stood
## from the burst. Deliberately no line-of-sight check.
func _blast_bodies(at: Vector3) -> void:
	var shape := SphereShape3D.new()
	shape.radius = blast_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, at)
	query.collide_with_areas = false

	for entry: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 32):
		var body: Object = entry.get("collider")
		if body == null or not body.has_method("take_damage"):
			continue
		# Terrain is dealt with block by block below. Left in here, a chunk
		# would soak the whole blast into whichever single block sits nearest.
		if body is VoxelChunk:
			continue
		if not (body is Node3D):
			continue

		# Measure to the nearest point on the body's standing height rather than
		# to its origin, which sits down at the feet.
		var foot: Vector3 = (body as Node3D).global_position
		var point := Geometry3D.get_closest_point_to_segment(
			at, foot, foot + Vector3.UP * target_height
		)
		var dealt := damage_at(at.distance_to(point))
		if dealt > 0.0:
			body.take_damage(dealt, point, (point - at).normalized())


## Carves the ground. Blocks are damaged one at a time so the crater falls away
## with distance exactly as the casualties do.
func _blast_terrain(at: Vector3) -> void:
	var world: Node = get_tree().get_first_node_in_group("voxel_world")
	if world == null:
		return

	var reach_m: float = minf(crater_yards * Lethality.YARD, blast_radius)
	var reach := int(ceil(reach_m / VoxelWorld.BLOCK))
	var centre: Vector3i = world.world_to_grid(at)
	for dx in range(-reach, reach + 1):
		for dy in range(-reach, reach + 1):
			for dz in range(-reach, reach + 1):
				var gx: int = centre.x + dx
				var gy: int = centre.y + dy
				var gz: int = centre.z + dz
				if not world.in_bounds(gx, gy, gz):
					continue
				# Cheapest rejections first: empty cells, then the corners of
				# the cube that fall outside the sphere.
				if world.block_at(gx, gy, gz) == VoxelWorld.AIR:
					continue
				var distance := at.distance_to(world.grid_to_world(gx, gy, gz))
				if distance > reach_m:
					continue
				var dealt := damage_at(distance)
				if dealt > 0.0:
					world.damage_grid_block(gx, gy, gz, dealt)


## A flash and a bang out where the rocket went off. Built in code rather than
## as its own scene because nothing else in the game needs one.
func _show_burst(at: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var light := OmniLight3D.new()
	scene_root.add_child(light)
	light.global_position = at
	light.light_color = Color(1.0, 0.76, 0.42)
	light.light_energy = 22.0
	light.omni_range = maxf(blast_radius * 2.0, 1.0)
	var fade := light.create_tween()
	fade.tween_property(light, "light_energy", 0.0, 0.5)
	fade.tween_callback(light.queue_free)

	# Two voices rather than one: the crack at pitch, then a slower, deeper
	# copy a beat behind it. One sample on its own reads as a pop from any
	# distance; the pair reads as something large going off.
	_burst_sound(scene_root, at, 1.0, BURST_VOLUME_DB, 0.0)
	_burst_sound(scene_root, at, 0.42, BURST_VOLUME_DB - 2.0, 0.06)


## One voice of the burst. `delay` is in seconds, so the rumble can trail the
## crack without either being a separate asset.
func _burst_sound(
	scene_root: Node, at: Vector3, pitch: float, volume_db: float, delay: float
) -> void:
	var sound := AudioStreamPlayer3D.new()
	scene_root.add_child(sound)
	sound.global_position = at
	sound.stream = EXPLOSION
	sound.pitch_scale = pitch
	sound.volume_db = volume_db
	# Carries much further than a rifle shot, and stays loud while it does.
	sound.unit_size = 40.0
	sound.max_distance = 220.0
	sound.finished.connect(sound.queue_free)
	if delay > 0.0:
		get_tree().create_timer(delay).timeout.connect(sound.play)
	else:
		sound.play()


## Tube comes down off the shoulder, a fresh rocket goes in the back of it, and
## it goes back up. Same timeline shape as the base reload: every delay is a
## fraction of `reload_time`.
func _run_reload_animation() -> void:
	if _reload_tween != null and _reload_tween.is_valid():
		_reload_tween.kill()

	var t := reload_time
	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_reload_tween = tween

	# Off the shoulder, support hand back to the breech.
	tween.tween_property(self, "_reload_offset", CANT_OFFSET, t * 0.18)
	tween.tween_property(self, "_reload_tilt", _cant_tilt(), t * 0.18)
	tween.tween_property(self, "left_hand_offset", HAND_TO_BREECH, t * 0.18)

	# The spent round clears the tube and the hand drops out of frame for another.
	tween.tween_property(rocket, "position", _rocket_rest + ROCKET_BACK, t * 0.16) \
		.set_delay(t * 0.18)
	tween.tween_callback(rocket.hide).set_delay(t * 0.34)
	tween.tween_property(self, "left_hand_offset", HAND_OFF, t * 0.2).set_delay(t * 0.34)
	tween.tween_callback(_play.bind(reload_sound, MAG_OUT, 0.8, -4.0)).set_delay(t * 0.2)

	# Back with a fresh one, and slide it home.
	tween.tween_callback(_present_fresh_rocket).set_delay(t * 0.56)
	tween.tween_property(self, "left_hand_offset", HAND_TO_BREECH, t * 0.14).set_delay(t * 0.56)
	tween.tween_property(rocket, "position", _rocket_rest, t * 0.18) \
		.set_ease(Tween.EASE_IN).set_delay(t * 0.6)
	tween.tween_callback(_play.bind(reload_sound, MAG_IN, 0.75, -3.0)).set_delay(t * 0.78)

	# Back onto the shoulder.
	tween.tween_property(self, "_reload_offset", Vector3.ZERO, t * 0.18).set_delay(t * 0.8)
	tween.tween_property(self, "_reload_tilt", Vector3.ZERO, t * 0.18).set_delay(t * 0.8)
	tween.tween_property(self, "left_hand_offset", Vector3.ZERO, t * 0.16).set_delay(t * 0.82)

	tween.tween_callback(_finish_reload).set_delay(t)


func _present_fresh_rocket() -> void:
	rocket.position = _rocket_rest + ROCKET_BACK
	rocket.show()


func _finish_reload_state() -> void:
	super()
	rocket.position = _rocket_rest
	rocket.show()
