class_name Bazooka
extends Weapon

## Shoulder-fired rocket launcher.
##
## Every other weapon here hands its lethality to whatever the ray struck. This
## hands it to everything standing near where the rocket went off, falling away
## over its own much tighter set of bands. Blast is overpressure rather than
## fragments, so unlike a grenade it is not traced out along sightlines: ducking
## behind a wall does not spare you, though the wall itself may not survive
## either.

## How far out the blast still bothers the terrain. Only the innermost band by
## default, for two reasons: past it the numbers are noise against a block's
## thousand health, and the cell loop grows with the cube of the reach.
@export var crater_yards := 1.0
## Trim on each voice of the burst. Loud on purpose -- it should carry across
## the map and be plainly the biggest thing in the mix.
const BURST_VOLUME_DB := 8.0

## Left-hand waypoints for the reload, as offsets from its rest on the foregrip.
const HAND_TO_BREECH := Vector3(0.0, -0.02, 0.42)
const HAND_OFF := Vector3(0.05, -0.32, 0.34)
## Where a fresh rocket waits before being slid down the tube.
const ROCKET_BACK := Vector3(0.0, -0.03, 0.34)

@onready var rocket: MeshInstance3D = $Rocket

var _rocket_rest := Vector3.ZERO


## Everything inside this is in reach of the blast. Taken from the last band
## edge, because past there the profile has nothing left to give anyway.
var blast_radius: float:
	get:
		if band_yards.is_empty():
			return 0.0
		return float(band_yards[band_yards.size() - 1]) * Lethality.YARD


func _ready() -> void:
	super()
	_rocket_rest = rocket.position


## One rocket: fly it out along the shot and set it off wherever it stops.
## Overrides the pellet loop outright -- a launcher fires one thing, and what
## matters is where it lands rather than what the ray happened to touch.
func _raycast() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var origin := camera.global_position
	var spread := deg_to_rad(lerpf(min_spread, max_spread, _bloom)) * lerpf(
		1.0, aim_spread_factor, _aim
	)
	var direction := _shot_direction(camera, spread)

	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_range)
	if _shooter != null:
		query.exclude = [_shooter.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# A rocket that finds nothing burns out at the end of its run.
	var burst: Vector3 = hit.position if not hit.is_empty() else origin + direction * max_range

	_detonate(burst)


## Sets the warhead off. All three parts are Blast's, so a rocket and an
## artillery shell go off in exactly the same way.
func _detonate(at: Vector3) -> void:
	Blast.hurt(get_tree(), at, band_yards, _bands())
	Blast.crater(get_tree(), at, band_yards, _bands(), crater_yards)
	Blast.effect(
		get_tree().current_scene, at, 22.0, blast_radius * 2.0, BURST_VOLUME_DB, true
	)
	# A rocket has no projectile anyone else has a copy of -- it is traced and
	# spent in the same frame -- so the flash and the bang have to be sent. The
	# crater travels on its own, as terrain damage, and the casualties were told
	# directly by `hurt` above.
	Net.report_blast(at, 22.0, blast_radius * 2.0, BURST_VOLUME_DB, true, 0.0)


## This rocket's own profile, in the shape Blast wants it.
func _bands() -> Array:
	return [damage_short, damage_medium, damage_long, damage_beyond]


## Tube comes down off the shoulder, a fresh rocket goes in the back of it, and
## it goes back up. Same timeline shape as the base reload: every delay is a
## fraction of `reload_time`.
func _run_reload_animation() -> void:
	if _reload_tween != null and _reload_tween.is_valid():
		_reload_tween.kill()

	var t := reload_time
	var tween := create_tween().set_parallel(true)
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_reload_tween = tween

	# Off the shoulder, support hand back to the breech.
	tween.tween_property(self, "_reload_offset", CANT_OFFSET, t * 0.18)
	tween.tween_property(self, "_reload_tilt", _cant_tilt(), t * 0.18)
	tween.tween_property(self, "left_hand_offset", HAND_TO_BREECH, t * 0.18)

	# The spent round clears the tube and the hand drops out of frame for another.
	tween.tween_property(rocket, "position", _rocket_rest + ROCKET_BACK, t * 0.16) \
		.set_delay(t * 0.18)
	tween.tween_callback(rocket.hide).set_delay(t * 0.34)
	tween.tween_property(self, "left_hand_offset", HAND_OFF, t * 0.2).set_delay(t * 0.34)
	tween.tween_callback(_play.bind(reload_sound, MAG_OUT, 0.8, -4.0)).set_delay(t * 0.2)

	# Back with a fresh one, and slide it home.
	tween.tween_callback(_present_fresh_rocket).set_delay(t * 0.56)
	tween.tween_property(self, "left_hand_offset", HAND_TO_BREECH, t * 0.14).set_delay(t * 0.56)
	tween.tween_property(rocket, "position", _rocket_rest, t * 0.18) \
		.set_ease(Tween.EASE_IN).set_delay(t * 0.6)
	tween.tween_callback(_play.bind(reload_sound, MAG_IN, 0.75, -3.0)).set_delay(t * 0.78)

	# Back onto the shoulder.
	tween.tween_property(self, "_reload_offset", Vector3.ZERO, t * 0.18).set_delay(t * 0.8)
	tween.tween_property(self, "_reload_tilt", Vector3.ZERO, t * 0.18).set_delay(t * 0.8)
	tween.tween_property(self, "left_hand_offset", Vector3.ZERO, t * 0.16).set_delay(t * 0.82)

	tween.tween_callback(_finish_reload).set_delay(t)


func _present_fresh_rocket() -> void:
	rocket.position = _rocket_rest + ROCKET_BACK
	rocket.show()


func _finish_reload_state() -> void:
	super()
	rocket.position = _rocket_rest
	rocket.show()
