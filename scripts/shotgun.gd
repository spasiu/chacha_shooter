class_name Shotgun
extends Weapon

## Pump-action shotgun. The shot itself is entirely Weapon's -- buckshot is
## just `pellets` set above 1 -- so all this adds is the pump: a forend that is
## worked after every shot, and a reload that thumbs shells into the loading
## port instead of swapping a magazine.

## Seconds after the shot before the forend starts moving; the recoil should
## have peaked first.
@export var pump_delay := 0.14
## Seconds for the full back-and-forward stroke.
@export var pump_time := 0.42
## Shell-feeding gestures the reload plays. Cosmetic: like a magazine, the tube
## actually fills in one go at the end.
@export var shell_gestures := 3

# The port faces up and inboard when the weapon is canted over to be loaded.
const PORT_TILT_DEG := Vector3(-6.0, 20.0, -32.0)
# Left-hand waypoints, as offsets from its resting spot on the forend.
const HAND_TO_PORT := Vector3(0.0, -0.04, 0.2)
const HAND_TO_BELT := Vector3(0.03, -0.3, 0.22)
## How far back the forend is racked.
const PUMP_STROKE := Vector3(0.0, 0.0, 0.075)

@onready var forend: MeshInstance3D = $Forend

var _forend_rest := Vector3.ZERO
var _pump_tween: Tween


func _ready() -> void:
	super()
	_forend_rest = forend.position


func try_fire() -> bool:
	if not super():
		return false
	_run_pump_cycle()
	return true


## Rolls the loading port up toward the camera, where the Thompson rolls its
## mag well down.
func _cant_tilt() -> Vector3:
	return Vector3(
		deg_to_rad(PORT_TILT_DEG.x), deg_to_rad(PORT_TILT_DEG.y), deg_to_rad(PORT_TILT_DEG.z)
	)


## Works the action between shots. Kept on its own tween because it overlaps
## nothing else -- firing is blocked during a reload, and a reload that starts
## mid-stroke kills it.
func _run_pump_cycle() -> void:
	if _pump_tween != null and _pump_tween.is_valid():
		_pump_tween.kill()

	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_pump_tween = tween
	_rack(tween, pump_delay, pump_time)


## Same timeline shape as the base reload: every delay is a fraction of
## `reload_time`, so retuning the duration rescales the whole sequence.
func _run_reload_animation() -> void:
	if _reload_tween != null and _reload_tween.is_valid():
		_reload_tween.kill()
	if _pump_tween != null and _pump_tween.is_valid():
		_pump_tween.kill()

	var t := reload_time
	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_reload_tween = tween

	# Cant the weapon over so the loading port comes into view, support hand
	# off the forend and under the receiver.
	tween.tween_property(self, "_reload_offset", CANT_OFFSET, t * 0.15)
	tween.tween_property(self, "_reload_tilt", _cant_tilt(), t * 0.15)
	tween.tween_property(self, "left_hand_offset", HAND_TO_PORT, t * 0.15)

	# Shells go in one at a time, each its own dip to the belt and back.
	for i in shell_gestures:
		_thumb_shell(tween, t * (0.16 + 0.18 * i), t * 0.18)

	# Level out, hand back on the forend, then rack a shell into the chamber.
	tween.tween_property(self, "_reload_offset", Vector3.ZERO, t * 0.14).set_delay(t * 0.7)
	tween.tween_property(self, "_reload_tilt", Vector3.ZERO, t * 0.14).set_delay(t * 0.7)
	tween.tween_property(self, "left_hand_offset", Vector3.ZERO, t * 0.14).set_delay(t * 0.7)
	_rack(tween, t * 0.86, t * 0.12)

	tween.tween_callback(_finish_reload).set_delay(t)


## One shell: the hand drops out of frame to the belt and comes back to the
## port. Windows are sized so consecutive gestures never overlap -- two
## tweeners writing `left_hand_offset` at once would fight.
func _thumb_shell(tween: Tween, at: float, span: float) -> void:
	tween.tween_property(self, "left_hand_offset", HAND_TO_BELT, span * 0.45).set_delay(at)
	tween.tween_property(self, "left_hand_offset", HAND_TO_PORT, span * 0.45) \
		.set_delay(at + span * 0.5)
	tween.tween_callback(_play.bind(reload_sound, MAG_IN, 1.35, -7.0)) \
		.set_delay(at + span * 0.9)


## Forend back and forward again, the support hand riding it both ways.
func _rack(tween: Tween, at: float, span: float) -> void:
	tween.tween_property(forend, "position", _forend_rest + PUMP_STROKE, span * 0.4) \
		.set_delay(at)
	tween.tween_property(self, "left_hand_offset", PUMP_STROKE, span * 0.4).set_delay(at)
	tween.tween_callback(_play.bind(reload_sound, BOLT, 0.85, -5.0)).set_delay(at + span * 0.4)

	tween.tween_property(forend, "position", _forend_rest, span * 0.4) \
		.set_delay(at + span * 0.5)
	tween.tween_property(self, "left_hand_offset", Vector3.ZERO, span * 0.4) \
		.set_delay(at + span * 0.5)
	tween.tween_callback(_play.bind(reload_sound, BOLT, 1.05, -7.0)).set_delay(at + span * 0.92)


func _finish_reload_state() -> void:
	super()
	if _pump_tween != null and _pump_tween.is_valid():
		_pump_tween.kill()
	forend.position = _forend_rest
