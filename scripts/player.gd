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
## Height that can be walked up without jumping. One block is 0.25m; the extra
## is margin so a block edge is never caught on.
@export var step_height := 0.28

@export_group("Health")
@export var max_health := 100.0
## Speed of descent below which landing is harmless, in m/s.
@export var safe_fall_speed := 14.0
## Damage per m/s of impact beyond the safe threshold.
@export var fall_damage_per_speed := 6.0
## Seconds face-down before you may get back up. The body lies where it fell
## for the whole of it, so a position that has been taken stays visibly taken,
## and going down is a real loss of ground rather than a short pause.
@export var respawn_delay := 1.0
## Falling this far below the world kills, in case the edge is ever outrun.
@export var void_depth := -12.0

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
## How far the eye drops when prone.
@export var prone_drop := 1.25
## Seconds the crouch key must be held to drop prone.
@export var prone_hold_time := 1.0
## Seconds to lower into or rise out of prone.
@export var prone_transition := 0.45

## Metres of ground travel between footsteps. Cadence scales with speed on its
## own, so running steps more often without a separate interval.
@export var stride_length := 2.0

## How close you have to be to climb into a vehicle.
@export var vehicle_reach := 4.5

## How close to your own side's base counts as being in it, in metres. Generous:
## a resupply you have to go hunting for the exact spot of is a chore rather
## than a place on the map.
@export var resupply_radius := 14.0

## How fast the view settles back after weapon recoil, per second.
@export var recoil_recovery := 7.0
## How fast a shaken view settles, in radians per second.
@export var shake_recovery := 0.09

## Fraction of the aim pitch the third-person torso copies, so the weapon
## tracks roughly where you are aiming without the whole body tipping over.
@export var spine_pitch_ratio := 0.6

const PITCH_LIMIT := deg_to_rad(89.0)
const MIN_STEP_SPEED := 0.5
## How far from the map's start point a networked soldier may appear, in metres,
## and the fraction of the terrain's own draw distance that may be used for it.
##
## Both, because either alone gets it wrong. A fixed distance goes stale the
## moment the draw distance is retuned; a pure fraction of a generous draw
## distance would fling people to opposite ends of a field they can see across
## but would take half a minute to cross. Whichever is smaller wins, so people
## start near each other and always inside the ground each other is standing on.
const SPAWN_SCATTER := 16.0
const SPAWN_SCATTER_OF_VIEW := 0.25
## How many spots to try before giving up and using the map's own spawn point.
const SPAWN_TRIES := 12
## Footfalls sit well under the weapon; landing is 4dB above a normal step.
const STEP_VOLUME_DB := -10.0
## Where a jump jet rides: high on the back, clear of the legs it exhausts past.
const JET_MOUNT := Vector3(0.0, 1.12, 0.2)
## Where a plate carrier sits: on the chest, over the tunic.
const ARMOUR_MOUNT := Vector3(0.0, 0.34, 0.0)

const FOOTSTEPS: Array[AudioStream] = [
	preload("res://assets/audio/footstep_01.wav"),
	preload("res://assets/audio/footstep_02.wav"),
	preload("res://assets/audio/footstep_03.wav"),
	preload("res://assets/audio/footstep_04.wav"),
]
const LAND_SOUND: AudioStream = preload("res://assets/audio/land.wav")
## Put up over the death view so every life starts with a fresh choice of kit.
const LOADOUT_SCREEN: PackedScene = preload("res://scenes/loadout_select.tscn")

@onready var head: Node3D = $Head
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var step_player: AudioStreamPlayer = $StepPlayer
@onready var thompson: Equipment = $Head/Camera3D/WeaponSocket/WeaponThompson
@onready var grenade: Equipment = $Head/Camera3D/WeaponSocket/WeaponGrenade
@onready var shotgun: Equipment = $Head/Camera3D/WeaponSocket/WeaponShotgun
@onready var garand: Equipment = $Head/Camera3D/WeaponSocket/WeaponGarand
@onready var carbine: Equipment = $Head/Camera3D/WeaponSocket/WeaponCarbine
@onready var bazooka: Equipment = $Head/Camera3D/WeaponSocket/WeaponBazooka
@onready var bar: Equipment = $Head/Camera3D/WeaponSocket/WeaponBAR
@onready var m1911: Equipment = $Head/Camera3D/WeaponSocket/WeaponM1911
@onready var johnson: Equipment = $Head/Camera3D/WeaponSocket/WeaponJohnson
@onready var jump_jet: Equipment = $Head/Camera3D/WeaponSocket/WeaponJumpJet
@onready var shield_club: Equipment = $Head/Camera3D/WeaponSocket/WeaponShieldClub
@onready var body_armour: Equipment = $Head/Camera3D/WeaponSocket/WeaponBodyArmour
@onready var tnt: Equipment = $Head/Camera3D/WeaponSocket/WeaponTNT
@onready var shovel: Equipment = $Head/Camera3D/WeaponSocket/WeaponShovel
@onready var smoke: Equipment = $Head/Camera3D/WeaponSocket/WeaponSmoke
@onready var medic: Equipment = $Head/Camera3D/WeaponSocket/WeaponMedic
@onready var camera_fp: Camera3D = $Head/Camera3D
@onready var camera_tp: Camera3D = $Head/SpringArm3D/CameraTP
@onready var spring_arm: SpringArm3D = $Head/SpringArm3D
@onready var socket_fp: Node3D = $Head/Camera3D/WeaponSocket
@onready var viewmodel: ArmRig = $Head/Camera3D/ViewmodelArms
@onready var body_model: CharacterModel = $BodyModel
@onready var body_spine: Node3D = $BodyModel/Spine
@onready var body_arms: ArmRig = $BodyModel/Spine/Arms
@onready var socket_tp: Node3D = $BodyModel/Spine/WeaponSocket
## Everything that exists, keyed the way the select screen names it. What is
## actually carried is whichever subset was picked there.
@onready var _catalogue := {
	&"thompson": thompson,
	&"shotgun": shotgun,
	&"garand": garand,
	&"carbine": carbine,
	&"bazooka": bazooka,
	&"bar": bar,
	&"m1911": m1911,
	&"johnson": johnson,
	&"jumpjet": jump_jet,
	&"shieldclub": shield_club,
	&"armour": body_armour,
	&"tnt": tnt,
	&"shovel": shovel,
	&"smoke": smoke,
	&"medic": medic,
	&"grenade": grenade,
}

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
## Prone is a separate stance: held crouch drops into it, and it pins you in
## place -- you can turn and shoot, but not travel.
var _prone := false
var _prone_blend := 0.0
var _crouch_held := 0.0
var _head_rest_y := 0.0
var _stand_height := 0.0
var _rest_fov := 75.0
var health := 0.0
var _dead := false
var _spawn_transform := Transform3D.IDENTITY
var _death_tween: Tween
## Holds the respawn loadout screen while it is up; null the rest of the time.
var _select_layer: CanvasLayer
## The screen inside that layer, kept so the countdown can be fed to it.
var _select_screen: Control
## Seconds left before getting back up is allowed. Counts down only while dead.
var _respawn_in := 0.0
## Whether the current visit to the base has already been announced, so walking
## in wounded says so once rather than every frame you stand there.
var _resupply_told := false
## The tank being driven, if any. While this is set the player is parked: the
## vehicle reads the input and moves us, and everything below stands down.
## The pack, if one was picked. Kept apart from `loadout` on purpose: it is
## worn rather than held, so it never enters the slot rotation and never goes
## in the hands. Null when nobody chose one.
var _jet: JumpJet
## The plate carrier, if one was picked. Worn like the jet, and kept out of the
## hand rotation for the same reason.
var _armour: BodyArmour
## What a full tank of health is for this life. The armour doubles it, so it is
## worked out once when the loadout is built rather than read off the export
## everywhere -- a max that meant two different things in two places is how a
## health bar ends up reading 200/100.
var _health_cap := 0.0
var _vehicle: Node3D
var _voxel_world: Node
# Alternates each footfall so the gait phase runs 0..2PI over two steps, which
# lands each footplant exactly on its footstep sound.
var _step_parity := false
var _shoot_recency := 0.0
## Peak jitter left in the view, in radians. Set by anything that goes off hard
## enough to be felt rather than merely heard.
var _shake := 0.0
## Everything the player can hold; index 0 is slot 1.
var loadout: Array[Equipment] = []
var weapon: Equipment
var _slot := -1
## Last values handed to the body's walk cycle, kept so the same numbers can be
## published to everyone else rather than having them guess at a gait from a
## position that only arrives twenty times a second.
var _gait_phase := 0.0
var _gait_speed := 0.0


## The pack being worn, for the HUD. Null unless one was picked.
func jet() -> JumpJet:
	return _jet


## The vehicle being ridden, for anything outside that needs to know -- the HUD
## reads it to show the tank's ammunition instead of a rifle magazine.
func riding() -> Node3D:
	return _vehicle


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	add_to_group(Lethality.DAMAGEABLE)
	add_to_group(Blast.VIEWERS)
	_head_rest_y = head.position.y
	_stand_height = (collision_shape.shape as CapsuleShape3D).height
	_rest_fov = camera_fp.fov
	health = _full_health()
	health_changed.emit(health, _full_health())
	_spawn_transform = global_transform
	_voxel_world = get_tree().get_first_node_in_group("voxel_world")
	_aim_yaw = rotation.y
	_build_loadout()
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
	# Hand ourselves to the network last, once everything above is settled: the
	# first thing it does is ask where we are and what we are holding.
	Net.attach_local(self)
	# Onto the map's own start point, alone or not. The map is the thing that
	# knows where a side comes in, and the scene's position is only the fallback
	# for a world that has no map at all.
	_move_to(_scattered_spawn())
	if Net.active():
		Net.report_spawn(global_position)


## Which side this soldier is on, for anything deciding whether a shot that
## landed on him should have counted. Everything that can be hurt and belongs to
## a side answers this; see `Lethality.friendly`.
func team_name() -> String:
	return Net.my_team()


func _unhandled_input(event: InputEvent) -> void:
	# Neither does somebody waiting for the ground to finish.
	if not _terrain_ready():
		return
	# A corpse takes no orders, and while the loadout screen is up the number
	# keys belong to it rather than to weapon slots. The one exception is
	# asking to get back up: there is no reason to make anyone watch the timer
	# run down if they are ready to go.
	if _dead:
		if _select_layer == null and (
			event.is_action_pressed("shoot")
			or event.is_action_pressed("jump")
			or event.is_action_pressed("ui_accept")
		):
			_open_loadout_select()
		return

	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

	if event.is_action_pressed("interact"):
		if _vehicle != null:
			_vehicle.exit()
		else:
			_board_nearby_vehicle()
		return
	# Aboard, the vehicle has the controls; nothing here should answer.
	if _vehicle != null:
		return

	if event is InputEventMouseMotion and captured:
		# Sighted aiming slows the turn rate in proportion to the zoom.
		var sens := mouse_sensitivity * lerpf(1.0, _aim_sensitivity(), weapon.aim_ratio())
		_aim_yaw -= event.relative.x * sens
		_aim_pitch = clampf(
			_aim_pitch - event.relative.y * sens, -PITCH_LIMIT, PITCH_LIMIT
		)
	elif event.is_action_pressed("slot_1"):
		_equip(0)
	elif event.is_action_pressed("slot_2"):
		_equip(1)
	elif event.is_action_pressed("slot_3"):
		_equip(2)
	elif event.is_action_pressed("slot_4"):
		_equip(3)
	elif event.is_action_pressed("slot_5"):
		_equip(4)
	elif event.is_action_pressed("crouch"):
		# From prone, a tap gets you back up to a crouch rather than toggling.
		if _prone:
			_prone = false
			_crouching = true
		else:
			_crouching = not _crouching
		_crouch_held = 0.0
	elif event.is_action_pressed("toggle_view"):
		_third_person = not _third_person
		_apply_view()
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and not captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Whether there is a whole world to play in yet. True in any world that streams
## rather than prebuilds, and true forever once the build finishes.
func _terrain_ready() -> bool:
	if _voxel_world != null:
		# The whole map, when the map is built in one go before anybody plays.
		if not _voxel_world.is_terrain_ready():
			return false
		# And, far more often, the ground under this particular pair of boots.
		#
		# Streaming builds outward from whoever is looking, so for the first
		# second or two of a life there is a described world and no built one.
		# Standing still through that looks like a brief pause; letting gravity
		# have you instead means falling through terrain that is about to exist
		# and dying to the void before it does, which is exactly what a spawn
		# that kills you a second after loading is.
		if not _voxel_world.is_ground_ready(global_position.x, global_position.z):
			return false
	# Nor between rounds. The scoreboard is up, the ground is being put back and
	# the count is being reset; anybody still moving about during that would be
	# playing a round that has already been decided.
	return not Net.round_over


## Whether this soldier can act yet, for the HUD to put a screen over the wait.
func is_ready_to_play() -> bool:
	return _terrain_ready()


## A fresh round. Everything a respawn does, plus getting out of whatever was
## being driven and taking down the kit screen if it was up, because neither
## belongs to the round that just ended.
func round_reset() -> void:
	if _vehicle != null:
		_vehicle.exit()
	if _select_layer != null:
		_select_layer.queue_free()
		_select_layer = null
		_select_screen = null
	_respawn_in = 0.0
	respawn()


func _process(delta: float) -> void:
	if not _terrain_ready():
		return
	if _dead:
		# The death tween owns the camera; all there is to do is run the clock.
		_update_respawn_clock(delta)
		return
	if _vehicle != null:
		# Riding: the vehicle owns the camera, the aim and the guns.
		return

	# Recoil decays toward zero and is layered on top of the aim angles, so a
	# kick never permanently drags the player's aim off target.
	var settle := minf(recoil_recovery * delta, 1.0)
	_recoil_pitch = lerpf(_recoil_pitch, 0.0, settle)
	_recoil_yaw = lerpf(_recoil_yaw, 0.0, settle)

	rotation.y = _aim_yaw + _recoil_yaw
	var pitch := clampf(_aim_pitch + _recoil_pitch, -PITCH_LIMIT, PITCH_LIMIT)
	head.rotation.x = pitch
	_apply_shake(delta)
	body_model.spine_pitch = pitch * spine_pitch_ratio if _over_shoulder() else 0.0

	# Aim state is evaluated even when the mouse is released, so letting go of
	# the cursor lowers the weapon instead of leaving it stuck sighted.
	# Iron sights are first-person only; the pose is solved against the camera.
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	weapon.set_aiming(captured and not _over_shoulder() and Input.is_action_pressed("aim"))
	# Lying down puts a bipod on the ground, which is the whole reason to carry
	# an automatic rifle. Whether that means anything is the weapon's business.
	weapon.set_braced(_prone)
	camera_fp.fov = lerpf(_rest_fov, _sighted_fov(), weapon.aim_ratio())

	if not captured:
		return
	if Input.is_action_pressed("shoot"):
		if weapon.try_fire():
			_shoot_recency = shooting_walk_time
	else:
		# Only ever while the trigger is actually up. A pump gun needs to see it
		# come up before it will fire again, and a grenade throws on the way up,
		# so releasing on any other frame would throw the moment you pulled the
		# pin. Safe to repeat: both ignore it after the first.
		weapon.release_trigger()
	if Input.is_action_just_pressed("reload"):
		weapon.reload()


func _physics_process(delta: float) -> void:
	# Nothing moves until the ground is finished. Standing still on an unbuilt
	# map only looks like waiting; falling through it, which is what happens the
	# moment gravity is allowed to apply, looks like the game being broken.
	if not _terrain_ready():
		velocity = Vector3.ZERO
		return
	if _vehicle != null:
		# The tank puts us where it goes; no gravity, no footsteps, no input.
		return
	_check_out_of_bounds()
	if _dead:
		# Still fall, but take no input and make no footfalls.
		if not is_on_floor():
			velocity.y -= gravity * delta
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	_shoot_recency = maxf(_shoot_recency - delta, 0.0)
	_update_resupply()
	_update_ammo_box()
	_update_crouch(delta)
	var was_on_floor := is_on_floor()
	var fall_speed := velocity.y

	if not was_on_floor:
		if _jet != null and _jet.has_fuel():
			_fly(delta)
		else:
			velocity.y -= gravity * delta
			if _jet != null:
				_jet.set_burning(false)
	else:
		if _jet != null:
			_jet.set_burning(false)
		if not _prone and Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed := _current_speed()

	var target := direction * speed
	velocity.x = move_toward(velocity.x, target.x, acceleration * delta * speed)
	velocity.z = move_toward(velocity.z, target.z, acceleration * delta * speed)

	# Remember the intent: after sliding, velocity no longer reflects where we
	# were trying to go.
	var intended := Vector3(velocity.x, 0.0, velocity.z) * delta
	move_and_slide()
	if is_on_floor() and is_on_wall() and intended.length_squared() > 1e-8:
		_try_step_up(intended)

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


## Godot's CharacterBody3D has no step climbing, so this does it by hand: lift,
## move across, then drop back down. Bails out unless all three succeed, which
## is what stops it from being used to climb walls or cross gaps.
func _try_step_up(motion: Vector3) -> bool:
	var lift := Vector3.UP * step_height
	var start := global_transform
	if test_move(start, lift):
		return false

	var raised := start.translated(lift)
	if test_move(raised, motion):
		return false

	var across := raised.translated(motion)
	var landing := KinematicCollision3D.new()
	var drop := Vector3.DOWN * (step_height + 0.02)
	if not test_move(across, drop, landing):
		# Nothing underneath: that was a gap, not a step.
		return false

	global_position = across.origin + landing.get_travel()
	return true


## FOV to zoom to when the held item is fully raised. Irons use the player's
## own setting; anything with glass on it names its own.
func _sighted_fov() -> float:
	return weapon.sighted_fov if weapon.sighted_fov > 0.0 else aim_fov


## A magnified optic has to slow the turn rate further, or the view whips around
## at the same angular rate through several times the magnification. Scaled by
## how much further the optic zooms than plain irons do, so irons are unchanged.
func _aim_sensitivity() -> float:
	return aim_sensitivity * (_sighted_fov() / aim_fov)


## Running is the default; every other state can only slow it down, so the
## slowest applicable restriction always wins.
## A full tank for this life: the export, doubled if a plate carrier was picked.
## Falls back to the export before the loadout has been built, which is the case
## for the frame or two before the first spawn.
func _full_health() -> float:
	return _health_cap if _health_cap > 0.0 else max_health


func _current_speed() -> float:
	# Prone is stationary by design: turn and shoot, but do not travel.
	if _prone:
		return 0.0
	var speed := run_speed
	if _shoot_recency > 0.0 or Input.is_action_pressed("shoot"):
		speed = minf(speed, walk_speed)
	if _crouching:
		speed = minf(speed, crouch_speed)
	# Kit has weight, and it is carried in every stance: a burden takes its cut
	# off whatever pace the restrictions above have left you with, rather than
	# competing with them for the slowest.
	speed *= 1.0 - weapon.move_penalty
	# Armour is worn in every stance, so it takes its cut after the stance
	# restrictions rather than competing with them: crouching in plate is half
	# of a crouch, not the slower of the two.
	if _armour != null:
		speed *= _armour.speed_factor
	# Blended rather than switched, so raising the sights eases you down to a
	# shuffle instead of snapping.
	return lerpf(speed, minf(speed, shuffle_speed), weapon.aim_ratio())


## Shrinks the capsule and drops the eye together, so the collider always
## matches what the camera implies. Note there is no headroom check on standing
## back up.
func _update_crouch(delta: float) -> void:
	_update_prone_hold(delta)

	# Crouch relaxes as prone takes over, so the drop hands off smoothly.
	var crouch_target := 1.0 if (_crouching and not _prone) else 0.0
	_crouch = move_toward(_crouch, crouch_target, crouch_transition * delta)
	_prone_blend = move_toward(
		_prone_blend, 1.0 if _prone else 0.0, delta / maxf(prone_transition, 0.001)
	)

	var drop := crouch_drop * _crouch + prone_drop * _prone_blend
	head.position.y = _head_rest_y - drop
	var shape := collision_shape.shape as CapsuleShape3D
	# A capsule cannot be shorter than its own diameter, so prone bottoms out
	# there: the collider stays a little taller than the pose suggests.
	var height := maxf(_stand_height - drop, shape.radius * 2.0 + 0.02)
	shape.height = height
	collision_shape.position.y = height * 0.5


## Holding crouch, rather than tapping it, drops you prone.
func _update_prone_hold(delta: float) -> void:
	if _prone or not Input.is_action_pressed("crouch"):
		if not Input.is_action_pressed("crouch"):
			_crouch_held = 0.0
		return
	_crouch_held += delta
	if _crouch_held >= prone_hold_time:
		_prone = true
		_crouching = true


## Feeds the body's walk cycle. Runs in both views: in first person the body is
## invisible but still casting an animated shadow.
func _drive_gait(delta: float) -> void:
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	_gait_phase = (_stride_accum / stride_length) * PI
	if _step_parity:
		_gait_phase += PI
	_gait_speed = clampf(ground_speed / walk_speed, 0.0, 1.3)
	body_model.prone_amount = _prone_blend
	body_model.set_gait(_gait_phase, _gait_speed, is_on_floor(), _crouch, delta)


## Everything another client needs to draw this soldier, in the order
## RemotePlayer reads it back out. Sent twenty times a second, so it carries the
## smoothed stance values rather than the flags behind them: the far end is
## interpolating anyway and has no use for "the crouch key is down".
##
## Packed floats rather than an array of values, because this is the one message
## sent on a timer and everything else is sent when something happens. A plain
## Array puts a type tag on every entry and sends every float at full width; ten
## packed floats are forty bytes and no tags. That difference is what decides how
## long a client that has stopped draining its socket -- a browser tab in the
## background, mostly -- can fall behind before the buffer gives up and starts
## discarding packets that matter.
func net_state() -> PackedFloat32Array:
	var flags := 0
	if is_on_floor():
		flags |= RemotePlayer.FLAG_ON_FLOOR
	if _dead:
		flags |= RemotePlayer.FLAG_DEAD
	if _vehicle != null:
		flags |= RemotePlayer.FLAG_RIDING
	return PackedFloat32Array([
		global_position.x, global_position.y, global_position.z,
		_aim_yaw, _aim_pitch, _crouch, _prone_blend,
		_gait_phase, _gait_speed, float(flags),
	])


## Signature matches TargetCharacter so anything that damages one can damage
## the other -- grenade fragments do not care who they hit.
func take_damage(
	amount: float,
	_hit_position := Vector3.ZERO,
	_from: Vector3 = Vector3.ZERO,
	_kind: StringName = Lethality.BLAST
) -> void:
	if _dead:
		return
	# Behind a raised shield, a bullet from in front and below the top edge is
	# stopped outright. Done here rather than with a collider in front of the
	# man, because every shot in the game ends at whoever it hit -- and because
	# a bot's shot is a roll rather than a ray, so this is the one place that
	# covers both without the bot having to know shields exist.
	if _stopped_by_shield(_hit_position, _from, _kind):
		return
	# What is left after the front plate, if there is one and the hit arrived
	# where it covers.
	if _armour != null:
		amount = _armour.absorb(amount, _from, -global_basis.z)
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, _full_health())
	if health <= 0.0:
		_die()


func is_dead() -> bool:
	return _dead


## There is no wall at the edge of the world, only a painted line. Crossing it
## is fatal; so is falling off the side into the void.
func _check_out_of_bounds() -> void:
	if _dead:
		return
	if global_position.y < void_depth:
		_die()
		return
	if _voxel_world == null:
		return
	var limit: Vector2 = _voxel_world.boundary_half_extent()
	if absf(global_position.x) > limit.x or absf(global_position.z) > limit.y:
		health = 0.0
		health_changed.emit(health, _full_health())
		_die()


## How long until getting back up is allowed, for the HUD to show. Zero once the
## wait is served, and zero while alive.
func respawn_countdown() -> float:
	return _respawn_in


## Runs the wait down and gets us back up at the end of it. If the loadout
## screen is open the player is still choosing, so the clock running out only
## unlocks its deploy button; confirming is what actually stands us up.
func _update_respawn_clock(delta: float) -> void:
	_respawn_in = maxf(_respawn_in - delta, 0.0)
	if _select_screen != null:
		_select_screen.hold_for(_respawn_in)
	elif _respawn_in <= 0.0:
		# Deferred: standing back up reparents the whole loadout between sockets,
		# and the frame's own process pass is no place to be rebuilding the tree.
		respawn.call_deferred()


## Drops the camera to the ground and collapses the body, which then lies where
## it fell until the wait is served. Input is ignored throughout, bar asking for
## the loadout screen.
## Whether the shield ate it. `from` points back toward whoever fired.
func _stopped_by_shield(at: Vector3, from: Vector3, kind: StringName) -> bool:
	var held: Equipment = weapon
	if held == null or not held.has_method("stops"):
		return false
	# Above the eye is over the top of the plate: a man behind a shield still
	# has to see past it, and what he can see out of can be shot into.
	var eye: float = head.global_position.y
	var above_eye: bool = at != Vector3.ZERO and at.y > eye
	if not held.stops(kind, from, -global_basis.z, above_eye):
		return false
	held.ring()
	return true


func _die() -> void:
	if _dead:
		return
	_dead = true
	_respawn_in = respawn_delay
	velocity = Vector3.ZERO
	weapon.set_aiming(false)
	# Nothing to see from inside your own corpse.
	viewmodel.visible = false
	weapon.visible = false
	body_model.die(false)
	# The pack goes up with you, a chest height off the deck rather than at your
	# boots, so it throws over cover the way a rocket would.
	if _jet != null:
		_jet.explode(get_tree(), global_position + Vector3.UP)
	died.emit()
	# Who gets the credit is the network's business, not ours: it knows who last
	# put a round into us, and a fall or the boundary line has nobody behind it.
	Net.report_death(Net.last_attacker())

	_death_tween = create_tween().set_parallel(true)
	_death_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_death_tween.tween_property(head, "position:y", 0.32, 1.0)
	_death_tween.tween_property(head, "rotation:z", deg_to_rad(74.0), 1.1)
	_death_tween.tween_property(head, "rotation:x", deg_to_rad(-12.0), 1.1)


## Offers the kit for the next life. Choosing it is something to do while the
## wait runs down rather than a way of cutting it short: the screen is told how
## long is left and keeps its own deploy button shut until there is none.
func _open_loadout_select() -> void:
	if _select_layer != null:
		return
	# The screen is a Control and this is a 3D node, so it needs a canvas of its
	# own. Layer above the HUD, which is still drawing underneath.
	_select_layer = CanvasLayer.new()
	_select_layer.layer = 10
	add_child(_select_layer)

	var screen: Control = LOADOUT_SCREEN.instantiate()
	# Instanced over a live match: the world stays exactly as it was shot up.
	screen.loads_world = false
	screen.confirmed.connect(_on_loadout_confirmed)
	_select_layer.add_child(screen)
	_select_screen = screen
	screen.hold_for(_respawn_in)


func _on_loadout_confirmed(_picks: Array) -> void:
	_close_loadout_select()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# The screen will not deploy early, so this is only ever reached with the
	# wait served. Checked anyway, because nothing else is standing between a
	# confirmation and being back on your feet.
	if _respawn_in <= 0.0:
		respawn()


func _close_loadout_select() -> void:
	if _select_layer != null:
		_select_layer.queue_free()
		_select_layer = null
	_select_screen = null


func respawn() -> void:
	if _death_tween != null and _death_tween.is_valid():
		_death_tween.kill()
	_dead = false
	_respawn_in = 0.0
	_close_loadout_select()
	health = _full_health()
	health_changed.emit(health, _full_health())

	# Always back at your own side's base, whether or not anyone else is on the
	# field: where you fell is somebody else's ground now, and the map is the
	# thing that says where yours is.
	_move_to(_scattered_spawn())
	velocity = Vector3.ZERO
	_aim_pitch = 0.0
	_recoil_pitch = 0.0
	_recoil_yaw = 0.0
	_crouching = false
	_crouch = 0.0
	_prone = false
	_prone_blend = 0.0
	_crouch_held = 0.0
	_shoot_recency = 0.0
	head.position.y = _head_rest_y
	head.rotation = Vector3.ZERO
	body_model.revive()

	# A throw or reload cut short by dying would otherwise leave the item busy
	# and block re-equipping below.
	if weapon != null:
		weapon.on_holstered()
	# Everything gets restocked, not just what was carried last life: an item
	# taken for this life should arrive full whether or not it saw the last one.
	for item: Equipment in _catalogue.values():
		item.restock()

	# The picks may have changed while the loadout screen was up, so whatever
	# slot the old weapon sat in means nothing now -- rebuild and start at one.
	_build_loadout()
	_slot = -1
	_equip(0)
	_apply_view()
	Net.report_spawn(global_position)


## Puts the soldier somewhere, keeping the aim pointed the way the body is.
func _move_to(at: Vector3) -> void:
	global_position = at
	# Facing out into the map rather than whichever way the scene happened to
	# leave the node. You spawn inside your own base, so the scene's heading
	# points you at the nearest wall of it; turning to face the middle costs a
	# second off every life and is where the fighting is anyway.
	if at.length_squared() > 1.0:
		rotation.y = atan2(at.x, at.z)
	else:
		rotation.y = _spawn_transform.basis.get_euler().y
	_aim_yaw = rotation.y
	_aim_pitch = 0.0


## Standing in your own base puts you right: full health and a full loadout.
##
## A base you can only respawn at is a place you visit once a life; one that
## restocks you is a place worth walking back to with a bazooka empty, which is
## what makes the ground between the bases matter more than the bases do.
##
## Announced once per visit rather than every frame you stand there.
## Airborne with a pack on: jump climbs, crouch drops, neither sinks slowly.
##
## The tank burns whenever the boots are off the ground rather than only while
## the nozzles are lit, because the pack is what is holding you up either way --
## a minute in the air is a minute in the air, however it is spent. That is also
## the only thing stopping a jet from being a permanent hover: idling costs the
## same as climbing.
func _fly(delta: float) -> void:
	var climbing := Input.is_action_pressed("jump")
	var dropping := Input.is_action_pressed("crouch")
	if climbing:
		velocity.y = move_toward(velocity.y, _jet.climb_speed, _jet.thrust_accel * delta)
	elif dropping:
		velocity.y = move_toward(velocity.y, -_jet.descend_speed, _jet.thrust_accel * delta)
	else:
		velocity.y -= gravity * _jet.idle_gravity * delta
	_jet.spend(delta)
	# Lit while it is doing something. Coasting down on what is left of gravity
	# is the one airborne state that should look like falling, because it is.
	_jet.set_burning(climbing or dropping)


func _update_resupply() -> void:
	if _voxel_world == null or _dead:
		return
	var home: Vector2 = _voxel_world.team_spawn(Net.my_team())
	if home == Vector2.ZERO:
		return
	var away := Vector2(global_position.x, global_position.z).distance_to(home)
	if away > resupply_radius:
		_resupply_told = false
		return
	if _resupply_told:
		return
	_resupply_told = true
	var wanted := health < max_health
	health = _full_health()
	health_changed.emit(health, _full_health())
	for item: Equipment in _catalogue.values():
		item.restock()
	if wanted:
		Net.notice.emit("resupplied")


## Ammunition boxes standing on the map, which fill everything you carry and
## then go empty for a while.
##
## Nothing happens while you are carrying a full load, so walking past a box on
## the way somewhere costs nobody anything -- a box is only spent by somebody
## who actually needed it. It hands over ammunition alone: your own base and a
## man with a medical pack are what put health back, and a crate that did that
## too would leave both with nothing to offer.
##
## Only one box per pass, and it stops at the first one in reach. Two crates
## close enough together to both be in range is a thing a map can do, and
## emptying both to fill one soldier would be a waste of the map's ammunition.
func _update_ammo_box() -> void:
	if _dead:
		return
	var wanting := false
	for item: Equipment in _catalogue.values():
		if not item.is_full():
			wanting = true
			break
	if not wanting:
		return

	for node in get_tree().get_nodes_in_group(AmmoBox.BOXES):
		var box := node as AmmoBox
		if box == null or not box.has_stock():
			continue
		if global_position.distance_to(box.global_position) > box.reach:
			continue
		for item: Equipment in _catalogue.values():
			item.restock()
		box.empty_out()
		# The box is part of the map, so everybody has their own copy of it and
		# every one of those copies has to shut.
		Net.report_ammo(box)
		Net.notice.emit("ammunition")
		return


## Where this soldier's side comes into the world. The map says, because the map
## is the thing that knows where its bases are; falling back to wherever the
## scene put the player covers a map that names no sides at all, which is what
## the test harnesses run on.
func _team_origin() -> Vector3:
	if _voxel_world == null:
		return _spawn_transform.origin
	var at: Vector2 = _voxel_world.team_spawn(Net.my_team())
	if at == Vector2.ZERO:
		return _spawn_transform.origin
	return Vector3(at.x, _spawn_transform.origin.y, at.y)


## A spot near the start point rather than on it, dropped onto whatever ground
## is there. Sharing a field with other people means the start point is both
## crowded and watched, and appearing inside somebody else is worse than either.
func _scattered_spawn() -> Vector3:
	var origin := _team_origin()
	if _voxel_world == null:
		return origin

	# Inside our own walls, if the map says where they are. Somewhere in that
	# room rather than on one spot in it: the start point is both crowded and
	# watched, and appearing inside somebody else is worse than either.
	var zone: Rect2 = _voxel_world.team_zone(Net.my_team())
	for _attempt in SPAWN_TRIES:
		var at := _somewhere_in(zone, origin)
		var stand: float = _voxel_world.standing_height(at.x, at.z)
		if not is_nan(stand):
			# Clear of the ground rather than level with it, so the first thing
			# that happens is a short drop and not a scramble out of a hillside.
			at.y = stand + 0.3
			return at

	# Everywhere we looked was built on -- the stores, the crates, the mast. The
	# map's own spawn point is the one spot its author definitely meant to be
	# standable, so fall back to that.
	var home: float = _voxel_world.standing_height(origin.x, origin.z)
	return Vector3(origin.x, (home if not is_nan(home) else origin.y) + 0.3, origin.z)


## A spot to try. Inside the base when the map declared one, and otherwise a
## ring around the spawn point, which is all a map without walls can offer.
func _somewhere_in(zone: Rect2, origin: Vector3) -> Vector3:
	if zone.size.x > 1.0 and zone.size.y > 1.0:
		return Vector3(
			randf_range(zone.position.x, zone.end.x), origin.y,
			randf_range(zone.position.y, zone.end.y)
		)
	var limit := SPAWN_SCATTER
	if _voxel_world != null:
		limit = minf(limit, _voxel_world.view_distance() * SPAWN_SCATTER_OF_VIEW)
	var angle := randf() * TAU
	var reach := randf_range(limit * 0.35, limit)
	return origin + Vector3(cos(angle) * reach, 0.0, sin(angle) * reach)


## Treated by somebody else's medic while still on your feet. Full health, not
## a top-up: the pack is a scarce thing and reaching a man under fire ought to
## be worth the whole of what it costs to carry.
func heal_full() -> void:
	if _dead:
		return
	health = _full_health()
	health_changed.emit(health, _full_health())


## Carried off and put back in the line. Returns whether it actually took --
## false if we were never down, or gave up and respawned before the medic got
## here. Net leans on that answer: only a real revive refunds the side its man.
func revive_from_aid() -> bool:
	if not _dead:
		return false
	if _select_layer != null:
		_select_layer.queue_free()
		_select_layer = null
		_select_screen = null
	_respawn_in = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	respawn()
	return true


func heal(amount: float) -> void:
	health = minf(health + amount, max_health)
	health_changed.emit(health, _full_health())


## Assembles what is carried from the select screen's picks, in pick order, so
## slot 1 is whatever was chosen first. Everything else stays parented where it
## is and simply never becomes visible: `_equip` and `_apply_view` only ever
## walk `loadout`, so an item left behind is inert.
func _build_loadout() -> void:
	loadout.clear()
	_jet = null
	_armour = null
	for key: StringName in LoadoutConfig.chosen:
		# Capped here as well as on the select screen: a slot past the last one
		# has no key bound to it, so anything beyond the cap would be carried
		# but unreachable.
		if loadout.size() >= LoadoutConfig.SLOTS:
			break
		var item: Equipment = _catalogue.get(key)
		if item is BodyArmour:
			# Worn, like the jet: it takes a pick and then it is simply on.
			_armour = item
			continue
		if item is JumpJet:
			# Worn, not held. It takes a pick on the select screen and then stays
			# out of the hand rotation entirely, which is what "always equipped"
			# has to mean for something strapped to your back.
			_jet = item
			continue
		if item != null and not loadout.has(item):
			loadout.append(item)
	# Nothing in hand would break every weapon call below, so an empty or
	# unrecognised selection falls back to the starting weapon.
	if loadout.is_empty():
		loadout.append(thompson)
	for item: Equipment in _catalogue.values():
		item.visible = false
	_health_cap = max_health * (_armour.health_multiplier if _armour != null else 1.0)
	if _armour != null:
		if _armour.get_parent() != body_spine:
			_armour.reparent(body_spine, false)
		_armour.transform = Transform3D(Basis.IDENTITY, ARMOUR_MOUNT)
		_armour.visible = true
	if _jet != null:
		# Hung off the player rather than off the body model, which is switched
		# to shadows-only in first person -- the exhaust is worth seeing from
		# inside the helmet as well as outside it.
		if _jet.get_parent() != self:
			_jet.reparent(self, false)
		_jet.transform = Transform3D(Basis.IDENTITY, JET_MOUNT)
		_jet.visible = true
		_jet.refill()


## Swaps which item is in hand. The arm rig and HUD follow the change without
## needing to know what was equipped.
func _equip(index: int) -> void:
	if index == _slot or index < 0 or index >= loadout.size():
		return
	# A grenade with the pin out is not going back on the belt.
	if weapon != null and weapon.is_busy():
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
	Net.report_equip(_catalogue_index(weapon))
	# Each item solves its own raised pose relative to the camera; convert that
	# into socket-local space, since the socket is what it hangs from.
	weapon.set_aim_pose(
		socket_fp.transform.affine_inverse() * weapon.sight_transform(weapon.eye_relief)
	)
	weapon.on_equipped()
	viewmodel.set_weapon(weapon)
	# What is now in hand may want a different camera than the last thing did.
	# This also settles the arms and the shadows, so nothing else has to here.
	_apply_view()


## Where an item sits in the catalogue, which is how the network names it. -1
## for something not in the catalogue at all, which nothing currently is.
func _catalogue_index(item: Equipment) -> int:
	for key: StringName in _catalogue:
		if _catalogue[key] == item:
			for i in LoadoutConfig.ITEMS.size():
				if LoadoutConfig.ITEMS[i]["key"] == key:
					return i
	return -1


## Rattles the view. Called on everyone at once by whatever went off, so the
## amount is the shake at its peak rather than anything to do with distance.
func shake_view(radians: float) -> void:
	_shake = maxf(_shake, radians)


## Jitter laid over the aim rather than added to it: pitch is rewritten from
## the aim angles every frame and yaw is never touched, so a shake cannot drag
## anyone off target the way recoil deliberately does.
func _apply_shake(delta: float) -> void:
	if _shake <= 0.0:
		head.rotation.y = 0.0
		head.rotation.z = 0.0
		return
	_shake = maxf(_shake - shake_recovery * delta, 0.0)
	head.rotation.x += randf_range(-_shake, _shake)
	head.rotation.y = randf_range(-_shake, _shake)
	head.rotation.z = randf_range(-_shake, _shake)


## Climbs into whatever is close enough and will have us. Reach is generous:
## the hull is wide, and hunting for a hotspot on it is nobody's idea of fun.
func _board_nearby_vehicle() -> void:
	if _dead:
		return
	var nearest: Node3D = null
	var best := vehicle_reach
	for node in get_tree().get_nodes_in_group(Tank.VEHICLES):
		if not (node is Node3D) or not node.has_method("can_be_entered"):
			continue
		if not node.can_be_entered():
			continue
		var d: float = global_position.distance_to((node as Node3D).global_position)
		if d < best:
			best = d
			nearest = node
	if nearest == null:
		return

	_vehicle = nearest
	velocity = Vector3.ZERO
	visible = false
	weapon.visible = false
	viewmodel.visible = false
	body_model.set_shadow_only(false)
	# A rider has no business being in the physics world at all: the vehicle
	# parks our body on its seat every frame, and a seat is inside the hull, so
	# leaving the capsule solid means the tank spends the whole drive pushing
	# against its own driver and going nowhere. Deferred because boarding
	# happens mid-step, and shapes may not come and go while the space is
	# being solved.
	collision_shape.set_deferred("disabled", true)
	nearest.enter(self)


## Called by the vehicle when we get out, or when it is knocked out from under
## us. `at` is where it wants to put us down.
func leave_vehicle(at: Vector3) -> void:
	_vehicle = null
	global_position = at
	velocity = Vector3.ZERO
	visible = true
	collision_shape.set_deferred("disabled", false)
	_apply_view()
	if weapon != null:
		weapon.visible = true


## Whether the camera is over the shoulder: either the player asked for it with
## the view key, or what they are holding has to be used from out there.
func _over_shoulder() -> bool:
	return _third_person or (weapon != null and weapon.wants_third_person())


## Moves the weapon between the viewmodel socket and the body socket, and swaps
## which camera and which set of arms is live.
func _apply_view() -> void:
	var third := _over_shoulder()
	var socket: Node3D = socket_tp if third else socket_fp
	# The whole loadout travels together; only the equipped item is visible.
	for item: Equipment in loadout:
		if item.get_parent() != socket:
			item.reparent(socket, false)
		# Which socket it is in changes how a weapon is held: a launcher carried
		# on the shoulder in front of the camera would hang off the glove when
		# the same instance is seen from outside.
		if item.has_method("set_viewmodel"):
			item.set_viewmodel(not third)
	if third:
		weapon.set_aiming(false)
		camera_fp.fov = _rest_fov
	camera_fp.current = not third
	camera_tp.current = third
	viewmodel.visible = not third

	# The body is never hidden — in first person it is switched to shadows-only
	# so we still cast a silhouette. Its arms drop to their idle carry pose,
	# since the weapon they were gripping has moved up to the camera.
	body_model.set_shadow_only(not third)
	body_arms.set_weapon(weapon if third else null)
	_set_shadows(
		weapon,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if third
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	if not third:
		body_model.spine_pitch = 0.0


func _set_shadows(root: Node, mode: int) -> void:
	for mesh: MeshInstance3D in root.find_children("*", "MeshInstance3D", true):
		mesh.cast_shadow = mode


func _on_weapon_fired(pitch_kick: float, yaw_kick: float) -> void:
	_recoil_pitch += pitch_kick
	_recoil_yaw += yaw_kick
	# Every real shot passes through here, which makes it the one place worth
	# telling everyone else about. What the round hit is not their business:
	# it was traced here, and whoever it hit has already been told.
	Net.report_fire()


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
