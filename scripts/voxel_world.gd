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

enum { AIR, GRASS, DIRT, CONCRETE, BEDROCK, WOOD, LEAVES }

## Base colours per block type: [top face, side/bottom face].
const COLOURS := {
	GRASS: [Color(0.36, 0.52, 0.24), Color(0.42, 0.31, 0.18)],
	DIRT: [Color(0.42, 0.31, 0.18), Color(0.38, 0.28, 0.16)],
	CONCRETE: [Color(0.62, 0.62, 0.59), Color(0.56, 0.56, 0.54)],
	BEDROCK: [Color(0.24, 0.24, 0.26), Color(0.21, 0.21, 0.23)],
	WOOD: [Color(0.47, 0.35, 0.21), Color(0.31, 0.22, 0.12)],
	LEAVES: [Color(0.25, 0.44, 0.19), Color(0.21, 0.38, 0.16)],
}

## Per-type overrides for `block_health`. Ground and concrete are left at the
## full 1000; foliage is not built like a bunker.
const HEALTH := {
	WOOD: 600.0,
	LEAVES: 150.0,
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
## Chunks are built within this many chunk-widths of the camera and freed
## beyond it. One chunk is 4m, so 24 is a 96m working set.
@export var view_chunks := 10
## Chunk columns brought in per frame while streaming.
@export var stream_budget := 14
## Colour of the boundary marker painted on the ground at the world edge.
@export var boundary_colour := Color(0.86, 0.09, 0.07)
## Width of that stripe, in metres.
@export var boundary_width := 0.3
## Chunks remeshed per frame; keeps a burst of destruction from stalling.
@export var rebuild_budget := 2
@export var debris_per_block := 5
@export var max_debris := 90

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
var _baked_trees := {}
var _empty_chunks := {}
var _stream_centre := Vector2i(9999, 9999)
## Set once a full pass finds nothing left to build, so a settled world
## stops rescanning every ring every frame. Cleared when the camera moves
## to a new chunk or a chunk is thrown away.
var _stream_settled := false
var _damage := {}
var _chunks := {}
var _dirty := {}
var _debris_live := 0

@onready var _chunk_root := Node3D.new()


func _ready() -> void:
	add_to_group("voxel_world")
	add_child(_chunk_root)
	height = depth_blocks + build_height + 1
	_load_map()
	_build_boundary_marker()


func _process(_delta: float) -> void:
	_update_streaming()
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
		return GRASS if _material[col] == 0 else (DIRT if _material[col] == 1 else CONCRETE)
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
	var type := block_at(gx, gy, gz)
	if type == AIR or type == BEDROCK:
		return false

	var idx := index_of(gx, gy, gz)
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
	if block_at(gx, gy, gz) != AIR:
		return false
	_edits[index_of(gx, gy, gz)] = type
	_mark_dirty(gx, gy, gz)
	return true


func _destroy(gx: int, gy: int, gz: int, type: int) -> void:
	var idx := index_of(gx, gy, gz)
	_edits[idx] = AIR
	_damage.erase(idx)
	_mark_dirty(gx, gy, gz)
	_spawn_debris(gx, gy, gz, type)


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
func _load_map() -> void:
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

	_load_structures()


func _load_structures() -> void:
	if not FileAccess.file_exists(structures_path):
		return
	var text := FileAccess.get_file_as_string(structures_path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Could not read %s" % structures_path)
		return

	for entry: Dictionary in parsed.get("structures", []):
		var from: int = int(entry.get("from", 0))
		var to: int = int(entry.get("height", 1))
		var clear: bool = bool(entry.get("clear", false))
		for gz in range(int(entry["z0"]), int(entry["z1"]) + 1):
			for gx in range(int(entry["x0"]), int(entry["x1"]) + 1):
				if gx < 0 or gx >= size_x or gz < 0 or gz >= size_z:
					continue
				var col := column_of(gx, gz)
				var base: int = _surface[col] + 1
				for step in range(from, to):
					var gy := base + step
					if gy >= height:
						break
					_edits[index_of(gx, gy, gz)] = AIR if clear else CONCRETE
				if not clear:
					_top[col] = mini(maxi(_top[col], base + to), height - 1)


## Trees are marked in the map but only turned into blocks when a chunk near
## them is first built, so a 500m forest does not have to exist all at once.
func _bake_trees_near(cx: int, cz: int) -> void:
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

	# Drop anything that fell outside the window, however we got here.
	if centre != _stream_centre:
		_stream_centre = centre
		_stream_settled = false
		for key: Vector3i in _chunks.keys():
			if absi(key.x - centre.x) > view_chunks or absi(key.z - centre.y) > view_chunks:
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
	for cy in range(maxi((lowest - 1) / CHUNK, 0), mini((highest + 1) / CHUNK + 1, 3)):
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
