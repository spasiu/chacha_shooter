class_name VoxelWorld
extends Node3D

## Destructible block terrain. Blocks are quarter-size (0.25m), stored in one
## flat byte array and rendered as chunked meshes that only emit faces where a
## solid block touches air.
##
## Vertical layout, from the bottom:
##   gy 0                     indestructible bedrock
##   gy 1 .. depth_blocks     destructible ground (top of it is world y = 0)
##   gy depth+1 .. depth+build_height   buildable airspace

const BLOCK := 0.25
const CHUNK := 16

## Everything a block can be. Append only: the number is what the map file and
## the wire both carry, so inserting in the middle repaints every existing map.
enum {
	AIR, GRASS, DIRT, CONCRETE, BEDROCK, WOOD, LEAVES,
	ASPHALT, SAND, STONE, PLASTER, TILE, RUST, TEAM_RED, TEAM_BLUE,
	BRICK, GRAVEL, CANVAS, STEEL,
	WHITEWASH, OCHRE, SLATE, TIN, TIMBER,
}

## What the map file may call each of them. The generator writes names rather
## than numbers so a map stays readable and survives the enum growing.
const BLOCK_NAMES := {
	"air": AIR, "grass": GRASS, "dirt": DIRT, "concrete": CONCRETE,
	"bedrock": BEDROCK, "wood": WOOD, "leaves": LEAVES, "asphalt": ASPHALT,
	"sand": SAND, "stone": STONE, "plaster": PLASTER, "tile": TILE,
	"rust": RUST, "team_red": TEAM_RED, "team_blue": TEAM_BLUE,
	"brick": BRICK, "gravel": GRAVEL, "canvas": CANVAS, "steel": STEEL,
	"whitewash": WHITEWASH, "ochre": OCHRE, "slate": SLATE, "tin": TIN,
	"timber": TIMBER,
}

## Base colours per block type: [top face, side/bottom face].
##
## Kept deliberately desaturated. The palette is doing two jobs at once -- it
## has to tell four quite different places apart at a glance, and it has to stay
## inside a 1944 photograph. So the colours that separate the areas are earths
## and greys a shade apart from each other rather than hues, and the only two
## saturated things on the whole map are the team markings, which is exactly
## what wants to be visible from across a field.
const COLOURS := {
	GRASS: [Color(0.36, 0.52, 0.24), Color(0.42, 0.31, 0.18)],
	DIRT: [Color(0.42, 0.31, 0.18), Color(0.38, 0.28, 0.16)],
	CONCRETE: [Color(0.62, 0.62, 0.59), Color(0.56, 0.56, 0.54)],
	BEDROCK: [Color(0.24, 0.24, 0.26), Color(0.21, 0.21, 0.23)],
	WOOD: [Color(0.47, 0.35, 0.21), Color(0.31, 0.22, 0.12)],
	LEAVES: [Color(0.25, 0.44, 0.19), Color(0.21, 0.38, 0.16)],
	# Nuketown's street and the hardstanding at Shipment.
	ASPHALT: [Color(0.25, 0.25, 0.26), Color(0.20, 0.20, 0.21)],
	# Crossfire is a dry town; this is its ground and its rubble.
	SAND: [Color(0.72, 0.63, 0.44), Color(0.63, 0.54, 0.37)],
	# The walls of the gulch. Warmer and darker than concrete so a cliff never
	# reads as a building.
	STONE: [Color(0.48, 0.43, 0.38), Color(0.41, 0.36, 0.32)],
	# Rendered housefronts: Nuketown's bungalows, Crossfire's terraces.
	PLASTER: [Color(0.80, 0.76, 0.66), Color(0.72, 0.68, 0.58)],
	# Roofs. The one red that is not a team colour, kept dark and dusty enough
	# not to be mistaken for one.
	TILE: [Color(0.46, 0.26, 0.20), Color(0.39, 0.22, 0.17)],
	# Shipping containers, weathered.
	RUST: [Color(0.55, 0.34, 0.22), Color(0.47, 0.29, 0.19)],
	TEAM_RED: [Color(0.62, 0.17, 0.15), Color(0.52, 0.14, 0.12)],
	TEAM_BLUE: [Color(0.18, 0.32, 0.60), Color(0.15, 0.27, 0.50)],
	# Brickwork. Browner and far duller than the roof tile beside it, because a
	# wall of it covers ten times the area and a saturated one would shout.
	BRICK: [Color(0.47, 0.33, 0.27), Color(0.41, 0.28, 0.23)],
	# Yards, verges and the scree at the foot of the gulch walls: the surface
	# that sits between made ground and open country.
	GRAVEL: [Color(0.50, 0.47, 0.42), Color(0.44, 0.41, 0.36)],
	# Tentage and tarpaulins over the stores at a base.
	CANVAS: [Color(0.58, 0.55, 0.40), Color(0.50, 0.47, 0.34)],
	# Painted sheet: container ends, shutters, the doors on a bunker.
	STEEL: [Color(0.34, 0.37, 0.36), Color(0.29, 0.31, 0.30)],
	# Lime-washed render. The brightest thing on any map, which is what makes a
	# village read as a village from the far side of it: one white gable end
	# does more for a skyline than a dozen grey ones.
	WHITEWASH: [Color(0.86, 0.84, 0.78), Color(0.78, 0.76, 0.70)],
	# Yellow render, the other half of the same street.
	OCHRE: [Color(0.74, 0.61, 0.36), Color(0.66, 0.54, 0.31)],
	# Slate roofing. Cool where the tile is warm, so two roofs side by side are
	# obviously two roofs.
	SLATE: [Color(0.33, 0.36, 0.40), Color(0.28, 0.30, 0.34)],
	# Galvanised corrugated iron: sheds, lean-tos, and the ridged roofs that
	# catch the light one strip at a time.
	TIN: [Color(0.56, 0.58, 0.59), Color(0.48, 0.50, 0.51)],
	# Creosoted structural timber -- beams, posts, shutters, fence rails. Far
	# darker than the WOOD a crate is made of, on purpose.
	TIMBER: [Color(0.26, 0.19, 0.13), Color(0.21, 0.15, 0.10)],
}

## Per-type overrides for `block_health`. Ground and concrete are left at the
## full 1000; foliage is not built like a bunker, and neither is a housefront.
const HEALTH := {
	WOOD: 600.0,
	LEAVES: 150.0,
	PLASTER: 450.0,
	TILE: 350.0,
	RUST: 500.0,
	SAND: 700.0,
	# Team markings are paint on whatever is underneath, so they come off about
	# as easily as the render does.
	TEAM_RED: 450.0,
	TEAM_BLUE: 450.0,
	BRICK: 700.0,
	GRAVEL: 800.0,
	CANVAS: 120.0,
	STEEL: 800.0,
	WHITEWASH: 450.0,
	OCHRE: 450.0,
	SLATE: 320.0,
	TIN: 260.0,
	TIMBER: 550.0,
}
## What a block past the degraded threshold blends toward.
const DEGRADED_TINT := Color(0.14, 0.12, 0.11)
const DEGRADED_BLEND := 0.55

## Vertical room a tree needs above the ground it stands on.
const TREE_REACH := 14
## How far a canopy can spill sideways from its trunk column.
const TREE_RADIUS := 5

## Set from the map file on load; the exports are only a fallback.
@export var size_x := 2000
@export var size_z := 2000
## Destructible blocks below floor level; below them is bedrock.
@export var depth_blocks := 16
## Blocks of airspace above floor level that may be built in.
@export var build_height := 16
@export var block_health := 1000.0
## Fraction of a block's health at which it visibly degrades. Ground and
## concrete have 1000 health, so the default puts that at 500.
@export var degraded_fraction := 0.5
@export var debris_scene: PackedScene
## Read as raw PNG bytes rather than an imported texture: the import
## pipeline may compress a texture, and these pixels are height data that
## has to survive exactly.
@export var terrain_path := "res://maps/default_terrain.png"
@export var structures_path := "res://maps/default_structures.json"
## Which of the catalogue's maps to load, overriding the two paths above.
##
## Left empty -- which is how the world scene ships -- this takes whatever the
## player chose on the map screen. A dedicated server names one outright
## instead, because a server holds one map's terrain and has nobody to ask.
@export var map_id := ""
## Chunks are built within this many chunk-widths of the camera and freed
## beyond it. One chunk is 4m, so this is a 64m working set.
##
## This is a draw distance in the strong sense: past it the ground is not there
## at all, and what you see instead is the sky meeting nothing. That is easy to
## miss alone on a map and impossible to miss with somebody else on it -- two
## soldiers further apart than this each stand on an island in a void, which
## looks far more like two separate worlds than like one shared one. Whatever
## this is set to, `Player.SPAWN_SCATTER` has to stay well inside it.
@export var view_chunks := 16
## Chunk columns brought in per frame while streaming.
@export var stream_budget := 14
## Colour of the boundary marker painted on the ground at the world edge.
@export var boundary_colour := Color(0.86, 0.09, 0.07)
## Width of that stripe, in metres.
@export var boundary_width := 0.3
## Chunks remeshed per frame; keeps a burst of destruction from stalling.
@export var rebuild_budget := 2

@export_group("Prebuild")
## Whether terrain is ever thrown away once it has been built.
##
## Off, and it is never given back. That is the setting that matters, and it is
## what closes the whole class of bug where two clients disagree about the map:
## the ground under anything you are not standing near still exists, so nothing
## resting on it can fall through, and which chunks a client has stops depending
## on where that particular player happened to walk.
##
## The cost is memory rather than time. The world grows to cover wherever people
## actually go and stops there -- touring every corner of this map would reach a
## few hundred megabytes, and a match fought over half of it far less. That is a
## much better bargain than building the lot up front, which on this map is a ten
## minute wait in a browser before anyone can play at all.
@export var discard_distant := false
## Build the entire map before anyone plays on it, rather than streaming it in
## around whoever is looking.
##
## Off by default and worth leaving off. It removes terrain pop-in entirely and
## guarantees every client is looking at the same finished world from the first
## frame, but on a map this size the browser build meshes it in single-threaded
## WASM for the better part of ten minutes, behind a loading screen, every time
## anybody joins. Streaming without discarding gets almost all of the benefit for
## none of that.
@export var prebuild := false
## Milliseconds per frame to spend on it. The engine still has to draw a loading
## screen and answer the browser between helpings, and a tab that stops
## responding altogether is one the browser offers to kill.
@export var prebuild_ms_per_frame := 24.0

## Keep building the rest of the map behind the player, once the ground around
## them is in.
##
## The middle road between the two settings above, and the one to leave on. Play
## starts the moment the streaming window is up -- exactly as it does with both
## of those off, with no loading screen and no wait -- and from then on whatever
## frame time is going spare goes on filling the rest of the map in, a few
## columns at a time. Some minutes into a match every client has the whole world
## standing and terrain pop-in has stopped happening at all, without anybody
## having waited for it.
##
## The ground the player is actually near always comes first: this only gets the
## frame once the streaming pass has nothing left to bring in, so walking into
## fresh country still builds that country ahead of the far side of the map.
##
## Costs what prebuilding costs in memory and in total work. It simply declines
## to charge any of it up front. On a machine that cannot afford the whole map,
## turn this off rather than turning `prebuild` on.
@export var background_fill := true
## Milliseconds per frame to spend on it. Deliberately a fraction of
## `prebuild_ms_per_frame`: nobody is watching a loading screen this time, they
## are playing, and one dropped frame costs more than the fill finishing sooner.
@export var background_fill_ms := 3.0

## Emitted once the whole map is standing. Nothing should let a player move
## before this: half a world is exactly the state all of this exists to avoid.
signal terrain_ready
@export var debris_per_block := 5
@export var max_debris := 90
## Set on the dedicated server, which keeps the world only to know what shape it
## is in. It answers the same questions about blocks as any other copy and
## replays the same damage, but never builds a mesh or a collider for any of it:
## nobody is looking, and nothing there is standing on the ground.
@export var meshless := false

var height := 0
## Terrain is stored as columns rather than a full voxel array: at 2000x2000x33
## a flat array would be 132MB. Surface height and material per column, plus a
## sparse dictionary of everything that deviates from it.
var _surface := PackedByteArray()
var _material := PackedByteArray()
var _tree := PackedByteArray()
## Highest block any column can contain, so a chunk can tell which vertical
## slices are worth scanning without touching them.
var _top := PackedByteArray()
var _edits := {}
## The subset of `_edits` that players made, as opposed to the structures and
## trees the map itself describes. Only this travels to a joining client: the
## rest they work out from the same map file we did.
var _player_edits := {}
## What each of those blocks was before a player first touched it, so a round
## can be undone without rebuilding the map. Null means it came from the
## heightmap rather than from an edit.
var _pristine := {}
var _baked_trees := {}
## Chunk columns whose trees have already been grown, so the sweep below can be
## asked repeatedly without walking a few hundred columns every time.
var _baked_columns := {}
var _empty_chunks := {}
var _stream_centre := Vector2i(9999, 9999)
## Whole-map build progress: how many chunk columns exist in total, and how many
## have been walked so far. Shared by both ways of building the lot -- up front
## behind a loading screen, or a slice a frame behind a match already running --
## because the walk itself is the same either way.
var _prebuilding := false
var _fill_columns := Vector2i.ZERO
var _fill_done := 0
## Set once the walk has been all the way round. Nothing waits on it; it is what
## stops the fill from costing anything at all once there is nothing left to do.
var _map_complete := false
## Whether to fill in behind the player at all. Resolved once in `_ready`
## because it depends on two exports agreeing, not just on the one.
var _filling := false
## Frame time the fill is allowed to spend, in milliseconds, banked forward.
##
## A column cannot be stopped in the middle -- it is up to three chunk meshes
## and their colliders, tens of milliseconds of work with no yield point in it --
## so a straight per-frame deadline does not bound anything: the check only comes
## round after the damage is done. Instead the overrun is carried as a debt and
## the fill sits out however many frames it takes to earn it back, which makes
## `background_fill_ms` an average that is actually kept rather than a limit that
## is politely exceeded every time.
var _fill_credit := 0.0
## How many 16-block layers it takes to cover `height`. Derived, because a map
## that wants cliffs needs more of them than one that is all fields.
var _chunk_layers := 3
## Set once a full pass finds nothing left to build, so a settled world
## stops rescanning every ring every frame. Cleared when the camera moves
## to a new chunk or a chunk is thrown away.
var _stream_settled := false
## Where each side enters the world and what there is to fight over, both read
## off the map file. Empty on a map that names neither.
var team_spawns := {}
var capture_points: Array = []
## Where the map parks its armour: {"x", "z", "yaw"} in metres and degrees.
var tank_points: Array = []
## The same, for walkers. Kept as its own list rather than a kind field on the
## one above, because the two are parked by two different nodes and a vehicle is
## named across the network by its path under the node that parked it.
var mech_points: Array = []
## Where the map wants ammunition standing, as world (x, z) in metres. The map
## picks the spots because the map is the thing that knows which side of a wall
## is the useful one; everything here does is hand them over.
var ammo_points: Array[Vector2] = []
var _damage := {}
var _chunks := {}
var _dirty := {}
var _debris_live := 0

@onready var _chunk_root := Node3D.new()


func _ready() -> void:
	add_to_group("voxel_world")
	add_child(_chunk_root)
	# `_load_map` sets the vertical budget from the map itself; this is only the
	# shape of a world with no map file to read.
	_set_vertical_budget()
	_load_map()
	if meshless:
		# The server keeps the map as data and never draws a face of it, so
		# there is nothing here worth building and no one to keep waiting.
		Net.set_server_world(self)
		return
	_build_boundary_marker()
	_fill_columns = Vector2i(
		ceili(float(size_x) / CHUNK), ceili(float(size_z) / CHUNK)
	)
	_fill_done = 0
	_prebuilding = prebuild
	# Filling in behind the player only makes sense if what is built stays built.
	# With `discard_distant` on the two would spend the match fighting: this
	# builds the far side of the map and the streaming pass throws it straight
	# back away, forever. Prebuilding already owns the whole map, so there is
	# nothing left for the fill to do there either.
	_filling = background_fill and not discard_distant and not prebuild


func _process(_delta: float) -> void:
	if meshless:
		return
	if prebuild:
		# Note what is deliberately missing once this finishes: the streaming
		# pass. It is the half that frees chunks, and having built everything the
		# whole point is that nothing is ever taken away again.
		if _prebuilding:
			_prebuild_step()
			return
	else:
		_update_streaming()
		# Ground the player is near comes first, always: the fill only gets the
		# frame once the streaming window has nothing left to bring in, so
		# walking into fresh country still builds that country ahead of the far
		# side of the map.
		if _filling and not _map_complete and _stream_settled:
			# Capped as well as accrued, so frames the fill sat out -- while the
			# streaming pass had the ground, say -- cannot be banked and spent
			# all at once as one long stall later.
			_fill_credit = minf(_fill_credit + background_fill_ms, background_fill_ms)
			if _fill_credit > 0.0:
				var began := Time.get_ticks_usec()
				if _fill_step(_fill_credit):
					_map_complete = true
					_announce_complete()
				_fill_credit -= float(Time.get_ticks_usec() - began) / 1000.0
	if _dirty.is_empty():
		return
	var done := 0
	for key: Vector3i in _dirty.keys():
		_rebuild_chunk(key)
		_dirty.erase(key)
		done += 1
		if done >= rebuild_budget:
			break


## Half-extent of the playable field on X and Z. Past this there is nothing to
## stand on, which is why crossing it is fatal rather than merely blocked.
func boundary_half_extent() -> Vector2:
	return Vector2(size_x * BLOCK * 0.5, size_z * BLOCK * 0.5)


## True once there is a whole world to play in. Always true when prebuilding is
## off, because then there is no moment at which the map is finished -- it is
## built and unbuilt around whoever is looking for as long as the match lasts.
func is_terrain_ready() -> bool:
	return not (prebuild and _prebuilding)


## How far along the whole-map build is, 0 to 1. The loading screen shows it
## while prebuilding, where somebody really is waiting on it; with the
## background fill it is nobody's business but worth being able to read.
func terrain_progress() -> float:
	var total := _fill_columns.x * _fill_columns.y
	if total <= 0:
		return 1.0
	return clampf(float(_fill_done) / float(total), 0.0, 1.0)


## One frame's worth of building, row by row, stopping on the clock rather than
## on a column count. Columns vary enormously in cost -- open ground is nearly
## free and a wooded hillside is not -- so a fixed number of them per frame
## would take wildly different times, which shows up as a stuttering loading
## screen up front and as dropped frames mid-match.
##
## Returns true once the walk has been all the way round. Columns already
## standing cost next to nothing to pass over, so it is safe to reach here with
## most of the map built by the streaming pass already.
func _fill_step(budget_ms: float) -> bool:
	var deadline := Time.get_ticks_usec() + int(budget_ms * 1000.0)
	var total := _fill_columns.x * _fill_columns.y
	while _fill_done < total:
		@warning_ignore("integer_division")
		var cz := _fill_done / _fill_columns.x
		var cx := _fill_done % _fill_columns.x
		_build_column(cx, cz)
		_fill_done += 1
		if Time.get_ticks_usec() >= deadline:
			return false
	return true


## The blocking version, with a loading screen in front of it.
func _prebuild_step() -> void:
	if not _fill_step(prebuild_ms_per_frame):
		return
	_prebuilding = false
	_announce_complete()


func _announce_complete() -> void:
	print("VoxelWorld: %d chunks built; the map is not going anywhere now." % _chunks.size())
	terrain_ready.emit()


## Whether the ground at a world position has actually been meshed and given a
## collider yet, as opposed to merely being described by the map.
##
## The distinction matters to anything heavy that starts the match resting on
## the terrain. Chunks are built a few per frame from wherever the camera is, so
## for the first second or two of a match there is nothing under the map's
## furniture to hold it up -- and how long that lasts depends entirely on how
## fast the machine is. A client that streams slowly will watch the tank drop
## out of the world while a quicker one has it sitting there in the sun, which
## is two clients disagreeing about the map for no better reason than hardware.
func is_ground_ready(x: float, z: float) -> bool:
	var g := world_to_grid(Vector3(x, 0.0, z))
	if g.x < 0 or g.x >= size_x or g.z < 0 or g.z >= size_z:
		return true
	var column := Vector2i(g.x / CHUNK, g.z / CHUNK)
	# A column with nothing in it will never produce a chunk, so waiting on one
	# would wait forever.
	if _empty_chunks.has(column):
		return true
	for cy in _chunk_layers:
		if _chunks.has(Vector3i(column.x, cy, column.y)):
			return true
	return false


## How far out the ground is actually built, in metres. Not a level of detail --
## past this the terrain does not exist, so anything that cares where a person
## can be put down and still see the world around them asks this rather than
## carrying a distance of its own that could drift out of step with it.
func view_distance() -> float:
	return view_chunks * CHUNK * BLOCK


## Flat red stripe laid on the ground along the edge, in place of a wall. Drawn
## unshaded so it stays legible from across the field and at a glancing angle.
func _build_boundary_marker() -> void:
	var half := boundary_half_extent()
	var inner_x := half.x - boundary_width
	var inner_z := half.y - boundary_width
	var y := 0.012

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var strips := [
		[Vector3(-half.x, y, -half.y), Vector3(half.x, y, -inner_z)],
		[Vector3(-half.x, y, inner_z), Vector3(half.x, y, half.y)],
		[Vector3(-half.x, y, -inner_z), Vector3(-inner_x, y, inner_z)],
		[Vector3(inner_x, y, -inner_z), Vector3(half.x, y, inner_z)],
	]
	for strip: Array in strips:
		var a: Vector3 = strip[0]
		var b: Vector3 = strip[1]
		var corners := [
			Vector3(a.x, y, a.z), Vector3(b.x, y, a.z),
			Vector3(b.x, y, b.z), Vector3(a.x, y, b.z),
		]
		# Winding matters: the reverse order faces downward and is culled.
		for i in [0, 1, 2, 0, 2, 3]:
			verts.append(corners[i])
			normals.append(Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = boundary_colour
	mesh.surface_set_material(0, mat)

	var marker := MeshInstance3D.new()
	marker.name = "BoundaryMarker"
	marker.mesh = mesh
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(marker)


## World-space Y of the bottom face of a block row.
func block_bottom_y(gy: int) -> float:
	return (gy - depth_blocks - 1) * BLOCK


func world_to_grid(pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(pos.x / BLOCK) + size_x / 2,
		floori(pos.y / BLOCK) + depth_blocks + 1,
		floori(pos.z / BLOCK) + size_z / 2
	)


func grid_to_world(gx: int, gy: int, gz: int) -> Vector3:
	return Vector3(
		(gx - size_x / 2) * BLOCK, block_bottom_y(gy), (gz - size_z / 2) * BLOCK
	)


func in_bounds(gx: int, gy: int, gz: int) -> bool:
	return gx >= 0 and gx < size_x and gy >= 0 and gy < height and gz >= 0 and gz < size_z


func index_of(gx: int, gy: int, gz: int) -> int:
	return (gy * size_z + gz) * size_x + gx


func column_of(gx: int, gz: int) -> int:
	return gz * size_x + gx


## Derived rather than stored: an edit wins, otherwise the column's surface
## height decides whether this row is ground, and of what.
func block_at(gx: int, gy: int, gz: int) -> int:
	if not in_bounds(gx, gy, gz):
		return AIR
	var edit: Variant = _edits.get(index_of(gx, gy, gz))
	if edit != null:
		return edit
	if gy == 0:
		return BEDROCK
	var col := column_of(gx, gz)
	var surface: int = _surface[col]
	if gy > surface:
		return AIR
	if gy == surface:
		# The map paints its own surface: the green channel is the block type
		# outright, so a road is asphalt and a beach is sand without anything
		# here having to know which map it is looking at. Zero means grass,
		# since a surface made of air is not a thing a map can mean.
		var painted: int = _material[col]
		return GRASS if painted == AIR else painted
	return DIRT


## Out-of-world counts as solid so the outer shell emits no wasted faces.
func is_solid(gx: int, gy: int, gz: int) -> bool:
	if gx < 0 or gx >= size_x or gz < 0 or gz >= size_z or gy < 0:
		return true
	if gy >= height:
		return false
	return block_at(gx, gy, gz) != AIR


## Highest buildable grid row. Placing above this is refused.
func max_build_gy() -> int:
	return depth_blocks + build_height


func damage_at(gx: int, gy: int, gz: int) -> float:
	return _damage.get(index_of(gx, gy, gz), 0.0)


func health_of(type: int) -> float:
	return HEALTH.get(type, block_health)


## True once a block has taken enough damage to show it.
func is_degraded(gx: int, gy: int, gz: int) -> bool:
	var type := block_at(gx, gy, gz)
	if type == AIR:
		return false
	return damage_at(gx, gy, gz) >= health_of(type) * degraded_fraction


## Applies damage to whichever block contains `at`, nudged along `into` so a hit
## landing exactly on a face resolves to the block behind it. Returns true if
## the block was destroyed.
func damage_block(at: Vector3, into: Vector3, amount: float) -> bool:
	var g := world_to_grid(at + into.normalized() * (BLOCK * 0.25))
	return damage_grid_block(g.x, g.y, g.z, amount)


func damage_grid_block(gx: int, gy: int, gz: int, amount: float) -> bool:
	if not in_bounds(gx, gy, gz):
		return false
	# Trees are grown lazily as chunks come into view, which on a headless
	# server never happens and on a client has not happened yet for terrain
	# somebody else is shooting at. Grow them before deciding this is thin air.
	_bake_trees_near(gx / CHUNK, gz / CHUNK)
	var type := block_at(gx, gy, gz)
	if type == AIR or type == BEDROCK:
		return false

	var idx := index_of(gx, gy, gz)
	# Everyone chews the same wall down together: this is what turns a hit here
	# into the same hit on every other client. Net drops it when the damage
	# arrived off the wire in the first place, so it cannot echo.
	Net.report_terrain(idx, amount)
	var limit := health_of(type)
	var was := float(_damage.get(idx, 0.0))
	var now := was + amount
	if now >= limit:
		_destroy(gx, gy, gz, type)
		return true

	_damage[idx] = now
	# Only remesh when it crosses into the degraded look.
	var threshold := limit * degraded_fraction
	if was < threshold and now >= threshold:
		_mark_dirty(gx, gy, gz)
	return false


func place_block(gx: int, gy: int, gz: int, type: int) -> bool:
	if not in_bounds(gx, gy, gz) or gy > max_build_gy() or gy <= 0:
		return false
	_bake_trees_near(gx / CHUNK, gz / CHUNK)
	if block_at(gx, gy, gz) != AIR:
		return false
	var idx := index_of(gx, gy, gz)
	_set_block(idx, gx, gy, gz, type)
	Net.report_place(idx, type)
	return true


func _destroy(gx: int, gy: int, gz: int, type: int) -> void:
	var idx := index_of(gx, gy, gz)
	_damage.erase(idx)
	_set_block(idx, gx, gy, gz, AIR)
	_spawn_debris(gx, gy, gz, type)


## Writes a block and remembers that a player put it there. Everything that
## deviates from the map goes through here, which is what lets `net_snapshot`
## hand a joining client the difference rather than the whole world.
func _set_block(idx: int, gx: int, gy: int, gz: int, type: int) -> void:
	# What was here before anybody touched it, remembered the first time they do.
	# Null means the map never had an opinion and the block came from the
	# heightmap, which is a different thing from it having been air.
	if not _pristine.has(idx):
		_pristine[idx] = _edits.get(idx, null)
	_edits[idx] = type
	_player_edits[idx] = type
	_mark_dirty(gx, gy, gz)


## Puts the ground back exactly as the map file describes it, and forgets every
## shot ever fired into it. Used between rounds.
##
## Restoring only what was changed, rather than reloading the map, is the whole
## reason `_pristine` is kept: rebuilding this map from scratch is a two-minute
## job and would have to happen between every round, where undoing a few
## thousand blocks takes a frame or two of remeshing.
func reset_to_map() -> void:
	for idx: int in _damage:
		var damaged := grid_of(idx)
		_mark_dirty(damaged.x, damaged.y, damaged.z)
	_damage.clear()

	for idx: int in _pristine:
		var was: Variant = _pristine[idx]
		if was == null:
			_edits.erase(idx)
		else:
			_edits[idx] = was
		var g := grid_of(idx)
		_mark_dirty(g.x, g.y, g.z)
	_pristine.clear()
	_player_edits.clear()


# --- multiplayer --------------------------------------------------------
#
# The wire talks in flat block indices rather than coordinates, because that is
# what the damage and edit tables are keyed by and it is one integer instead of
# three. These are the entry points Net applies incoming changes through.

func damage_index(index: int, amount: float) -> void:
	var g := grid_of(index)
	damage_grid_block(g.x, g.y, g.z, amount)


## Writes a block without asking whether it may. Unlike `place_block` this is
## not a request -- it is state that has already happened elsewhere, so a
## joining client applying a snapshot must end up with it whatever is currently
## in the way.
func place_index(index: int, type: int) -> void:
	var g := grid_of(index)
	if not in_bounds(g.x, g.y, g.z):
		return
	_bake_trees_near(g.x / CHUNK, g.z / CHUNK)
	_set_block(index, g.x, g.y, g.z, type)


func grid_of(index: int) -> Vector3i:
	var gx := index % size_x
	var rest := index / size_x
	return Vector3i(gx, rest / size_z, rest % size_z)


## Every way this world differs from the map on disk, flattened for the wire.
## Blocks first, then damage: a block that was destroyed, rebuilt and then shot
## at needs the rebuild applied before the shooting.
func net_snapshot() -> Dictionary:
	var place_indices := PackedInt64Array()
	var place_types := PackedByteArray()
	for idx: int in _player_edits:
		place_indices.append(idx)
		place_types.append(_player_edits[idx])

	var damage_indices := PackedInt64Array()
	var damage_amounts := PackedFloat32Array()
	for idx: int in _damage:
		damage_indices.append(idx)
		damage_amounts.append(_damage[idx])

	return {
		"place_indices": place_indices,
		"place_types": place_types,
		"damage_indices": damage_indices,
		"damage_amounts": damage_amounts,
	}


## The height a soldier can actually stand at in this column, or NAN when there
## is nowhere in it they fit.
##
## Emphatically not the same thing as the height of the ground. A wall, a
## shipping container and a housefront all sit on ground that is perfectly flat
## underneath them, so anything that places a body by asking how high the ground
## is will happily put them three metres inside a wall -- and a capsule spawned
## inside solid rock does not politely stay there. The physics engine pushes it
## out along whichever axis is shortest, which for somebody standing in the
## middle of a base wall is straight down and through the floor.
##
## `headroom` is in blocks: eight is two metres, which is a soldier and a little
## to spare.
func standing_height(x: float, z: float, headroom := 8) -> float:
	var gx := floori(x / BLOCK) + size_x / 2
	var gz := floori(z / BLOCK) + size_z / 2
	if gx < 0 or gx >= size_x or gz < 0 or gz >= size_z:
		return NAN

	var ceiling := max_build_gy()
	var gy := int(_surface[column_of(gx, gz)]) + 1
	while gy + headroom <= ceiling:
		var blocked := -1
		for step in headroom:
			if block_at(gx, gy + step, gz) != AIR:
				blocked = step
				break
		if blocked < 0:
			return block_bottom_y(gy)
		# Skip past whatever was in the way rather than testing the next block
		# up: inside a wall that would mean one query per block of its height.
		gy += blocked + 1
	return NAN


## Ground level in metres at a world position, for standing somebody on it.
## Reads the map's own column heights rather than dropping a ray, so it works
## before any terrain has been meshed -- which is the case at spawn time.
func ground_height(x: float, z: float) -> float:
	var gx := floori(x / BLOCK) + size_x / 2
	var gz := floori(z / BLOCK) + size_z / 2
	if gx < 0 or gx >= size_x or gz < 0 or gz >= size_z:
		return 0.0
	return block_bottom_y(_surface[column_of(gx, gz)] + 1)


## A handful of shards per block, capped globally so a grenade levelling a wall
## cannot spawn hundreds of rigid bodies at once.
@warning_ignore("shadowed_variable")
func _spawn_debris(gx: int, gy: int, gz: int, type: int) -> void:
	if debris_scene == null or _debris_live >= max_debris:
		return
	var centre := grid_to_world(gx, gy, gz) + Vector3.ONE * (BLOCK * 0.5)
	var pair: Array = COLOURS.get(type, [Color.GRAY, Color.GRAY])
	var count := mini(debris_per_block, max_debris - _debris_live)
	for i in count:
		var shard = debris_scene.instantiate()
		add_child(shard)
		shard.global_position = centre + Vector3(
			randf_range(-0.06, 0.06), randf_range(-0.06, 0.06), randf_range(-0.06, 0.06)
		)
		shard.tint((pair[0] as Color).lerp(pair[1] as Color, randf()))
		shard.linear_velocity = Vector3(
			randf_range(-2.2, 2.2), randf_range(1.4, 4.0), randf_range(-2.2, 2.2)
		)
		shard.angular_velocity = Vector3(
			randf_range(-9.0, 9.0), randf_range(-9.0, 9.0), randf_range(-9.0, 9.0)
		)
		shard.on_expired = _on_debris_expired
		_debris_live += 1


func _on_debris_expired() -> void:
	_debris_live = maxi(_debris_live - 1, 0)


func _mark_dirty(gx: int, gy: int, gz: int) -> void:
	if meshless:
		return
	# Neighbouring chunks too: removing a block exposes faces across the seam.
	var cx := gx / CHUNK
	var cy := gy / CHUNK
	var cz := gz / CHUNK
	_dirty[Vector3i(cx, cy, cz)] = true
	if gx % CHUNK == 0 and cx > 0:
		_dirty[Vector3i(cx - 1, cy, cz)] = true
	if gx % CHUNK == CHUNK - 1:
		_dirty[Vector3i(cx + 1, cy, cz)] = true
	if gy % CHUNK == 0 and cy > 0:
		_dirty[Vector3i(cx, cy - 1, cz)] = true
	if gy % CHUNK == CHUNK - 1:
		_dirty[Vector3i(cx, cy + 1, cz)] = true
	if gz % CHUNK == 0 and cz > 0:
		_dirty[Vector3i(cx, cy, cz - 1)] = true
	if gz % CHUNK == CHUNK - 1:
		_dirty[Vector3i(cx, cy, cz + 1)] = true


## Reads the authored map: one pixel per column carrying surface height,
## material and a tree marker, plus a JSON list of concrete works. Nothing here
## is rolled at runtime -- the same files produce the same map every time.
## Works out how tall the world is and how many chunk layers that takes. Both
## are derived rather than fixed because a map that wants a canyon in it needs
## far more room overhead than one that is all fields, and paying for that
## everywhere would mean scanning empty sky on every column of every flat map.
func _set_vertical_budget() -> void:
	height = depth_blocks + build_height + 1
	_chunk_layers = ceili(float(height) / CHUNK)


func _load_map() -> void:
	# The chosen ground, or the one this node was told to hold. Resolved here
	# rather than in the scene so every map is loaded through the same door.
	var chosen := map_id if not map_id.is_empty() else Net.map_id
	if MapCatalogue.has(chosen):
		terrain_path = MapCatalogue.terrain_path(chosen)
		structures_path = MapCatalogue.structures_path(chosen)
		# A server holding one map's terrain is a server whose field is that
		# map; everything it replays to a joiner is only right for that one.
		if not map_id.is_empty():
			Net.map_id = chosen

	# Read before the heightmap: the map's own idea of how deep the ground goes
	# and how much sky it needs decides how the columns below are indexed.
	var meta := _read_meta()
	depth_blocks = int(meta.get("depth_blocks", depth_blocks))
	build_height = int(meta.get("build_height", build_height))
	_set_vertical_budget()
	_read_places(meta)

	if not FileAccess.file_exists(terrain_path):
		push_error("VoxelWorld cannot find %s; the world will be empty." % terrain_path)
		return
	var image := Image.new()
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(terrain_path)) != OK:
		push_error("VoxelWorld could not read %s" % terrain_path)
		return
	if image.get_format() != Image.FORMAT_RGB8:
		image.convert(Image.FORMAT_RGB8)

	size_x = image.get_width()
	size_z = image.get_height()
	var pixels := image.get_data()

	var columns := size_x * size_z
	_surface.resize(columns)
	_material.resize(columns)
	_tree.resize(columns)
	_top.resize(columns)
	for i in columns:
		var p := i * 3
		var surface := pixels[p]
		_surface[i] = surface
		_material[i] = pixels[p + 1]
		_tree[i] = pixels[p + 2]
		# A tree adds roughly its own height above the ground it stands on.
		_top[i] = mini(surface + (TREE_REACH if pixels[p + 2] != 0 else 0), height - 1)

	_build_structures(_read_meta())


## The map's companion file, or an empty dictionary if it has none.
func _read_meta() -> Dictionary:
	if not FileAccess.file_exists(structures_path):
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(structures_path)
	)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Could not read %s" % structures_path)
		return {}
	return parsed


## Where each side starts and what there is to fight over. Read straight off the
## map, because these are properties of a place rather than of the game -- a
## different map puts its bases somewhere else and nothing else should have to
## know that.
func _read_places(meta: Dictionary) -> void:
	team_spawns.clear()
	capture_points.clear()
	ammo_points.clear()
	tank_points.clear()
	mech_points.clear()
	for at: Array in meta.get("ammo_boxes", []):
		ammo_points.append(Vector2(float(at[0]), float(at[1])))
	for spot: Dictionary in meta.get("tanks", []):
		tank_points.append({
			"position": Vector2(float(spot["x"]), float(spot["z"])),
			"yaw": float(spot.get("yaw", 0.0)),
		})
	for spot: Dictionary in meta.get("mechs", []):
		mech_points.append({
			"position": Vector2(float(spot["x"]), float(spot["z"])),
			"yaw": float(spot.get("yaw", 0.0)),
		})
	for side: String in meta.get("team_spawns", {}):
		var at: Array = meta["team_spawns"][side]
		team_spawns[side] = Vector2(float(at[0]), float(at[1]))
	for point: Dictionary in meta.get("capture_points", []):
		capture_points.append({
			"name": String(point.get("name", "objective")),
			"position": Vector2(float(point["x"]), float(point["z"])),
			"radius": float(point.get("radius", 8.0)),
		})


## Where a side comes into the world, in metres. Falls back to the middle of the
## map, which is where a map that names no sides puts everybody anyway.
func team_spawn(side: String) -> Vector2:
	return team_spawns.get(side, Vector2.ZERO)


func _build_structures(meta: Dictionary) -> void:
	for entry: Dictionary in meta.get("structures", []):
		var from: int = int(entry.get("from", 0))
		var to: int = int(entry.get("height", 1))
		var clear: bool = bool(entry.get("clear", false))
		# Structures name their material, so a housefront is plaster, a cliff is
		# stone and a base is painted in its own colour, rather than everything
		# built out of the same concrete.
		var type: int = BLOCK_NAMES.get(String(entry.get("type", "concrete")), CONCRETE)
		# Anchored to the ground it stands on by default; a structure that has to
		# sit at one height regardless of the slope under it says so instead,
		# which is what keeps a container stack level and a roof flat.
		var flat: bool = bool(entry.get("flat", false))
		var floor_gy: int = int(entry.get("gy", 0))
		for gz in range(int(entry["z0"]), int(entry["z1"]) + 1):
			for gx in range(int(entry["x0"]), int(entry["x1"]) + 1):
				if gx < 0 or gx >= size_x or gz < 0 or gz >= size_z:
					continue
				var col := column_of(gx, gz)
				var base: int = floor_gy if flat else _surface[col] + 1
				for step in range(from, to):
					var gy := base + step
					if gy >= height or gy < 1:
						continue
					_edits[index_of(gx, gy, gz)] = AIR if clear else type
				if not clear:
					_top[col] = mini(maxi(_top[col], base + to), height - 1)


## Trees are marked in the map but only turned into blocks when a chunk near
## them is first built, so a 500m forest does not have to exist all at once.
func _bake_trees_near(cx: int, cz: int) -> void:
	var column := Vector2i(cx, cz)
	if _baked_columns.has(column):
		return
	_baked_columns[column] = true
	var x0 := maxi(cx * CHUNK - TREE_RADIUS, 0)
	var z0 := maxi(cz * CHUNK - TREE_RADIUS, 0)
	var x1 := mini(cx * CHUNK + CHUNK + TREE_RADIUS, size_x - 1)
	var z1 := mini(cz * CHUNK + CHUNK + TREE_RADIUS, size_z - 1)
	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var col := column_of(gx, gz)
			if _tree[col] == 0 or _baked_trees.has(col):
				continue
			_baked_trees[col] = true
			_grow_tree(gx, _surface[col] + 1, gz)


## A trunk with a squashed, ragged canopy. Deterministic from its own position
## so the same map always grows the same wood.
func _grow_tree(gx: int, base_gy: int, gz: int) -> void:
	var hash := (gx * 73856093) ^ (gz * 19349663)
	var trunk := 8 + absi(hash) % 4
	var radius := 3 + absi(hash >> 7) % 2
	var top := base_gy + trunk
	for gy in range(base_gy, top):
		if gy < height:
			_edits[index_of(gx, gy, gz)] = WOOD

	var centre := top - 1
	for dy in range(-radius, radius + 2):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var d := Vector3(dx, dy * 1.35, dz).length()
				if d > float(radius) + 0.35:
					continue
				# Ragged edge rather than a clean ball, from the same hash.
				if d > radius - 0.6 and ((hash >> (absi(dx + dz + dy) % 20)) & 1) == 0:
					continue
				var tx := gx + dx
				var ty := centre + dy
				var tz := gz + dz
				if not in_bounds(tx, ty, tz) or ty > max_build_gy():
					continue
				if block_at(tx, ty, tz) == AIR:
					_edits[index_of(tx, ty, tz)] = LEAVES


## Keeps a window of chunks around the camera built, and frees the rest. At
## 2000x2000 columns the whole map is about 47,000 chunks, so only a working
## set can exist as nodes.
func _update_streaming() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var here := world_to_grid(camera.global_position)
	var centre := Vector2i(here.x / CHUNK, here.z / CHUNK)

	# Moving to a new chunk means there is probably fresh ground to bring in, so
	# the settled flag comes off and the rings get another look.
	if centre != _stream_centre:
		_stream_centre = centre
		_stream_settled = false
		# Giving ground back is optional, and off by default. Everything that
		# has ever been built stays built: it is the only way the map under a
		# tank -- or under anybody's feet -- is guaranteed to still be there
		# after somebody walks away from it and back.
		if discard_distant:
			for key: Vector3i in _chunks.keys():
				if absi(key.x - centre.x) > view_chunks \
						or absi(key.z - centre.y) > view_chunks:
					_chunks[key].queue_free()
					_chunks.erase(key)

	if _stream_settled:
		return

	var spent := 0
	for ring in range(0, view_chunks + 1):
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				# Only the newly-reached edge of each ring.
				if absi(dx) != ring and absi(dz) != ring:
					continue
				if _build_column(centre.x + dx, centre.y + dz):
					spent += 1
					if spent >= stream_budget:
						return

	# A whole pass with nothing built means the window is full.
	_stream_settled = true


## Builds the vertical slices of one chunk column that can actually contain a
## face, worked out from the column heights rather than by scanning. Returns
## true if anything was built.
func _build_column(cx: int, cz: int) -> bool:
	if cx < 0 or cz < 0 or cx * CHUNK >= size_x or cz * CHUNK >= size_z:
		return false
	if _empty_chunks.has(Vector2i(cx, cz)):
		return false
	if _chunks.has(Vector3i(cx, 0, cz)) or _chunks.has(Vector3i(cx, 1, cz)) \
			or _chunks.has(Vector3i(cx, 2, cz)):
		return false

	_bake_trees_near(cx, cz)

	var lowest := height
	var highest := 0
	for gz in range(cz * CHUNK, mini(cz * CHUNK + CHUNK, size_z)):
		for gx in range(cx * CHUNK, mini(cx * CHUNK + CHUNK, size_x)):
			var col := column_of(gx, gz)
			lowest = mini(lowest, _surface[col])
			highest = maxi(highest, _top[col])

	var built := false
	for cy in range(
			maxi((lowest - 1) / CHUNK, 0),
			mini((highest + 1) / CHUNK + 1, _chunk_layers)):
		_rebuild_chunk(Vector3i(cx, cy, cz))
		built = true
	if not built:
		_empty_chunks[Vector2i(cx, cz)] = true
	return built


func _rebuild_chunk(key: Vector3i) -> void:
	var chunk: VoxelChunk = _chunks.get(key)
	if chunk == null:
		chunk = VoxelChunk.new()
		chunk.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
		_chunk_root.add_child(chunk)
		_chunks[key] = chunk
	chunk.build(self, key)
