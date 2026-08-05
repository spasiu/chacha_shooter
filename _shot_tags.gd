extends Node3D

const OUT := "/private/tmp/claude-501/-Users-anastasi-Documents-Claude-Projects-chacha-shooter/8c73e8d0-00db-4203-b02c-cc0f513efe48/scratchpad"

func _ready() -> void:
	Net.map_id = "crossfire"
	var world: Node3D = load("res://scenes/world.tscn").instantiate()
	add_child(world)
	var player: Node3D = world.get_node("Player")
	var voxel: Node = world.get_node("VoxelWorld")
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 68.0
	for i in 240:
		await get_tree().process_frame

	# One of each side, stood on open ground where both tags are readable.
	var scene: PackedScene = load("res://scenes/bot.tscn")
	var ground := voxel.ground_height(0.0, 0.0)
	var pair := []
	for i in 2:
		var b: Bot = scene.instantiate()
		b.team = Net.BLUE if i == 0 else Net.RED
		world.add_child(b)
		b.global_position = Vector3(-1.3 + i * 2.6, ground + 0.2, 0.0)
		pair.append(b)
	for i in 12:
		await get_tree().physics_frame
	cam.global_position = Vector3(0.0, ground + 1.65, 5.2)
	cam.look_at(Vector3(0.0, ground + 1.25, 0.0))
	cam.current = true
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT + "/green_tags.png")
	get_tree().quit()
