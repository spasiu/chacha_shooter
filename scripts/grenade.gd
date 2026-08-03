class_name Grenade
extends Equipment

## Held fragmentation grenade. Throwing is a timed animation: the projectile
## leaves the hand partway through, and a fresh grenade appears afterwards if
## any remain.

@export var count := 10
## Throw velocity from the hip. Raising it adds `aim_throw_bonus`.
@export var throw_speed := 15.0
@export var aim_throw_bonus := 6.0
## Upward bias added to the camera direction, before normalising.
@export var throw_arc := 0.28
@export var throw_time := 0.5
## Fraction of the animation at which the grenade actually leaves the hand.
@export var release_at := 0.38
@export var raise_time := 0.18
@export var projectile_scene: PackedScene

const PIN_PULL: AudioStream = preload("res://assets/audio/pin_pull.wav")

@onready var body: Node3D = $Body
@onready var throw_sound: AudioStreamPlayer = $ThrowSound

var _aim := 0.0
var _aim_held := false
var _throwing := false
var _throw_tween: Tween
var _starting_count := 0
var _rest_position := Vector3.ZERO
var _aim_position := Vector3.ZERO
var _aim_rotation := Vector3.ZERO
var _anim_offset := Vector3.ZERO
var _anim_tilt := Vector3.ZERO


func _ready() -> void:
	_rest_position = position
	_starting_count = count


func restock() -> void:
	count = _starting_count
	on_holstered()


func try_fire() -> bool:
	if _throwing or count <= 0:
		return false
	_throwing = true
	throw_sound.stream = PIN_PULL
	throw_sound.play()
	_run_throw()
	return true


func set_aiming(aiming: bool) -> void:
	_aim_held = aiming


func aim_ratio() -> float:
	return _aim


func status_text() -> String:
	return "GRENADES  %d" % count


func is_empty() -> bool:
	return count <= 0


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
	_throwing = false
	_anim_offset = Vector3.ZERO
	_anim_tilt = Vector3.ZERO
	left_hand_offset = Vector3.ZERO
	body.visible = count > 0


func _process(delta: float) -> void:
	var target := 1.0 if (_aim_held and not _throwing) else 0.0
	_aim = move_toward(_aim, target, delta / maxf(raise_time, 0.001))
	position = _rest_position.lerp(_aim_position, _aim) + _anim_offset
	rotation = _anim_tilt


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
	scene_root.add_child(projectile)
	# Clear of the player's own capsule so it does not immediately collide.
	projectile.global_position = camera.global_position + forward * 0.5
	var thrower := _find_ancestor_body()
	if thrower != null:
		projectile.add_collision_exception_with(thrower)
	projectile.linear_velocity = direction * (throw_speed + aim_throw_bonus * _aim)
	projectile.angular_velocity = Vector3(randf_range(-8.0, 8.0), randf_range(-4.0, 4.0), 0.0)

	fired.emit(deg_to_rad(1.4), deg_to_rad(randf_range(-0.4, 0.4)))


func _finish_throw() -> void:
	_throwing = false
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
