class_name Blast

## One warhead going off at a point: who it hurts, what it does to the ground,
## and what that looks and sounds like.
##
## A bazooka rocket and an artillery shell are the same event with different
## numbers behind them, so they share this rather than each keeping a copy --
## and since a fire mission drops a hundred of them, an artillery shell now is
## a bazooka shell.
##
## Blast is overpressure, not fragments, so none of it is traced along
## sightlines: cover does not save you from any of it. The grenade is the odd
## one out and deliberately so. It casts real fragment rays, which is exactly
## what makes ducking behind something work against a grenade and not against
## this.

## What a bazooka rocket carries, measured out from the burst. Kept here rather
## than on either of the two things that fire one, so they cannot drift apart.
const ROCKET_YARDS := [1.0, 3.0, 9.0]
const ROCKET_DAMAGE := [1000.0, 100.0, 10.0, 0.0]

## Standing height a body is measured against, so a warhead going off at chest
## level reads as a direct hit rather than as one a yard from the feet.
const TARGET_HEIGHT := 1.8

## Anything with a view that a big enough detonation should rattle.
const VIEWERS := &"viewers"

const EXPLOSION: AudioStream = preload("res://assets/audio/explosion.wav")


## Hurts everything inside the last band, scaled by how far it stood from the
## burst.
static func hurt(tree: SceneTree, at: Vector3, yards: Array, damage: Array) -> void:
	var reach := float(yards[yards.size() - 1]) * Lethality.YARD
	for casualty: Array in Lethality.casualties_near(tree, at, reach, TARGET_HEIGHT):
		var dealt := Lethality.banded(casualty[2], yards, damage)
		if dealt > 0.0:
			casualty[0].take_damage(
				dealt, casualty[1], (casualty[1] - at).normalized(), Lethality.BLAST
			)


## Chews the ground out to `crater_yards`, block by block, so the hole falls
## away with distance the same way the casualties do.
##
## That reach is deliberately kept well inside the blast's own: past the first
## band the numbers are noise against a block's thousand health, and the cell
## loop grows with the cube of it.
static func crater(
	tree: SceneTree, at: Vector3, yards: Array, damage: Array, crater_yards: float
) -> void:
	var world: Node = tree.get_first_node_in_group("voxel_world")
	if world == null:
		return

	var reach_m := crater_yards * Lethality.YARD
	var reach := int(ceil(reach_m / VoxelWorld.BLOCK))
	var centre: Vector3i = world.world_to_grid(at)
	for dx in range(-reach, reach + 1):
		for dy in range(-reach, reach + 1):
			for dz in range(-reach, reach + 1):
				var gx: int = centre.x + dx
				var gy: int = centre.y + dy
				var gz: int = centre.z + dz
				# Integer reject first: this throws out the corners of the cube
				# without a single call into the world, which is a little under
				# half of every cell walked.
				if dx * dx + dy * dy + dz * dz > reach * reach:
					continue
				if not world.in_bounds(gx, gy, gz):
					continue
				if world.block_at(gx, gy, gz) == VoxelWorld.AIR:
					continue
				var distance := at.distance_to(world.grid_to_world(gx, gy, gz))
				if distance > reach_m:
					continue
				var dealt := Lethality.banded(distance, yards, damage)
				if dealt > 0.0:
					world.damage_grid_block(gx, gy, gz, dealt)


## Flash and bang. `rumble` adds a slower, deeper copy of the sample a beat
## behind the crack: one voice on its own reads as a pop from any distance,
## where the pair reads as something large going off.
static func effect(
	scene_root: Node,
	at: Vector3,
	light_energy: float,
	light_range: float,
	volume_db: float,
	rumble := false
) -> void:
	if scene_root == null or not scene_root.is_inside_tree():
		return

	var light := OmniLight3D.new()
	scene_root.add_child(light)
	light.global_position = at
	light.light_color = Color(1.0, 0.75, 0.41)
	light.light_energy = light_energy
	light.omni_range = maxf(light_range, 1.0)
	var fade := light.create_tween()
	fade.tween_property(light, "light_energy", 0.0, 0.45)
	fade.tween_callback(light.queue_free)

	_voice(scene_root, at, randf_range(0.92, 1.06), volume_db, 0.0)
	if rumble:
		_voice(scene_root, at, 0.42, volume_db - 2.0, 0.06)


## One voice of a burst. `delay` is in seconds, so the rumble can trail the
## crack without either needing to be a separate asset.
static func _voice(
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
		scene_root.get_tree().create_timer(delay).timeout.connect(sound.play)
	else:
		sound.play()


## Rattles every view in the game. Deliberately not scaled by distance: this is
## for charges big enough that the whole field feels them go, and a shake that
## faded with range would just be a worse version of the sound doing that job.
static func shake(tree: SceneTree, radians: float) -> void:
	tree.call_group(VIEWERS, "shake_view", radians)
