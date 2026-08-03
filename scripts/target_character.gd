class_name TargetCharacter
extends StaticBody3D

## A shootable character. Holds health, reacts to hits, collapses when killed
## and (optionally) gets back up so it can be used as a range target.

signal health_changed(current: float, maximum: float)
signal died

@export var max_health := 100.0
## Multiplier applied to hits landing above `head_height`.
@export var headshot_multiplier := 2.5
## Height above the character's feet at which a hit counts as a headshot.
@export var head_height := 1.32
## Seconds before it stands back up. Zero leaves the body down for good.
@export var respawn_delay := 6.0

const HIT_FLESH: AudioStream = preload("res://assets/audio/hit_flesh.wav")
const HIT_HEAD: AudioStream = preload("res://assets/audio/hit_head.wav")
const BODY_FALL: AudioStream = preload("res://assets/audio/body_fall.wav")

@onready var model: CharacterModel = $CharacterBody
@onready var collision: CollisionShape3D = $CollisionShape3D
@onready var health_bar: Node3D = $HealthBar
@onready var health_fill: Node3D = $HealthBar/FillPivot
@onready var hit_sound: AudioStreamPlayer3D = $HitSound

var health := 0.0
var _alive := true


func _ready() -> void:
	health = max_health
	health_changed.emit(health, max_health)


func _process(delta: float) -> void:
	# Standing idle, but still ticked so the death collapse blends in.
	model.set_gait(0.0, 0.0, true, 0.0, delta)

	# Face the bar at whichever camera is live, upright.
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var away := health_bar.global_position - camera.global_position
	if away.length_squared() > 0.0001:
		health_bar.global_basis = Basis.looking_at(away, Vector3.UP)


## Called by the weapon's raycast. `from_shooter` points back at whoever fired.
func take_damage(amount: float, hit_position: Vector3, from_shooter: Vector3) -> void:
	if not _alive:
		return

	var local_height := hit_position.y - global_position.y
	var headshot := local_height > head_height
	if headshot:
		amount *= headshot_multiplier

	# Bullet travelling the same way we face means it came in through our back.
	var from_behind := from_shooter.dot(-global_basis.z) < 0.0

	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	_update_bar()

	hit_sound.stream = HIT_HEAD if headshot else HIT_FLESH
	hit_sound.pitch_scale = randf_range(0.94, 1.08)
	hit_sound.play()

	if health <= 0.0:
		_die(from_behind)
	else:
		model.flinch(clampf(amount / 25.0, 0.3, 1.4), from_behind)


func _die(from_behind: bool) -> void:
	_alive = false
	model.die(from_behind)
	# Stop blocking movement and bullets once down.
	collision.set_deferred("disabled", true)
	health_bar.visible = false
	died.emit()

	await get_tree().create_timer(model.death_time * 0.75).timeout
	if is_instance_valid(self):
		hit_sound.stream = BODY_FALL
		hit_sound.pitch_scale = randf_range(0.95, 1.05)
		hit_sound.play()

	if respawn_delay <= 0.0:
		return
	await get_tree().create_timer(respawn_delay).timeout
	if is_instance_valid(self):
		revive()


func revive() -> void:
	health = max_health
	_alive = true
	model.revive()
	collision.set_deferred("disabled", false)
	health_bar.visible = true
	_update_bar()
	health_changed.emit(health, max_health)


func _update_bar() -> void:
	health_fill.scale.x = maxf(health / max_health, 0.001)
