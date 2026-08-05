class_name JumpJet
extends Equipment

## Back-mounted jump jet. Worn rather than held.
##
## Everything else in the catalogue is something a soldier picks up and points.
## This is the one thing that is only ever worn: it never goes in the hands, it
## has no sights and no trigger, and there is no slot key that brings it out.
## Choosing it costs a pick on the loadout screen and after that it is simply
## on, which is what "always equipped" has to mean for a thing strapped to your
## back.
##
## Because of that it is deliberately dumb. It knows how much burn is left and
## what its nozzles are doing; the flying itself belongs to Player, which is the
## only thing that knows whether there is ground underneath. That split is the
## same one the vehicles use, and it keeps two quite different sets of movement
## rules from having to share a script.

## Seconds of air time in a full pack, spent whenever the wearer is off the
## ground rather than only while the nozzles are lit. Standing on a roof costs
## nothing; hanging in the air costs, whether you are climbing, hovering or
## dropping, because the pack is what is keeping you up either way.
@export var fly_seconds := 60.0
## Metres per second climbed with the jump key held.
@export var climb_speed := 4.2
## Metres per second dropped with the crouch key held. Faster than the climb:
## coming down is the easy direction.
@export var descend_speed := 6.5
## How hard the nozzles take hold, in metres per second squared. High enough to
## feel like thrust rather than a balloon.
@export var thrust_accel := 16.0
## What is left of gravity while airborne with neither key held, so a pack that
## is on but idle sinks slowly instead of hanging.
@export_range(0.0, 1.0, 0.05) var idle_gravity := 0.35

const BURN: AudioStream = preload("res://assets/audio/engine_rumble.wav")

@onready var flame_left: GPUParticles3D = $NozzleLeft/Flame
@onready var flame_right: GPUParticles3D = $NozzleRight/Flame
@onready var smoke_left: GPUParticles3D = $NozzleLeft/Smoke
@onready var smoke_right: GPUParticles3D = $NozzleRight/Smoke
@onready var burn_sound: AudioStreamPlayer3D = $BurnSound

## Seconds of burn left in the pack.
var fuel := 0.0

var _burning := false


func _ready() -> void:
	fuel = fly_seconds
	burn_sound.stream = BURN
	_set_jets(false)


func has_fuel() -> bool:
	return fuel > 0.0


func fuel_ratio() -> float:
	return clampf(fuel / maxf(fly_seconds, 0.001), 0.0, 1.0)


## Burns down the tank. There is no reload: the pack is refilled at your own
## base, the same place and by the same rule as ammunition, or by dying.
func spend(seconds: float) -> void:
	fuel = maxf(fuel - seconds, 0.0)
	if fuel <= 0.0 and _burning:
		_set_jets(false)


func refill() -> void:
	fuel = fly_seconds


## Your own base fills everything you carry, and a pack is something you carry.
## Hooking the existing call rather than adding one means the jet is filled by
## the same rule as ammunition, in the same place, with nothing to remember.
func restock() -> void:
	refill()


## Nozzles lit or out. Idempotent, because this is called every frame from the
## movement code and restarting particles forty times a second would leave the
## exhaust permanently one frame old.
func set_burning(on: bool) -> void:
	var wanted: bool = on and has_fuel()
	if wanted == _burning:
		return
	_set_jets(wanted)


func _set_jets(on: bool) -> void:
	_burning = on
	flame_left.emitting = on
	flame_right.emitting = on
	smoke_left.emitting = on
	smoke_right.emitting = on
	if on:
		if not burn_sound.playing:
			burn_sound.play()
	else:
		burn_sound.stop()


## What is left in the tanks, going off where the wearer fell.
##
## A pack of pressurised fuel strapped to a man's back is a bomb that has not
## gone off yet, and this is the bill for the mobility: the fuller it is, the
## worse it is to be near you when you drop. A share of a rocket's profile
## rather than a profile of its own, because a rocket is the thing in this game
## that already means "one warhead going off", and the share is simply what is
## left of the minute.
##
## Reported like any other blast so everybody's copy of the field agrees about
## it; the tank is emptied afterwards so it cannot go off twice.
func explode(tree: SceneTree, at: Vector3) -> void:
	if not has_fuel():
		return
	var share := fuel_ratio()
	var damage: Array = []
	for value in Blast.ROCKET_DAMAGE:
		damage.append(float(value) * share)
	Blast.hurt(tree, at, Blast.ROCKET_YARDS, damage)
	Blast.crater(tree, at, Blast.ROCKET_YARDS, damage, 1.0)
	# The noise and the flash scale too: a nearly empty pack should sound like
	# one, or the sight would promise damage it is not carrying.
	Blast.effect(tree.current_scene, at, 18.0 * share + 4.0, 12.0 * share, 4.0, true)
	Blast.shake(tree, 0.03 * share)
	Net.report_blast(at, 18.0 * share + 4.0, 12.0 * share, 4.0, true, 0.03 * share)
	fuel = 0.0
	_set_jets(false)


## Never in the hands, so nothing about being equipped applies to it. These are
## answered rather than inherited so that a jet which somehow did reach the
## weapon slot would sit there inert instead of firing something.
func try_fire() -> bool:
	return false


func wants_third_person() -> bool:
	return false


func status_text() -> String:
	return "JET %ds" % ceili(fuel)


func is_empty() -> bool:
	return not has_fuel()
