class_name TNTCharge
extends Node3D

## A planted demolition charge, counting down.
##
## Once it is in the ground it is nobody's: the player who set it can switch
## away, walk off or die, and it still goes off on time. That is the whole
## point of a timed charge over a thrown grenade.

signal detonated

## Seconds from planting to going off.
@export var fuse_time := 15.0
## Bands out from the charge, in yards, and what it does inside each. Two edges
## and three values: everything past the last edge takes nothing at all, so the
## charge has a hard outer limit rather than a long thin tail.
@export var blast_yards := [1.0, 5.0]
@export var blast_damage := [2000.0, 500.0, 0.0]
## How far out it chews the ground. Matched to the last band, past which the
## charge does nothing and there would be no cells left to change.
@export var crater_yards := 5.0
## Peak view shake, in radians. Everyone feels this one.
@export var shake_radians := 0.075

const TICK: AudioStream = preload("res://assets/audio/bolt.wav")

## True on everyone's copy but the one belonging to whoever planted it. A ghost
## ticks, blinks and goes off on time; it simply does not decide who it killed
## or what it took out of the ground. Those are worked out once, by the client
## that planted it, and travel from there.
var net_ghost := false

@onready var lamp: MeshInstance3D = $Lamp
@onready var sound: AudioStreamPlayer3D = $Sound

var _left := 0.0
var _next_tick := 0.0
var _spent := false
## What it was stuck to, if that was something that moves, and where on it.
## Held as a transform in the host's own space so the charge turns with the
## hull as well as travelling with it -- a charge on the side of a tank that
## stayed upright while the tank turned would be visibly wrong.
var _host: Node3D
## Whether there ever was one. A freed Object compares equal to null in GDScript,
## so a charge whose tank had been destroyed could not tell "stuck to something
## that is gone" from "never stuck to anything" -- and quietly hung in the air
## instead of falling, which is the exact case this was written for.
var _hosted := false
var _host_local := Transform3D.IDENTITY
var _falling := false
var _fall := 0.0


func _ready() -> void:
	_left = fuse_time
	_next_tick = 1.0


## Stick it to something that moves. Anything else is left where it was put:
## the ground does not go anywhere, and a charge parented to a block would come
## off the moment that block was shot away.
func attach_to(host: Node3D) -> void:
	if host == null or not is_instance_valid(host):
		return
	_host = host
	_hosted = true
	_host_local = host.global_transform.affine_inverse() * global_transform


## Seconds remaining, for anything that wants to show a countdown.
func fuse_remaining() -> float:
	return maxf(_left, 0.0)


func _process(delta: float) -> void:
	if _spent:
		return
	_ride(delta)
	_left -= delta

	# Blinks and ticks faster the closer it gets, so the last few seconds are
	# audibly different from the first ten.
	var urgency := clampf(1.0 - _left / maxf(fuse_time, 0.001), 0.0, 1.0)
	var interval := lerpf(1.0, 0.18, urgency * urgency)
	lamp.visible = fmod(_left, interval) < interval * 0.5

	_next_tick -= delta
	if _next_tick <= 0.0:
		_next_tick = interval
		sound.stream = TICK
		sound.pitch_scale = lerpf(1.5, 2.4, urgency)
		sound.volume_db = -14.0
		sound.play()

	if _left <= 0.0:
		_detonate()


## Travel with the host, or come down if there is no longer one.
##
## Losing the host is not a rare case: a wrecked hull is thrown about, a round
## can end and put every vehicle back where it started, and a charge that was
## stuck to one would otherwise be left hanging in the air exactly where the
## tank used to be. So it falls, and stops on the first thing under it.
func _ride(delta: float) -> void:
	if _hosted:
		if is_instance_valid(_host) and _host.is_inside_tree():
			global_transform = _host.global_transform * _host_local
			return
		_hosted = false
		_host = null
		_falling = true
		_fall = 0.0
	if not _falling:
		return
	_fall += ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	var step := _fall * delta
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position, global_position + Vector3.DOWN * (step + 0.05)
	)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		global_position += Vector3.DOWN * step
		return
	global_position = hit.position + hit.normal * 0.04
	_falling = false


func _detonate() -> void:
	if _spent:
		return
	_spent = true
	lamp.visible = false
	set_process(false)

	var at := global_position
	if not net_ghost:
		Blast.hurt(get_tree(), at, blast_yards, blast_damage)
		Blast.crater(get_tree(), at, blast_yards, blast_damage, crater_yards)
	Blast.effect(get_tree().current_scene, at, 40.0, 26.0, 10.0, true)
	Blast.shake(get_tree(), shake_radians)
	detonated.emit()

	# Nothing left to draw, but let the bang finish before going away.
	for child in get_children():
		if child is MeshInstance3D:
			child.visible = false
	get_tree().create_timer(4.0).timeout.connect(queue_free)
