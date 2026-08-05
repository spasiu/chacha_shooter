class_name ShieldClub
extends Equipment

## Shield and club: the oldest loadout there is, carried into 1944.
##
## Primary swings the club. Secondary -- the aim key, which is Shift as well as
## the right button -- brings the shield up in front of you, where it stops
## rifle fire outright.
##
## The shield is not a collider and does not try to be. A plate of steel that
## bullets have to physically miss would need its own body in front of a moving
## man, and every ray in the game already ends at whoever it hit; so instead the
## man himself knows he is behind it, and the round is stopped where damage is
## worked out. That has one large advantage beyond being simpler: it works
## identically for a bot, whose shot is a roll rather than a ray, without the
## bot having to know a shield exists.

## What the club does per hit.
@export var swing_damage := 50.0
## How far in front the club reaches, in metres.
@export var reach := 2.2
## Seconds between swings.
@export var swing_interval := 0.75
## Half-angle of the arc the shield covers, in degrees. Ninety is everything in
## front of you: the shield faces where you face, and nothing behind it is
## covered at all.
@export var cover_degrees := 90.0
## How far the shield reaches up the body, as a fraction of eye height. One is
## exactly to the eye, which is what a man crouching behind a plate can hold up
## and still see over.
@export_range(0.2, 1.2, 0.05) var cover_to_eye := 1.0

## What the plate stops.
##
## Fragments as well as bullets, which is the same list the tank's armour keeps.
## A grenade here is not a radius of damage -- it casts nine hundred individual
## rays and cover genuinely stops them -- so a plate held up in front of one is
## doing exactly the job a plate is for, and each fragment gets tested on its
## own. A grenade at your feet is largely eaten; the same grenade behind you is
## not touched by any of this.
##
## Blast still goes round it, and a club is not troubled by it either.
const STOPS := [Lethality.BULLET, Lethality.FRAGMENT]
## The shortest gap between two clangs. Without it a single grenade rings the
## plate once per fragment stopped -- hundreds of times inside one frame.
const RING_INTERVAL := 0.09

const SWING_SOUND: AudioStream = preload("res://assets/audio/shovel_dig.wav")
const CLANG: AudioStream = preload("res://assets/audio/hit_head.wav")

@onready var shield: Node3D = $Shield
@onready var club: Node3D = $Club
@onready var swing_sound: AudioStreamPlayer = $SwingSound

## Raised or not. Read by the player when it is working out whether a round got
## through, which is the only thing that ever asks.
var raised := false

var _cooldown := 0.0
var _ring_cooldown := 0.0
var _swing_tween: Tween


func _ready() -> void:
	_set_shield(false)


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	_ring_cooldown = maxf(_ring_cooldown - delta, 0.0)


## The aim key is the shield. Nothing is sighted here -- there is nothing on
## either arm to sight with.
func set_aiming(aiming: bool) -> void:
	if aiming == raised:
		return
	raised = aiming
	_set_shield(aiming)


func is_shielding() -> bool:
	return raised


## Whether a round arriving from `from` -- pointing back toward whoever fired
## it, the way weapon.gd and the vehicles report it -- is caught by the plate.
##
## Three tests, all of which have to pass: the shield is up, the round is
## something a plate stops, and it came from in front and below the top edge.
## A man who turns his back, or who is shot at from a roof, is not covered.
func stops(kind: StringName, from: Vector3, facing: Vector3, above_eye: bool) -> bool:
	if not raised or kind not in STOPS:
		return false
	if above_eye:
		return false
	var flat_from := Vector2(from.x, from.z)
	var flat_face := Vector2(facing.x, facing.z)
	if flat_from.length_squared() < 1e-6 or flat_face.length_squared() < 1e-6:
		return false
	var away := rad_to_deg(flat_face.normalized().angle_to(flat_from.normalized()))
	# A hair of tolerance on the edge: at a 90 degree half-angle a shot arriving
	# exactly side-on works out as 90.0000001 and would fall outside an arc it
	# is precisely on the rim of.
	return absf(away) <= cover_degrees + 0.01


## A clang rather than a wound, so being saved by the shield is something you
## hear happen rather than something you infer from not dying.
func ring() -> void:
	if _ring_cooldown > 0.0:
		return
	_ring_cooldown = RING_INTERVAL
	swing_sound.stream = CLANG
	swing_sound.pitch_scale = randf_range(0.7, 0.85)
	swing_sound.play()


func try_fire() -> bool:
	if _cooldown > 0.0:
		return false
	_cooldown = swing_interval
	_swing()
	return true


func _swing() -> void:
	swing_sound.stream = SWING_SOUND
	swing_sound.pitch_scale = randf_range(0.92, 1.08)
	swing_sound.play()

	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	var rest := club.rotation
	_swing_tween = create_tween()
	_swing_tween.tween_property(club, "rotation", rest + Vector3(-1.5, 0.35, 0.0), 0.09)
	_swing_tween.tween_property(club, "rotation", rest, 0.28).set_ease(Tween.EASE_OUT)

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var origin := camera.global_position
	var into := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + into * reach)
	var wielder := _wielder()
	if wielder != null:
		query.exclude = [wielder.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var target: Object = hit.collider
	if target != null and target.has_method("take_damage"):
		target.take_damage(swing_damage, hit.position, -into, Lethality.MELEE)
	fired.emit(0.12, 0.0)


## The body swinging this, so a swing does not land on its own owner. Equipment
## has no such lookup of its own -- Weapon does, and this is not one.
func _wielder() -> CollisionObject3D:
	var node: Node = get_parent()
	while node != null:
		if node is CollisionObject3D:
			return node
		node = node.get_parent()
	return null


func _set_shield(up: bool) -> void:
	# Up in front of the face, or down at the side. Tweened rather than snapped
	# so it is plainly a man raising a shield rather than one appearing.
	var to := Vector3(0.0, 0.0, 0.0) if up else Vector3(0.16, -0.14, 0.12)
	var tilt := Vector3.ZERO if up else Vector3(0.0, 0.5, 0.35)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(shield, "position", to, 0.16)
	tween.tween_property(shield, "rotation", tilt, 0.16)


func wants_third_person() -> bool:
	return false


func reticule_size() -> float:
	return 0.0


func status_text() -> String:
	return "SHIELD UP" if raised else "CLUB  ·  SHIELD READY"


func is_empty() -> bool:
	return false
