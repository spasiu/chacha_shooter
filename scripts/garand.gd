class_name Garand
extends Weapon

## Scoped M1 Garand. Aiming is Weapon's -- the scope works because RearSight and
## FrontSight sit on the tube's rims, so the same solve that lines up irons
## lines up the optic, and a short `eye_relief` puts the eye at the eyepiece.
##
## What this adds is the en-bloc clip: rather than a magazine dropping out of
## the bottom, the empty clip pings up out of the open action and a fresh one is
## pressed down through the top.

## Fraction of the reload at which the empty clip pings clear.
@export var eject_at := 0.22
## Fraction at which the fresh clip is seated.
@export var feed_at := 0.66

# The action tips inboard and back so the open receiver faces the camera.
const OPEN_TILT_DEG := Vector3(-9.0, 16.0, -20.0)
# Left-hand waypoints, as offsets from its resting spot on the foregrip.
const HAND_TO_ACTION := Vector3(0.0, 0.06, 0.16)
const HAND_WITH_CLIP := Vector3(0.0, 0.09, 0.14)
## Where the spent clip flies. Mostly sideways rather than straight up: the
## scope is centred over the receiver, so the clip has to come out from under
## the tube instead of through it.
const CLIP_EJECT := Vector3(0.24, 0.15, 0.08)
## Where a fresh clip is presented before being pressed in -- off to the right
## for the same reason.
const CLIP_RAISED := Vector3(0.14, 0.07, 0.0)
const BOLT_BACK := Vector3(0.0, 0.0, 0.07)

@onready var clip: MeshInstance3D = $Clip

var _clip_rest := Vector3.ZERO


func _ready() -> void:
	super()
	_clip_rest = clip.position


## Tips the open action toward the camera, where the Thompson rolls its mag
## well down.
func _cant_tilt() -> Vector3:
	return Vector3(
		deg_to_rad(OPEN_TILT_DEG.x), deg_to_rad(OPEN_TILT_DEG.y), deg_to_rad(OPEN_TILT_DEG.z)
	)


## Same timeline shape as the base reload: every delay is a fraction of
## `reload_time`, so retuning the duration rescales the whole sequence.
func _run_reload_animation() -> void:
	if _reload_tween != null and _reload_tween.is_valid():
		_reload_tween.kill()

	var t := reload_time
	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_reload_tween = tween

	# Tip the action up into view; the support hand comes over the top.
	tween.tween_property(self, "_reload_offset", CANT_OFFSET, t * 0.16)
	tween.tween_property(self, "_reload_tilt", _cant_tilt(), t * 0.16)
	tween.tween_property(self, "left_hand_offset", HAND_TO_ACTION, t * 0.16)

	# Op rod back, and the empty clip pings out of the top.
	tween.tween_property(bolt_handle, "position", _bolt_rest + BOLT_BACK, t * 0.1) \
		.set_delay(t * 0.1)
	tween.tween_callback(_play.bind(reload_sound, MAG_OUT, 1.9, -6.0)).set_delay(t * eject_at)
	tween.tween_property(clip, "position", _clip_rest + CLIP_EJECT, t * 0.16) \
		.set_ease(Tween.EASE_OUT).set_delay(t * eject_at)
	tween.tween_callback(clip.hide).set_delay(t * (eject_at + 0.16))

	# Hand drops out of frame for a fresh clip and brings it back over the
	# receiver, ready to be thumbed in. HAND_OFFSCREEN is the base class's --
	# reaching for ammunition looks the same whatever it is being fed into.
	tween.tween_property(self, "left_hand_offset", HAND_OFFSCREEN, t * 0.2) \
		.set_delay(t * (eject_at + 0.06))
	tween.tween_callback(_present_fresh_clip).set_delay(t * 0.52)
	tween.tween_property(self, "left_hand_offset", HAND_WITH_CLIP, t * 0.16).set_delay(t * 0.52)

	# Clip pressed down into the receiver, then the bolt slams shut on it.
	tween.tween_property(clip, "position", _clip_rest, t * 0.12) \
		.set_ease(Tween.EASE_IN).set_delay(t * (feed_at - 0.12))
	tween.tween_callback(_play.bind(reload_sound, MAG_IN, 0.9, -3.0)).set_delay(t * feed_at)
	tween.tween_property(bolt_handle, "position", _bolt_rest, t * 0.07) \
		.set_ease(Tween.EASE_IN).set_delay(t * (feed_at + 0.04))
	tween.tween_callback(_play.bind(reload_sound, BOLT, 0.95, -4.0)) \
		.set_delay(t * (feed_at + 0.11))

	# Level out and put the hand back on the foregrip.
	tween.tween_property(self, "_reload_offset", Vector3.ZERO, t * 0.18).set_delay(t * 0.8)
	tween.tween_property(self, "_reload_tilt", Vector3.ZERO, t * 0.18).set_delay(t * 0.8)
	tween.tween_property(self, "left_hand_offset", Vector3.ZERO, t * 0.16).set_delay(t * 0.8)

	tween.tween_callback(_finish_reload).set_delay(t)


func _present_fresh_clip() -> void:
	clip.position = _clip_rest + CLIP_RAISED
	clip.show()


func _finish_reload_state() -> void:
	super()
	clip.position = _clip_rest
	clip.show()
