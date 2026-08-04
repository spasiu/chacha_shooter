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


func _ready() -> void:
	_left = fuse_time
	_next_tick = 1.0


## Seconds remaining, for anything that wants to show a countdown.
func fuse_remaining() -> float:
	return maxf(_left, 0.0)


func _process(delta: float) -> void:
	if _spent:
		return
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
