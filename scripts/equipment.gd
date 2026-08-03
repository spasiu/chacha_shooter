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

@onready var grip_right: Marker3D = $GripRight
@onready var grip_left: Marker3D = $GripLeft

## Displacement of the support hand from its grip, driven by animations.
var left_hand_offset := Vector3.ZERO


## True if the action actually happened, so the caller can react to it.
func try_fire() -> bool:
	return false


func reload() -> void:
	pass


func set_aiming(_aiming: bool) -> void:
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


## Shown in the HUD's bottom-right readout.
func status_text() -> String:
	return ""


func is_empty() -> bool:
	return false


## Restores starting ammunition, e.g. on respawn.
func restock() -> void:
	pass


func on_equipped() -> void:
	pass


func on_holstered() -> void:
	pass
