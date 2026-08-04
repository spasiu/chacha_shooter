extends Control

## Map screen, and the game's entry point: pick the ground, then the kit.
##
## The cards are built from MapCatalogue rather than from the scene, so a map
## added to the generator and listed in the catalogue appears here without this
## file or the .tscn being touched.
##
## Choosing here does two things. It decides which terrain the world loads, and
## it decides who you are playing with: everybody on a map shares a field, and
## people on the other maps are not in it -- see `Net.map_id`.

const LOADOUT := "res://scenes/loadout_select.tscn"
const CARD_SIZE := Vector2(300, 250)
const CARD_MIN_WIDTH := 190.0
const CARD_PAD := 20.0

@onready var cards_box: HBoxContainer = $Root/Cards
@onready var subtitle: Label = $Root/Subtitle
@onready var status: Label = $Root/Status
@onready var next_button: Button = $Root/Next

## id -> the card Button presenting it.
var _cards := {}
var _picked := ""


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for id: String in MapCatalogue.IDS:
		_add_card(id)
	_choose(MapCatalogue.resolve(Net.map_id))
	next_button.pressed.connect(_on_next)
	Net.status_changed.connect(_refresh_status)
	Net.roster_changed.connect(_refresh_status)
	_refresh_status()
	get_viewport().size_changed.connect(_resize_cards)
	_resize_cards()


func _add_card(id: String) -> void:
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.toggle_mode = true
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(_choose.bind(id))
	cards_box.add_child(card)
	_cards[id] = card

	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.set_anchors_preset(Control.PRESET_FULL_RECT)
	text.offset_left = CARD_PAD
	text.offset_top = CARD_PAD
	text.offset_right = -CARD_PAD
	text.offset_bottom = -CARD_PAD
	text.add_theme_constant_override("separation", 10)
	card.add_child(text)

	var title := Label.new()
	title.text = MapCatalogue.title(id)
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.94, 0.93, 0.89))
	text.add_child(title)

	# What the ground is like, in the map's own words.
	var blurb := Label.new()
	blurb.text = MapCatalogue.blurb(id)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	blurb.add_theme_font_size_override("font_size", 15)
	blurb.add_theme_color_override("font_color", Color(0.7, 0.72, 0.68))
	text.add_child(blurb)

	# The three numbers that actually decide which one you want to play.
	var facts := Label.new()
	facts.text = "%dm ACROSS   ·   %d BASES   ·   %s" % [
		roundi(MapCatalogue.metres(id)),
		MapCatalogue.spawn_count(id),
		"NO ARMOUR" if MapCatalogue.tank_count(id) == 0
		else "%d TANKS" % MapCatalogue.tank_count(id),
	]
	facts.add_theme_font_size_override("font_size", 13)
	facts.add_theme_color_override("font_color", Color(0.55, 0.57, 0.53))
	text.add_child(facts)


## Cards share the row, so they shrink as the catalogue grows rather than
## running off the edge of the screen.
func _resize_cards() -> void:
	var across := get_viewport_rect().size.x - 80.0
	var each := maxf((across - 16.0 * (_cards.size() - 1)) / maxf(_cards.size(), 1),
					 CARD_MIN_WIDTH)
	for card: Button in _cards.values():
		card.custom_minimum_size = Vector2(each, CARD_SIZE.y)


func _choose(id: String) -> void:
	_picked = id
	Net.choose_map(id)
	for other: String in _cards:
		_cards[other].button_pressed = other == id
	subtitle.text = "%s  ·  %s" % [
		MapCatalogue.title(id), MapCatalogue.blurb(id)
	]
	_refresh_status()


## Who else is on this ground. Deliberately the count for the chosen map rather
## than for the server: the whole point of picking is that the other maps are
## somebody else's match.
func _refresh_status() -> void:
	var here := Net.player_count()
	if not Net.active():
		status.text = Net.status_text()
		return
	status.text = "%s  ·  %d ON %s" % [
		Net.status_text(), maxi(here, 1), MapCatalogue.title(_picked)
	]


func _on_next() -> void:
	get_tree().change_scene_to_file(LOADOUT)
