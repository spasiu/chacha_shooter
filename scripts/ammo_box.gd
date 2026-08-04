class_name AmmoBox
extends StaticBody3D

## A crate of ammunition standing where the fighting is.
##
## Walk into one carrying anything short and it fills everything you have --
## every weapon's magazines and reserve, grenades, charges, the lot -- and then
## goes empty for a while. It hands over ammunition and nothing else: health
## belongs to your own base and to whoever is carrying a medical pack, and a
## crate that healed you too would make both of those pointless.
##
## The emptying is the whole design. A box that never ran out would mean nobody
## ever had to leave a good position, and the reason a good position is worth
## anything is that holding it costs you something. A box that ran out for good
## would mean a map that quietly becomes unplayable an hour into a match. So it
## comes back, on its own, after long enough that you cannot simply stand on it.
##
## It is solid, which matters more than it sounds: a waist-high crate is cover,
## and putting cover exactly where people have to walk to resupply is the point
## rather than an accident.

## Group every box joins, so the player can sweep them without the scene tree
## needing to say where any of them are.
const BOXES := &"ammo_boxes"

const RESUPPLY: AudioStream = preload("res://assets/audio/mag_in.wav")

## How close you have to be, in metres. Generous enough that you do not have to
## hunt for the exact spot, tight enough that you cannot take one from behind
## the wall it is standing against.
@export var reach := 2.4
## Seconds before a spent box is worth walking to again.
@export var cooldown := 35.0

@onready var _lid: Node3D = $Lid
@onready var _rounds: Node3D = $Rounds
@onready var _sound: AudioStreamPlayer3D = $Sound

## Seconds left before it refills. Zero means it is ready now.
var _empty_for := 0.0
## Where the lid sits when the box is open, so closing and reopening it does not
## need the number written down twice.
var _lid_open := Transform3D.IDENTITY


func _ready() -> void:
	add_to_group(BOXES)
	_lid_open = _lid.transform
	set_process(false)


func has_stock() -> bool:
	return _empty_for <= 0.0


## Somebody took it. The local player calls this after helping themselves; it is
## also what arrives from the far end when somebody else did, so both paths land
## on exactly the same state.
func empty_out() -> void:
	if not has_stock():
		return
	_empty_for = cooldown
	_rounds.visible = false
	# Lid down. The hinge sits at the crate's back edge and the scene leaves it
	# standing open, so shut is simply the hinge unrotated. A closed crate reads
	# as "nothing here" from across a street, which is the difference between
	# walking over and knowing not to bother.
	_lid.transform = Transform3D(Basis(), _lid_open.origin)
	_sound.stream = RESUPPLY
	_sound.pitch_scale = randf_range(0.94, 1.06)
	_sound.play()
	set_process(true)


## A fresh round starts with every box full, however the last one left them.
func round_reset() -> void:
	_empty_for = 0.0
	_refill()


func _process(delta: float) -> void:
	_empty_for -= delta
	if _empty_for > 0.0:
		return
	_empty_for = 0.0
	_refill()


func _refill() -> void:
	_rounds.visible = true
	_lid.transform = _lid_open
	set_process(false)
