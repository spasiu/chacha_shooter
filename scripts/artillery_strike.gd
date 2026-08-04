class_name ArtilleryStrike
extends Node3D

## A fire mission, from the moment it is called to the last shell landing.
##
## Added to the world by the radio and left to run itself, so the caller can
## switch weapons, wander off or die without affecting what is already in the
## air. Nothing about it is tied to whoever called it.
##
## Timeline, from `call_in`:
##   0s                        the guns are told
##   impact - warning_lead     they fire: the report carries, and the target is
##                             painted large enough for anyone to see
##   impact                    the barrage begins
##   impact + barrage_time     the last shell lands
##
## Each shell is a bazooka rocket: same warhead, same code, by way of Blast.
## Not grenades, because a grenade sprays nine hundred fragment rays and a
## hundred of those would be ninety thousand raycasts a barrage. A rocket
## applies its damage by distance from where it lands instead, which costs
## nothing and is what makes a hundred of them affordable.

signal landed

## Where shells can fall, measured from the painted point.
@export var radius_yards := 50.0
@export var shells := 100
## Seconds from the call to the first shell.
@export var time_to_impact := 30.0
## How far ahead of impact the guns are heard and the target goes up.
@export var warning_lead := 5.0
## Seconds the barrage takes to walk through all its shells. Spread out both
## because a battery does not land a hundred rounds at once, and because it
## keeps the work off any single frame.
@export var barrage_time := 4.5

@export_group("One shell")
## A shell is a bazooka rocket. Same warhead, same numbers, same code -- see
## Blast. Overridable here if a fire mission should ever carry something else.
@export var shell_yards := Blast.ROCKET_YARDS
@export var shell_damage := Blast.ROCKET_DAMAGE
## How far out a shell chews up the ground. Small on purpose: a hundred of
## these, and the cell loop grows with the cube of the reach.
@export var crater_yards := 1.0
## One in this many shells is loud and lit. All hundred would be a wall of
## overlapping players and lights for no extra drama.
@export var effect_every := 4

const CANNON: AudioStream = preload("res://assets/audio/cannon_fire.wav")

@onready var marker: Node3D = $Marker
## Only the ground ring is sized to the zone; the column stays as authored.
@onready var zone: Node3D = $Marker/Zone
@onready var cannon_sound: AudioStreamPlayer = $CannonSound

var _fired := 0
var _elapsed := 0.0
var _falling := false


func _ready() -> void:
	marker.visible = false
	set_process(false)


## Starts the clock. `at` is the painted point, in world space.
func call_in(at: Vector3) -> void:
	global_position = at
	zone.scale = Vector3.ONE * (radius_yards * Lethality.YARD)

	var lead := maxf(time_to_impact - warning_lead, 0.0)
	get_tree().create_timer(lead).timeout.connect(_warn)
	get_tree().create_timer(time_to_impact).timeout.connect(_begin)


## The guns fire. The report reaches everyone at once wherever they are -- the
## battery is miles off, not somewhere on the map -- and the target goes up
## bright enough to be worth running away from.
func _warn() -> void:
	marker.visible = true
	var settled := zone.scale
	var pulse := create_tween().set_loops()
	pulse.tween_property(zone, "scale", settled * 1.04, 0.45)
	pulse.tween_property(zone, "scale", settled, 0.45)
	cannon_sound.play()


func _begin() -> void:
	_falling = true
	_elapsed = 0.0
	set_process(true)


## Walks through the shells over `barrage_time` rather than dropping them in
## one frame.
func _process(delta: float) -> void:
	if not _falling:
		return
	_elapsed += delta
	var due := shells if barrage_time <= 0.0 else int(
		ceil(shells * minf(_elapsed / barrage_time, 1.0))
	)
	while _fired < due:
		_land_shell()
		_fired += 1
	if _fired >= shells:
		_falling = false
		set_process(false)
		marker.visible = false
		landed.emit()
		# Outlive the last bang so it is not cut off.
		get_tree().create_timer(4.0).timeout.connect(queue_free)


## Drops one shell somewhere inside the beaten zone.
func _land_shell() -> void:
	var reach := radius_yards * Lethality.YARD
	# Square root keeps the scatter even across the circle instead of piling it
	# all into the middle.
	var angle := randf() * TAU
	var distance := sqrt(randf()) * reach
	var at := global_position + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
	at = _ground_under(at)

	Blast.hurt(get_tree(), at, shell_yards, shell_damage)
	Blast.crater(get_tree(), at, shell_yards, shell_damage, crater_yards)
	if _fired % effect_every == 0:
		Blast.effect(self, at + Vector3.UP * 0.5, 16.0, 9.0, 4.0)
		# Only the shells that make a show of themselves are worth sending; a
		# hundred rounds of pure bookkeeping across the wire would say nothing
		# the craters do not already say.
		Net.report_blast(at + Vector3.UP * 0.5, 16.0, 9.0, 4.0, false, 0.0)


## Puts the shell on the ground rather than wherever the circle happened to
## sit, so a strike across a hillside lands on the hillside.
func _ground_under(at: Vector3) -> Vector3:
	var from := at + Vector3.UP * 40.0
	var query := PhysicsRayQueryParameters3D.create(from, at + Vector3.DOWN * 40.0)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position if not hit.is_empty() else at
