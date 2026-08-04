extends Node

## Root of the dedicated server. Almost everything it does, it does by being
## the thing that is running rather than by running anything: `Net` opens the
## socket, the VoxelWorld under here keeps the terrain, and this only makes sure
## the two of them are actually on and says so once a second's worth of anything
## has happened.

## How often the console line is refreshed, in seconds. Frequent enough to see
## somebody arrive, infrequent enough to leave in a log overnight.
const REPORT_SECONDS := 30.0

var _report := 0.0
var _last_count := -1


func _ready() -> void:
	# Nothing to draw and nobody to draw it for. Without this the server spends
	# its whole life rendering empty frames as fast as it can.
	Engine.max_fps = 30
	# Normally `--server` on the command line has already done this; doing it
	# here as well means running this scene is enough on its own.
	if not Net.is_server():
		Net.start_server(Net.DEFAULT_PORT)
	Net.roster_changed.connect(_on_roster_changed)


func _process(delta: float) -> void:
	_report -= delta
	if _report > 0.0:
		return
	_report = REPORT_SECONDS
	_say_who_is_here()


func _on_roster_changed() -> void:
	# Somebody coming or going is worth saying immediately rather than at the
	# next scheduled line.
	if Net.player_count() != _last_count:
		_say_who_is_here()


func _say_who_is_here() -> void:
	_last_count = Net.player_count()
	var names: Array[String] = []
	for id: int in Net.roster:
		names.append(Net.name_of(id))
	if names.is_empty():
		print("[server] nobody in the field")
		return
	print("[server] %d in the field: %s" % [names.size(), ", ".join(names)])
