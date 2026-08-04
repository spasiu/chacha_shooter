class_name Grenade
extends Equipment

## Held fragmentation grenade. Throwing is a timed animation: the projectile
## leaves the hand partway through, and a fresh grenade appears afterwards if
## any remain.

@export var count := 3
## Throw velocity from the hip. Raising it adds `aim_throw_bonus`.
@export var throw_speed := 15.0
@export var aim_throw_bonus := 6.0
## Upward bias added to the camera direction, before normalising.
@export var throw_arc := 0.28
@export var throw_time := 0.5
## Fraction of the animation at which the grenade actually leaves the hand.
@export var release_at := 0.38
@export var raise_time := 0.18
## Total fuse carried by the grenade. Time spent cooking in hand comes off
## what is left once it is in flight. Matches the projectile's own default
## so an uncooked throw behaves the same as before.
@export var fuse_time := 2.6
## How far the grenade is raised while the fuse burns.
@export var cook_offset := Vector3(0.03, 0.05, 0.09)
@export var projectile_scene: PackedScene

const PIN_PULL: AudioStream = preload("res://assets/audio/pin_pull.wav")

@onready var body: Node3D = $Body
@onready var throw_sound: AudioStreamPlayer = $ThrowSound

var _aim := 0.0
var _aim_held := false
var _throwing := false
var _throw_tween: Tween
var _cooking := false
var _cook_time := 0.0
## Whether the trigger has gone down and not yet come back up. One pull is one
## grenade: without this, holding on through a cook-off in the hand pulls the
## pin on the next one straight away, and so on until you run out or die.
var _pulled := false
var _starting_count := 0
var _rest_position := Vector3.ZERO
var _aim_position := Vector3.ZERO
var _aim_rotation := Vector3.ZERO
var _anim_offset := Vector3.ZERO
var _anim_tilt := Vector3.ZERO


func _ready() -> void:
	_rest_position = position
	_starting_count = count


## Which of Net's projectiles this throws, so everyone else can spawn a copy of
## the right thing. Smoke is the same grenade with a different canister on the
## end of it, and says so by overriding this.
func net_projectile_kind() -> int:
	return Net.PROJECTILE_GRENADE


func restock() -> void:
	count = _starting_count
	on_holstered()


## Pressing pulls the pin and starts the fuse; the throw happens on release.
func try_fire() -> bool:
	var held := _pulled
	_pulled = true
	if held or _throwing or _cooking or count <= 0:
		return false
	_cooking = true
	_cook_time = 0.0
	throw_sound.stream = PIN_PULL
	throw_sound.play()
	return true


func release_trigger() -> void:
	_pulled = false
	if not _cooking:
		return
	_cooking = false
	_throwing = true
	_run_throw()


func is_busy() -> bool:
	return _cooking or _throwing


## Seconds of fuse left, for the HUD.
func fuse_remaining() -> float:
	return maxf(fuse_time - _cook_time, 0.0)


func set_aiming(aiming: bool) -> void:
	_aim_held = aiming


func aim_ratio() -> float:
	return _aim


func status_text() -> String:
	if _cooking:
		return "COOKING  %.1f" % fuse_remaining()
	return "GRENADES  %d" % count


func is_empty() -> bool:
	return count <= 0


func is_full() -> bool:
	return count >= _starting_count


## No sights to align; raising simply brings the grenade up and inboard ready
## for an overhand throw.
func sight_transform(_relief: float) -> Transform3D:
	return Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-12.0)), Vector3(0.08, -0.12, -0.34))


func set_aim_pose(pose: Transform3D) -> void:
	_aim_position = pose.origin
	_aim_rotation = pose.basis.get_euler()


func on_holstered() -> void:
	# Never leave a half-finished throw pose behind when switching away. The
	# tween has to die first or it keeps writing over the reset.
	if _throw_tween != null and _throw_tween.is_valid():
		_throw_tween.kill()
	_cooking = false
	_cook_time = 0.0
	_pulled = false
	_throwing = false
	_anim_offset = Vector3.ZERO
	_anim_tilt = Vector3.ZERO
	left_hand_offset = Vector3.ZERO
	body.visible = count > 0


func _process(delta: float) -> void:
	if _cooking:
		_cook_time += delta
		# Held too long and it goes off in your hand.
		if _cook_time >= fuse_time:
			_cook_off_in_hand()
		else:
			_anim_offset = _anim_offset.lerp(cook_offset, minf(delta * 9.0, 1.0))

	var target := 1.0 if (_aim_held and not _throwing) else 0.0
	_aim = move_toward(_aim, target, delta / maxf(raise_time, 0.001))
	position = _rest_position.lerp(_aim_position, _aim) + _anim_offset
	rotation = _anim_tilt


## Detonates where it is being held. Entirely the player's fault.
func _cook_off_in_hand() -> void:
	_cooking = false
	_cook_time = 0.0
	count = maxi(count - 1, 0)
	body.visible = count > 0
	_anim_offset = Vector3.ZERO

	var scene_root := get_tree().current_scene
	if scene_root == null or projectile_scene == null:
		return
	var live := projectile_scene.instantiate() as RigidBody3D
	live.fuse_time = 0.02
	scene_root.add_child(live)
	live.global_position = global_position
	live.freeze = true
	Net.report_projectile(net_projectile_kind(), live.global_position, Vector3.ZERO, 0.02)


func _run_throw() -> void:
	var t := throw_time
	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_throw_tween = tween

	# Wind up back and down, then whip forward.
	tween.tween_property(self, "_anim_offset", Vector3(0.04, -0.10, 0.16), t * release_at * 0.7)
	tween.tween_property(self, "_anim_tilt", Vector3(deg_to_rad(38.0), 0.0, 0.0),
		t * release_at * 0.7)
	tween.tween_property(self, "_anim_offset", Vector3(-0.05, 0.10, -0.26), t * 0.22) \
		.set_delay(t * release_at * 0.7)
	tween.tween_property(self, "_anim_tilt", Vector3(deg_to_rad(-26.0), 0.0, 0.0), t * 0.22) \
		.set_delay(t * release_at * 0.7)

	tween.tween_callback(_release).set_delay(t * release_at)
	tween.tween_property(self, "_anim_offset", Vector3.ZERO, t * 0.35).set_delay(t * 0.62)
	tween.tween_property(self, "_anim_tilt", Vector3.ZERO, t * 0.35).set_delay(t * 0.62)
	tween.tween_callback(_finish_throw).set_delay(t)


func _release() -> void:
	body.visible = false
	count = maxi(count - 1, 0)

	var camera := get_viewport().get_camera_3d()
	var scene_root := get_tree().current_scene
	if camera == null or scene_root == null or projectile_scene == null:
		return

	var forward := -camera.global_basis.z
	var direction := (forward + Vector3.UP * throw_arc).normalized()
	var projectile := projectile_scene.instantiate() as RigidBody3D
	projectile.fuse_time = maxf(fuse_time - _cook_time, 0.25)
	scene_root.add_child(projectile)
	# Clear of the player's own capsule so it does not immediately collide.
	projectile.global_position = camera.global_position + forward * 0.5
	var thrower := _find_ancestor_body()
	if thrower != null:
		projectile.add_collision_exception_with(thrower)
	projectile.linear_velocity = direction * (throw_speed + aim_throw_bonus * _aim)
	# Just enough tumble to look thrown, not enough to roll away on landing.
	projectile.angular_velocity = Vector3(
		randf_range(-2.5, 2.5), randf_range(-1.5, 1.5), randf_range(-1.0, 1.0)
	)
	# Everyone else gets a copy thrown from the same place at the same speed.
	# It will not land in exactly the same spot as this one -- two physics
	# engines never quite agree -- but it does not have to: only this copy
	# decides anything, and the rest are there to be watched.
	Net.report_projectile(
		net_projectile_kind(), projectile.global_position,
		projectile.linear_velocity, projectile.fuse_time
	)

	fired.emit(deg_to_rad(1.4), deg_to_rad(randf_range(-0.4, 0.4)))


func _finish_throw() -> void:
	_throwing = false
	_cook_time = 0.0
	_anim_offset = Vector3.ZERO
	_anim_tilt = Vector3.ZERO
	body.visible = count > 0


func _find_ancestor_body() -> CollisionObject3D:
	var node := get_parent()
	while node != null:
		if node is CollisionObject3D:
			return node
		node = node.get_parent()
	return null
