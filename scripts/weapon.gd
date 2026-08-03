class_name Weapon
extends Equipment

## Hitscan automatic weapon. Owns fire timing, the raycast, recoil impulses and
## its own visual kick; the player applies the camera recoil it emits.

@export_group("Ballistics")
## Thompson M1928A1 ran roughly 700rpm.
@export var rounds_per_minute := 700.0
@export var damage := 12.0
@export var max_range := 120.0

@export_group("Accuracy")
## Cone half-angle when fully settled, in degrees.
@export var min_spread := 0.25
## Cone half-angle at full bloom, in degrees.
@export var max_spread := 4.0
## Bloom added per shot, as a fraction of the min..max range.
@export var bloom_per_shot := 0.14
## Bloom fraction recovered per second.
@export var bloom_recovery := 0.9

@export_group("Recoil")
@export var recoil_pitch := 0.55
@export var recoil_yaw := 0.22
## Metres the viewmodel slides back per shot.
@export var kick_back := 0.035
@export var kick_recovery := 12.0

@export_group("Aim")
## Seconds to raise or lower the weapon.
@export var aim_time := 0.16
## Spread multiplier at full aim.
@export var aim_spread_factor := 0.25
## Recoil multiplier at full aim.
@export var aim_recoil_factor := 0.35
## Bloom-per-shot multiplier while aiming: sighted fire walks off target slower.
@export var aim_bloom_factor := 0.4

@export_group("Ammo")
@export var magazine_size := 50
@export var reserve_ammo := 150
@export var reload_time := 2.6

const FLASH_TIME := 0.045
const MAX_BULLET_HOLES := 64

const GUNSHOT: AudioStream = preload("res://assets/audio/gunshot.wav")
const MAG_OUT: AudioStream = preload("res://assets/audio/mag_out.wav")
const MAG_IN: AudioStream = preload("res://assets/audio/mag_in.wav")
const BOLT: AudioStream = preload("res://assets/audio/bolt.wav")
const BULLET_HOLE: PackedScene = preload("res://scenes/bullet_hole.tscn")

# Reload pose, in weapon-local space. The cant rolls the underside toward the
# camera (which sits inboard of the weapon) so the mag well comes into view.
const CANT_OFFSET := Vector3(-0.05, -0.06, 0.04)
const CANT_TILT_DEG := Vector3(-12.0, 14.0, -25.0)
# Left-hand waypoints, as offsets from its resting spot on the foregrip.
const HAND_TO_MAG := Vector3(0.0, -0.06, 0.21)
const HAND_OFFSCREEN := Vector3(0.02, -0.3, 0.28)
const HAND_WITH_MAG := Vector3(0.0, -0.1, 0.2)
const HAND_TO_BOLT := Vector3(0.0, 0.1, 0.235)
const MAG_DROP := Vector3(0.0, -0.28, 0.02)
const BOLT_PULL := Vector3(0.0, 0.0, 0.055)

@onready var muzzle: Marker3D = $Muzzle
@onready var muzzle_flash: MeshInstance3D = $Muzzle/MuzzleFlash
@onready var flash_light: OmniLight3D = $Muzzle/FlashLight
@onready var fire_sound: AudioStreamPlayer = $FireSound
@onready var reload_sound: AudioStreamPlayer = $ReloadSound
@onready var drum: MeshInstance3D = $DrumMag
@onready var bolt_handle: MeshInstance3D = $BoltHandle
@onready var rear_sight: Node3D = $RearSight
@onready var front_sight: Node3D = $FrontSight

var in_magazine := 0
var is_reloading := false

var _rest_position := Vector3.ZERO
var _rest_rotation := Vector3.ZERO
var _drum_rest := Vector3.ZERO
var _bolt_rest := Vector3.ZERO

var _cooldown := 0.0
var _flash_timer := 0.0
var _bloom := 0.0
# Firing kick and the reload pose both displace the weapon, so they are kept
# separate and summed in _process rather than either one writing `position`.
var _kick := Vector3.ZERO
var _reload_offset := Vector3.ZERO
var _reload_tilt := Vector3.ZERO
var _reload_tween: Tween

var _aim := 0.0
var _aim_held := false
var _aim_position := Vector3.ZERO
var _aim_rotation := Vector3.ZERO

var _starting_reserve := 0
var _shooter: CollisionObject3D
var _holes: Array[Node3D] = []


func _ready() -> void:
	_rest_position = position
	_rest_rotation = rotation
	_drum_rest = drum.position
	_bolt_rest = bolt_handle.position
	in_magazine = magazine_size
	_starting_reserve = reserve_ammo
	_shooter = _find_ancestor_body()


## Fraction of the way from min to max spread, for the HUD crosshair.
func spread_ratio() -> float:
	return _bloom


## 0 = hip, 1 = fully sighted. Drives FOV, sensitivity and the crosshair fade.
func aim_ratio() -> float:
	return _aim


func set_aiming(aiming: bool) -> void:
	_aim_held = aiming


## Local transform, relative to the camera, that puts this weapon's rear and
## front sights on the camera's centre line with the rear sight `relief` metres
## from the eye. Derived from the sight nodes, so any weapon carrying a
## RearSight and FrontSight aims correctly without hand-tuned numbers.
func sight_transform(relief: float) -> Transform3D:
	var rear := rear_sight.position
	var axis := (front_sight.position - rear).normalized()
	# Shortest-arc rotation taking the sight line onto the camera's forward axis.
	var basis := Basis(Quaternion(axis, Vector3.FORWARD))
	return Transform3D(basis, Vector3(0.0, 0.0, -relief) - basis * rear)


## Called once by whoever owns the socket, which knows how to convert the
## camera-relative sight pose into this weapon's local space.
func set_aim_pose(pose: Transform3D) -> void:
	_aim_position = pose.origin
	_aim_rotation = pose.basis.get_euler()


func try_fire() -> bool:
	if is_reloading or _cooldown > 0.0:
		return false
	if in_magazine <= 0:
		reload()
		return false

	in_magazine -= 1
	_cooldown = 60.0 / rounds_per_minute
	_raycast()
	_show_flash()
	_play(fire_sound, GUNSHOT, randf_range(0.94, 1.06), 0.0)

	_kick.z += kick_back
	_bloom = minf(_bloom + bloom_per_shot * lerpf(1.0, aim_bloom_factor, _aim), 1.0)
	var recoil_scale := lerpf(1.0, aim_recoil_factor, _aim)
	fired.emit(
		deg_to_rad(recoil_pitch) * randf_range(0.8, 1.2) * recoil_scale,
		deg_to_rad(recoil_yaw) * randf_range(-1.0, 1.0) * recoil_scale
	)
	return true


func reload() -> void:
	if is_reloading or in_magazine >= magazine_size or reserve_ammo <= 0:
		return
	is_reloading = true
	_run_reload_animation()


func restock() -> void:
	if _reload_tween != null and _reload_tween.is_valid():
		_reload_tween.kill()
	is_reloading = false
	_finish_reload_state()
	in_magazine = magazine_size
	reserve_ammo = _starting_reserve


func status_text() -> String:
	return "RELOADING" if is_reloading else "%d / %d" % [in_magazine, reserve_ammo]


func is_empty() -> bool:
	return in_magazine <= 0 and not is_reloading


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	_bloom = maxf(_bloom - bloom_recovery * delta, 0.0)

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			muzzle_flash.visible = false
			flash_light.visible = false

	# Sights cannot be used mid-reload; the reload animation owns the pose.
	var aim_target := 1.0 if (_aim_held and not is_reloading) else 0.0
	_aim = move_toward(_aim, aim_target, delta / maxf(aim_time, 0.001))

	_kick = _kick.lerp(Vector3.ZERO, minf(kick_recovery * delta, 1.0))
	position = _rest_position.lerp(_aim_position, _aim) + _kick + _reload_offset
	rotation = _rest_rotation.lerp(_aim_rotation, _aim) + _reload_tilt


## Keyframed timeline for the reload. Every delay is a fraction of
## `reload_time`, so retuning the duration rescales the whole sequence.
func _run_reload_animation() -> void:
	if _reload_tween != null and _reload_tween.is_valid():
		_reload_tween.kill()

	var t := reload_time
	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_reload_tween = tween

	# Cant the weapon down and inboard, left hand leaves the foregrip.
	tween.tween_property(self, "_reload_offset", CANT_OFFSET, t * 0.18)
	tween.tween_property(self, "_reload_tilt", _cant_tilt(), t * 0.18)
	tween.tween_property(self, "left_hand_offset", HAND_TO_MAG, t * 0.18)

	# Drum releases and falls away.
	tween.tween_callback(_play.bind(reload_sound, MAG_OUT, 1.0, -3.0)).set_delay(t * 0.2)
	tween.tween_property(drum, "position", _drum_rest + MAG_DROP, t * 0.18).set_delay(t * 0.2)
	tween.tween_callback(drum.hide).set_delay(t * 0.4)

	# Hand dips out of frame for a fresh drum, then rides it back up.
	tween.tween_property(self, "left_hand_offset", HAND_OFFSCREEN, t * 0.22).set_delay(t * 0.22)
	tween.tween_callback(_present_fresh_drum).set_delay(t * 0.46)
	tween.tween_property(drum, "position", _drum_rest, t * 0.21).set_delay(t * 0.47)
	tween.tween_property(self, "left_hand_offset", HAND_WITH_MAG, t * 0.2).set_delay(t * 0.48)
	tween.tween_callback(_play.bind(reload_sound, MAG_IN, 1.0, -3.0)).set_delay(t * 0.68)

	# Level the weapon; left hand goes over the top to the bolt.
	tween.tween_property(self, "_reload_offset", Vector3.ZERO, t * 0.24).set_delay(t * 0.7)
	tween.tween_property(self, "_reload_tilt", Vector3.ZERO, t * 0.24).set_delay(t * 0.7)
	tween.tween_property(self, "left_hand_offset", HAND_TO_BOLT, t * 0.16).set_delay(t * 0.7)

	# Charge the bolt, then back to the foregrip.
	tween.tween_property(bolt_handle, "position", _bolt_rest + BOLT_PULL, t * 0.06) \
		.set_delay(t * 0.84)
	tween.tween_callback(_play.bind(reload_sound, BOLT, 1.0, -5.0)).set_delay(t * 0.9)
	tween.tween_property(bolt_handle, "position", _bolt_rest, t * 0.05).set_delay(t * 0.9)
	tween.tween_property(self, "left_hand_offset", Vector3.ZERO, t * 0.12).set_delay(t * 0.88)

	tween.tween_callback(_finish_reload).set_delay(t)


func _cant_tilt() -> Vector3:
	return Vector3(
		deg_to_rad(CANT_TILT_DEG.x), deg_to_rad(CANT_TILT_DEG.y), deg_to_rad(CANT_TILT_DEG.z)
	)


func _present_fresh_drum() -> void:
	drum.position = _drum_rest + MAG_DROP
	drum.show()


func _finish_reload() -> void:
	var needed := magazine_size - in_magazine
	var loaded := mini(needed, reserve_ammo)
	in_magazine += loaded
	reserve_ammo -= loaded
	is_reloading = false
	_finish_reload_state()


## Snaps every animated part back to rest, shared by finishing and restocking.
func _finish_reload_state() -> void:
	_reload_offset = Vector3.ZERO
	_reload_tilt = Vector3.ZERO
	left_hand_offset = Vector3.ZERO
	drum.position = _drum_rest
	bolt_handle.position = _bolt_rest
	drum.show()


func _raycast() -> void:
	# Resolved per shot rather than cached: the active camera changes when the
	# player switches between first and third person.
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	# Fire from the camera, not the muzzle, so the shot goes where the
	# crosshair points regardless of where the viewmodel sits.
	var origin := camera.global_position
	var spread := deg_to_rad(lerpf(min_spread, max_spread, _bloom)) * lerpf(
		1.0, aim_spread_factor, _aim
	)
	var direction := -camera.global_basis.z
	direction = direction.rotated(
		camera.global_basis.x, randf_range(-spread, spread)
	).rotated(
		camera.global_basis.y, randf_range(-spread, spread)
	)

	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_range)
	if _shooter != null:
		query.exclude = [_shooter.get_rid()]

	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return

	var target: Object = hit.collider
	if target != null and target.has_method("take_damage"):
		target.take_damage(damage, hit.position, -direction)
		return

	_spawn_hole(hit.position, hit.normal)


func _spawn_hole(hit_position: Vector3, normal: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var hole := BULLET_HOLE.instantiate() as Node3D
	scene_root.add_child(hole)
	# Nudge off the surface so the decal doesn't z-fight with the wall, and
	# jitter the depth so overlapping holes don't z-fight with each other.
	var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var basis := Basis.looking_at(-normal, up).rotated(normal, randf_range(0.0, TAU))
	hole.global_transform = Transform3D(
		basis, hit_position + normal * randf_range(0.006, 0.012)
	)

	# Holes also expire on their own lifetime timer, so let the node tell us when
	# it goes away. Without this the array accumulates freed instances and
	# popping one below fails on the typed assignment.
	_holes.append(hole)
	hole.tree_exited.connect(_on_hole_removed.bind(hole))

	while _holes.size() > MAX_BULLET_HOLES:
		var oldest: Node3D = _holes.pop_front()
		oldest.queue_free()


func _on_hole_removed(hole: Node3D) -> void:
	_holes.erase(hole)


func _show_flash() -> void:
	muzzle_flash.rotation.z = randf_range(0.0, TAU)
	muzzle_flash.visible = true
	flash_light.visible = true
	_flash_timer = FLASH_TIME


func _play(player: AudioStreamPlayer, stream: AudioStream, pitch: float, volume_db: float) -> void:
	player.stream = stream
	player.pitch_scale = pitch
	player.volume_db = volume_db
	player.play()


func _find_ancestor_body() -> CollisionObject3D:
	var node := get_parent()
	while node != null:
		if node is CollisionObject3D:
			return node
		node = node.get_parent()
	return null
