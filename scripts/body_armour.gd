class_name BodyArmour
extends Equipment

## Plate carrier. Worn, never held: same arrangement as the jump jet, and for
## the same reason -- there is no sense in which you draw a flak vest.
##
## It does three things and they are meant to pull against each other. Twice the
## man to kill and half the damage from anything arriving at the front plate,
## bought with half your speed, in every stance, all the time. Nothing about it
## is situational: you are wearing it in the open and you are wearing it running
## for cover, and the second one is where it hurts.
##
## It decides nothing itself. Player asks it what a hit should become and how
## fast a man in it moves; the armour only knows its own numbers.
## That keeps the one place where damage is worked out as the one place where
## damage is worked out.

## What is left of your pace while wearing it.
@export_range(0.1, 1.0, 0.05) var speed_factor := 0.5
## Multiplies the health you spawn with.
@export var health_multiplier := 2.0
## What reaches you through the front plate.
@export_range(0.0, 1.0, 0.05) var front_factor := 0.5
## Half-angle of the plate's cover, in degrees. Ninety is the whole front of
## you: the back plate is thinner in life and is thinner here too, which is to
## say absent.
@export var front_degrees := 90.0


## What `amount` becomes, given where it came from. `from` points back toward
## whoever fired, the way everything reports it.
##
## Everything is halved at the front, not only bullets: a plate carrier is worn
## against fragments as much as rounds, and that is most of what it is for.
func absorb(amount: float, from: Vector3, facing: Vector3) -> float:
	if not covers(from, facing):
		return amount
	return amount * front_factor


## Whether the front plate is between you and where this came from.
func covers(from: Vector3, facing: Vector3) -> bool:
	var flat_from := Vector2(from.x, from.z)
	var flat_face := Vector2(facing.x, facing.z)
	if flat_from.length_squared() < 1e-6 or flat_face.length_squared() < 1e-6:
		return false
	var away := rad_to_deg(flat_face.normalized().angle_to(flat_from.normalized()))
	# A hair of tolerance, so a hit arriving exactly side-on is on the rim of the
	# arc rather than outside it.
	return absf(away) <= front_degrees + 0.01


func try_fire() -> bool:
	return false


func wants_third_person() -> bool:
	return false


func reticule_size() -> float:
	return 0.0


func status_text() -> String:
	return "PLATE"


func is_empty() -> bool:
	return false
