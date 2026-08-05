extends Node3D

## Throwaway: kills bots and the player and checks the attrition count moves.

const REPORT := "/private/tmp/claude-501/-Users-anastasi-Documents-Claude-Projects-chacha-shooter/8c73e8d0-00db-4203-b02c-cc0f513efe48/scratchpad/attrition.txt"
var _log := ""

func say(t: String) -> void:
	_log += t + "\n"
	FileAccess.open(REPORT, FileAccess.WRITE).store_string(_log)

func tally() -> String:
	return "blue %d left, red %d left" % [Net.tickets(Net.BLUE), Net.tickets(Net.RED)]

func _ready() -> void:
	Net.map_id = "crossfire"
	var world: Node3D = load("res://scenes/world.tscn").instantiate()
	add_child(world)
	for i in 260:
		await get_tree().process_frame
	var player: Node3D = world.get_node("Player")
	say("at the start: %s   (player is %s)" % [tally(), Net.my_team()])

	var bots := get_tree().get_nodes_in_group(&"damageable").filter(
		func(n: Node) -> bool: return n is Bot and not n.is_dead())
	say("bots standing: %d" % bots.size())

	# Kill three of the enemy.
	var killed := 0
	for b: Bot in bots:
		if b.team == Net.my_team() or killed >= 3:
			continue
		b.take_damage(500.0, b.global_position + Vector3.UP, Vector3.FORWARD,
			Lethality.BULLET)
		killed += 1
	await get_tree().physics_frame
	say("after killing %d of the enemy: %s" % [killed, tally()])

	# And one of our own, to be sure it is booked against the right side.
	for b: Bot in bots:
		if b.team == Net.my_team() and not b.is_dead():
			b.take_damage(500.0, b.global_position + Vector3.UP, Vector3.FORWARD,
				Lethality.BULLET)
			break
	await get_tree().physics_frame
	say("after losing one of ours:     %s" % tally())

	# The player's own death should cost his side a man too.
	player.take_damage(500.0, player.global_position, Vector3.FORWARD, Lethality.BULLET)
	for i in 4:
		await get_tree().physics_frame
	say("after the player goes down:   %s" % tally())

	# And the round should end when a side runs out.
	Net.casualties[Net.RED] = Net.CASUALTY_LIMIT - 1
	var last: Bot = null
	for b: Bot in get_tree().get_nodes_in_group(&"damageable"):
		if b is Bot and b.team != Net.my_team() and not b.is_dead():
			last = b
			break
	if last != null:
		last.take_damage(500.0, last.global_position + Vector3.UP, Vector3.FORWARD,
			Lethality.BULLET)
		await get_tree().physics_frame
		say("last red man down: round over %s, loser %s" % [Net.round_over, Net.round_loser])
	get_tree().quit()
