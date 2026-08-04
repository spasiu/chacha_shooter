class_name Equipment
extends Node3D

## Anything the player can hold. The arm rig, HUD and player talk to this
## interface, so a weapon and a grenade are interchangeable to them.
##
## Subclasses must provide GripRight and GripLeft markers; everything else has
## a harmless default.

signal fired(pitch_kick: float, yaw_kick: float)

## Distance from eye to sight when raised. Meaningless for un-sighted items,
## which simply ignore it.
@export var eye_relief := 0.45
## Camera FOV to zoom to when fully raised. Zero means "whatever the player uses
## for irons"; only magnified optics need to override it.
@export var sighted_fov := 0.0
## What carrying this costs the holder's pace, as a fraction of it. A carbine
## is barely felt; a launcher or a radio set is a real burden. Anything a
## soldier can hang off a belt leaves this at zero.
@export_range(0.0, 0.9, 0.01) var move_penalty := 0.0

@export_group("Lethality")
## Damage out of 100 inside 5 yards.
@export var damage_short := 100.0
## Inside 25 yards.
@export var damage_medium := 50.0
## Inside 125 yards.
@export var damage_long := 25.0
## Past 125 yards.
@export var damage_beyond := 10.0
## Outer edge of each band, in yards. The default is the small-arms curve the
## comments above describe; a blast weapon quotes a far tighter one.
@export var band_yards := [5.0, 25.0, 125.0]

@onready var grip_right: Marker3D = $GripRight
@onready var grip_left: Marker3D = $GripLeft

## Displacement of the support hand from its grip, driven by animations.
var left_hand_offset := Vector3.ZERO


## Damage this weapon does at a given distance, using its own bands. For a
## bullet that distance is how far the round flew; for a blast it is how far
## the target stood from the burst.
func damage_at(metres: float) -> float:
	return Lethality.banded(
		metres, band_yards, [damage_short, damage_medium, damage_long, damage_beyond]
	)


## True for items used from outside the body rather than aimed down: the radio
## picks a spot on the ground, which you cannot do from behind your own eyes.
## The player puts the camera over the shoulder while one of these is out.
func wants_third_person() -> bool:
	return false


## True if the action actually happened, so the caller can react to it.
func try_fire() -> bool:
	return false


## Called when the fire button is let go. Automatic weapons ignore it; items
## that do not repeat while the trigger is held use it to tell a fresh pull
## from a held one, and a cooked grenade uses it as the moment of release.
func release_trigger() -> void:
	pass


## True while mid-action, e.g. cooking a grenade. Blocks weapon switching so a
## live grenade cannot be holstered.
func is_busy() -> bool:
	return false


func reload() -> void:
	pass


func set_aiming(_aiming: bool) -> void:
	pass


## Told whether the holder is lying down, where a weapon with a bipod under it
## is resting on the ground rather than being held up. Ignored by anything that
## is fired off the shoulder however you happen to be lying.
func set_braced(_braced: bool) -> void:
	pass


## 0 = lowered, 1 = fully raised.
func aim_ratio() -> float:
	return 0.0


## Drives the HUD crosshair spread. Un-aimed items report zero.
func spread_ratio() -> float:
	return 0.0


## Local pose, relative to the camera, for the raised position.
func sight_transform(_relief: float) -> Transform3D:
	return Transform3D()


func set_aim_pose(_pose: Transform3D) -> void:
	pass


## How big a marker the HUD should draw at the aim point, as a multiplier of its
## own size, or a negative number for none at all.
##
## Negative by default, and that is the right default: every weapon here carries
## modelled iron sights and is meant to be aimed down rather than through a
## painted cross. It is for the things with no sights on them, where the game
## would otherwise be asking you to guess where the middle of the screen is.
func reticule_size() -> float:
	return -1.0


## Shown in the HUD's bottom-right readout.
func status_text() -> String:
	return ""


func is_empty() -> bool:
	return false


## True when this is carrying everything it went out with. A resupply point
## reads it to tell whether there is anything to hand over, so that standing on
## one costs nothing while there is not.
func is_full() -> bool:
	return true


## Restores starting ammunition, e.g. on respawn.
func restock() -> void:
	pass


## Shows whatever this item does when it goes off, without any of the rest of
## firing it. Only ever called on a remote player's copy: the round itself was
## traced on the machine that fired it, and all that is left over here is the
## flash. Silent by default, since most things a soldier carries have none.
func show_muzzle_flash() -> void:
	pass


func on_equipped() -> void:
	pass


func on_holstered() -> void:
	pass
