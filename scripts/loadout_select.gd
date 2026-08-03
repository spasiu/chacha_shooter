extends Control

## Loadout screen. Presents everything in LoadoutConfig.ITEMS as a card and
## takes up to LoadoutConfig.SLOTS of them.
##
## Serves two jobs. As the game's entry point it loads the world itself once a
## selection is confirmed. Instanced over a running game -- which is how you
## re-kit on respawn -- it leaves the world alone and just emits `confirmed`,
## because the world is destructible and reloading it would undo the match.
##
## The cards are built here rather than in the scene because they are driven
## entirely by the catalogue: adding an item there adds a card without touching
## this file or the .tscn.

## Emitted when the player confirms a selection. LoadoutConfig.chosen is already
## up to date by the time this fires.
signal confirmed(picks: Array[StringName])

## True when this screen is the game's entry point, so deploying loads the world
## itself. A respawn overlay sets it false and listens for `confirmed` instead.
@export var loads_world := true

const WORLD := "res://scenes/world.tscn"
const CARD_SIZE := Vector2(250, 300)
## Cards give up size as the catalogue grows rather than running off the edge
## of the screen; below these they would stop being readable.
const CARD_MIN_WIDTH := 148.0
const CARD_MIN_HEIGHT := 150.0
## Past this many items one row no longer fits, so they wrap onto two.
const ONE_ROW_LIMIT := 6
## Roughly what the title, counter, button and hint take off the height.
const CHROME_HEIGHT := 300.0
## Below this a card has no room for its description and shows the stats alone.
const BLURB_HEIGHT := 236.0
## Inset from the card's edge to its text.
const CARD_PAD := 18.0

@onready var cards_box: GridContainer = $Root/Cards
@onready var counter: Label = $Root/Counter
@onready var deploy_button: Button = $Root/Deploy
@onready var hint: Label = $Root/Hint
@onready var subtitle: Label = $Root/Subtitle

## Picked keys, in pick order.
var _picked: Array[StringName] = []
## key -> the card Button presenting it.
var _cards: Dictionary = {}


func _ready() -> void:
	# The world captures the mouse on entry; the menu needs it back.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Start from the last confirmed picks, so backing out and coming in again
	# does not throw the selection away.
	for key: StringName in LoadoutConfig.chosen:
		if not LoadoutConfig.item(key).is_empty():
			_picked.append(key)

	var card_size := _card_size()
	for entry: Dictionary in LoadoutConfig.ITEMS:
		var card := _build_card(entry, card_size)
		cards_box.add_child(card)
		_cards[entry["key"]] = card

	subtitle.text = "Take up to %d into the field." % LoadoutConfig.SLOTS
	hint.text = "1-%d TOGGLE      ENTER DEPLOY" % LoadoutConfig.ITEMS.size()
	deploy_button.pressed.connect(_on_deploy)
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	# The number keys that pick slots in game pick items here.
	for i in LoadoutConfig.ITEMS.size():
		var action := "slot_%d" % (i + 1)
		if InputMap.has_action(action) and event.is_action_pressed(action):
			_toggle(LoadoutConfig.ITEMS[i]["key"])
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("ui_accept") and not deploy_button.disabled:
		_on_deploy()


## Adds a key to the picks, or removes it if it is already in. A full selection
## refuses further picks rather than silently dropping one the player chose.
func _toggle(key: StringName) -> void:
	if _picked.has(key):
		_picked.erase(key)
	elif _picked.size() < LoadoutConfig.SLOTS:
		_picked.append(key)
	_refresh()


func _refresh() -> void:
	var full := _picked.size() >= LoadoutConfig.SLOTS
	for key: StringName in _cards:
		var card: Button = _cards[key]
		var picked: bool = _picked.has(key)
		card.set_pressed_no_signal(picked)
		# Dim what can no longer be taken, so a full selection reads as full
		# rather than as an unresponsive card.
		card.modulate = Color(1, 1, 1, 0.45) if (full and not picked) else Color.WHITE
		var slot: Label = card.get_node("Content/Slot")
		slot.text = "SLOT %d" % (_picked.find(key) + 1) if picked else ""

	counter.text = "%d OF %d SELECTED" % [_picked.size(), LoadoutConfig.SLOTS]
	# Any non-empty selection will do. Requiring the full four would make this a
	# rubber stamp whenever the catalogue is no bigger than the slot count.
	deploy_button.disabled = _picked.is_empty()
	deploy_button.modulate = Color.WHITE if not deploy_button.disabled else Color(1, 1, 1, 0.4)


func _on_deploy() -> void:
	if _picked.is_empty():
		return
	LoadoutConfig.chosen = _picked.duplicate()
	if loads_world:
		get_tree().change_scene_to_file(WORLD)
	else:
		confirmed.emit(_picked.duplicate())


## Fits the catalogue to the screen: one row of cards while they still come out
## readable, two rows once they do not, each card taking an equal share of what
## is left over after the gaps.
func _card_size() -> Vector2:
	var count := maxi(LoadoutConfig.ITEMS.size(), 1)
	var gap: int = cards_box.get_theme_constant("h_separation")
	var rows := 1 if count <= ONE_ROW_LIMIT else 2
	var columns := ceili(float(count) / rows)
	cards_box.columns = columns

	# `size` is not laid out yet this early, so measure against the viewport and
	# allow for the margins the root container holds on either side.
	var view := get_viewport_rect().size
	var width := clampf(
		(view.x - 80.0 - gap * (columns - 1)) / columns, CARD_MIN_WIDTH, CARD_SIZE.x)
	var height := clampf(
		(view.y - CHROME_HEIGHT - gap * (rows - 1)) / rows, CARD_MIN_HEIGHT, CARD_SIZE.y)
	return Vector2(width, height)


func _build_card(entry: Dictionary, card_size: Vector2) -> Button:
	var accent: Color = entry["accent"]
	var scale := clampf(card_size.x / CARD_SIZE.x, 0.74, 1.0)

	var card := Button.new()
	card.toggle_mode = true
	card.custom_minimum_size = card_size
	card.focus_mode = Control.FOCUS_NONE
	card.add_theme_stylebox_override("normal", _card_style(accent, false, false))
	card.add_theme_stylebox_override("hover", _card_style(accent, false, true))
	card.add_theme_stylebox_override("pressed", _card_style(accent, true, false))
	card.add_theme_stylebox_override("hover_pressed", _card_style(accent, true, true))
	card.add_theme_stylebox_override("focus", _card_style(accent, false, false))
	card.add_theme_stylebox_override("disabled", _card_style(accent, false, false))
	card.pressed.connect(_toggle.bind(entry["key"]))

	var content := VBoxContainer.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = CARD_PAD
	content.offset_top = CARD_PAD
	content.offset_right = -CARD_PAD
	content.offset_bottom = -CARD_PAD
	content.add_theme_constant_override("separation", 6)
	card.add_child(content)

	var stripe := ColorRect.new()
	stripe.color = accent
	stripe.custom_minimum_size = Vector2(0, 3)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(stripe)

	content.add_child(_label(entry["kind"], roundi(12 * scale), accent))
	content.add_child(_label(entry["name"], roundi(21 * scale), Color(0.94, 0.94, 0.92)))

	# A short card has no room to describe itself and keeps to the numbers.
	if card_size.y >= BLURB_HEIGHT:
		var blurb := _label(entry["blurb"], roundi(13 * scale), Color(0.68, 0.69, 0.66))
		blurb.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.add_child(blurb)
	else:
		var filler := Control.new()
		filler.mouse_filter = Control.MOUSE_FILTER_IGNORE
		filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.add_child(filler)

	content.add_child(_label(entry["stats"], roundi(12 * scale), Color(0.55, 0.56, 0.53)))

	# Filled in by _refresh once the item is actually carried.
	var slot := _label("", roundi(13 * scale), accent)
	slot.name = "Slot"
	content.add_child(slot)

	return card


func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Every line wraps: cards get narrow when the catalogue is long, and a Label
	# will happily draw straight over the card next to it otherwise.
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label


func _card_style(accent: Color, picked: bool, hover: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	if picked:
		box.bg_color = Color(accent.r, accent.g, accent.b, 0.16)
		box.border_color = accent
		box.set_border_width_all(2)
	else:
		box.bg_color = Color(0.13, 0.14, 0.13) if hover else Color(0.105, 0.115, 0.105)
		box.border_color = Color(0.30, 0.32, 0.29) if hover else Color(0.20, 0.22, 0.20)
		box.set_border_width_all(1)
	box.set_corner_radius_all(3)
	return box
