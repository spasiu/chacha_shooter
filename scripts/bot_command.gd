extends Node3D

## Puts bots on the field when there is nobody else on it, and takes them away
## again when somebody arrives.
##
## The rule is deliberately blunt: bots exist only while you are the only
## soldier on your map. That is what keeps them out of the network entirely --
## nothing about a bot is ever sent or received, because by the time there is
## anybody to send it to there are no bots left. It also means the answer to
## "whose bots are they?" never has to be asked.
##
## They come out of their own side's spawn and walk at whoever is on the other,
## which on these maps is enough: every one of them is two bases and the ground
## between, so each half is where a soldier from that side should come from.
##
## Both sides get them. The enemy's are what make the map a fight; your own are
## what make it a fight you are in the middle of rather than one you are having
## on your own. They form up on you, break off at anything they can see, and
## come back when it is dealt with -- the escort behaviour is Bot's, and all
## that happens here is deciding who is escorting whom.

const BOT: PackedScene = preload("res://scenes/bot.tscn")

## How many of the enemy to keep on the field.
@export var strength := 5
## How many of your own. A little short of the enemy on purpose: a section that
## outnumbers what it is fighting clears the map without you, and watching that
## happen is not playing.
@export var allies := 3
## Metres around a spawn they come out in.
@export var scatter := 14.0
## Seconds between checks that the field still wants the bots it has.
@export var muster_interval := 2.0

var _bots: Array[Bot] = []
var _due := 0.0
var _player: Node3D
var _world: Node


func _ready() -> void:
	_world = get_tree().get_first_node_in_group("voxel_world")
	Net.roster_changed.connect(_muster)
	# A frame's grace so the player and the terrain are both up.
	_due = 1.0


func _process(delta: float) -> void:
	_due -= delta
	if _due > 0.0:
		return
	_due = muster_interval
	_muster()


## Brings the field up to strength, or clears it if we are no longer alone.
func _muster() -> void:
	# Rebuilt by hand rather than with `filter`, which hands back an untyped
	# array: assigning that to a typed one throws, and it threw here on the
	# first line of the muster, so nothing below it ever ran and no casualty was
	# ever replaced.
	var alive: Array[Bot] = []
	for bot in _bots:
		if is_instance_valid(bot):
			alive.append(bot)
	_bots = alive
	if not _alone():
		for bot in _bots:
			bot.queue_free()
		_bots.clear()
		return
	if _player == null or not is_instance_valid(_player):
		# The local soldier is the one thing in Blast.VIEWERS -- a camera shake
		# belongs to whoever is looking, and only one player ever is.
		_player = get_tree().get_first_node_in_group(Blast.VIEWERS) as Node3D
		if _player == null:
			return
	# Only the ones still standing count toward strength. A body on the ground
	# clears itself away after its own linger time and the next muster replaces
	# it, so reinforcements arrive a few seconds after a man goes down.
	var mine := Net.my_team()
	var theirs := _other_side()
	var standing := {mine: 0, theirs: 0}
	for bot in _bots:
		if not bot.is_dead():
			standing[bot.team] = int(standing.get(bot.team, 0)) + 1

	# The enemy first: with the ground still streaming in, whichever side is
	# tried first is the one that gets men out, and an empty field is worse than
	# an unaccompanied one.
	while int(standing[theirs]) < strength:
		if not _deploy(theirs):
			break
		standing[theirs] = int(standing[theirs]) + 1
	while int(standing[mine]) < allies:
		if not _deploy(mine):
			break
		standing[mine] = int(standing[mine]) + 1


## True while we are the only soldier on this map. Somebody playing one of the
## other maps is on the server but not in this match, and `player_count` already
## counts only our own field.
func _alone() -> bool:
	return not Net.active() or Net.player_count() <= 1


## Puts one out, or says it cannot yet. Ground is streamed in around whoever is
## looking, so a bot mustered onto a chunk that has not been built yet has
## nothing under its feet and falls out of the world.
func _deploy(side: String) -> bool:
	var at := _muster_point(side)
	if _world != null and is_instance_valid(_world) \
			and not _world.is_ground_ready(at.x, at.z):
		return false
	var bot: Bot = BOT.instantiate()
	bot.team = side
	# Your own fall in on you; the enemy's are pointed at you and find the rest
	# for themselves. Either way the bot re-picks from whoever is actually on
	# the other side once it is on the ground.
	if side == Net.my_team():
		bot.escort = _player
	else:
		bot.target = _player
	add_child(bot)
	bot.name = "Bot%d" % (Time.get_ticks_msec() % 100000 + _bots.size())
	bot.global_position = at
	_bots.append(bot)
	return true


func _other_side() -> String:
	return Net.RED if Net.my_team() == Net.BLUE else Net.BLUE


## Somewhere around that side's own spawn, dropped onto the ground. Falls back
## to a ring around the player on a map that names no spawns at all, which is
## the test harnesses rather than anything anybody plays.
func _muster_point(side: String) -> Vector3:
	var at := Vector2.ZERO
	if _world != null and is_instance_valid(_world):
		# Out of their own base, inside its walls, the same as a player.
		var zone: Rect2 = _world.team_zone(side)
		if zone.size.x > 1.0 and zone.size.y > 1.0:
			return _dropped(Vector2(
				randf_range(zone.position.x, zone.end.x),
				randf_range(zone.position.y, zone.end.y)
			))
		at = _world.team_spawn(side)
	if at == Vector2.ZERO and _player != null:
		var away := randf_range(30.0, 45.0)
		var turn := randf() * TAU
		at = Vector2(_player.global_position.x + cos(turn) * away,
					 _player.global_position.z + sin(turn) * away)
	at += Vector2(randf_range(-scatter, scatter), randf_range(-scatter, scatter))
	return _dropped(at)


## Stands a point on the ground under it.
func _dropped(at: Vector2) -> Vector3:
	var ground := 1.0
	if _world != null and is_instance_valid(_world):
		ground = _world.ground_height(at.x, at.y)
	return Vector3(at.x, ground + 0.2, at.y)
