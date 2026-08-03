extends CharacterBody3D

signal health_changed(current: float, maximum: float)
signal died


## Default gait: the character runs unless something slows them down.
@export var run_speed := 8.5
## Drops to this while shooting, and briefly after.
@export var walk_speed := 5.0
## Sighted movement is a shuffle.
@export var shuffle_speed := 1.8
## How long after a shot the walk restriction lingers.
@export var shooting_walk_time := 0.35
@export var jump_velocity := 4.5
@export var mouse_sensitivity := 0.002
@export var acceleration := 12.0

@export_group("Health")
@export var max_health := 100.0
## Speed of descent below which landing is harmless, in m/s.
@export var safe_fall_speed := 14.0
## Damage per m/s of impact beyond the safe threshold.
@export var fall_damage_per_speed := 6.0
## Seconds face-down before respawning at the start point.
@export var respawn_delay := 4.0

@export_group("Aim")
@export var aim_fov := 55.0
## Mouse sensitivity multiplier while sighted.
@export var aim_sensitivity := 0.55

@export_group("Crouch")
@export var crouch_speed := 2.2
## How far the eye drops when crouched; the capsule shortens by the same amount.
@export var crouch_drop := 0.35
## Crouch blend rate, per second.
@export var crouch_transition := 8.0

## Metres of ground travel between footsteps. Cadence scales with speed on its
## own, so running steps more often without a separate interval.
@export var stride_length := 2.0

## How fast the view settles back after weapon recoil, per second.
@export var recoil_recovery := 7.0

## Fraction of the aim pitch the third-person torso copies, so the weapon
## tracks roughly where you are aiming without the whole body tipping over.
@export var spine_pitch_ratio := 0.6

const PITCH_LIMIT := deg_to_rad(89.0)
const MIN_STEP_SPEED := 0.5
## Footfalls sit well under the weapon; landing is 4dB above a normal step.
const STEP_VOLUME_DB := -10.0

const FOOTSTEPS: Array[AudioStream] = [
	preload("res://assets/audio/footstep_01.wav"),
	preload("res://assets/audio/footstep_02.wav"),
	preload("res://assets/audio/footstep_03.wav"),
	preload("res://assets/audio/footstep_04.wav"),
]
const LAND_SOUND: AudioStream = preload("res://assets/audio/land.wav")

@onready var head: Node3D = $Head
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var step_player: AudioStreamPlayer = $StepPlayer
@onready var thompson: Equipment = $Head/Camera3D/WeaponSocket/WeaponThompson
@onready var grenade: Equipment = $Head/Camera3D/WeaponSocket/WeaponGrenade
@onready var camera_fp: Camera3D = $Head/Camera3D
@onready var camera_tp: Camera3D = $Head/SpringArm3D/CameraTP
@onready var spring_arm: SpringArm3D = $Head/SpringArm3D
@onready var socket_fp: Node3D = $Head/Camera3D/WeaponSocket
@onready var viewmodel: ArmRig = $Head/Camera3D/ViewmodelArms
@onready var body_model: CharacterModel = $BodyModel
@onready var body_spine: Node3D = $BodyModel/Spine
@onready var body_arms: ArmRig = $BodyModel/Spine/Arms
@onready var socket_tp: Node3D = $BodyModel/Spine/WeaponSocket

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Where the player is actually aiming, before recoil is layered on top.
var _aim_yaw := 0.0
var _aim_pitch := 0.0
var _recoil_pitch := 0.0
var _recoil_yaw := 0.0

var _stride_accum := 0.0
var _last_step := -1
var _third_person := false
## Toggled by the crouch key; `_crouch` is its smoothed 0..1 form.
var _crouching := false
var _crouch := 0.0
var _head_rest_y := 0.0
var _stand_height := 0.0
var _rest_fov := 75.0
var health := 0.0
var _dead := false
var _spawn_transform := Transform3D.IDENTITY
var _death_tween: Tween
# Alternates each footfall so the gait phase runs 0..2PI over two steps, which
# lands each footplant exactly on its footstep sound.
var _step_parity := false
var _shoot_recency := 0.0
## Everything the player can hold; index 0 is slot 1.
var loadout: Array[Equipment] = []
var weapon: Equipment
var _slot := -1


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_head_rest_y = head.position.y
	_stand_height = (collision_shape.shape as CapsuleShape3D).height
	_rest_fov = camera_fp.fov
	health = max_health
	health_changed.emit(health, max_health)
	_spawn_transform = global_transform
	_aim_yaw = rotation.y
	loadout = [thompson, grenade]
	# Keep the camera from clipping into our own capsule.
	spring_arm.add_excluded_object(get_rid())
	# Both rigs grip the same weapon node, whichever socket it currently hangs
	# from, so they keep working across a reparent.
	viewmodel.set_weapon(weapon)
	body_arms.set_weapon(weapon)
	# Viewmodel arms sit at the camera; their shadow would be nonsense.
	_set_shadows(viewmodel, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_equip(0)
	_apply_view()


func _unhandled_input(event: InputEvent) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

	if event is InputEventMouseMotion and captured:
		# Sighted aiming slows the turn rate in proportion to the zoom.
		var sens := mouse_sensitivity * lerpf(1.0, aim_sensitivity, weapon.aim_ratio())
		_aim_yaw -= event.relative.x * sens
		_aim_pitch = clampf(
			_aim_pitch - event.relative.y * sens, -PITCH_LIMIT, PITCH_LIMIT
		)
	elif event.is_action_pressed("slot_1"):
		_equip(0)
	elif event.is_action_pressed("slot_2"):
		_equip(1)
	elif event.is_action_pressed("crouch"):
		_crouching = not _crouching
	elif event.is_action_pressed("toggle_view"):
		_third_person = not _third_person
		_apply_view()
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and not captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	if _dead:
		# The death tween owns the camera; leave it alone.
		return

	# Recoil decays toward zero and is layered on top of the aim angles, so a
	# kick never permanently drags the player's aim off target.
	var settle := minf(recoil_recovery * delta, 1.0)
	_recoil_pitch = lerpf(_recoil_pitch, 0.0, settle)
	_recoil_yaw = lerpf(_recoil_yaw, 0.0, settle)

	rotation.y = _aim_yaw + _recoil_yaw
	var pitch := clampf(_aim_pitch + _recoil_pitch, -PITCH_LIMIT, PITCH_LIMIT)
	head.rotation.x = pitch
	body_model.spine_pitch = pitch * spine_pitch_ratio if _third_person else 0.0

	# Aim state is evaluated even when the mouse is released, so letting go of
	# the cursor lowers the weapon instead of leaving it stuck sighted.
	# Iron sights are first-person only; the pose is solved against the camera.
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	weapon.set_aiming(captured and not _third_person and Input.is_action_pressed("aim"))
	camera_fp.fov = lerpf(_rest_fov, aim_fov, weapon.aim_ratio())

	if not captured:
		return
	if Input.is_action_pressed("shoot"):
		if weapon.try_fire():
			_shoot_recency = shooting_walk_time
	if Input.is_action_just_pressed("reload"):
		weapon.reload()


func _physics_process(delta: float) -> void:
	if _dead:
		# Still fall, but take no input and make no footfalls.
		if not is_on_floor():
			velocity.y -= gravity * delta
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	_shoot_recency = maxf(_shoot_recency - delta, 0.0)
	_update_crouch(delta)
	var was_on_floor := is_on_floor()
	var fall_speed := velocity.y

	if not was_on_floor:
		velocity.y -= gravity * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed := _current_speed()

	var target := direction * speed
	velocity.x = move_toward(velocity.x, target.x, acceleration * delta * speed)
	velocity.z = move_toward(velocity.z, target.z, acceleration * delta * speed)

	move_and_slide()

	if is_on_floor() and not was_on_floor:
		_play_step(LAND_SOUND, 1.0, STEP_VOLUME_DB + 4.0)
		_stride_accum = 0.0
		# Only source of player damage that exists so far.
		var impact := -fall_speed
		if impact > safe_fall_speed:
			take_damage((impact - safe_fall_speed) * fall_damage_per_speed)
	else:
		_update_footsteps(delta)

	_drive_gait(delta)


## Running is the default; every other state can only slow it down, so the
## slowest applicable restriction always wins.
func _current_speed() -> float:
	var speed := run_speed
	if _shoot_recency > 0.0 or Input.is_action_pressed("shoot"):
		speed = minf(speed, walk_speed)
	if _crouching:
		speed = minf(speed, crouch_speed)
	# Blended rather than switched, so raising the sights eases you down to a
	# shuffle instead of snapping.
	return lerpf(speed, minf(speed, shuffle_speed), weapon.aim_ratio())


## Shrinks the capsule and drops the eye together, so the collider always
## matches what the camera implies. Note there is no headroom check on standing
## back up.
func _update_crouch(delta: float) -> void:
	_crouch = move_toward(_crouch, 1.0 if _crouching else 0.0, crouch_transition * delta)
	var drop := crouch_drop * _crouch
	head.position.y = _head_rest_y - drop
	var height := _stand_height - drop
	(collision_shape.shape as CapsuleShape3D).height = height
	collision_shape.position.y = height * 0.5


## Feeds the body's walk cycle. Runs in both views: in first person the body is
## invisible but still casting an animated shadow.
func _drive_gait(delta: float) -> void:
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var phase := (_stride_accum / stride_length) * PI
	if _step_parity:
		phase += PI
	body_model.set_gait(
		phase, clampf(ground_speed / walk_speed, 0.0, 1.3), is_on_floor(), _crouch, delta
	)


## Signature matches TargetCharacter so anything that damages one can damage
## the other -- grenade fragments do not care who they hit.
func take_damage(amount: float, _hit_position := Vector3.ZERO, _from: Vector3 = Vector3.ZERO) -> void:
	if _dead:
		return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_die()


func is_dead() -> bool:
	return _dead


## Drops the camera to the ground, collapses the body and respawns after a
## delay. Input is ignored throughout.
func _die() -> void:
	if _dead:
		return
	_dead = true
	velocity = Vector3.ZERO
	weapon.set_aiming(false)
	# Nothing to see from inside your own corpse.
	viewmodel.visible = false
	weapon.visible = false
	body_model.die(false)
	died.emit()

	_death_tween = create_tween().set_parallel(true)
	_death_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_death_tween.tween_property(head, "position:y", 0.32, 1.0)
	_death_tween.tween_property(head, "rotation:z", deg_to_rad(74.0), 1.1)
	_death_tween.tween_property(head, "rotation:x", deg_to_rad(-12.0), 1.1)
	_death_tween.chain().tween_interval(respawn_delay)
	_death_tween.chain().tween_callback(respawn)


func respawn() -> void:
	if _death_tween != null and _death_tween.is_valid():
		_death_tween.kill()
	_dead = false
	health = max_health
	health_changed.emit(health, max_health)

	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_aim_yaw = _spawn_transform.basis.get_euler().y
	_aim_pitch = 0.0
	_recoil_pitch = 0.0
	_recoil_yaw = 0.0
	_crouching = false
	_crouch = 0.0
	_shoot_recency = 0.0
	head.position.y = _head_rest_y
	head.rotation = Vector3.ZERO
	body_model.revive()
	for item: Equipment in loadout:
		item.restock()
	weapon.visible = true
	_apply_view()


func heal(amount: float) -> void:
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


## Swaps which item is in hand. The arm rig and HUD follow the change without
## needing to know what was equipped.
func _equip(index: int) -> void:
	if index == _slot or index < 0 or index >= loadout.size():
		return
	if weapon != null:
		weapon.on_holstered()
		weapon.visible = false
		if weapon.fired.is_connected(_on_weapon_fired):
			weapon.fired.disconnect(_on_weapon_fired)

	_slot = index
	weapon = loadout[index]
	weapon.visible = true
	weapon.fired.connect(_on_weapon_fired)
	# Each item solves its own raised pose relative to the camera; convert that
	# into socket-local space, since the socket is what it hangs from.
	weapon.set_aim_pose(
		socket_fp.transform.affine_inverse() * weapon.sight_transform(weapon.eye_relief)
	)
	weapon.on_equipped()
	viewmodel.set_weapon(weapon)
	body_arms.set_weapon(weapon if _third_person else null)
	_set_shadows(
		weapon,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _third_person
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)


## Moves the weapon between the viewmodel socket and the body socket, and swaps
## which camera and which set of arms is live.
func _apply_view() -> void:
	var socket: Node3D = socket_tp if _third_person else socket_fp
	# The whole loadout travels together; only the equipped item is visible.
	for item: Equipment in loadout:
		if item.get_parent() != socket:
			item.reparent(socket, false)
	if _third_person:
		weapon.set_aiming(false)
		camera_fp.fov = _rest_fov
	camera_fp.current = not _third_person
	camera_tp.current = _third_person
	viewmodel.visible = not _third_person

	# The body is never hidden — in first person it is switched to shadows-only
	# so we still cast a silhouette. Its arms drop to their idle carry pose,
	# since the weapon they were gripping has moved up to the camera.
	body_model.set_shadow_only(not _third_person)
	body_arms.set_weapon(weapon if _third_person else null)
	_set_shadows(
		weapon,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _third_person
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	if not _third_person:
		body_model.spine_pitch = 0.0


func _set_shadows(root: Node, mode: int) -> void:
	for mesh: MeshInstance3D in root.find_children("*", "MeshInstance3D", true):
		mesh.cast_shadow = mode


func _on_weapon_fired(pitch_kick: float, yaw_kick: float) -> void:
	_recoil_pitch += pitch_kick
	_recoil_yaw += yaw_kick


func _update_footsteps(delta: float) -> void:
	if not is_on_floor():
		_stride_accum = 0.0
		return

	var ground_speed := Vector2(velocity.x, velocity.z).length()
	if ground_speed < MIN_STEP_SPEED:
		return

	_stride_accum += ground_speed * delta
	if _stride_accum < stride_length:
		return
	_stride_accum = 0.0

	# Avoid repeating the previous sample so the loop is less obvious.
	var index := randi() % FOOTSTEPS.size()
	if index == _last_step:
		index = (index + 1) % FOOTSTEPS.size()
	_last_step = index
	_step_parity = not _step_parity
	if _crouching:
		return
	_play_step(FOOTSTEPS[index], randf_range(0.92, 1.08), STEP_VOLUME_DB)


func _play_step(stream: AudioStream, pitch: float, volume_db: float) -> void:
	step_player.stream = stream
	step_player.pitch_scale = pitch
	step_player.volume_db = volume_db
	step_player.play()
