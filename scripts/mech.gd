class_name Mech
extends Tank

## A walking gun platform: the tank's insides on a pair of legs.
##
## It is a Tank on purpose rather than by laziness. Everything that makes a
## vehicle a vehicle here -- climbing in, the camera and the controls changing
## hands, being taken over across the wire by whoever got in first, armour that
## ignores rifle fire, and the two weapons -- is the same machine underneath and
## has already been got right once. What is genuinely different about a walker
## is how it moves and what that looks like, and that is all this file is.
##
## So there is no netcode here, and no firing code. If either misbehaves it
## misbehaves identically in the tank, which is the point: one bug, one place.
##
## The gait is driven by distance covered rather than by a clock. A leg cycle
## belongs to the ground it crosses, so the legs cannot skate when the hull is
## slowed by a slope or stopped dead against a wall -- if the machine is not
## getting anywhere, its feet are not moving either.

@export_group("Gait")
## Metres of travel per full two-step cycle. Roughly twice the stride, and the
## one number that decides whether the walk reads as heavy or as scurrying.
@export var stride := 3.4
## Degrees the thigh swings either side of vertical at full stride.
@export var leg_swing := 26.0
## Degrees the knee folds at the top of the swing. Only ever backwards: a knee
## that bent the other way would read as a broken leg rather than a stride.
@export var knee_bend := 34.0
## How much of the leg's angle the ankle takes back out again, so the sole stays
## somewhere near flat instead of pointing at the sky. 1.0 is perfectly level.
@export var ankle_level := 0.75
## Metres the hull rises and falls over a step.
@export var body_bob := 0.07
## Turning on the spot still shuffles the feet. Metres of imaginary travel per
## radian turned, so a mech spinning in place is not a statue on a turntable.
@export var turn_shuffle := 0.8

## Footfalls, one per half cycle. Infantry boots dropped a long way in pitch:
## the samples are already the right shape, and a heavy thing landing is the
## same event as a light thing landing, slower.
const FOOTFALLS: Array[AudioStream] = [
	preload("res://assets/audio/footstep_01.wav"),
	preload("res://assets/audio/footstep_02.wav"),
	preload("res://assets/audio/footstep_03.wav"),
	preload("res://assets/audio/footstep_04.wav"),
]

@onready var leg_l: Node3D = $LegL
@onready var leg_r: Node3D = $LegR
@onready var knee_l: Node3D = $LegL/Knee
@onready var knee_r: Node3D = $LegR/Knee
@onready var ankle_l: Node3D = $LegL/Knee/Ankle
@onready var ankle_r: Node3D = $LegR/Knee/Ankle

## Where in the two-step cycle the legs are, in radians.
var _phase := 0.0
## Eased rather than switched, so the legs settle to standing instead of
## freezing mid-stride the moment the throttle comes off.
var _gait_power := 0.0
## Which half cycle the last footfall was played on, so one step makes one bang.
var _last_half := 0
var _torso_rest_y := 0.0


func _ready() -> void:
	super()
	_torso_rest_y = turret.position.y
	# The tank sets this to a looping tread bed. A walker has footfalls instead:
	# discrete, one per step, played from _animate_gait. Replaced after the
	# parent has had its say rather than instead of it, so the tread sample is
	# left exactly as the tank found it -- these streams are shared, and looping
	# one here would loop it for everybody using it.
	tread_sound.stream = FOOTFALLS[0]


## Distance is the clock. Everything below reads how far the machine actually
## got this frame, which is why it works just as well for a mech being driven by
## somebody else: that one is not simulated at all, it is lerped toward the pose
## its driver reported, and the legs still have real ground to measure.
func _physics_process(delta: float) -> void:
	var before := global_position
	var yaw_before := rotation.y
	super(delta)
	_animate_gait(before, yaw_before, delta)


func _animate_gait(before: Vector3, yaw_before: float, delta: float) -> void:
	# A wreck is being thrown about by a tween that owns the same nodes. Two
	# things writing one transform is one thing too many.
	if is_dead():
		return

	var moved := Vector2(global_position.x - before.x, global_position.z - before.z)
	var forward := -global_basis.z
	# Signed along the machine's own nose, so walking backwards walks the legs
	# backwards rather than playing the same loop either way.
	var along := moved.dot(Vector2(forward.x, forward.z))
	var turned := absf(angle_difference(yaw_before, rotation.y)) * turn_shuffle
	var travelled := along + (turned if along >= 0.0 else -turned)

	_phase = wrapf(_phase + TAU * travelled / maxf(stride, 0.01), -PI, PI)

	# Whether the legs should be doing anything at all, eased both ways.
	var wants: float = 1.0 if absf(travelled) > delta * 0.15 else 0.0
	_gait_power = move_toward(_gait_power, wants, delta * 4.0)

	var swing := deg_to_rad(leg_swing) * _gait_power
	var bend := deg_to_rad(knee_bend) * _gait_power
	_pose_leg(leg_l, knee_l, ankle_l, _phase, swing, bend)
	_pose_leg(leg_r, knee_r, ankle_r, _phase + PI, swing, bend)

	# The hull drops as each foot takes the weight -- twice a cycle, which is
	# why this is doubled against the leg phase.
	turret.position.y = _torso_rest_y - absf(sin(_phase)) * body_bob * _gait_power

	_maybe_footfall()


## One leg, posed from where it is in the cycle.
##
## The thigh swings about the hip, the knee folds only while the leg is coming
## through, and the ankle takes most of that back out again so the foot meets
## the ground flat rather than toe-first.
func _pose_leg(
	leg: Node3D, knee: Node3D, ankle: Node3D, phase: float, swing: float, bend: float
) -> void:
	var lift := sin(phase)
	leg.rotation.x = lift * swing
	# Negative folds the shin backwards, which is the only way a leg bends.
	knee.rotation.x = -maxf(lift, 0.0) * bend
	ankle.rotation.x = -(leg.rotation.x + knee.rotation.x) * ankle_level


## A bang as each foot comes down. The cycle crosses zero and pi once each per
## two steps, and those two crossings are the two feet landing.
func _maybe_footfall() -> void:
	var half := 0 if _phase >= 0.0 else 1
	if half == _last_half:
		return
	_last_half = half
	if _gait_power < 0.5 or not is_on_floor():
		return
	tread_sound.stream = FOOTFALLS[randi() % FOOTFALLS.size()]
	# Dropped most of an octave, and jittered, so a walk is not a metronome.
	tread_sound.pitch_scale = randf_range(0.5, 0.62)
	tread_sound.play()


func round_reset() -> void:
	super()
	_phase = 0.0
	_gait_power = 0.0
	_pose_leg(leg_l, knee_l, ankle_l, 0.0, 0.0, 0.0)
	_pose_leg(leg_r, knee_r, ankle_r, PI, 0.0, 0.0)
	turret.position.y = _torso_rest_y


## Same shape as the tank's readout, different words on it: what this carries is
## an autocannon and a machine gun, not a 75 and a coax.
func status_text() -> String:
	if is_dead():
		return "MECH  WRECKED"
	return "CANNON %d  ·  MG %d  ·  HULL %d" % [_main_left, _coax_left, roundi(health)]
