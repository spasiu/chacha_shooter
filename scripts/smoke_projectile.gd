extends RigidBody3D

## Thrown smoke canister. It does not detonate: after a short delay it starts
## pouring smoke, keeps going for `duration`, then stops and waits for the last
## particles to die before removing itself.
##
## Smoke is cover you can see through the edges of, not a wall -- rounds pass
## straight through it, which is what smoke does.

## Delay between landing and the canister lighting off.
@export var fuse_time := 1.1
## Seconds it pours smoke for.
@export var duration := 15.0

const HISS: AudioStream = preload("res://assets/audio/smoke_hiss.wav")

## True on everyone's copy but the thrower's. Smoke hurts nobody and takes
## nothing out of the ground, so a ghost canister behaves identically -- the
## flag exists so every thrown thing answers to the same question.
var net_ghost := false

@onready var canister: Node3D = $Body
@onready var smoke: GPUParticles3D = $Smoke
@onready var sound: AudioStreamPlayer3D = $Sound

var _lit := false


func _ready() -> void:
	smoke.emitting = false
	get_tree().create_timer(fuse_time).timeout.connect(_light)


func _light() -> void:
	if _lit:
		return
	_lit = true
	smoke.emitting = true
	sound.stream = HISS
	sound.play()
	get_tree().create_timer(duration).timeout.connect(_burn_out)


func _burn_out() -> void:
	smoke.emitting = false
	# Outlive the last particle rather than popping the cloud out of existence.
	get_tree().create_timer(smoke.lifetime + 1.0).timeout.connect(queue_free)
