class_name Radio
extends Equipment

## Field radio. Picks a point on the ground and calls artillery onto it.
##
## Carrying it swings the view over the shoulder, because you are choosing a
## spot on the map rather than aiming at anything: a marker tracks wherever you
## are pointing, and pressing fire sends the grid reference. Everything after
## that belongs to the ArtilleryStrike it spawns, which runs its own clock in
## the world -- so switching away, or dying, does not call it off.

## Fire missions carried.
@export var calls := 3
## How far out a point can be painted.
@export var paint_range := 300.0
@export var strike_scene: PackedScene
@export var paint_scene: PackedScene
## Seconds of chatter between one handset transmission and the next, so holding
## the radio out does not machine-gun the sample.
@export var chatter_interval := 3.4

const CHATTER: AudioStream = preload("res://assets/audio/radio_chatter.wav")
const CALL: AudioStream = preload("res://assets/audio/radio_call.wav")
## The handset is at your ear; the call goes out at a shout.
const CHATTER_DB := -9.0
const CALL_DB := 5.0

@onready var body: Node3D = $Body
@onready var speaker: AudioStreamPlayer = $Speaker

var _starting_calls := 0
var _paint: Node3D
## Where the marker currently sits, and whether it is on anything at all.
var _paint_at := Vector3.ZERO
var _painting := false
var _chatter_wait := 0.0
var _pulled := false
## Whether the handset is actually out. `_process` runs on every item the
## player owns, equipped or not, and a radio muttering from inside the pack
## would be a puzzle.
var _out := false


func _ready() -> void:
	_starting_calls = calls


## The whole point of the thing: it is used from outside the body, looking at
## the ground, so the player puts the camera over the shoulder while it is out.
func wants_third_person() -> bool:
	return true


func restock() -> void:
	calls = _starting_calls
	on_holstered()


func on_equipped() -> void:
	_out = true
	body.visible = calls > 0
	_chatter_wait = 0.6


func on_holstered() -> void:
	_out = false
	_pulled = false
	_painting = false
	if _paint != null:
		_paint.queue_free()
		_paint = null


func _exit_tree() -> void:
	if _paint != null:
		_paint.queue_free()
		_paint = null


## Sends the mission. One press per call: the radio is not something you lean on.
func try_fire() -> bool:
	var held := _pulled
	_pulled = true
	if held or calls <= 0 or not _painting:
		return false

	calls -= 1
	body.visible = calls > 0
	_play(CALL, CALL_DB)
	# Suppress the idle chatter for as long as the call itself runs.
	_chatter_wait = CALL.get_length() + 1.5

	var scene_root := get_tree().current_scene
	if scene_root != null and strike_scene != null:
		var strike: Node3D = strike_scene.instantiate()
		scene_root.add_child(strike)
		strike.call_in(_paint_at)
	return true


func release_trigger() -> void:
	_pulled = false


func status_text() -> String:
	if calls <= 0:
		return "RADIO  NO CALLS LEFT"
	if not _painting:
		return "RADIO  %d  ·  NO TARGET" % calls
	return "RADIO  %d  ·  TARGET SET" % calls


func is_empty() -> bool:
	return calls <= 0


func is_full() -> bool:
	return calls >= _starting_calls


## Nothing to raise: the radio has no sights, and the view is already where it
## needs to be.
func sight_transform(_relief: float) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.06, -0.1, -0.3))


func _process(delta: float) -> void:
	if not _out:
		return
	_update_paint()

	# An open channel, muttering away to itself while the handset is out.
	_chatter_wait -= delta
	if _chatter_wait <= 0.0 and calls > 0:
		_chatter_wait = chatter_interval + randf_range(-0.8, 1.4)
		_play(CHATTER, CHATTER_DB)


## Walks the marker to whatever the player is looking at.
func _update_paint() -> void:
	_ensure_paint()
	if _paint == null or not _paint.is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var origin := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin - camera.global_basis.z * paint_range
	)
	var shooter := _find_ancestor_body()
	if shooter != null:
		query.exclude = [shooter.get_rid()]

	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	_painting = not hit.is_empty()
	_paint.visible = _painting and calls > 0
	if _painting:
		_paint_at = hit.position
		_paint.global_position = _paint_at


## Built on first use rather than on equip: the radio can be the item in hand
## before the world has finished setting itself up, and adding a child to a
## parent that is still building its own is refused.
func _ensure_paint() -> void:
	if _paint != null or paint_scene == null:
		return
	var scene_root := get_tree().current_scene
	if scene_root == null or not scene_root.is_inside_tree():
		return
	_paint = paint_scene.instantiate()
	scene_root.add_child(_paint)
	_paint.visible = false


func _play(stream: AudioStream, volume_db: float) -> void:
	speaker.stream = stream
	speaker.volume_db = volume_db
	speaker.play()


func _find_ancestor_body() -> CollisionObject3D:
	var node := get_parent()
	while node != null:
		if node is CollisionObject3D:
			return node
		node = node.get_parent()
	return null
