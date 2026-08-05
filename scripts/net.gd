extends Node

## The whole multiplayer seam, in one autoload.
##
## Everything else talks to `Net` and nothing talks to Godot's MultiplayerAPI
## directly, so single-player still works exactly as it did: when `active()` is
## false every broadcast here is a no-op and every caller carries on as though
## it were alone in the world.
##
## Transport is WebSocket rather than ENet, because ENet is UDP and a browser
## cannot open a UDP socket. That is the one hard constraint the web build puts
## on this file, and it is why the dedicated server is a WebSocket server.
##
## The model is client-authoritative. Each client owns its own soldier: it moves
## it, it decides what its own shots hit, and it applies damage to itself when
## somebody else's client says it was hit. The server keeps the terrain and
## relays everything else. That is trivially cheatable and entirely appropriate
## for a browser game people wander into; a server that simulated every player
## would have to run the whole game twice and would not make the shooting feel
## any better.
##
## What is shared, and how:
##   soldiers    20Hz unreliable state, interpolated on the far end
##   gunfire     one reliable event per shot, for the flash and the report
##   damage      the shooter's client tells the victim's client
##   terrain     damage batched per frame; the server holds the master copy and
##               replays it to anyone who joins late
##   explosives  the owner spawns a live one and everyone else an inert copy,
##               so the thing is visible in flight
##
## Messages travel client -> server -> everyone else. That is not a choice:
## WebSocket clients have no way to reach each other. Godot's SceneMultiplayer
## does the forwarding itself (`server_relay`, on by default) and preserves the
## original sender's id, so a broadcast is one `rpc()` and every handler can ask
## who really sent it.

## Emitted when the connection state changes, so the join screen can say so.
signal status_changed
## Emitted when someone joins, leaves or is renamed.
signal roster_changed
## `text` is already formatted for display, e.g. "IVAN killed SOLDIER".
signal notice(text: String)

enum { OFFLINE, CONNECTING, CLIENT, SERVER }

## Where a browser client connects when the page does not say otherwise.
##
## Over https the browser will only allow wss, and a bare wss port needs a
## certificate of its own, so the production assumption is the usual one: the
## same host proxies PROXY_PATH through to the game server. Over plain http --
## which in practice means `python3 dev.py serve` on a laptop -- there is no
## proxy, so it goes straight at the port the server listens on.
##
## Either way `?server=ws://host:port` on the page URL overrides it, which is
## the quickest way to point a build somewhere else without rebuilding it.
const DEFAULT_PORT := 8100
const PROXY_PATH := "/ws"

## What version of this conversation the build speaks. Bump it whenever anything
## about what travels over the wire changes: a new message, a changed argument
## list, a reordered enum -- and, less obviously, any edit to
## `LoadoutConfig.ITEMS`. What `report_equip` sends is a position in that list,
## so adding, removing or moving an entry silently re-points every index after
## it at somebody else's weapon.
##
## It exists because the failure it catches is so quiet. Godot numbers remote
## calls by their order on the node, so a client and a server built from
## different code do not fail to understand each other -- they understand each
## other wrongly, calling whatever now happens to sit at that number. Nothing
## errors. Terrain edits arrive as something else, damage lands on nothing, and
## the two of them drift apart while both look perfectly healthy. Nothing is
## easier to do by accident, either: rebuilding the page and leaving the server
## running is the obvious thing to do, and it is enough.
## The hand-written half, for everything a person has to notice: a new message,
## a changed argument list, a reordered enum.
##
## 3: the chevrons came out of the catalogue and the medic went in, which moved
## the smoke, TNT and grenade indices. Two builds either side of that agreed on
## every other weapon and disagreed on those, which reads as a soldier
## respawning with kit he did not pick.
const PROTOCOL_BASE := 3

## The catalogue's half, worked out rather than remembered.
##
## Editing `LoadoutConfig.ITEMS` is a wire change, because `report_equip` sends a
## position in that list. It is also the wire change nobody thinks of as one --
## adding a weapon feels like content, not protocol -- and forgetting it is how
## the smoke grenade above came to arrive as a medic bag. So the catalogue
## fingerprints itself and no one has to remember.
static var _fingerprint := -1

## What version of this conversation the build speaks, both halves together.
## Compared outright, so any difference in either one refuses the connection.
static func protocol() -> int:
	if _fingerprint < 0:
		_fingerprint = _catalogue_fingerprint()
	return PROTOCOL_BASE * 1000000 + _fingerprint


## FNV-1a over the catalogue's keys, in order. Written out here rather than
## reached for through `String.hash()` so the number depends on the catalogue
## alone -- an engine free to change its own hash between versions would
## otherwise be able to split two builds that agree about everything.
static func _catalogue_fingerprint() -> int:
	var h := 2166136261
	for entry: Dictionary in LoadoutConfig.ITEMS:
		for byte: int in String(entry["key"]).to_utf8_buffer():
			h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
		# Between entries, so ["ab", "c"] cannot hash as ["a", "bc"].
		h = ((h ^ 0x2C) * 16777619) & 0xFFFFFFFF
	return h % 1000000


## The version in a form worth putting in front of a person: the half they wrote
## and the half the catalogue wrote, kept apart so a mismatch says which moved.
static func protocol_text(value: int) -> String:
	@warning_ignore("integer_division")
	return "v%d+%06d" % [value / 1000000, value % 1000000]
## How long a client waits to be told the server's version before deciding it is
## talking to a build too old to say.
const HANDSHAKE_SECONDS := 5.0

## Socket buffers, per peer, in bytes, and the packet count to match.
##
## The engine defaults to 64KB, which is not enough and fails badly when it runs
## out: the overflow is silent to us -- an error on the console and the packet is
## simply gone. Unreliable state survives that, because another one is along in
## fifty milliseconds. Everything else does not. A dropped block, a dropped
## joining snapshot or a dropped change of weapon never comes again, and what it
## leaves behind is two people standing in worlds that disagree.
##
## Two things routinely overrun 64KB. A browser tab that loses focus stops being
## given frames at all, so nothing drains the socket until it comes back; and the
## snapshot handed to somebody joining a well-chewed map is one large packet that
## has to fit whole. A megabyte covers about a minute of a stalled tab at this
## traffic, and a snapshot of some tens of thousands of altered blocks.
const SOCKET_BUFFER := 1 << 20
const SOCKET_QUEUE := 4096

## How often a client publishes where it is. Twenty is enough for the far end to
## interpolate smoothly and is a fraction of the traffic of sending every frame.
const STATE_HZ := 20.0

## Wire codes for `_event`. An enum rather than strings so a typo is a parse
## error instead of an event that silently never arrives.
enum {
	EV_FIRE,       ## pulled a trigger: [] -- the avatar knows the rest
	EV_EQUIP,      ## changed weapon: [catalogue index]
	EV_DIE,        ## went down: [killer id]
	EV_SPAWN,      ## got back up: [position]
	EV_NAME,       ## joined or was renamed: [name]
	EV_PROJECTILE, ## threw or planted something: [kind, position, velocity, fuse]
	EV_FX_BLAST,   ## something went off: [position, energy, range, volume, rumble, shake]
	EV_VEHICLE,    ## got into or out of something: [scene path, aboard]
	EV_REVIVED,    ## a medic got us back up: [medic id]
	EV_AMMO,       ## emptied an ammunition box: [scene path]
}

## Scenes an EV_PROJECTILE can name. The wire carries the index, so this list is
## append-only: inserting in the middle would repoint every older client.
const PROJECTILE_GRENADE := 0
const PROJECTILE_SMOKE := 1
const PROJECTILE_TNT := 2
const PROJECTILES: Array[PackedScene] = [
	preload("res://scenes/grenade_projectile.tscn"),
	preload("res://scenes/smoke_projectile.tscn"),
	preload("res://scenes/tnt_charge.tscn"),
]

const REMOTE_PLAYER: PackedScene = preload("res://scenes/remote_player.tscn")

var mode := OFFLINE
## Why the last attempt failed, so the join screen can say something more useful
## than sitting on "connecting" forever.
var last_error := ""

## peer id -> {"name": String, "kills": int, "deaths": int}
var roster := {}

## peer id -> RemotePlayer, for everyone but us.
var _avatars := {}
## The local soldier, once one exists. Handed over by Player as it enters.
var _local: Node3D
## Where avatars are parented. Remade whenever the world scene is.
var _arena: Node3D
## The server's copy of the terrain, for replaying to late joiners. Null on a
## client, where the real VoxelWorld in the scene does that job.
var _server_world: Node
## A joining snapshot held until there is a world to put it into: joining
## happens on the menu, where no terrain exists yet.
var _pending_world: Array = []
## Damage each map-owned thing has taken, path -> total. Kept by the server so a
## joiner is handed a world with the same wrecks in it; held on a client only
## between arriving and there being a map to apply it to.
var _entity_log := {}
var _pending_entities := {}

## Who last put damage into us, and when. Kept here rather than on the player
## because the wire is where the answer comes from: a soldier being shot has no
## idea who did it until the shooter's client says so.
var _attacker := 0
var _attacked_at := 0.0
## How long a shooter stays credited for a kill. Long enough that finishing
## somebody off with a grenade after wounding them still counts, short enough
## that walking off a cliff a minute later does not.
const CREDIT_SECONDS := 12.0

## When each peer was last heard from, in seconds. A browser that is not the tab
## you are looking at gets no frames, so its game loop stops dead -- but its
## socket stays open, so the server goes on counting it and it goes on appearing
## in the roster while sending absolutely nothing. Without this that reads as
## "the game is broken", when what it means is "their window is behind another
## one". See `is_awake`.
var _heard_from := {}
## How long a peer can go quiet before it is called asleep. State arrives twenty
## times a second, so this is many missed packets rather than a slow connection.
const AWAKE_SECONDS := 2.0

## Whether the server has confirmed it speaks the same version we do.
var _verified := false
var _handshake_due := 0.0

var _state_accum := 0.0
## Terrain damage this frame, coalesced so a burst chewing a wall is one message
## rather than one per round. index -> amount.
var _terrain_batch := {}
## Set while an incoming change to the world is being applied, so VoxelWorld --
## which reports every block it changes, and cannot tell who asked -- does not
## bounce it straight back out. Deliberately narrow: it guards the terrain and
## nothing else. Wrapping it round incoming damage as well would be the obvious
## thing to do and would be wrong, because a soldier dying of that damage has to
## be able to say so.
var _applying := false


## True once there is a connection worth using. Everything that broadcasts tests
## this first, which is what keeps single-player working untouched.
func active() -> bool:
	return mode == CLIENT or mode == SERVER


func is_server() -> bool:
	return mode == SERVER


func local_id() -> int:
	return multiplayer.get_unique_id() if active() else 1


## Who to credit if we go down right now. Zero when nobody has shot at us
## recently enough, which is how a fall or the boundary line reads as an
## accident rather than as somebody's kill.
func last_attacker() -> int:
	if _attacker == 0:
		return 0
	if Time.get_ticks_msec() / 1000.0 - _attacked_at > CREDIT_SECONDS:
		return 0
	return _attacker


func name_of(id: int) -> String:
	var entry: Dictionary = roster.get(id, {})
	return entry.get("name", "SOLDIER")


## Which ground this client is playing on. Set from the map screen before
## anything connects, and carried in the roster for everybody else.
##
## This is what splits one server into several matches. Everybody who picked the
## same map shares a field: they see each other, shoot each other, share a
## ticket count and a round. Everybody who picked a different one is on the same
## socket and in the same roster and is otherwise not there at all -- no avatar,
## no state, no events, no effect on the score. One server, four matches.
var map_id := MapCatalogue.DEFAULT_ID


## Moves this client to a different ground. Safe before connecting, which is the
## usual case, and tells the server if we are already in.
func choose_map(id: String) -> void:
	id = MapCatalogue.resolve(id)
	if id == map_id:
		return
	map_id = id
	if mode == CLIENT:
		_switch_field.rpc_id(1, id)
	# Everybody we could see was on the old field, so none of them are ours now.
	for peer: int in _avatars.keys():
		_drop_avatar(peer)
	roster_changed.emit()
	status_changed.emit()


## Which ground somebody is on. Ourselves by definition -- we are the one
## running the code that asks.
func map_of(id: int) -> String:
	if id == local_id():
		return map_id
	var entry: Dictionary = roster.get(id, {})
	return String(entry.get("map", MapCatalogue.DEFAULT_ID))


## Whether somebody is on our ground, which is the test every incoming message
## is filtered through.
func on_my_field(id: int) -> bool:
	return map_of(id) == map_id


## The same question for anything that touches the terrain, asked the right way
## round at each end. A client keeps what its own field sends. A server keeps
## one map's ground -- whichever its own world loaded -- so it keeps what that
## field sends and lets the rest pass through to the people it belongs to.
func _from_this_field(id: int) -> bool:
	if mode != SERVER:
		return on_my_field(id)
	return String(roster.get(id, {}).get("map", MapCatalogue.DEFAULT_ID)) == map_id


## The two sides. Names rather than numbers because the map file names its
## spawns the same way, and a map is easier to read that way than as 0 and 1.
const BLUE := "blue"
const RED := "red"

## What each side wears. The same two colours the map paints its own bases in,
## so a soldier reads as belonging to the compound he came out of rather than to
## some separate scheme the scoreboard keeps to itself.
const TEAM_COLOURS := {
	BLUE: Color(0.18, 0.32, 0.6),
	RED: Color(0.62, 0.17, 0.15),
}

## Casualties a side can take before it loses. Every respawn is one man off the
## roll, which is what makes a bad trade cost something even when you win it.
const CASUALTY_LIMIT := 100
## Seconds the scoreboard is up between rounds.
const INTERMISSION := 14.0

## Emitted when the round starts, ends, or the count moves.
signal round_changed

## Every field the server is running, by map id, each with its own casualties
## and its own round. A match is a map: two people on different maps can be
## mid-round and mid-scoreboard at the same time and neither is aware of it.
##
## Only the server fills this in. A client keeps the single set of numbers below
## for the one field it is actually on, fed by the server.
var _fields := {}

## Casualties taken so far, by side. The server owns these outright: it is the
## only thing that hears every death, and a count each client kept for itself
## would be a count that disagreed the moment one of them missed a packet.
var casualties := {BLUE: 0, RED: 0}
## True while the scoreboard is up and nobody is playing.
var round_over := false
## Which side ran out, and the standings as they were when it did. Frozen at the
## moment the round ended rather than read live, so the scoreboard does not
## quietly rewrite itself while people are reading it.
var round_loser := ""
var round_standings := {}
## Unix-ish seconds at which the next round begins, for the countdown.
var round_resumes_at := 0.0


## One field's books, made the first time anybody stands on it.
func _field(name: String) -> Dictionary:
	if not _fields.has(name):
		_fields[name] = {
			"casualties": {BLUE: 0, RED: 0},
			"over": false, "loser": "", "standings": {}, "resumes": 0.0,
		}
	return _fields[name]


## Everybody on one field, for a message that belongs to that match alone.
func _peers_on(field: String) -> Array:
	var out: Array = []
	for id: int in roster:
		if String(roster[id].get("map", MapCatalogue.DEFAULT_ID)) == field:
			out.append(id)
	return out


## How many a side has left. What the readout shows, because "sixteen left" is a
## thing you can act on and "eighty-four lost" is a thing you have to subtract.
func tickets(side: String) -> int:
	return maxi(CASUALTY_LIMIT - int(casualties.get(side, 0)), 0)


## Seconds until play resumes, for the countdown on the scoreboard.
func intermission_left() -> float:
	return maxf(round_resumes_at - Time.get_ticks_msec() / 1000.0, 0.0)


## Which side to put the next arrival on: whichever is short, and blue when the
## sides are level. Decided by the server and only by the server -- two clients
## each picking for themselves would both pick the same empty side.
func _thinnest_side(field: String) -> String:
	var blue := 0
	var red := 0
	for id: int in roster:
		if String(roster[id].get("map", MapCatalogue.DEFAULT_ID)) != field:
			continue
		if roster[id].get("team", BLUE) == RED:
			red += 1
		else:
			blue += 1
	return RED if red < blue else BLUE


## Which side somebody is on. Everyone is blue when playing alone, which costs
## nothing and means the rest of the game never has to ask whether there is a
## match on before it can ask a question about teams.
func team_of(id: int) -> String:
	var entry: Dictionary = roster.get(id, {})
	return entry.get("team", BLUE)


func my_team() -> String:
	return team_of(local_id())


## The colour of a side's uniform. Falls back to blue, the same way `team_of`
## does, so a soldier whose side has not arrived yet is dressed rather than
## invisible.
func team_colour(side: String) -> Color:
	return TEAM_COLOURS.get(side, TEAM_COLOURS[BLUE])


## Whether a peer is actually playing, as opposed to merely still connected.
## The two come apart whenever somebody's window goes behind another one: the
## browser stops giving that tab frames, so the game stops running and stops
## saying where it is, while the socket sits there perfectly healthy. Ourselves,
## by definition -- we are the one running the code that asks.
func is_awake(id: int) -> bool:
	if id == local_id():
		return true
	var last: float = _heard_from.get(id, -1.0)
	if last < 0.0:
		return false
	return Time.get_ticks_msec() / 1000.0 - last <= AWAKE_SECONDS


## How many soldiers are on our ground, us included. People who picked one of
## the other maps are on the server but not in this match, so they are not in
## this number either. The headless server is neither, and is not in the roster.
func player_count() -> int:
	var here := 0
	for id: int in roster:
		if String(roster[id].get("map", MapCatalogue.DEFAULT_ID)) == map_id:
			here += 1
	return here


## Connection state, for the join screen.
func status_text() -> String:
	match mode:
		SERVER:
			return "HOSTING  ·  %d IN THE FIELD" % player_count()
		CLIENT:
			return "CONNECTED  ·  %d IN THE FIELD" % maxi(player_count(), 1)
		CONNECTING:
			return "CONNECTING..."
	if last_error.is_empty():
		return "OFFLINE"
	return "OFFLINE  ·  %s" % last_error


func _ready() -> void:
	# Autoloads keep ticking across scene changes, which is the point: the
	# connection is opened on the join screen and has to survive the change into
	# the world.
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	if _wants_server():
		start_server(_argument_int("--port", DEFAULT_PORT))
	else:
		join(resolve_url())


## Listens for players. Headless: `godot --headless --path . -- --server`.
func start_server(port: int) -> void:
	var peer := _socket()
	var err := peer.create_server(port)
	if err != OK:
		push_error("Net: cannot listen on port %d (error %d)" % [port, err])
		last_error = "port %d busy" % port
		status_changed.emit()
		return
	multiplayer.multiplayer_peer = peer
	mode = SERVER
	print("Net: listening on port %d" % port)
	status_changed.emit()


## Opens a connection. Failing is not fatal -- the game falls back to playing
## alone, which is what should happen when someone runs the desktop build with
## no server up.
func join(url: String) -> void:
	if url.is_empty():
		return
	var peer := _socket()
	if peer.create_client(url) != OK:
		last_error = "bad address"
		status_changed.emit()
		return
	multiplayer.multiplayer_peer = peer
	mode = CONNECTING
	last_error = ""
	print("Net: connecting to %s" % url)
	status_changed.emit()


## A socket with room in it. Both ends want the same treatment: the server holds
## one set of these buffers per client it is talking to, and a client one for the
## server, and either running dry loses the same packets.
func _socket() -> WebSocketMultiplayerPeer:
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = SOCKET_BUFFER
	peer.outbound_buffer_size = SOCKET_BUFFER
	peer.max_queued_packets = SOCKET_QUEUE
	return peer


## Where this build should look for the server, in order of preference: an
## explicit command line argument, the page's own `?server=`, then the defaults
## described up at PROXY_PATH.
func resolve_url() -> String:
	var override := _argument("--url", "")
	if not override.is_empty():
		return override
	if not OS.has_feature("web"):
		return "ws://127.0.0.1:%d" % DEFAULT_PORT

	var query := str(JavaScriptBridge.eval("window.location.search", true))
	for part: String in query.trim_prefix("?").split("&", false):
		if part.begins_with("server="):
			return part.substr(7).uri_decode()

	var host := str(JavaScriptBridge.eval("window.location.hostname", true))
	if host.is_empty():
		return ""
	# Behind TLS the only thing that works without a certificate of its own is a
	# path on the same origin; without it, the port stands on its own.
	if str(JavaScriptBridge.eval("window.location.protocol", true)) == "https:":
		return "wss://%s%s" % [host, PROXY_PATH]
	return "ws://%s:%d" % [host, DEFAULT_PORT]


## Called by Player as it enters the world, both to hand over the soldier we are
## driving and to say which scene the avatars belong in.
func attach_local(player: Node3D) -> void:
	_local = player
	_arena = null
	_avatars.clear()
	if not active():
		return
	# The world we were handed on joining has been waiting for a world to be
	# applied to. This is that moment, and it has to be here rather than
	# wherever the first avatar turns up: walking into an empty server still
	# means walking into whatever the last people there did to the ground.
	_apply_pending_world()
	_send_event(EV_NAME, [_own_name()])


## What to call ourselves. Normally whatever was typed on the join screen, but
## the world scene can be run directly without ever seeing that screen, and an
## unnamed soldier on somebody else's scoreboard is worse than a generic one.
func _own_name() -> String:
	if LoadoutConfig.player_name.is_empty():
		return LoadoutConfig.DEFAULT_NAME
	return LoadoutConfig.player_name


func _process(delta: float) -> void:
	if not active():
		return
	# A server old enough to predate the version handshake will never send one,
	# so silence for long enough is itself the answer.
	if mode == CLIENT and not _verified:
		_handshake_due -= delta
		if _handshake_due <= 0.0:
			_refuse("server never said which build it is; it is an old one")
			return
	_flush_terrain()
	if _local == null or not is_instance_valid(_local):
		return
	_state_accum += delta
	if _state_accum < 1.0 / STATE_HZ:
		return
	_state_accum = 0.0
	_state.rpc(_local.net_state())

	# Riding something means driving it for everybody, so its pose goes out on
	# the same tick as ours. Only the driver ever sends this, which is what makes
	# one machine the answer to where the thing is.
	var vehicle: Node3D = _local.riding()
	if vehicle != null and is_instance_valid(vehicle) and vehicle.has_method("net_state"):
		_vehicle_state.rpc(scene_path_of(vehicle), vehicle.net_state())


# --- outgoing -----------------------------------------------------------

## One shot fired. Carries nothing: the avatar already knows which weapon it is
## holding and where that weapon's muzzle is.
func report_fire() -> void:
	_send_event(EV_FIRE, [])


func report_equip(item_index: int) -> void:
	_send_event(EV_EQUIP, [item_index])


func report_death(killer_id: int) -> void:
	if not active():
		return
	_send_event(EV_DIE, [killer_id])
	# An event does not come back to whoever sent it, so the one person who
	# most wants to know who did it would otherwise be the only one not told.
	_announce_kill(killer_id, local_id())


func report_spawn(at: Vector3) -> void:
	_send_event(EV_SPAWN, [at])


## A thrown or planted device, so everyone else can watch it fly. Their copy is
## inert -- see `net_ghost` on the projectiles themselves.
func report_projectile(kind: int, at: Vector3, velocity: Vector3, fuse: float) -> void:
	_send_event(EV_PROJECTILE, [kind, at, velocity, fuse])


## The flash and the bang of something going off. Only needed for detonations
## with no projectile behind them -- a bazooka rocket, an artillery shell, a
## tank round. A grenade or a charge is already on everyone's screen and brings
## its own effects with it.
func report_blast(
	at: Vector3, energy: float, light_range: float, volume_db: float,
	rumble: bool, shake: float
) -> void:
	_send_event(EV_FX_BLAST, [at, energy, light_range, volume_db, rumble, shake])


## Everyone else's soldier that currently has a body in the world. For anything
## that needs to find people rather than shoot at them -- a ray finds the living
## well enough, but a man who is down has his collider switched off and there is
## nothing there to hit.
func soldiers() -> Array:
	var found: Array = []
	for id: int in _avatars:
		var soldier: Node3D = _avatars[id]
		if soldier != null and is_instance_valid(soldier):
			found.append(soldier)
	return found


## A medic has patched somebody up. Sent to them rather than applied here: their
## client is the one keeping their health, exactly as it is for damage.
func report_heal(target_id: int) -> void:
	if not active() or target_id == local_id():
		return
	_aid.rpc_id(target_id, false)


## A medic has reached a body. Whether it takes is the casualty's own client to
## decide -- it is the only one that knows whether they have already given up
## and respawned on their own, and only one of the two answers refunds the man.
func report_revive(target_id: int) -> void:
	if not active() or target_id == local_id():
		return
	_aid.rpc_id(target_id, true)


## Damage one client's shot did to another client's soldier. The victim decides
## what it does to them; all this does is deliver the message.
func report_hit(
	target_id: int, amount: float, at: Vector3, from: Vector3, kind: StringName
) -> void:
	if not active() or target_id == local_id():
		return
	_hit.rpc_id(target_id, amount, at, from, kind)


## Damage to something that belongs to the map rather than to a player: the
## tank, the mannequin, anything else standing in the world when it loads.
##
## These are the other half of the world, and they need the same treatment the
## terrain gets and for the same reason. Every client has its own copy running
## its own simulation, so a hit that lands on one copy is invisible to the rest
## and the two drift apart immediately -- most obviously when one of them has
## taken enough to blow up and the others still have it sitting there intact.
##
## Named by where it sits in the scene, because every client loaded the same map
## and therefore has the same node at the same path. That is worth more than a
## registry of ids: there is nothing to assign, nothing to keep in step, and
## anything added to the map is covered the moment it calls this.
func report_entity_damage(
	node: Node, amount: float, at: Vector3, from: Vector3, kind: StringName
) -> void:
	if not active() or _applying or amount <= 0.0:
		return
	var path := scene_path_of(node)
	if path.is_empty():
		return
	_entity_damage.rpc(path, amount, at, from, kind)


## Somebody climbing into a vehicle, or back out of it. Whoever is in it owns it
## until they get out, and everybody else stops simulating their copy.
func report_vehicle(node: Node, aboard: bool) -> void:
	if not active() or _applying:
		return
	var path := scene_path_of(node)
	if not path.is_empty():
		_send_event(EV_VEHICLE, [path, aboard])


## Somebody took the ammunition out of a box. Named by its path in the scene
## rather than by an index, the same way a vehicle is: the box belongs to the
## map, and the map is the one thing every client loaded identically.
##
## Sent rather than asked for. The ammunition itself is the taker's own business
## -- their client is the only one keeping what they are carrying -- so all that
## has to travel is the fact that this crate is empty now.
func report_ammo(node: Node) -> void:
	if not active() or _applying:
		return
	var path := scene_path_of(node)
	if not path.is_empty():
		_send_event(EV_AMMO, [path])


## Where a node sits relative to the scene root, which is the one name for it
## every client agrees on.
func scene_path_of(node: Node) -> NodePath:
	var scene := get_tree().current_scene
	if scene == null or node == null or not node.is_inside_tree():
		return NodePath()
	return scene.get_path_to(node)


## Terrain that took damage this frame, coalesced by block and sent once. A
## burst of automatic fire into a wall is otherwise a message per round.
func report_terrain(index: int, amount: float) -> void:
	if not active() or _applying:
		return
	_terrain_batch[index] = float(_terrain_batch.get(index, 0.0)) + amount


## A block put down by hand. Rare enough to send on its own.
func report_place(index: int, type: int) -> void:
	if not active() or _applying:
		return
	_place.rpc(index, type)


func _flush_terrain() -> void:
	if _terrain_batch.is_empty():
		return
	var indices := PackedInt64Array()
	var amounts := PackedFloat32Array()
	for index: int in _terrain_batch:
		indices.append(index)
		amounts.append(_terrain_batch[index])
	_terrain_batch.clear()
	_terrain.rpc(indices, amounts)


func _send_event(kind: int, data: Array) -> void:
	if not active():
		return
	_event.rpc(kind, data)


# --- the wire -----------------------------------------------------------
#
# Each handler runs on the server as well as on every other client, and branches
# on which one it is. The server only cares about the messages that change the
# world; the rest it forwards without looking, which the relay does for free.

@rpc("any_peer", "unreliable_ordered", "call_remote")
func _state(data: PackedFloat32Array) -> void:
	var from := multiplayer.get_remote_sender_id()
	_heard_from[from] = Time.get_ticks_msec() / 1000.0
	if mode == SERVER:
		return
	# Somebody playing one of the other maps. The relay hands their packets to
	# everybody because it does not know about fields; this is where they stop.
	if not on_my_field(from):
		return
	var avatar := _ensure_avatar(from)
	if avatar != null:
		avatar.apply_state(data)


@rpc("any_peer", "reliable", "call_remote")
func _event(kind: int, data: Array) -> void:
	var from := multiplayer.get_remote_sender_id()
	if mode == SERVER:
		# The roster is the server's, so anything that changes it lands here
		# rather than being left for each client to tally on its own and drift.
		if kind == EV_NAME and roster.has(from):
			roster[from]["name"] = str(data[0])
			_roster_update.rpc(roster)
		elif kind == EV_DIE:
			_tally_kill(int(data[0]), from)
		elif kind == EV_REVIVED:
			_refund_casualty(from, int(data[0]))
		return
	_apply_event(from, kind, data)


## Books one death against the victim and, when somebody earned it, one kill for
## whoever did. A soldier who walks off the edge is charged the death and nobody
## is credited with it.
func _tally_kill(killer: int, victim: int) -> void:
	var field := String(roster.get(victim, {}).get("map", MapCatalogue.DEFAULT_ID))
	var books := _field(field)
	# Nothing counts while the scoreboard is up. Somebody who was already falling
	# when the round ended would otherwise land a casualty on the next one.
	if books["over"]:
		return
	if roster.has(victim):
		roster[victim]["deaths"] = int(roster[victim]["deaths"]) + 1
	if killer != victim and roster.has(killer):
		roster[killer]["kills"] = int(roster[killer]["kills"]) + 1
	_roster_update.rpc(roster)

	# A death is a casualty against the side that took it, however it happened.
	# Walking off the boundary line costs your side a man exactly as being shot
	# does, which is the point of counting respawns rather than kills.
	var side := team_of(victim)
	var count: Dictionary = books["casualties"]
	count[side] = int(count.get(side, 0)) + 1
	for peer: int in _peers_on(field):
		_casualties.rpc_id(peer, count)
	if field == map_id:
		casualties = count.duplicate()
		round_changed.emit()
	if count[side] >= CASUALTY_LIMIT:
		_end_round(side, field)


## Takes a casualty back off the board. The man was counted when he went down,
## because at that moment nobody knew whether anyone would reach him; a medic
## who does is undoing that, so the side gets its hundredth back and the death
## comes off his record too.
##
## Clamped at zero and refused between rounds, so a dressing applied on the far
## side of a round boundary cannot hand the next one a free man.
func _refund_casualty(victim: int, medic: int) -> void:
	var field := String(roster.get(victim, {}).get("map", MapCatalogue.DEFAULT_ID))
	var books := _field(field)
	if books["over"]:
		return
	var side := team_of(victim)
	var count: Dictionary = books["casualties"]
	count[side] = maxi(int(count.get(side, 0)) - 1, 0)
	if roster.has(victim):
		roster[victim]["deaths"] = maxi(int(roster[victim]["deaths"]) - 1, 0)
	if roster.has(medic):
		roster[medic]["revives"] = int(roster[medic].get("revives", 0)) + 1
	for peer: int in _peers_on(field):
		_casualties.rpc_id(peer, count)
	_roster_update.rpc(roster)
	if field == map_id:
		casualties = count.duplicate()
	round_changed.emit()


## Calls the round. Only ever runs on the server, which is the only thing that
## has seen every death.
func _end_round(loser: String, field: String) -> void:
	var books := _field(field)
	if books["over"]:
		return
	books["over"] = true
	books["loser"] = loser
	# Only the people who fought it are on its scoreboard.
	var standings := {}
	for peer: int in _peers_on(field):
		standings[peer] = roster[peer].duplicate(true)
	books["standings"] = standings
	books["resumes"] = Time.get_ticks_msec() / 1000.0 + INTERMISSION
	for peer: int in _peers_on(field):
		_round_over.rpc_id(peer, loser, standings, INTERMISSION)
	if field == map_id:
		round_over = true
		round_loser = loser
		round_standings = standings
		round_resumes_at = books["resumes"]
		round_changed.emit()
	print("[server] %s: %s is out of men; %s holds the field" % [
		field, loser, RED if loser == BLUE else BLUE])
	get_tree().create_timer(INTERMISSION).timeout.connect(_begin_round.bind(field))


## Wipes the slate and puts everyone back in the field.
func _begin_round(field: String) -> void:
	if mode != SERVER:
		return
	var books := _field(field)
	books["casualties"] = {BLUE: 0, RED: 0}
	books["over"] = false
	books["loser"] = ""
	books["standings"] = {}
	var here := _peers_on(field)
	for id: int in here:
		roster[id]["kills"] = 0
		roster[id]["deaths"] = 0
	# The next people to join must not be handed the last round's wreckage --
	# but only this field's, and the terrain we hold is one map's.
	if field == map_id:
		_entity_log.clear()
		casualties = {BLUE: 0, RED: 0}
		round_over = false
		round_loser = ""
		round_standings = {}
		round_changed.emit()
	_roster_update.rpc(roster)
	for peer: int in here:
		_round_start.rpc_id(peer)
	print("[server] %s: round begins" % field)


@rpc("any_peer", "reliable", "call_remote")
func _hit(amount: float, at: Vector3, from: Vector3, kind: StringName) -> void:
	if _local == null or not is_instance_valid(_local):
		return
	_attacker = multiplayer.get_remote_sender_id()
	_attacked_at = Time.get_ticks_msec() / 1000.0
	_local.take_damage(amount, at, from, kind)


## Somebody's medic has got to us. Applied here rather than by them, because
## this is the only client that knows whether we are up, down, or already back
## on our feet by the time the dressing arrives.
@rpc("any_peer", "reliable", "call_remote")
func _aid(revive: bool) -> void:
	if _local == null or not is_instance_valid(_local):
		return
	var medic := multiplayer.get_remote_sender_id()
	if not revive:
		_local.heal_full()
		notice.emit("%s patched you up" % name_of(medic))
		return
	# Only a body that is still a body. Somebody who gave up and respawned a
	# moment ago has already cost their side the man, and reviving them now
	# would hand it back for nothing.
	if not _local.revive_from_aid():
		return
	notice.emit("%s got you back on your feet" % name_of(medic))
	# Reported after the fact, by the man who was actually revived. The server
	# refunds on the strength of that rather than on the medic's say-so, so a
	# medic working a body that had already given up cannot claim the man back.
	_send_event(EV_REVIVED, [medic])


@rpc("any_peer", "reliable", "call_remote")
func _terrain(indices: PackedInt64Array, amounts: PackedFloat32Array) -> void:
	if not _from_this_field(multiplayer.get_remote_sender_id()):
		return
	var world: Node = _server_world if mode == SERVER else _world()
	if world == null:
		return
	_applying = true
	for i in indices.size():
		world.damage_index(indices[i], amounts[i])
	_applying = false


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _vehicle_state(path: NodePath, data: PackedFloat32Array) -> void:
	if mode == SERVER:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var vehicle := scene.get_node_or_null(path)
	if vehicle == null or not vehicle.has_method("apply_net_state"):
		return
	# A pose from somebody who is not driving it is not worth having: they will
	# have handed it back and this is simply a packet that outlived the handover.
	if vehicle.get("net_driver") != multiplayer.get_remote_sender_id():
		return
	vehicle.apply_net_state(data)


@rpc("any_peer", "reliable", "call_remote")
func _entity_damage(
	path: NodePath, amount: float, at: Vector3, from: Vector3, kind: StringName
) -> void:
	if not _from_this_field(multiplayer.get_remote_sender_id()):
		return
	# The server holds the running total so that somebody joining an hour late
	# does not find a wreck standing up again, but it has no map of its own to
	# apply it to -- its scene is the terrain and nothing else.
	if mode == SERVER:
		_entity_log[path] = float(_entity_log.get(path, 0.0)) + amount
		return
	_apply_entity_damage(path, amount, at, from, kind)


func _apply_entity_damage(
	path: NodePath, amount: float, at: Vector3, from: Vector3, kind: StringName
) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var node := scene.get_node_or_null(path)
	if node == null or not node.has_method("take_damage"):
		return
	_applying = true
	node.take_damage(amount, at, from, kind)
	_applying = false


@rpc("any_peer", "reliable", "call_remote")
func _place(index: int, type: int) -> void:
	if not _from_this_field(multiplayer.get_remote_sender_id()):
		return
	var world: Node = _server_world if mode == SERVER else _world()
	if world == null:
		return
	_applying = true
	world.place_index(index, type)
	_applying = false


## Everything a joiner needs: who is here, and every block that has been shot,
## dug or built since the server came up.
@rpc("authority", "reliable", "call_remote")
func _welcome(
	who: Dictionary, indices: PackedInt64Array, amounts: PackedFloat32Array,
	placed: PackedInt64Array, types: PackedByteArray, entities: Dictionary
) -> void:
	roster = who
	_pending_world = [indices, amounts, placed, types]
	_pending_entities = entities
	_apply_pending_world()
	roster_changed.emit()
	status_changed.emit()


@rpc("authority", "reliable", "call_remote")
func _casualties(count: Dictionary) -> void:
	casualties = count
	round_changed.emit()


@rpc("authority", "reliable", "call_remote")
func _round_over(loser: String, standings: Dictionary, seconds: float) -> void:
	round_over = true
	round_loser = loser
	round_standings = standings
	round_resumes_at = Time.get_ticks_msec() / 1000.0 + seconds
	round_changed.emit()


## Back to the start: the count, the standings, the ground and everything
## standing on it. Reloading the scene would be simpler and is not an option --
## on this map that is a two-minute rebuild, and the whole match would sit
## through it between every round.
@rpc("authority", "reliable", "call_remote")
func _round_start() -> void:
	round_over = false
	round_loser = ""
	round_standings = {}
	casualties = {BLUE: 0, RED: 0}

	var world := _world()
	if world != null:
		_applying = true
		world.reset_to_map()
		_applying = false
	# Everything the fighting damaged puts itself back. Asked of the whole group
	# rather than of the tank by name, so anything added to a map later is
	# included by implementing the method and nothing else.
	for node in get_tree().get_nodes_in_group(Lethality.DAMAGEABLE):
		if node.has_method("round_reset"):
			node.round_reset()
	for node in get_tree().get_nodes_in_group(Tank.VEHICLES):
		if node.has_method("round_reset"):
			node.round_reset()
	for node in get_tree().get_nodes_in_group(AmmoBox.BOXES):
		if node.has_method("round_reset"):
			node.round_reset()
	round_changed.emit()


@rpc("authority", "reliable", "call_remote")
func _roster_update(who: Dictionary) -> void:
	roster = who
	# Somebody may have left while we were not looking.
	for id: int in _avatars.keys():
		if not roster.has(id):
			_drop_avatar(id)
	roster_changed.emit()
	status_changed.emit()


## A client saying who it is. Until this arrives the server has a socket but not
## a soldier behind it.
@rpc("any_peer", "reliable", "call_remote")
func _hello(player_name: String, field: String) -> void:
	if mode != SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	field = MapCatalogue.resolve(field)
	roster[id] = {
		"name": player_name, "kills": 0, "deaths": 0, "map": field,
		"team": _thinnest_side(field),
	}
	# The terrain we hold is one map's. Somebody who picked a different one gets
	# a clean world rather than another map's craters.
	var mine := field == map_id
	var snapshot: Array = _server_snapshot() if mine else [
		PackedInt64Array(), PackedFloat32Array(), PackedInt64Array(), PackedByteArray()
	]
	_welcome.rpc_id(
		id, roster, snapshot[0], snapshot[1], snapshot[2], snapshot[3],
		_entity_log if mine else {}
	)
	_casualties.rpc_id(id, _field(field)["casualties"])
	_roster_update.rpc(roster)
	roster_changed.emit()
	print("Net: %s joined as peer %d, on %s" % [player_name, id, field])


## Somebody went back to the map screen and picked a different ground. They keep
## their name and their socket and lose everything else: a new side, a new
## ticket count, and no part in the match they walked out of.
@rpc("any_peer", "reliable", "call_remote")
func _switch_field(field: String) -> void:
	if mode != SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	if not roster.has(id):
		return
	field = MapCatalogue.resolve(field)
	if String(roster[id].get("map", "")) == field:
		return
	roster[id]["map"] = field
	roster[id]["team"] = _thinnest_side(field)
	roster[id]["kills"] = 0
	roster[id]["deaths"] = 0
	_casualties.rpc_id(id, _field(field)["casualties"])
	_roster_update.rpc(roster)
	roster_changed.emit()
	print("Net: peer %d moved to %s" % [id, field])


# --- applying what arrived ---------------------------------------------

func _apply_event(id: int, kind: int, data: Array) -> void:
	if not on_my_field(id):
		return
	match kind:
		EV_NAME:
			if roster.has(id):
				roster[id]["name"] = str(data[0])
			var named := _ensure_avatar(id)
			if named != null:
				named.set_player_name(str(data[0]))
			roster_changed.emit()
		EV_FIRE:
			var shooter: Node3D = _avatars.get(id)
			if shooter != null and is_instance_valid(shooter):
				shooter.play_fire()
		EV_EQUIP:
			var holder := _ensure_avatar(id)
			if holder != null:
				holder.set_item(int(data[0]))
		EV_DIE:
			var casualty: Node3D = _avatars.get(id)
			if casualty != null and is_instance_valid(casualty):
				casualty.go_down()
			_announce_kill(int(data[0]), id)
		EV_SPAWN:
			var risen := _ensure_avatar(id)
			if risen != null:
				risen.get_back_up(data[0])
		EV_VEHICLE:
			var scene := get_tree().current_scene
			if scene == null:
				return
			var vehicle := scene.get_node_or_null(data[0])
			if vehicle != null and vehicle.has_method("set_net_driver"):
				vehicle.set_net_driver(id if bool(data[1]) else 0)
		EV_AMMO:
			var arena := get_tree().current_scene
			if arena == null:
				return
			var crate := arena.get_node_or_null(data[0])
			if crate != null and crate.has_method("empty_out"):
				crate.empty_out()
		EV_REVIVED:
			var risen_by_medic := _ensure_avatar(id)
			if risen_by_medic != null:
				risen_by_medic.get_back_up(risen_by_medic.global_position)
			notice.emit("%s got %s back up" % [name_of(int(data[0])), name_of(id)])
		EV_PROJECTILE:
			_spawn_ghost(int(data[0]), data[1], data[2], float(data[3]))
		EV_FX_BLAST:
			Blast.effect(
				get_tree().current_scene, data[0], float(data[1]), float(data[2]),
				float(data[3]), bool(data[4])
			)
			if float(data[5]) > 0.0:
				Blast.shake(get_tree(), float(data[5]))


func _announce_kill(killer: int, victim: int) -> void:
	if killer == victim or killer <= 0:
		notice.emit("%s went down" % name_of(victim))
	else:
		notice.emit("%s killed %s" % [name_of(killer), name_of(victim)])


func _apply_pending_world() -> void:
	if _pending_world.is_empty():
		return
	var world := _world()
	if world == null:
		return
	_applying = true
	# Blocks before damage: a wall that was blown in, rebuilt and then shot at
	# again has to be rebuilt before the shooting is replayed onto it.
	var placed: PackedInt64Array = _pending_world[2]
	var types: PackedByteArray = _pending_world[3]
	for i in placed.size():
		world.place_index(placed[i], types[i])
	var indices: PackedInt64Array = _pending_world[0]
	var amounts: PackedFloat32Array = _pending_world[1]
	for i in indices.size():
		world.damage_index(indices[i], amounts[i])
	_applying = false
	_pending_world = []
	if not _pending_entities.is_empty():
		_replay_entities.call_deferred()


## The map's own things, brought up to date. Deferred by a frame rather than
## done inline, because the moment this becomes possible is the player entering
## the tree, and the player is not the last node in the map to do so -- anything
## after it has had no _ready yet, so its @onready references are still null and
## a tank told to blow up would reach for an engine note it has not fetched.
## A frame's wait costs nothing here and puts the whole scene on its feet first.
func _replay_entities() -> void:
	# One lump per thing rather than blow by blow: what matters is that a wreck
	# is a wreck by the time anyone looks at it, not how it got that way.
	for path: NodePath in _pending_entities:
		_apply_entity_damage(
			path, _pending_entities[path], Vector3.ZERO, Vector3.ZERO, Lethality.BLAST
		)
	_pending_entities = {}


# --- avatars ------------------------------------------------------------

## Everyone else's soldier, made on demand. There is no separate spawn message:
## the first thing to arrive about a peer -- usually a position -- is what
## brings their body into being.
func _ensure_avatar(id: int) -> Node3D:
	if id == local_id() or id <= 1:
		return null
	# Bodies exist only for the people we are actually playing against.
	if not on_my_field(id):
		_drop_avatar(id)
		return null
	var existing: Node3D = _avatars.get(id)
	if existing != null and is_instance_valid(existing):
		return existing

	var arena := _players_root()
	if arena == null:
		return null
	var avatar: Node3D = REMOTE_PLAYER.instantiate()
	avatar.name = "Peer%d" % id
	avatar.peer_id = id
	arena.add_child(avatar)
	avatar.set_player_name(name_of(id))
	_avatars[id] = avatar
	return avatar


func _drop_avatar(id: int) -> void:
	var avatar: Node3D = _avatars.get(id)
	if avatar != null and is_instance_valid(avatar):
		avatar.queue_free()
	_avatars.erase(id)
	_heard_from.erase(id)
	_release_vehicles(id)


## Hands back anything a departing peer was driving. Somebody who closes the tab
## while sitting in the tank never gets to say they got out, and without this the
## hull would sit there for the rest of the match belonging to nobody, following
## a client that is not going to send anything ever again.
func _release_vehicles(id: int) -> void:
	for node in get_tree().get_nodes_in_group(Tank.VEHICLES):
		if node.has_method("set_net_driver") and node.get("net_driver") == id:
			node.set_net_driver(0)


## The container avatars hang off, made once per world scene. Anchored to the
## current scene rather than to this autoload so changing scene takes the bodies
## with it -- they belong to a match, not to the connection.
func _players_root() -> Node3D:
	if _arena != null and is_instance_valid(_arena):
		return _arena
	var scene := get_tree().current_scene
	if scene == null or scene.get_node_or_null("VoxelWorld") == null:
		# Still on the menu: nowhere to stand a soldier up.
		return null
	_avatars.clear()
	_arena = Node3D.new()
	_arena.name = "Players"
	scene.add_child(_arena)
	# A snapshot that arrived while the menu was up goes in now.
	_apply_pending_world.call_deferred()
	return _arena


func _world() -> Node:
	return get_tree().get_first_node_in_group("voxel_world")


func _spawn_ghost(kind: int, at: Vector3, velocity: Vector3, fuse: float) -> void:
	if kind < 0 or kind >= PROJECTILES.size():
		return
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var ghost: Node3D = PROJECTILES[kind].instantiate()
	# Both set before it enters the tree, so its own _ready sees them.
	ghost.set("net_ghost", true)
	ghost.set("fuse_time", fuse)
	scene_root.add_child(ghost)
	ghost.global_position = at
	if ghost is RigidBody3D:
		(ghost as RigidBody3D).linear_velocity = velocity


# --- connection bookkeeping --------------------------------------------

func _on_connected() -> void:
	mode = CLIENT
	last_error = ""
	_verified = false
	_handshake_due = HANDSHAKE_SECONDS
	print("Net: connected as peer %d" % multiplayer.get_unique_id())
	_hello.rpc_id(1, _own_name(), map_id)
	status_changed.emit()


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	mode = OFFLINE
	last_error = "no server"
	status_changed.emit()


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	mode = OFFLINE
	last_error = "server went away"
	for id: int in _avatars.keys():
		_drop_avatar(id)
	roster.clear()
	roster_changed.emit()
	status_changed.emit()


## The server says which version it is, unasked, the moment somebody arrives.
## Unasked because a client cannot ask a server too old to answer.
func _on_peer_connected(id: int) -> void:
	if mode == SERVER:
		_server_hello.rpc_id(id, protocol())


@rpc("authority", "reliable", "call_remote")
func _server_hello(theirs: int) -> void:
	var ours := protocol()
	if theirs != ours:
		# Which half moved is the whole of the diagnosis: the same base with a
		# different fingerprint means somebody edited the catalogue and rebuilt
		# only one end, which is much the commoner mistake.
		@warning_ignore("integer_division")
		var same_base: bool = theirs / 1000000 == ours / 1000000
		_refuse("server speaks %s, this build %s%s" % [
			protocol_text(theirs), protocol_text(ours),
			" -- same protocol, different weapon catalogue" if same_base else "",
		])
		return
	_verified = true


## Gives up on a server this build cannot talk to properly. Refusing outright is
## the whole point: half-understanding each other is what produces a match that
## looks fine and disagrees about everything.
func _refuse(reason: String) -> void:
	push_error("Net: refusing to play -- %s" % reason)
	print("Net: refusing to play -- %s" % reason)
	multiplayer.multiplayer_peer = null
	mode = OFFLINE
	last_error = reason
	roster.clear()
	for id: int in _avatars.keys():
		_drop_avatar(id)
	roster_changed.emit()
	status_changed.emit()


func _on_peer_disconnected(id: int) -> void:
	if mode == SERVER:
		roster.erase(id)
		_roster_update.rpc(roster)
		roster_changed.emit()
		print("Net: peer %d left" % id)
		return
	_drop_avatar(id)


## Everything the server knows about the terrain, flattened for the wire.
func _server_snapshot() -> Array:
	if _server_world == null or not is_instance_valid(_server_world):
		return [PackedInt64Array(), PackedFloat32Array(), PackedInt64Array(), PackedByteArray()]
	var state: Dictionary = _server_world.net_snapshot()
	return [
		state["damage_indices"], state["damage_amounts"],
		state["place_indices"], state["place_types"],
	]


## Called by the headless server scene once its copy of the terrain is loaded.
func set_server_world(world: Node) -> void:
	_server_world = world


# --- command line -------------------------------------------------------

func _wants_server() -> bool:
	return "--server" in OS.get_cmdline_args() or "--server" in OS.get_cmdline_user_args()


func _argument(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for i in args.size():
		var arg: String = args[i]
		if arg.begins_with(flag + "="):
			return arg.substr(flag.length() + 1)
		if arg == flag and i + 1 < args.size():
			return args[i + 1]
	return fallback


func _argument_int(flag: String, fallback: int) -> int:
	var raw := _argument(flag, "")
	return int(raw) if raw.is_valid_int() else fallback
