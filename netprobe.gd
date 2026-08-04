extends Node
# Where does a blue spawn actually put you, and is anything already there?
func _ready() -> void:
	if not ("--probe" in OS.get_cmdline_user_args()):
		return
	call_deferred("_run")
func _run() -> void:
	await get_tree().create_timer(1.0).timeout
	get_tree().change_scene_to_file("res://scenes/world.tscn")
	await get_tree().create_timer(2.0).timeout
	var w = get_tree().get_first_node_in_group("voxel_world")
	var origin: Vector2 = w.team_spawn("blue")
	print("blue spawn %s   ground_height there = %.2f" % [origin, w.ground_height(origin.x, origin.y)])

	var blocked := 0
	var samples := 60
	for i in samples:
		var angle := TAU * i / float(samples)
		var reach := 5.6 + 10.4 * ((i * 7) % 11) / 10.0
		var x: float = origin.x + cos(angle) * reach
		var z: float = origin.y + sin(angle) * reach
		var g: Vector3i = w.world_to_grid(Vector3(x, 0.0, z))
		var surface := 0
		for gy in range(w.height - 1, 0, -1):
			if w.block_at(g.x, gy, g.z) != 0:
				surface = gy
				break
		# What ground_height claims, versus what is really solid up there.
		var claimed: float = w.ground_height(x, z)
		var real_top: float = w.block_bottom_y(surface + 1)
		if real_top > claimed + 0.01:
			blocked += 1
			if blocked <= 6:
				print("  BLOCKED at %6.1f,%6.1f  spawn puts you at y=%.2f but solid up to y=%.2f (%.2fm inside)" % [
					x, z, claimed + 0.3, real_top, real_top - claimed - 0.3])
	print("%d of %d spawn points land inside something" % [blocked, samples])
	get_tree().quit()
