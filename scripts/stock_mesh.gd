@tool
class_name StockMesh
extends MeshInstance3D

## A piece of gunstock, built as one smooth surface.
##
## Wood was the last thing here still made of stacked primitives, and it showed:
## a run of separate tapered cylinders meets at hard edges, so a butt assembled
## from five of them reads as ribbed, like a caterpillar, however carefully the
## radii line up. There is no way round that with primitives -- the crease is
## between two meshes, and no amount of subdividing removes it.
##
## So this lofts one surface through the control points instead. Because it is a
## single mesh with averaged normals, it shades continuously from the fore-end
## to the buttplate, which is what makes a stock look carved rather than turned
## on a lathe in sections.
##
## A control point is (z, y, half_width, half_height): where along the weapon,
## how far the centre line has dropped, and the two radii of the oval there. The
## path between points is a Catmull-Rom spline, so the comb falls away in a
## curve rather than a series of ramps.

## The profile, front to back, in the weapon's own space.
@export var points: Array[Vector4] = []:
	set(value):
		points = value
		_rebuild()
## Samples between each pair of control points. The cost of smoothness, and it
## is cheap: a stock at 10 is a few hundred triangles.
@export_range(2, 24) var steps := 10:
	set(value):
		steps = value
		_rebuild()
## Sides to the oval.
@export_range(6, 32) var sides := 16:
	set(value):
		sides = value
		_rebuild()
@export var material: Material:
	set(value):
		material = value
		_rebuild()


func _ready() -> void:
	_rebuild()


## Catmull-Rom through the control points, clamped at both ends so the first and
## last points are actually reached rather than merely approached.
func _sample(t: float) -> Vector4:
	var n := points.size()
	if n == 0:
		return Vector4.ZERO
	if n < 3:
		return points[0].lerp(points[n - 1], t)
	var span := (n - 1) * t
	var i := clampi(int(span), 0, n - 2)
	var f := span - i
	var p0: Vector4 = points[maxi(i - 1, 0)]
	var p1: Vector4 = points[i]
	var p2: Vector4 = points[i + 1]
	var p3: Vector4 = points[mini(i + 2, n - 1)]
	var f2 := f * f
	var f3 := f2 * f
	return 0.5 * (
		2.0 * p1
		+ (p2 - p0) * f
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f3
	)


func _rebuild() -> void:
	if points.size() < 2:
		return
	var rings := (points.size() - 1) * steps + 1
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for r in rings:
		var p := _sample(float(r) / float(rings - 1))
		for s in sides:
			var a := TAU * float(s) / float(sides)
			st.set_uv(Vector2(float(s) / float(sides), float(r) / float(rings - 1)))
			st.add_vertex(Vector3(
				p.z * cos(a), p.y + p.w * sin(a), p.x
			))

	for r in rings - 1:
		for s in sides:
			var s1 := (s + 1) % sides
			var a := r * sides + s
			var b := r * sides + s1
			var c := (r + 1) * sides + s
			var d := (r + 1) * sides + s1
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(d)

	# Both ends are capped: the front runs into the receiver and the back into
	# the buttplate, but an open tube shows its own inside the moment either is
	# a millimetre out of place.
	# SurfaceTool will not say how many vertices it holds, so the cap centres are
	# counted rather than asked for: the rings above added rings * sides of them.
	var added := rings * sides
	for end: int in [0, rings - 1]:
		var p := _sample(0.0 if end == 0 else 1.0)
		var centre: int = added
		added += 1
		st.set_uv(Vector2(0.5, 0.5))
		st.add_vertex(Vector3(0.0, p.y, p.x))
		for s in sides:
			var s1: int = (s + 1) % sides
			var a: int = end * sides + s
			var b: int = end * sides + s1
			if end == 0:
				st.add_index(centre); st.add_index(a); st.add_index(b)
			else:
				st.add_index(centre); st.add_index(b); st.add_index(a)

	# Averaged across the seams, which is the whole point of building it as one
	# surface rather than as a stack of them.
	st.generate_normals()
	st.generate_tangents()
	mesh = st.commit()
	if material != null:
		mesh.surface_set_material(0, material)
