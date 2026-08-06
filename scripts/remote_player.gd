class_name RemotePlayer
extends AnimatableBody3D

## Somebody else's soldier, as seen from here.
##
## It holds no state of its own worth speaking of: twenty times a second the
## client driving it says where it is and what it is doing, and everything in
## between is interpolation. It is a body rather than a plain Node3D so that
## rounds and fragments stop on it, and it carries the same `take_damage`
## signature as everything else that can be shot -- but rather than deciding
## what a hit does, it posts the hit to the client that owns the soldier and
## lets them work it out. That client is the only one keeping their health, so
## there is exactly one place it can be wrong.
##
## It does not push anybody around, though; see the scene for why not.

## Which client is driving. Set by Net before this enters the tree.
var peer_id := 0

## What each catalogue entry looks like in somebody else's hands, keyed the way
## the catalogue keys it. Keyed rather than ordered on purpose: the wire carries
## the catalogue index, but resolving that index through LoadoutConfig means
## adding or reordering equipment needs one line here and nothing else.
const ITEM_SCENES := {
	&"thompson": preload("res://scenes/weapon_thompson.tscn"),
	&"shotgun": preload("res://scenes/weapon_shotgun.tscn"),
	&"garand": preload("res://scenes/weapon_garand.tscn"),
	&"carbine": preload("res://scenes/weapon_carbine.tscn"),
	&"bazooka": preload("res://scenes/weapon_bazooka.tscn"),
	&"bar": preload("res://scenes/weapon_bar.tscn"),
	&"johnson": preload("res://scenes/weapon_johnson.tscn"),
	&"m1911": preload("res://scenes/weapon_m1911.tscn"),
	&"shovel": preload("res://scenes/weapon_shovel.tscn"),
	&"radio": preload("res://scenes/weapon_radio.tscn"),
	&"smoke": preload("res://scenes/weapon_smoke.tscn"),
	&"medic": preload("res://scenes/weapon_medic.tscn"),
	&"tnt": preload("res://scenes/weapon_tnt.tscn"),
	&"grenade": preload("res://scenes/weapon_grenade.tscn"),
	&"shieldclub": preload("res://scenes/weapon_shield_club.tscn"),
}

## Catalogue entries that are worn rather than carried. Somebody who has the
## armour or the jet selected is holding nothing, and that is what has to be
## drawn: leaving the last weapon in their hands shows a man with a rifle who is
## about to hit you with a club.
const WORN := [&"armour", &"jumpjet"]

## Matches TargetCharacter, so a head is a head wherever you shoot it.
const HEADSHOT_MULTIPLIER := 2.5
const HEAD_HEIGHT := 1.32

const GUNSHOT: AudioStream = preload("res://assets/audio/gunshot.wav")
const HIT_FLESH: AudioStream = preload("res://assets/audio/hit_flesh.wav")
const HIT_HEAD: AudioStream = preload("res://assets/audio/hit_head.wav")

## Fraction of the aim pitch the torso copies. The same figure the player uses
## on its own body, so a remote soldier leans the way a local one does.
const SPINE_PITCH_RATIO := 0.6

## Seconds a state packet is worth. One send interval: by the time we have
## caught up with a packet the next one has arrived. Costs one interval of
## latency and buys smooth motion over a lossy connection, which is the trade
## every interpolating client makes.
const LERP_TIME := 1.0 / 20.0

## Seconds between range checks on the name tag. Four times a second is quicker
## than the number it shows can change at a walk, and a fraction of the cost of
## testing it every frame.
const TAG_INTERVAL := 0.25

## Flags packed into the state's last field.
const FLAG_ON_FLOOR := 1
const FLAG_DEAD := 2
## Inside a vehicle. The soldier is still there and still where the vehicle is,
## but drawing them would put a man standing in the open on top of a tank.
const FLAG_RIDING := 4

@onready var model: CharacterModel = $CharacterBody
@onready var label: Label3D = $NameTag
@onready var hit_sound: AudioStreamPlayer3D = $HitSound
@onready var shot_sound: AudioStreamPlayer3D = $ShotSound

## Field offsets into a state packet, which is a flat run of floats. Named
## rather than counted at each use, because the only thing keeping the two ends
## of the wire agreeing is that they read it in the order the other one wrote it.
const S_X := 0
const S_Y := 1
const S_Z := 2
const S_YAW := 3
const S_PITCH := 4
const S_CROUCH := 5
const S_PRONE := 6
const S_PHASE := 7
const S_GAIT := 8
const S_FLAGS := 9
const STATE_FIELDS := 10

## Where we are interpolating from and to, as whole packets.
var _from := PackedFloat32Array()
var _to := PackedFloat32Array()
var _blend := 1.0

var _item := -1
var _weapon: Equipment
var _down := false
var _riding := false
var _name := "SOLDIER"
## The side last written into the tag, so it is only rebuilt when it changes.
var _team := ""
## Last range written into the tag, so it is only rewritten when it changes.
var _tag_metres := -1
var _tag_due := 0.0


func _ready() -> void:
	add_to_group(Lethality.DAMAGEABLE)
	# Deliberately *not* in Blast.VIEWERS: a shake belongs to a camera, and the
	# only camera here is the local player's.
	set_item(0)
	# A body usually exists before its side does -- the first packet about a peer
	# is what creates it, and that can arrive ahead of the roster naming the side
	# they were put on -- so the tag is hung on the roster rather than read once
	# here.
	Net.roster_changed.connect(_refresh_team)
	_refresh_team()


## Puts this soldier's side on his tag. Everybody wears the same green, so the
## tag is the only thing that says which of them you are looking at -- which is
## why it is a side rather than a name.
func _refresh_team() -> void:
	var side := Net.team_of(peer_id)
	if side == _team:
		return
	_team = side
	_tag_metres = -1
	label.modulate = Net.team_colour(side).lightened(0.5)
	_refresh_tag()


## Which side this soldier is on. See `Lethality.friendly`.
func team_name() -> String:
	return Net.team_of(peer_id)


func set_player_name(text: String) -> void:
	_name = text
	_tag_metres = -1
	_refresh_tag()


## Which side they are on and how far off they are. Not their name: with every
## soldier in the same green, the one thing worth reading off a body at speed is
## whether you should be shooting at it, and a name cannot tell you that. The
## range is what turns the marker from "there is somebody" into something you
## can act on -- walking over, or deciding they are too far to bother with.
##
## Names are not lost, they have moved: the kill feed and the scoreboard both
## still use them, which is where a name is actually worth reading.
##
## Rebuilt only when the rounded distance actually changes, because setting the
## text on a Label3D remakes its mesh, and doing that every frame for every
## soldier on the field would be a real cost for a number that ticks over once a
## second at walking pace.
func _refresh_tag() -> void:
	if label == null:
		return
	var side := _team if not _team.is_empty() else Net.team_of(peer_id)
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		label.text = "%s SOLDIER" % side.to_upper()
		return
	var metres := roundi(camera.global_position.distance_to(global_position))
	if metres == _tag_metres:
		return
	_tag_metres = metres
	label.text = "%s SOLDIER  %dm" % [side.to_upper(), metres]


## Puts a different weapon in its hands. Held as the real weapon scene rather
## than a stand-in mesh so a distant soldier is carrying something recognisable,
## and so the arm rig has grips to solve against.
func set_item(index: int) -> void:
	if index == _item or index < 0 or index >= LoadoutConfig.ITEMS.size():
		return
	var key: StringName = LoadoutConfig.ITEMS[index]["key"]
	var scene: PackedScene = ITEM_SCENES.get(key)
	# Nothing to draw is a state, not a failure. Something worn empties their
	# hands; an item nobody has listed here does too, rather than leaving them
	# holding whatever they had last -- which is how a man who switched to the
	# club stayed visibly armed with a Thompson.
	if scene == null and key not in WORN:
		push_warning("RemotePlayer has no scene for '%s'; hands left empty." % key)
	_item = index
	if _weapon != null:
		_weapon.queue_free()
		_weapon = null
	model.arms.set_weapon(null)
	if scene == null:
		return
	_weapon = scene.instantiate()
	model.weapon_socket.add_child(_weapon)
	model.arms.set_weapon(_weapon)


## The far end pulled a trigger. Only the flash and the report: the round
## itself was traced on their machine, and whatever it hit has already been
## reported to whoever it hit.
func play_fire() -> void:
	if _weapon == null:
		return
	_weapon.show_muzzle_flash()
	# A gun's report is its own; anything else a soldier fires -- a thrown
	# grenade, a shovel swing -- makes no bang and gets the flash alone.
	if _weapon is not Weapon:
		return
	var gun := _weapon as Weapon
	shot_sound.stream = GUNSHOT
	shot_sound.pitch_scale = randf_range(0.94, 1.06) * gun.fire_pitch
	shot_sound.volume_db = gun.fire_volume_db
	shot_sound.play()


## A state packet. Kept whole rather than unpacked into fields, because every
## one of them is only ever read back out again by the interpolation below.
func apply_state(data: PackedFloat32Array) -> void:
	if data.size() < STATE_FIELDS:
		return
	_from = _to if not _to.is_empty() else data
	_to = data
	_blend = 0.0
	# A soldier who died out of sight still has to be found on the ground.
	var dead := (int(data[S_FLAGS]) & FLAG_DEAD) != 0
	if dead and not _down:
		go_down()
	elif _down and not dead:
		get_back_up(_position_in(data))


func go_down() -> void:
	if _down:
		return
	_down = true
	model.die(false)
	# A corpse stops blocking bullets, the same way the mannequin does.
	$CollisionShape3D.set_deferred("disabled", true)
	label.modulate = Color(1, 1, 1, 0.35)


func get_back_up(at: Vector3) -> void:
	_down = false
	model.revive()
	$CollisionShape3D.set_deferred("disabled", false)
	label.modulate = Color.WHITE
	global_position = at
	_from = PackedFloat32Array()
	_to = PackedFloat32Array()


func _position_in(data: PackedFloat32Array) -> Vector3:
	return Vector3(data[S_X], data[S_Y], data[S_Z])


func _process(delta: float) -> void:
	if _to.is_empty():
		return
	_blend = minf(_blend + delta / LERP_TIME, 1.0)
	var a := _from if not _from.is_empty() else _to
	var b := _to

	global_position = _position_in(a).lerp(_position_in(b), _blend)
	# Angles are lerped the short way round, or a soldier spinning past due
	# north takes the long way there.
	rotation.y = lerp_angle(a[S_YAW], b[S_YAW], _blend)
	var pitch := lerp_angle(a[S_PITCH], b[S_PITCH], _blend)
	var crouch := lerpf(a[S_CROUCH], b[S_CROUCH], _blend)

	model.prone_amount = lerpf(a[S_PRONE], b[S_PRONE], _blend)
	model.spine_pitch = pitch * SPINE_PITCH_RATIO
	model.set_gait(
		lerpf(a[S_PHASE], b[S_PHASE], _blend), lerpf(a[S_GAIT], b[S_GAIT], _blend),
		(int(b[S_FLAGS]) & FLAG_ON_FLOOR) != 0, crouch, delta
	)

	# Buttoned up inside something: the body goes away, and so does the marker,
	# because the vehicle is the thing to look at and shoot at now.
	var riding := (int(b[S_FLAGS]) & FLAG_RIDING) != 0
	if riding != _riding:
		_riding = riding
		model.visible = not riding
		$CollisionShape3D.set_deferred("disabled", riding or _down)

	# Ride above whatever the body is doing, upright and readable from anywhere.
	label.position.y = 2.05 - crouch * 0.35
	label.visible = not _down and not riding
	_tag_due -= delta
	if _tag_due <= 0.0:
		_tag_due = TAG_INTERVAL
		_refresh_tag()


## Same signature as every other thing in the game that can be shot, so a bullet
## does not need to know whose soldier it hit. Nothing is decided here: the
## damage is posted to the client that owns this body, which is the only one
## keeping its health. All that happens locally is the feedback the shooter has
## earned -- a sound and a flinch -- so a hit reads as a hit without waiting a
## round trip to find out.
func take_damage(
	amount: float,
	hit_position: Vector3,
	from_shooter: Vector3,
	kind: StringName = Lethality.BLAST
) -> void:
	if _down:
		return
	if hit_position.y - global_position.y > HEAD_HEIGHT:
		amount *= HEADSHOT_MULTIPLIER
		hit_sound.stream = HIT_HEAD
	else:
		hit_sound.stream = HIT_FLESH
	hit_sound.pitch_scale = randf_range(0.94, 1.08)
	hit_sound.play()
	model.flinch(clampf(amount / 25.0, 0.3, 1.4), from_shooter.dot(-global_basis.z) < 0.0)

	Net.report_hit(peer_id, amount, hit_position, from_shooter, kind)


func is_dead() -> bool:
	return _down
