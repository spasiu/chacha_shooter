class_name Lethality

## Shared range-band damage model. Every weapon quotes lethality out of 100 in
## three bands, and anything past the longest band falls to a floor value.
##
## Bands are in yards because that is how the weapon tables are written; the
## world is in metres, so conversion happens here rather than at each call site.

const YARD := 0.9144

## Anything that can be hurt joins this. A blast finds its casualties by asking
## the tree rather than by running a shape query, because over voxel terrain a
## query fills its result limit with chunk colliders long before it reaches a
## character -- and blast ignores line of sight anyway, so the physics engine
## was not earning its keep.
const DAMAGEABLE := &"damageable"

## What did the damage. Passed to `take_damage` so armour can ignore what it is
## proof against -- a tank shrugs off rifle fire and shrapnel but not a shell.
## Everything that hurts something names itself with one of these.
const BULLET := &"bullet"
const FRAGMENT := &"fragment"
const BLAST := &"blast"
const MELEE := &"melee"

const SHORT_YARDS := 5.0
const MEDIUM_YARDS := 25.0
const LONG_YARDS := 125.0

## Edges of the small-arms curve, which is what a weapon uses unless it names
## its own.
const SMALL_ARMS_YARDS := [SHORT_YARDS, MEDIUM_YARDS, LONG_YARDS]

const SHORT_RANGE := SHORT_YARDS * YARD
const MEDIUM_RANGE := MEDIUM_YARDS * YARD
const LONG_RANGE := LONG_YARDS * YARD


## `bands` is [short, medium, long, beyond], on the small-arms curve.
static func at_range(metres: float, bands: Array) -> float:
	return banded(metres, SMALL_ARMS_YARDS, bands)


## The same idea with the edges supplied, for anything whose falloff is not the
## small-arms curve: a blast is spent over a few yards rather than hundreds of
## them. `edges_yards` holds the outer edge of each band, and `values` carries
## one more entry than that -- whatever is left past the final edge.
static func banded(metres: float, edges_yards: Array, values: Array) -> float:
	for i in mini(edges_yards.size(), values.size() - 1):
		if metres < float(edges_yards[i]) * YARD:
			return float(values[i])
	return float(values[values.size() - 1])


## Which band a distance falls in, for readouts and tests.
static func band_name(metres: float) -> String:
	if metres < SHORT_RANGE:
		return "short"
	if metres < MEDIUM_RANGE:
		return "medium"
	if metres < LONG_RANGE:
		return "long"
	return "beyond"


## Bodies within `radius` of a burst, each paired with the nearest point on it
## and how far away that point was. Measuring to a standing body rather than to
## its origin, which sits down at the feet, is what makes a burst at chest
## height read as a direct hit instead of one a yard off.
##
## Returns an array of [body, point, distance].
static func casualties_near(
	tree: SceneTree, at: Vector3, radius: float, height: float
) -> Array:
	var found: Array = []
	for node in tree.get_nodes_in_group(DAMAGEABLE):
		if not (node is Node3D) or not node.has_method("take_damage"):
			continue
		var foot: Vector3 = (node as Node3D).global_position
		var point := Geometry3D.get_closest_point_to_segment(
			at, foot, foot + Vector3.UP * height
		)
		var distance := at.distance_to(point)
		if distance <= radius:
			found.append([node, point, distance])
	return found
