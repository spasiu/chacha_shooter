extends Node3D

## Throwaway: respawns many times on each map and checks every landing is
## inside the side's own walls.

const REPORT := "/private/tmp/claude-501/-Users-anastasi-Documents-Claude-Projects-chacha-shooter/8c73e8d0-00db-4203-b02c-cc0f513efe48/scratchpad/spawn.txt"
var _log := ""

func say(t: String) -> void:
	_log += t + "\n"
	FileAccess.open(REPORT, FileAccess.WRITE).store_string(_log)

func _ready() -> void:
	for id: String in MapCatalogue.IDS:
		Net.map_id = id
		var world: Node3D = load("res://scenes/world.tscn").instantiate()
		add_child(world)
		for i in 90:
			await get_tree().process_frame
		var player: Node3D = world.get_node("Player")
		var voxel: Node = world.get_node("VoxelWorld")
		var zone: Rect2 = voxel.team_zone(Net.my_team())

		say("%s: my team %s, origin %v, zone %s" % [
			id, Net.my_team(), player.global_position.snapped(Vector3.ONE * 0.1),
			str(zone)])
		var inside := 0
		var worst := 0.0
		for i in 40:
			player.respawn()
			await get_tree().physics_frame
			var at := Vector2(player.global_position.x, player.global_position.z)
			if zone.has_point(at):
				inside += 1
			else:
				worst = maxf(worst, _outside_by(zone, at))
				if i < 3:
					say("   landed at %v" % player.global_position.snapped(Vector3.ONE * 0.1))
		say("%-12s zone %s -- %d/40 landed inside, worst miss %.1fm" % [
			id, str(zone.size.round()), inside, worst])

		# And where the bots come out.
		var bots_in := 0
		var bots := 0
		for node in get_tree().get_nodes_in_group(&"damageable"):
			var b := node as Bot
			if b == null:
				continue
			bots += 1
			var bz: Rect2 = voxel.team_zone(b.team)
			if bz.has_point(Vector2(b.global_position.x, b.global_position.z)):
				bots_in += 1
		say("              bots mustered inside their own base: %d/%d" % [bots_in, bots])
		world.queue_free()
		await get_tree().process_frame
	get_tree().quit()

func _outside_by(zone: Rect2, at: Vector2) -> float:
	var dx := maxf(maxf(zone.position.x - at.x, at.x - zone.end.x), 0.0)
	var dz := maxf(maxf(zone.position.y - at.y, at.y - zone.end.y), 0.0)
	return Vector2(dx, dz).length()
