class_name VoxelChunk
extends StaticBody3D

## One 16^3 slice of the voxel world. Emits only faces where a solid block
## touches air, so fully buried chunks cost nothing. Mesh and collision share
## the same triangle soup.

## Face order: +X, -X, +Y, -Y, +Z, -Z. Each is four corners, counter-clockwise
## seen from outside.
const FACES := [
	[Vector3i(1, 0, 0), [Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)]],
	[Vector3i(-1, 0, 0), [Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1)]],
	[Vector3i(0, 1, 0), [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)]],
	[Vector3i(0, -1, 0), [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0)]],
	[Vector3i(0, 0, 1), [Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)]],
	[Vector3i(0, 0, -1), [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)]],
]

var _world: VoxelWorld
var _key := Vector3i.ZERO
var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D
var _material: StandardMaterial3D


func build(world: VoxelWorld, key: Vector3i) -> void:
	_world = world
	_key = key
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
		_collision = CollisionShape3D.new()
		add_child(_collision)
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		_material.roughness = 0.95

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()

	var size := VoxelWorld.CHUNK
	var bs := VoxelWorld.BLOCK
	var ox := key.x * size
	var oy := key.y * size
	var oz := key.z * size

	for ly in size:
		var gy := oy + ly
		if gy >= world.height:
			break
		for lz in size:
			var gz := oz + lz
			if gz >= world.size_z:
				break
			for lx in size:
				var gx := ox + lx
				if gx >= world.size_x:
					break
				var type := world.block_at(gx, gy, gz)
				if type == VoxelWorld.AIR:
					continue

				var exposed := false
				for f in 6:
					var dir: Vector3i = FACES[f][0]
					if world.is_solid(gx + dir.x, gy + dir.y, gz + dir.z):
						continue
					if not exposed:
						exposed = true
					var pair: Array = VoxelWorld.COLOURS[type]
					var colour: Color = pair[0] if f == 2 else pair[1]
					if world.is_degraded(gx, gy, gz):
						colour = colour.lerp(
							VoxelWorld.DEGRADED_TINT, VoxelWorld.DEGRADED_BLEND
						)
					# Per-block brightness jitter. Without it a flat field of
					# identical blocks renders as one smooth plane and the grid
					# is invisible; textures would normally do this job.
					var shade := _block_shade(gx, gy, gz)
					colour = Color(
						colour.r * shade, colour.g * shade, colour.b * shade
					)
					# Vertex colours are consumed as linear, but these are
					# authored as sRGB.
					colour = colour.srgb_to_linear()
					var origin := Vector3(
						(gx - world.size_x / 2) * bs,
						world.block_bottom_y(gy),
						(gz - world.size_z / 2) * bs
					)
					var corners: Array = FACES[f][1]
					var n := Vector3(dir.x, dir.y, dir.z)
					# Two triangles per quad, expanded so the same array can be
					# handed straight to the collision shape.
					for i in [0, 1, 2, 0, 2, 3]:
						verts.append(origin + (corners[i] as Vector3) * bs)
						normals.append(n)
						colours.append(colour)

	if verts.is_empty():
		_mesh_instance.mesh = null
		_collision.shape = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	_mesh_instance.mesh = mesh

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)
	_collision.shape = shape


## Cheap deterministic hash so a block always shades the same way.
func _block_shade(gx: int, gy: int, gz: int) -> float:
	var h := (gx * 73856093) ^ (gy * 19349663) ^ (gz * 83492791)
	return 0.90 + 0.20 * (float(absi(h) % 1024) / 1023.0)


## Weapons and fragments hit the chunk; the world resolves which block. Returns
## true if that block broke, which is also how a shooter knows whether there is
## still a surface there worth leaving a bullet mark on.
func take_damage(amount: float, hit_position: Vector3, from_shooter: Vector3) -> bool:
	if _world == null:
		return false
	return _world.damage_block(hit_position, -from_shooter, amount)
