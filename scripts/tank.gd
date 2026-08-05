class_name Tank
extends CharacterBody3D

## A one-man tank: drive it, traverse the turret, and fire either the main gun
## or the machine gun beside it.
##
## Control lives here rather than on the player. Once someone climbs in, the
## player node is parked and switched off and this reads the input instead,
## which keeps two quite different sets of movement rules from having to share
## one script. The player is handed back at `Seat` when they get out.
##
## Armour is the point of it: rifle rounds and shrapnel do nothing at all, and
## only blast gets through. When it finally goes, the hull stays exactly where
## it stopped as permanent cover, the turret comes off, and it burns.

signal destroyed

@export_group("Driving")
## Metres per second flat out.
@export var drive_speed := 7.0
@export var reverse_speed := 3.5
## How quickly the hull comes up to speed, per second.
@export var acceleration := 2.4
## Degrees per second the hull turns on the spot.
@export var turn_speed := 16.0

@export_group("Turret")
## Degrees per second the turret traverses. Slow on purpose -- a turret that
## snapped round like a mouse-driven head would make the thing a giant rifle.
@export var traverse_speed := 24.0
@export var elevation_min := -8.0
@export var elevation_max := 18.0

## Ledge the hull can climb without help. Two voxels, twice what a man on foot
## manages, plus margin so a block edge is never caught on.
@export var step_height := 0.55

@export_group("Felling")
## Trees are driven through rather than stopped at: the hull clears wood and
## leaves out of its path as it advances.
@export var fell_trees := true
## How far ahead of the front plate tree blocks are cleared, in metres. Enough
## that the hull never actually reaches a trunk to be stopped by it.
@export var fell_margin := 0.45
## Extra height above the hull that is cleared too, so low canopy is pushed
## through instead of scraping over the turret.
@export var fell_headroom := 1.3

@export_group("Crushing")
## Anything caught under a moving hull takes this. Well past what a body has.
@export var crush_damage := 500.0
## Below this the hull is not really running anyone over.
@export var crush_speed := 0.8
## Physics can shove a body further in one frame than its own speed allows --
## a grenade pinned under the hull is enough to launch it. Anything past what
## could have been driven, plus this much slack for floor snapping, is undone.
@export var shove_allowance := 0.05

@export_group("Main gun")
## A bazooka warhead and a half, which is what the shell is worth.
@export var shell_multiplier := 1.5
@export var main_rounds := 20
## Seconds between rounds: one loader, one breech.
@export var main_reload := 3.5
@export var main_range := 400.0

@export_group("Machine gun")
## The coaxial M1941's own profile, mounted beside the main gun.
@export var coax_bands := [100.0, 100.0, 50.0, 10.0]
@export var coax_rounds := 200
@export var coax_rpm := 600.0
@export var coax_range := 180.0
@export var coax_spread := 0.7

@export_group("Survivability")
@export var max_health := 1000.0
## How quickly a hull being driven by somebody else is pulled onto the pose they
## last reported, per second. High enough to keep up with a tank at speed,
## low enough that the twenty-a-second stream reads as movement.
const NET_FOLLOW_RATE := 12.0

const CANNON: AudioStream = preload("res://assets/audio/cannon_fire.wav")
const GUNSHOT: AudioStream = preload("res://assets/audio/gunshot.wav")
const BULLET_HOLE: PackedScene = preload("res://scenes/bullet_hole.tscn")

## What armour simply does not notice.
const PROOF_AGAINST := [Lethality.BULLET, Lethality.FRAGMENT, Lethality.MELEE]

## Anything that can be climbed into puts itself in here. Lives on the vehicle
## rather than on the player, because the vehicle is what decides it is one.
const VEHICLES := &"vehicles"

@onready var hull_shape: CollisionShape3D = $CollisionShape3D
@onready var turret: Node3D = $Turret
@onready var gun: Node3D = $Turret/Gun
@onready var main_muzzle: Marker3D = $Turret/Gun/MainMuzzle
@onready var coax_muzzle: Marker3D = $Turret/Gun/CoaxMuzzle
## On the gun rather than on the turret, so the view pitches with the barrel.
## The HUD takes the crosshair away while you are aboard, which makes the gun
## itself the aim -- and an aim you cannot see is not one.
@onready var camera: Camera3D = $Turret/Gun/CameraMount/Camera3D
@onready var seat: Marker3D = $Seat
@onready var dismount: Marker3D = $Dismount
@onready var engine_sound: AudioStreamPlayer3D = $EngineSound
@onready var tread_sound: AudioStreamPlayer3D = $TreadSound
@onready var gun_sound: AudioStreamPlayer3D = $GunSound
@onready var coax_sound: AudioStreamPlayer3D = $CoaxSound
@onready var smoke: GPUParticles3D = $Smoke

var health := 0.0
var driver: Node3D
## Peer id of whoever else is driving this, or 0 when nobody is. While it is set
## this copy simulates nothing and follows what that client reports.
var net_driver := 0
var _net_target := Vector3.ZERO
var _net_yaw := 0.0
var _net_turret := 0.0
var _net_gun := 0.0
var _net_fresh := false
## Where this hull started and how its turret sat, so a new round can put both
## back. A wrecked tank that stayed wrecked for the rest of the match would make
## the first bazooka of the first round decide every round after it.
var _start_transform := Transform3D.IDENTITY
var _turret_rest := Transform3D.IDENTITY
var _wreck_tween: Tween
var _wrecked := false
var _traverse := 0.0
var _elevation := 0.0
var _world: Node
var _main_cooldown := 0.0
var _coax_cooldown := 0.0
var _main_left := 0
var _coax_left := 0
var _holes: Array[Node3D] = []

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	add_to_group(Lethality.DAMAGEABLE)
	add_to_group(VEHICLES)
	health = max_health
	_main_left = main_rounds
	_coax_left = coax_rounds
	_traverse = rotation.y
	_world = get_tree().get_first_node_in_group("voxel_world")
	_start_transform = global_transform
	_turret_rest = turret.transform
	smoke.emitting = false
	camera.current = false
	engine_sound.stream = preload("res://assets/audio/engine_rumble.wav")
	tread_sound.stream = preload("res://assets/audio/tank_tread.wav")
	# Both are short beds meant to run continuously; the samples carry no loop
	# flag of their own, so set it here rather than depending on import options.
	_loop(engine_sound.stream)
	_loop(tread_sound.stream)


## Anyone standing this close can climb in. Used by the player, which owns the
## interact key.
## Marks a sample as looping so a held note does not run out mid-idle.
func _loop(stream: AudioStream) -> void:
	var wav := stream as AudioStreamWAV
	if wav == null:
		return
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	# 16-bit mono: two bytes a frame.
	wav.loop_end = wav.data.size() / 2


## True once the tank has nothing left to shoot with, so the HUD can grey the
## readout the way it does an empty magazine.
func is_empty() -> bool:
	return _main_left <= 0 and _coax_left <= 0


func can_be_entered() -> bool:
	return not _wrecked and driver == null and net_driver == 0


func enter(who: Node3D) -> void:
	if not can_be_entered():
		return
	driver = who
	camera.current = true
	engine_sound.play()
	Net.report_vehicle(self, true)


func exit() -> void:
	if driver == null:
		return
	var who := driver
	driver = null
	camera.current = false
	engine_sound.stop()
	Net.report_vehicle(self, false)
	if who.has_method("leave_vehicle"):
		who.leave_vehicle(dismount.global_position)


# --- being driven by somebody else ---------------------------------------
#
# A vehicle is one object that several people can see and only one can drive, so
# unlike a soldier it cannot simply belong to the client running it. Whoever
# climbs in takes it over and publishes where it is; everybody else stops
# simulating their copy and follows. Without that half, a tank driven away is a
# tank that only moved on one screen, and every shot fired from it comes from
# somewhere nobody else can see.


## Whether there is built terrain beneath the hull to rest on, asked every frame
## rather than settled once.
##
## Terrain exists within a radius of the camera and is thrown away outside it, so
## the ground under anything you are not standing near is not merely invisible --
## it has no collider, and a heavy thing resting on it is resting on nothing. Ask
## once at the start and the hull sits still until somebody walks eighty metres
## away, at which point it drops out of the world and keeps going. It never
## recovers either: coming back rebuilds the ground far above wherever it has
## fallen to by then.
##
## What makes that worse than an ordinary bug is that it is not the same bug
## twice. Which chunks exist depends on where each player has been, so two people
## who wandered differently end up disagreeing about where the tank is, or
## whether there is one at all, having done nothing to it.
##
## Standing still in mid-air is the right answer here. It looks odd for the
## moment nobody is nearby to see it, and it is the only answer that has every
## client agreeing on where the thing is.
func _ground_under_us() -> bool:
	if _world == null:
		return true
	return _world.is_ground_ready(global_position.x, global_position.z)


## Whole again for a new round: back on its parking spot, turret on its ring,
## racks full. Called on every client at once, and it restores rather than
## rebuilds, so two clients that saw the round end differently still start the
## next one looking at the same tank.
func round_reset() -> void:
	if _wreck_tween != null and _wreck_tween.is_valid():
		_wreck_tween.kill()
	exit()
	_wrecked = false
	net_driver = 0
	health = max_health
	_main_left = main_rounds
	_coax_left = coax_rounds
	_main_cooldown = 0.0
	_coax_cooldown = 0.0
	velocity = Vector3.ZERO
	global_transform = _start_transform
	turret.transform = _turret_rest
	_traverse = rotation.y
	_elevation = 0.0
	smoke.emitting = false
	engine_sound.stop()


## Taken over by a remote driver, or handed back. Called by Net.
func set_net_driver(id: int) -> void:
	net_driver = id
	if id == 0:
		engine_sound.stop()
		return
	# Somebody else's hands on it: stop simulating and start following.
	driver = null
	velocity = Vector3.ZERO
	if not engine_sound.playing:
		engine_sound.play()


## Where this hull is and where its gun is pointed, for the clients following it.
func net_state() -> PackedFloat32Array:
	return PackedFloat32Array([
		global_position.x, global_position.y, global_position.z,
		rotation.y, turret.rotation.y, gun.rotation.x,
	])


func apply_net_state(data: PackedFloat32Array) -> void:
	if data.size() < 6 or _wrecked:
		return
	_net_target = Vector3(data[0], data[1], data[2])
	_net_yaw = data[3]
	_net_turret = data[4]
	_net_gun = data[5]
	_net_fresh = true


## Eased toward the last reported pose rather than snapped to it, for the same
## reason a soldier is: what arrives is twenty stills a second, and a hull that
## teleported between them would read as broken rather than as distant.
func _follow_net_driver(delta: float) -> void:
	if not _net_fresh:
		return
	var catch_up := minf(delta * NET_FOLLOW_RATE, 1.0)
	global_position = global_position.lerp(_net_target, catch_up)
	rotation.y = lerp_angle(rotation.y, _net_yaw, catch_up)
	turret.rotation.y = lerp_angle(turret.rotation.y, _net_turret, catch_up)
	gun.rotation.x = lerp_angle(gun.rotation.x, _net_gun, catch_up)


## Rifle rounds and shrapnel do nothing; only blast gets through the armour.
func take_damage(
	amount: float,
	_hit_position := Vector3.ZERO,
	_from := Vector3.ZERO,
	kind: StringName = Lethality.BLAST
) -> void:
	if _wrecked or kind in PROOF_AGAINST:
		return
	# Reported before it is applied, and only once it is known to count: there is
	# one hull and everybody is looking at it, so the round that goes into it has
	# to go into everybody's copy or the thing brews up on one screen and sits
	# there untouched on the others. Net drops this when the damage arrived off
	# the wire to begin with, so it cannot bounce back and forth.
	Net.report_entity_damage(self, amount, _hit_position, _from, kind)
	health = maxf(health - amount, 0.0)
	if health <= 0.0:
		_wreck()


func is_dead() -> bool:
	return _wrecked


## What the HUD shows while you are sitting in it.
func status_text() -> String:
	if _wrecked:
		return "TANK  WRECKED"
	return "MAIN %d  ·  COAX %d  ·  HULL %d" % [_main_left, _coax_left, roundi(health)]


func _physics_process(delta: float) -> void:
	# Somebody else's hull: none of the simulation below is ours to run, and
	# running it would mean two machines each deciding where the same tank is.
	if net_driver != 0:
		_follow_net_driver(delta)
		return
	# Nothing underneath yet. The map says there is ground here, but the chunk
	# carrying it has not been built, so falling now would be falling through
	# terrain rather than onto it -- and how far it got before the ground caught
	# up would come down to how quickly this particular machine streams, which is
	# no basis for two people agreeing on where the tank is.
	if not _ground_under_us():
		velocity = Vector3.ZERO
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	if driver != null and not _wrecked:
		_drive(delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta * drive_speed)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta * drive_speed)

	var before := global_position
	# move_and_slide rewrites velocity to whatever the collisions allowed, so
	# how hard we were pushing has to be read before it runs.
	var driving := Vector2(velocity.x, velocity.z).length()
	var intended := velocity
	move_and_slide()

	# And it writes back whatever a blast shoved into us, which would then
	# raise the ceiling on the next frame's clamp and let the hull accelerate
	# itself off the map. The engine decides how fast this thing moves, so the
	# driven velocity is put straight back. Falling is allowed; being thrown
	# upward is not.
	velocity.x = intended.x
	velocity.z = intended.z
	velocity.y = minf(velocity.y, intended.y)

	_undo_shoves(before, delta, driving, intended.y)
	_crush_what_we_hit(driving)
	# Felling happens before the step attempt: a trunk cleared now is not a
	# ledge to be climbed a moment later.
	_fell_ahead(driving, delta)
	if driving > 0.05:
		_climb_step(delta, driving)
	_update_tread_note()

	# The driver rides along inside, so anything that asks where they are gets
	# an answer that tracks the hull.
	if driver != null:
		driver.global_position = seat.global_position


## Nothing may move the hull except the hull. Depenetration from something
## caught under it can otherwise fling the tank across the map, so any
## displacement beyond what this frame could have driven is taken back.
func _undo_shoves(before: Vector3, delta: float, driving: float, rise_rate: float) -> void:
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z)
	# A parked hull does not drift at all -- depenetration creeps in millimetres
	# a frame, so any per-frame slack would let it walk away. A driving one just
	# cannot be shoved faster than it is driving.
	var allowed := 0.0 if driving <= 0.001 else driving * delta + shove_allowance
	if moved.length() <= allowed:
		return
	var capped := Vector2.ZERO if allowed <= 0.0 else moved.normalized() * allowed
	global_position = Vector3(before.x + capped.x, global_position.y, before.z + capped.y)
	_cap_rise(before, delta, capped.length(), rise_rate, driving)


## Falling is free, climbing is not. A hull gains height by driving up a slope,
## so it may rise about as far as it travelled along the ground -- never more.
## Deliberate step climbing happens after this and is not affected.
func _cap_rise(
	before: Vector3, delta: float, travelled: float, rise_rate: float,
	driving_now: float
) -> void:
	var rise := global_position.y - before.y
	if rise <= 0.0:
		return
	# Parked, it does not climb at all -- otherwise a blast underneath walks it
	# upward a few centimetres a frame. Driving, it may rise about as far as it
	# travelled along the ground, which covers any slope it can actually take.
	var allowed := 0.0
	if driving_now > 0.001:
		allowed = maxf(rise_rate, 0.0) * delta + travelled + 0.08
	if rise > allowed:
		global_position.y = before.y + allowed


## Runs over anything soft that the hull touched while moving.
func _crush_what_we_hit(driving: float) -> void:
	if driving < crush_speed:
		return
	for i in get_slide_collision_count():
		var hit := get_slide_collision(i)
		var body: Object = hit.get_collider()
		if body == null or body == driver or not body.has_method("take_damage"):
			continue
		# Terrain answers take_damage too; only crush things that can die.
		if body is VoxelChunk:
			continue
		body.take_damage(crush_damage, hit.get_position(), -hit.get_normal())


## Treads clatter in proportion to how fast the hull is actually moving.
func _update_tread_note() -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var rolling := speed > 0.25 and not _wrecked
	if rolling and not tread_sound.playing:
		tread_sound.play()
	elif not rolling and tread_sound.playing:
		tread_sound.stop()
	if rolling:
		var effort := clampf(speed / maxf(drive_speed, 0.001), 0.0, 1.0)
		tread_sound.pitch_scale = lerpf(0.8, 1.3, effort)
		tread_sound.volume_db = lerpf(-14.0, -3.0, effort)


## Clears wood and leaves from the slab of ground immediately ahead of the
## hull. Only tree material goes: concrete and earth still stop the tank, so
## this fells a wood without turning the thing into a tunnelling machine.
func _fell_ahead(driving: float, delta: float) -> void:
	if not fell_trees or _world == null or driving < 0.2:
		return
	var box := hull_shape.shape as BoxShape3D
	if box == null:
		return

	# The hull only ever travels along its own forward axis, so the slab is
	# either off the nose or off the tail.
	var forward := velocity.dot(-global_basis.z)
	if absf(forward) < 0.2:
		return
	var half := box.size * 0.5
	var reach := driving * delta + fell_margin
	var base := hull_shape.position.y

	var near_z := -half.z if forward > 0.0 else half.z
	var far_z := near_z - reach if forward > 0.0 else near_z + reach
	var lo := Vector3(-half.x, base - half.y - 0.1, minf(near_z, far_z))
	var hi := Vector3(half.x, base + half.y + fell_headroom, maxf(near_z, far_z))

	# World-space bounds of that slab, so only a handful of cells get tested.
	var bounds := AABB(to_global(lo), Vector3.ZERO)
	for i in 8:
		bounds = bounds.expand(to_global(Vector3(
			lo.x if (i & 1) == 0 else hi.x,
			lo.y if (i & 2) == 0 else hi.y,
			lo.z if (i & 4) == 0 else hi.z
		)))

	var step: float = VoxelWorld.BLOCK
	var from: Vector3i = _world.world_to_grid(bounds.position)
	var to: Vector3i = _world.world_to_grid(bounds.position + bounds.size)
	for gy in range(from.y, to.y + 1):
		for gz in range(from.z, to.z + 1):
			for gx in range(from.x, to.x + 1):
				var type: int = _world.block_at(gx, gy, gz)
				if type != VoxelWorld.WOOD and type != VoxelWorld.LEAVES:
					continue
				# Cell centre has to actually fall inside the slab, not just
				# its bounding box, or the hull would fell sideways too.
				var centre: Vector3 = _world.grid_to_world(gx, gy, gz) + Vector3.ONE * (step * 0.5)
				var local := to_local(centre)
				if local.x < lo.x or local.x > hi.x: continue
				if local.y < lo.y or local.y > hi.y: continue
				if local.z < lo.z or local.z > hi.z: continue
				_world.damage_grid_block(gx, gy, gz, 1e9)


## Godot has no step climbing of its own, so the hull does it by hand: lift,
## move across, drop back down, and give up unless all three succeed. That last
## part is what stops it climbing walls or crossing gaps.
func _climb_step(delta: float, driving: float) -> void:
	if not is_on_wall():
		return
	var motion := Vector3(velocity.x, 0.0, velocity.z).normalized() * (driving * delta + 0.05)
	if motion.length_squared() < 1e-8:
		return

	var lift := Vector3.UP * step_height
	var start := global_transform
	if test_move(start, lift):
		return
	var raised := start.translated(lift)
	if test_move(raised, motion):
		return

	var across := raised.translated(motion)
	var landing := KinematicCollision3D.new()
	if not test_move(across, Vector3.DOWN * (step_height + 0.05), landing):
		return
	global_position = across.origin + landing.get_travel()


## Tank controls: forward and back drive the hull, left and right pivot it.
func _drive(delta: float) -> void:
	var throttle := Input.get_axis("move_back", "move_forward")
	var steer := Input.get_axis("move_right", "move_left")

	rotation.y += deg_to_rad(turn_speed) * steer * delta
	var top := drive_speed if throttle >= 0.0 else reverse_speed
	var target := -global_basis.z * throttle * top
	velocity.x = move_toward(velocity.x, target.x, acceleration * delta * drive_speed)
	velocity.z = move_toward(velocity.z, target.z, acceleration * delta * drive_speed)

	# Engine note rises with how hard it is working.
	var effort := Vector2(velocity.x, velocity.z).length() / maxf(drive_speed, 0.001)
	engine_sound.pitch_scale = lerpf(0.85, 1.35, clampf(effort, 0.0, 1.0))


func _process(delta: float) -> void:
	_main_cooldown = maxf(_main_cooldown - delta, 0.0)
	_coax_cooldown = maxf(_coax_cooldown - delta, 0.0)
	if driver == null or _wrecked:
		return

	# The turret chases where the mouse has been pointed rather than snapping
	# to it, which is what makes it feel like traversing a turret.
	turret.rotation.y = _approach_angle(
		turret.rotation.y, _traverse - rotation.y, deg_to_rad(traverse_speed) * delta
	)
	gun.rotation.x = _approach_angle(
		gun.rotation.x, _elevation, deg_to_rad(traverse_speed) * delta
	)

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if Input.is_action_pressed("shoot"):
		_fire_main()
	if Input.is_action_pressed("aim"):
		_fire_coax()


func _unhandled_input(event: InputEvent) -> void:
	if driver == null or _wrecked:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Mouse sets where the turret is being asked to point; _process walks it
		# there at the traverse rate.
		var sens := 0.0022
		_traverse -= event.relative.x * sens
		_elevation = clampf(
			_elevation - event.relative.y * sens,
			deg_to_rad(elevation_min),
			deg_to_rad(elevation_max)
		)


## Shortest way round, capped at `step`, so the turret never spins the long way.
func _approach_angle(from: float, to: float, step: float) -> float:
	var delta := wrapf(to - from, -PI, PI)
	return from + clampf(delta, -step, step)


func _fire_main() -> void:
	if _main_cooldown > 0.0 or _main_left <= 0:
		return
	_main_left -= 1
	_main_cooldown = main_reload

	var from := main_muzzle.global_position
	var direction := -main_muzzle.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * main_range)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var burst: Vector3 = hit.position if not hit.is_empty() else from + direction * main_range

	var damage := []
	for value in Blast.ROCKET_DAMAGE:
		damage.append(float(value) * shell_multiplier)
	Blast.hurt(get_tree(), burst, Blast.ROCKET_YARDS, damage)
	Blast.crater(get_tree(), burst, Blast.ROCKET_YARDS, damage, 1.0)
	Blast.effect(get_tree().current_scene, burst, 26.0, 14.0, 8.0, true)
	Blast.shake(get_tree(), 0.02)
	Net.report_blast(burst, 26.0, 14.0, 8.0, true, 0.02)

	gun_sound.stream = CANNON
	gun_sound.pitch_scale = randf_range(1.15, 1.25)
	gun_sound.play()


func _fire_coax() -> void:
	if _coax_cooldown > 0.0 or _coax_left <= 0:
		return
	_coax_left -= 1
	_coax_cooldown = 60.0 / maxf(coax_rpm, 1.0)

	var from := coax_muzzle.global_position
	var spread := deg_to_rad(coax_spread)
	var direction := -coax_muzzle.global_basis.z
	direction = direction.rotated(
		coax_muzzle.global_basis.x, randf_range(-spread, spread)
	).rotated(
		coax_muzzle.global_basis.y, randf_range(-spread, spread)
	)

	var query := PhysicsRayQueryParameters3D.create(from, from + direction * coax_range)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)

	coax_sound.stream = GUNSHOT
	coax_sound.pitch_scale = randf_range(0.94, 1.06)
	coax_sound.play()

	if hit.is_empty():
		return
	var target: Object = hit.collider
	var dealt := Lethality.at_range(from.distance_to(hit.position), coax_bands)
	if target != null and target.has_method("take_damage"):
		var broke: Variant = target.take_damage(
			dealt, hit.position, -direction, Lethality.BULLET
		)
		if broke is bool and not broke:
			_mark(hit.position, hit.normal)
		return
	_mark(hit.position, hit.normal)


func _mark(at: Vector3, normal: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var hole := BULLET_HOLE.instantiate() as Node3D
	scene_root.add_child(hole)
	var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	hole.global_transform = Transform3D(
		Basis.looking_at(-normal, up), at + normal * randf_range(0.006, 0.012)
	)
	_holes.append(hole)
	hole.tree_exited.connect(func() -> void: _holes.erase(hole))
	while _holes.size() > 48:
		var oldest: Node3D = _holes.pop_front()
		oldest.queue_free()


## The hull is left exactly where it stopped and keeps its collision, so a dead
## tank is a permanent piece of cover rather than something to clear up.
func _wreck() -> void:
	if _wrecked:
		return
	_wrecked = true
	exit()
	# A hull that has brewed up belongs to nobody, including whoever was driving
	# it a moment ago. Cleared here rather than left to them to announce, because
	# a wreck arriving off the wire is applied without their client getting a say
	# -- and a wreck still recorded as driven would go on following a pose that
	# has stopped being sent.
	net_driver = 0
	engine_sound.stop()
	velocity = Vector3.ZERO
	smoke.emitting = true
	destroyed.emit()

	# Turret off the ring: up, over the side, and down on its face.
	var landing := turret.position + Vector3(randf_range(0.9, 1.6), -0.55, randf_range(-0.8, 0.8))
	var tween := create_tween().set_parallel(true)
	_wreck_tween = tween
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(turret, "position", turret.position + Vector3(0, 0.7, 0), 0.35)
	tween.tween_property(
		turret, "rotation", turret.rotation + Vector3(randf_range(-0.5, -0.2), 0.8, 2.4), 1.1
	)
	tween.chain().tween_property(turret, "position", landing, 0.75) \
		.set_ease(Tween.EASE_IN)

	Blast.effect(get_tree().current_scene, global_position + Vector3.UP, 30.0, 16.0, 8.0, true)
	Blast.shake(get_tree(), 0.05)
	Net.report_blast(global_position + Vector3.UP, 30.0, 16.0, 8.0, true, 0.05)
