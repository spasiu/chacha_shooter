extends Node3D

const OUT := "/private/tmp/claude-501/-Users-anastasi-Documents-Claude-Projects-chacha-shooter/8c73e8d0-00db-4203-b02c-cc0f513efe48/scratchpad"

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var id: String = args[0] if args.size() > 0 else "nuketown"
	Net.map_id = id
	var world: Node3D = load("res://scenes/world.tscn").instantiate()
	add_child(world)
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 66.0
	for i in 44:
		await get_tree().process_frame
	cam.global_position = Vector3(0, 30, 34)
	cam.look_at(Vector3(0, 2, 0))
	cam.current = true
	for i in 26:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/relief_%s.png" % [OUT, id])
	get_tree().quit()
