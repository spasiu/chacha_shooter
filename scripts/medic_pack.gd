class_name MedicPack
extends Equipment

## Field dressing satchel. Put it on a man who is still up and he is whole
## again; put it on one who is down and he is back on his feet at his own base,
## and his side never loses the man.
##
## That second half is the point of carrying it. Every death costs a side one of
## its hundred, so a medic who reaches a body before it gives up is not saving a
## teammate a walk -- he is taking a casualty back off the board that the other
## side has already paid for. A stretcher party working a contested position is
## worth more to the count than the rifle he is not firing.
##
## It works on the living and the dead alike and cannot be used on yourself:
## somebody else has to come for you, which is what makes going down a thing
## your side has to answer rather than a private inconvenience.

## Treatments carried. Few on purpose -- an endless supply of them would make
## the attrition count meaningless, which is the one number the whole match is
## played against.
@export var charges := 4
## How close you have to be, in metres. Arm's length and a bit: the medic has to
## come to the casualty and stand still in the open to do it.
@export var reach := 4.0
## Seconds spent working, during which nothing else can be done.
@export var use_time := 1.4
## How far off the crosshair a man can be and still be reached, in degrees.
## Generous, because a body lying in long grass is not an easy thing to aim at.
@export var aim_cone := 30.0
## Where on a body the treatment is aimed, above their feet. Chest height on
## somebody standing, and still inside somebody lying down.
@export var target_height := 0.9

const AID_SOUND: AudioStream = preload("res://assets/audio/mag_in.wav")
const REFUSED: AudioStream = preload("res://assets/audio/bolt.wav")

@onready var body: Node3D = $Body
@onready var sound: AudioStreamPlayer = $Sound

var _starting_charges := 0
var _busy := false
var _pulled := false
## What the readout last had to say, so a refusal lingers long enough to read.
var _message := ""
var _message_left := 0.0


func _ready() -> void:
	_starting_charges = charges


func restock() -> void:
	charges = _starting_charges
	on_holstered()


func on_equipped() -> void:
	body.visible = charges > 0


func on_holstered() -> void:
	_pulled = false
	_busy = false
	_message = ""
	_message_left = 0.0
	body.visible = charges > 0


func is_busy() -> bool:
	return _busy


func is_empty() -> bool:
	return charges <= 0


func status_text() -> String:
	if _message_left > 0.0:
		return _message
	if _busy:
		return "TREATING..."
	return "MEDIC PACK  %d" % charges


func release_trigger() -> void:
	_pulled = false


func _process(delta: float) -> void:
	_message_left = maxf(_message_left - delta, 0.0)


## One press, one treatment. Held down does nothing further: a medic pack is not
## something you can lean on.
func try_fire() -> bool:
	var held := _pulled
	_pulled = true
	if held or _busy or charges <= 0:
		return false

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return false
	var patient := _nearest_casualty(camera)
	if patient == null:
		_refuse("NOBODY IN REACH")
		return false

	# Spent whichever way it goes from here. Reaching a man and finding him
	# beyond help still costs the dressing.
	charges -= 1
	body.visible = charges > 0
	_busy = true
	_treat(patient)

	sound.stream = AID_SOUND
	sound.pitch_scale = 0.9
	sound.volume_db = -4.0
	sound.play()

	var tween := create_tween()
	tween.tween_interval(use_time)
	tween.tween_callback(_finish)
	return true


func _treat(patient: Node3D) -> void:
	if patient.is_dead():
		Net.report_revive(patient.peer_id)
		_say("STRETCHERING %s" % Net.name_of(patient.peer_id))
	else:
		Net.report_heal(patient.peer_id)
		_say("PATCHED %s" % Net.name_of(patient.peer_id))


## The friendly soldier nearest the crosshair and inside arm's reach, dead or
## alive. Chosen by angle rather than by a ray, because a body on the ground has
## its collider switched off -- a corpse does not stop bullets -- so there is
## nothing there for a ray to find.
func _nearest_casualty(camera: Camera3D) -> Node3D:
	var forward := -camera.global_basis.z
	var best: Node3D = null
	var best_dot := cos(deg_to_rad(aim_cone))
	for soldier in Net.soldiers():
		if Net.team_of(soldier.peer_id) != Net.my_team():
			continue
		var to: Vector3 = (
			soldier.global_position + Vector3.UP * target_height - camera.global_position
		)
		var away := to.length()
		if away > reach or away < 0.01:
			continue
		var alignment := forward.dot(to / away)
		if alignment > best_dot:
			best_dot = alignment
			best = soldier
	return best


func _refuse(why: String) -> void:
	_say(why)
	sound.stream = REFUSED
	sound.pitch_scale = 0.7
	sound.volume_db = -12.0
	sound.play()


func _say(text: String) -> void:
	_message = text
	_message_left = 2.0


func _finish() -> void:
	_busy = false
	body.visible = charges > 0
