extends CanvasLayer

## Crosshair gap in pixels when the weapon is fully settled.
@export var min_gap := 5.0
## Crosshair gap in pixels at full bloom.
@export var max_gap := 26.0
@export var arm_length := 9.0

@export var player_path: NodePath

@onready var ammo_label: Label = $Root/AmmoLabel
@onready var crosshair: Control = $Root/Crosshair
@onready var health_fill: ColorRect = $Root/HealthBack/HealthFill
@onready var health_label: Label = $Root/HealthLabel
@onready var death_overlay: ColorRect = $Root/DeathOverlay
@onready var _arms := {
	"top": $Root/Crosshair/Top,
	"bottom": $Root/Crosshair/Bottom,
	"left": $Root/Crosshair/Left,
	"right": $Root/Crosshair/Right,
}

var _player: Node


## Seconds for the death overlay to fade in.
const DEATH_FADE := 0.6


func _ready() -> void:
	death_overlay.modulate.a = 0.0
	death_overlay.visible = false
	_player = get_node_or_null(player_path)
	if _player != null and _player.has_signal("health_changed"):
		_player.health_changed.connect(_on_player_health_changed)
		_on_player_health_changed(_player.health, _player.max_health)



func _process(delta: float) -> void:
	_update_death_overlay(delta)

	# Polled rather than signal-driven: the player can swap what they are
	# holding at any time, and polling follows that for free.
	var held: Equipment = _player.weapon if _player != null else null
	if held == null:
		return
	_set_gap(lerpf(min_gap, max_gap, held.spread_ratio()))
	# The crosshair is redundant once you are looking through the irons.
	crosshair.modulate.a = 1.0 - held.aim_ratio()
	ammo_label.text = held.status_text()
	ammo_label.modulate = Color(1.0, 0.35, 0.3) if held.is_empty() else Color.WHITE


func _update_death_overlay(delta: float) -> void:
	var dead: bool = _player != null and _player.is_dead()
	var target := 1.0 if dead else 0.0
	death_overlay.modulate.a = move_toward(
		death_overlay.modulate.a, target, delta / DEATH_FADE
	)
	death_overlay.visible = death_overlay.modulate.a > 0.001


func _set_gap(gap: float) -> void:
	var far := gap + arm_length

	_arms["top"].offset_top = -far
	_arms["top"].offset_bottom = -gap
	_arms["bottom"].offset_top = gap
	_arms["bottom"].offset_bottom = far
	_arms["left"].offset_left = -far
	_arms["left"].offset_right = -gap
	_arms["right"].offset_left = gap
	_arms["right"].offset_right = far


func _on_player_health_changed(current: float, maximum: float) -> void:
	var ratio := 0.0 if maximum <= 0.0 else clampf(current / maximum, 0.0, 1.0)
	health_fill.anchor_right = ratio
	health_label.text = "%d" % roundi(current)
	# Bleeds toward a hotter red as it empties.
	health_fill.color = Color(0.75, 0.24, 0.2).lerp(Color(0.9, 0.1, 0.08), 1.0 - ratio)
