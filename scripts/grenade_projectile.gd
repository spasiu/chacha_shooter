extends RigidBody3D

## Thrown fragmentation grenade. On detonation it casts a dense sphere of
## individual fragment rays rather than applying damage in a radius, so cover
## genuinely stops fragments and damage falls off by solid angle: the further
## away a target is, the fewer fragments happen to intersect it.

@export var fuse_time := 2.6
## More fragments means a denser pattern and therefore lethality further out.
## Each ray costs ~8us, so this is a direct trade of pattern density against a
## one-frame hitch on detonation. count x damage is what sets lethality.
@export var fragment_count := 900
@export var fragment_damage := 16.0
@export var fragment_range := 16.0
## Leave an impact mark for every Nth fragment, so the ground is not carpeted.
@export var decal_every := 45

## Roughly half the mean angular spacing between fragments.
const JITTER := 0.03

const EXPLOSION: AudioStream = preload("res://assets/audio/explosion.wav")
const BULLET_HOLE: PackedScene = preload("res://scenes/bullet_hole.tscn")

@onready var mesh: Node3D = $Body
@onready var flash: MeshInstance3D = $Flash
@onready var flash_light: OmniLight3D = $FlashLight
@onready var sound: AudioStreamPlayer3D = $Sound

var _exploded := false


func _ready() -> void:
	flash.visible = false
	flash_light.visible = false
	get_tree().create_timer(fuse_time).timeout.connect(explode)


func explode() -> void:
	if _exploded:
		return
	_exploded = true

	_spray_fragments()

	mesh.visible = false
	freeze = true
	$CollisionShape3D.set_deferred("disabled", true)
	flash.visible = true
	flash_light.visible = true
	sound.stream = EXPLOSION
	sound.play()

	var tween := create_tween().set_parallel(true)
	tween.tween_property(flash_light, "light_energy", 0.0, 0.22)
	tween.tween_property(flash, "scale", Vector3.ONE * 2.4, 0.18)
	tween.chain().tween_callback(flash.hide)
	# Outlive the blast so the sound is not cut off.
	get_tree().create_timer(2.0).timeout.connect(queue_free)


func _spray_fragments() -> void:
	var space := get_world_3d().direct_space_state
	var origin := global_position
	# collider -> [accumulated damage, first hit position, first direction]
	var casualties := {}
	var decals := 0

	for i in fragment_count:
		var direction := _fragment_direction(i)
		var query := PhysicsRayQueryParameters3D.create(
			origin, origin + direction * fragment_range
		)
		query.exclude = [get_rid()]
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue

		var collider: Object = hit.collider
		if collider != null and collider.has_method("take_damage"):
			if casualties.has(collider):
				casualties[collider][0] += fragment_damage
			else:
				casualties[collider] = [fragment_damage, hit.position, direction]
		elif i % decal_every == 0 and decals < 32:
			decals += 1
			_spawn_decal(hit.position, hit.normal)

	# One call per victim with the summed damage, so a body takes a single
	# flinch and a single sound rather than dozens.
	for collider: Object in casualties:
		if not is_instance_valid(collider):
			continue
		var entry: Array = casualties[collider]
		collider.take_damage(entry[0], entry[1], -entry[2])


## Fibonacci sphere: even coverage without the clumping random directions give.
## A little jitter on top, so two grenades in the same spot are not identical
## and a target's damage does not hinge on exact pattern alignment.
func _fragment_direction(index: int) -> Vector3:
	var offset := 2.0 / fragment_count
	var increment := PI * (3.0 - sqrt(5.0))
	var y := ((index * offset) - 1.0) + (offset * 0.5)
	var radius := sqrt(maxf(1.0 - y * y, 0.0))
	var phi := index * increment
	var dir := Vector3(cos(phi) * radius, y, sin(phi) * radius)
	dir += Vector3(
		randf_range(-JITTER, JITTER), randf_range(-JITTER, JITTER), randf_range(-JITTER, JITTER)
	)
	return dir.normalized()


func _spawn_decal(at: Vector3, normal: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var hole := BULLET_HOLE.instantiate() as Node3D
	scene_root.add_child(hole)
	var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	hole.global_transform = Transform3D(
		Basis.looking_at(-normal, up), at + normal * randf_range(0.006, 0.012)
	)
