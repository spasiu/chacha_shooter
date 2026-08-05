extends CanvasLayer

@export var player_path: NodePath

@onready var ammo_label: Label = $Root/AmmoLabel
@onready var health_fill: ColorRect = $Root/HealthBack/HealthFill
@onready var health_label: Label = $Root/HealthLabel
@onready var death_overlay: ColorRect = $Root/DeathOverlay
@onready var death_hint: Label = $Root/DeathOverlay/DeathHint
@onready var name_label: Label = $Root/NameLabel
@onready var feed: VBoxContainer = $Root/Feed
@onready var roster: VBoxContainer = $Root/Roster
@onready var roster_title: Label = $Root/Roster/RosterTitle
@onready var loading: ColorRect = $Root/Loading
@onready var loading_fill: ColorRect = $Root/Loading/BarBack/BarFill
@onready var loading_percent: Label = $Root/Loading/LoadingPercent
@onready var tickets: Label = $Root/Tickets
@onready var reticule: Control = $Root/Reticule
@onready var round_over: ColorRect = $Root/RoundOver
@onready var round_title: Label = $Root/RoundOver/RoundTitle
@onready var round_sub: Label = $Root/RoundOver/RoundSub
@onready var blue_side: VBoxContainer = $Root/RoundOver/Columns/BlueSide
@onready var blue_head: Label = $Root/RoundOver/Columns/BlueSide/BlueHead
@onready var red_side: VBoxContainer = $Root/RoundOver/Columns/RedSide
@onready var red_head: Label = $Root/RoundOver/Columns/RedSide/RedHead

var _player: Node
var _world: Node
var _roster_due := 0.0


## Seconds for the death overlay to fade in.
const DEATH_FADE := 0.6
## How long a line in the kill feed stays up, and how many are kept at once.
const NOTICE_SECONDS := 6.0
const NOTICE_LIMIT := 5
## Seconds between roster rebuilds. Slow on purpose: it is a handful of labels
## rather than anything expensive, but nothing on it changes faster than people
## joining and leaving.
const ROSTER_INTERVAL := 0.5


func _ready() -> void:
	death_overlay.modulate.a = 0.0
	death_overlay.visible = false
	_world = get_tree().get_first_node_in_group("voxel_world")
	_update_loading()
	name_label.text = LoadoutConfig.player_name
	_player = get_node_or_null(player_path)
	if _player != null and _player.has_signal("health_changed"):
		_player.health_changed.connect(_on_player_health_changed)
		_on_player_health_changed(_player.health, _player.max_health)
	Net.notice.connect(_on_notice)
	Net.roster_changed.connect(_refresh_roster)
	Net.status_changed.connect(_refresh_roster)
	Net.round_changed.connect(_on_round_changed)
	_refresh_roster()
	_on_round_changed()


## The scoreboard, rebuilt only when the round actually changes. The countdown
## on it ticks every frame; the standings behind it are fixed at the moment the
## round ended and must not move while people are reading them.
func _on_round_changed() -> void:
	round_over.visible = Net.round_over
	if not Net.round_over:
		return
	var held := Net.RED if Net.round_loser == Net.BLUE else Net.BLUE
	round_title.text = "%s HOLDS THE FIELD" % held.to_upper()
	_fill_side(blue_side, blue_head, Net.BLUE)
	_fill_side(red_side, red_head, Net.RED)


## One team's column: a heading with what it had left, then everyone on it,
## heaviest scorer first.
func _fill_side(column: VBoxContainer, head: Label, side: String) -> void:
	for child in column.get_children():
		if child != head:
			column.remove_child(child)
			child.queue_free()

	var members: Array = []
	for id: int in Net.round_standings:
		var entry: Dictionary = Net.round_standings[id]
		if entry.get("team", Net.BLUE) == side:
			members.append([id, entry])
	members.sort_custom(func(a, b): return int(a[1].get("kills", 0)) > int(b[1].get("kills", 0)))

	head.text = "%s   %d LEFT" % [side.to_upper(), Net.tickets(side)]
	if members.is_empty():
		column.add_child(_score_row("nobody", "", Color(0.5, 0.52, 0.49)))
		return
	column.add_child(_score_row("", "KILLS   DEATHS", Color(0.52, 0.54, 0.5)))
	var me := Net.local_id()
	for pair in members:
		var entry: Dictionary = pair[1]
		column.add_child(_score_row(
			String(entry.get("name", "SOLDIER")),
			"%5d   %6d" % [int(entry.get("kills", 0)), int(entry.get("deaths", 0))],
			Color(1, 1, 1) if pair[0] == me else Color(0.72, 0.74, 0.7)))


func _score_row(who: String, figures: String, colour: Color) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := Label.new()
	name_label.text = who
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 17)
	name_label.add_theme_color_override("font_color", colour)
	var figure_label := Label.new()
	figure_label.text = figures
	figure_label.add_theme_font_size_override("font_size", 17)
	figure_label.add_theme_color_override("font_color", colour)
	row.add_child(name_label)
	row.add_child(figure_label)
	return row


## The aim marker, for whatever is in hand that wants one. Hidden whenever the
## player is not in a position to use it, so it never sits on top of the death
## screen or the scoreboard.
func _update_reticule() -> void:
	var held: Equipment = _player.weapon if _player != null else null
	var size: float = held.reticule_size() if held != null else -1.0
	var usable: bool = (
		_player != null and not _player.is_dead() and _player.is_ready_to_play()
		and not Net.round_over and _player.riding() == null
	)
	reticule.visible = size > 0.0 and usable
	if reticule.visible:
		reticule.scale = Vector2.ONE * size


## The running count, and the countdown while the scoreboard is up.
func _update_round() -> void:
	# Shown alone as well as in company: with bots on the field the count moves
	# whether or not anybody else is connected, and a number that is being kept
	# but not shown is worse than one nobody keeps.
	tickets.visible = not Net.round_over
	if tickets.visible:
		# Whoever is nearer the end is the urgent number, so both are always
		# shown and the reading is left to the player rather than to a colour.
		tickets.text = "BLUE %d      RED %d" % [
			Net.tickets(Net.BLUE), Net.tickets(Net.RED)
		]
	if Net.round_over:
		round_sub.text = "next round in %d" % ceili(Net.intermission_left())


## Rebuilds the list of who is here. Driven by the roster rather than by the
## avatars standing about, so somebody on the far side of the map counts the
## same as somebody in front of you -- which is the whole point of showing it.
func _refresh_roster() -> void:
	roster.visible = Net.active()
	if not roster.visible:
		return
	# Taken out of the tree here and freed later, rather than only queued: two
	# roster changes can land in one frame, and a queued node is still a child
	# until the frame ends, so the second pass would count and re-list rows that
	# are already on their way out.
	for child in roster.get_children():
		if child != roster_title:
			roster.remove_child(child)
			child.queue_free()

	var me := Net.local_id()
	for id: int in Net.roster:
		var entry: Dictionary = Net.roster[id]
		var line := Label.new()
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_theme_font_size_override("font_size", 15)
		# Us in white, everyone else dimmer, so the list reads at a glance.
		line.add_theme_color_override(
			"font_color",
			Color(0.94, 0.94, 0.9) if id == me else Color(0.66, 0.68, 0.63)
		)
		line.text = "%s   %d / %d" % [
			Net.name_of(id), int(entry.get("kills", 0)), int(entry.get("deaths", 0))
		]
		# Connected but not playing. Saying so outright is the whole point: a
		# name on this list with nobody to be found anywhere in the world is the
		# single most confusing thing multiplayer can show you, and this is
		# almost always the reason for it.
		if not Net.is_awake(id):
			line.text += "   asleep"
			line.add_theme_color_override("font_color", Color(0.55, 0.5, 0.4))
		roster.add_child(line)


## One line in the kill feed. Nothing here is stored: the label is the record,
## and it takes itself away when it has been up long enough.
func _on_notice(text: String) -> void:
	var line := Label.new()
	line.text = text
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_theme_font_size_override("font_size", 16)
	line.add_theme_color_override("font_color", Color(0.86, 0.84, 0.78))
	feed.add_child(line)

	# Oldest out of the top once the column is full, so a firefight does not
	# push the feed off the screen.
	while feed.get_child_count() > NOTICE_LIMIT:
		feed.get_child(0).queue_free()

	var fade := line.create_tween()
	fade.tween_interval(NOTICE_SECONDS)
	fade.tween_property(line, "modulate:a", 0.0, 0.8)
	fade.tween_callback(line.queue_free)


func _process(delta: float) -> void:
	_update_loading()
	_update_round()
	_update_reticule()
	_update_death_overlay(delta)

	# Rebuilt on a slow tick as well as on joins and leaves, because whether
	# somebody is awake is not an event anyone sends -- it is worked out from
	# them having gone quiet, and so it can only be noticed by looking.
	_roster_due -= delta
	if _roster_due <= 0.0:
		_roster_due = ROSTER_INTERVAL
		_refresh_roster()

	# Polled rather than signal-driven: the player can swap what they are
	# holding at any time, and polling follows that for free.
	# Aboard a vehicle the readout belongs to the vehicle, not to whatever is
	# slung on the player's back.
	var vehicle: Node3D = _player.riding() if _player != null else null
	if vehicle != null and vehicle.has_method("status_text"):
		ammo_label.text = vehicle.status_text()
		ammo_label.modulate = Color(1.0, 0.35, 0.3) if vehicle.is_empty() else Color.WHITE
		return

	var held: Equipment = _player.weapon if _player != null else null
	if held == null:
		return
	ammo_label.text = held.status_text()
	# A jump jet is worn rather than held, so it has no turn at this readout of
	# its own -- it goes on a line under whatever is in the hands, for as long
	# as it is being worn.
	var pack: JumpJet = _player.jet()
	if pack != null:
		ammo_label.text += "\n" + pack.status_text()
	ammo_label.modulate = Color(1.0, 0.35, 0.3) if held.is_empty() else Color.WHITE


## The wait while the map is built, if there is one. Polled rather than driven
## by the world's signal because this has to be right on the very first frame
## too, before anything has had a chance to be emitted.
func _update_loading() -> void:
	# Driven by whether the player can actually act, not by whether the map is
	# finished. Those were the same thing when the whole map was built up front;
	# with streaming they are not, and the gap between them is a second or two of
	# standing on ground that has not been built yet.
	var waiting: bool = _player != null and not _player.is_ready_to_play()
	if not waiting:
		if loading.visible:
			loading.visible = false
			# The mouse was let go while the screen was up; take it back so the
			# match starts with the player looking around rather than clicking.
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	loading.visible = true
	# A prebuild knows how far along it is and can say so. Streaming has no total
	# to count against -- it is building what this player can see and no more --
	# so it gets the message without the arithmetic.
	var building: bool = _world != null and not _world.is_terrain_ready()
	var done: float = _world.terrain_progress() if building else 0.0
	loading_fill.anchor_right = done
	loading_percent.text = "%d%%" % roundi(done * 100.0) if building else ""


func _update_death_overlay(delta: float) -> void:
	var dead: bool = _player != null and _player.is_dead()
	var target := 1.0 if dead else 0.0
	death_overlay.modulate.a = move_toward(
		death_overlay.modulate.a, target, delta / DEATH_FADE
	)
	death_overlay.visible = death_overlay.modulate.a > 0.001
	if dead:
		_update_death_hint()


## How long is left face-down, and what there is to do meanwhile. Assigned every
## frame the overlay is up rather than on a tick, because a Label drops a write
## that does not change the string and the number only changes once a second.
func _update_death_hint() -> void:
	if death_hint == null or not _player.has_method("respawn_countdown"):
		return
	var left: float = _player.respawn_countdown()
	if left <= 0.0:
		death_hint.text = "respawning..."
		return
	death_hint.text = "BACK IN %d      FIRE TO CHOOSE YOUR KIT" % ceili(left)


func _on_player_health_changed(current: float, maximum: float) -> void:
	var ratio := 0.0 if maximum <= 0.0 else clampf(current / maximum, 0.0, 1.0)
	health_fill.anchor_right = ratio
	health_label.text = "%d" % roundi(current)
	# Bleeds toward a hotter red as it empties.
	health_fill.color = Color(0.75, 0.24, 0.2).lerp(Color(0.9, 0.1, 0.08), 1.0 - ratio)
