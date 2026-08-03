class_name CharacterModel
extends Node3D

## Placeholder soldier. Owns a procedural walk cycle and knows how to hold a
## weapon, but nothing about input — the player drives it, and the standalone
## mannequin in the world just leaves it idle.

## Instantiated into WeaponSocket on ready. Leave empty when something else
## supplies the weapon (the player hands over its own shared instance).
@export var weapon_scene: PackedScene

@export_group("Crouch")
## How far the pelvis drops at full crouch. The legs fold to match so the feet
## stay planted; anything past twice the leg-segment length is unreachable.
@export var crouch_drop := 0.35

@export_group("Reactions")
## Peak spine kick from a hit, in degrees.
@export var flinch_deg := 16.0
## How fast a flinch settles, per second.
@export var flinch_recover := 5.0
## Seconds for the body to go from upright to flat.
@export var death_time := 1.1
## How far past vertical the body ends up.
@export var death_angle_deg := 88.0

@export_group("Gait")
@export var hip_swing_deg := 32.0
@export var knee_bend_deg := 55.0
## Vertical torso bounce at full stride, in metres.
@export var torso_bob := 0.03
## How fast the legs catch up to the target pose, per second.
@export var gait_blend := 14.0

@onready var spine: Node3D = $Spine
@onready var arms: ArmRig = $Spine/Arms
@onready var weapon_socket: Node3D = $Spine/WeaponSocket
@onready var weapon_shadow_proxy: MeshInstance3D = $Spine/WeaponShadowProxy
@onready var _legs := {
	"left_hip": $LeftLeg,
	"left_knee": $LeftLeg/Knee,
	"right_hip": $RightLeg,
	"right_knee": $RightLeg/Knee,
}
@onready var _boots := [$LeftLeg/Knee/Boot, $RightLeg/Knee/Boot]

## Set by whoever is driving the torso (the player's aim pitch). Kept separate
## so a flinch can be layered on top rather than fighting it.
var spine_pitch := 0.0

var _spine_rest_y := 0.0
var _death_rest_y := 0.0
var _flinch := 0.0
var _death := 0.0
## +1 topples onto its back, -1 onto its face.
var _death_sign := 1.0
var _death_tween: Tween
var _hip_rest_y := 0.0
## Thigh and shin are the same length; the knee's offset from the hip is it.
var _segment := 0.315
var _pose := {"left_hip": 0.0, "left_knee": 0.0, "right_hip": 0.0, "right_knee": 0.0}


func _ready() -> void:
	_spine_rest_y = spine.position.y
	_death_rest_y = position.y
	_hip_rest_y = _legs["left_hip"].position.y
	_segment = absf(_legs["left_knee"].position.y)
	if weapon_scene != null:
		var weapon := weapon_scene.instantiate()
		weapon_socket.add_child(weapon)
		if weapon is Weapon:
			arms.set_weapon(weapon)


func _process(delta: float) -> void:
	_flinch = lerpf(_flinch, 0.0, minf(flinch_recover * delta, 1.0))
	# Spine carries aim pitch, hit flinch and the death slump at once.
	spine.rotation.x = spine_pitch + _flinch + _death * deg_to_rad(22.0) * -_death_sign
	# The body pivots about its feet, so rotating the root lays it on the floor.
	var fall := ease(_death, 0.35)
	rotation.x = _death_sign * deg_to_rad(death_angle_deg) * fall
	position.y = _death_rest_y + 0.12 * fall


## Kicks the torso away from an impact. `from_behind` flips which way it folds.
func flinch(strength: float, from_behind: bool) -> void:
	_flinch = deg_to_rad(flinch_deg) * strength * (-1.0 if from_behind else 1.0)


## Starts the collapse. Idempotent — a corpse cannot die twice.
func die(from_behind: bool) -> void:
	if _death > 0.0 or (_death_tween != null and _death_tween.is_valid()):
		return
	_death_sign = -1.0 if from_behind else 1.0
	_death_tween = create_tween()
	_death_tween.tween_property(self, "_death", 1.0, death_time) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)


func revive() -> void:
	if _death_tween != null and _death_tween.is_valid():
		_death_tween.kill()
	_death = 0.0
	_flinch = 0.0
	rotation.x = 0.0
	position.y = _death_rest_y


func is_dead() -> bool:
	return _death >= 1.0


## Drives the walk cycle. `phase` is continuous radians (one full gait cycle is
## two footfalls), `intensity` scales the swing with speed, and going airborne
## swaps in a tuck.
func set_gait(
	phase: float, intensity: float, on_floor: bool, crouch: float, delta: float
) -> void:
	var swing := deg_to_rad(hip_swing_deg) * intensity
	var bend := deg_to_rad(knee_bend_deg) * intensity

	# Fold the legs into a squat deep enough to drop the pelvis by `drop` while
	# the ankle stays put: ankle_y = hip_y - 2*segment*cos(theta).
	var drop := crouch_drop * crouch
	var span := 2.0 * _segment - drop
	var theta := acos(clampf(span / (2.0 * _segment), -1.0, 1.0))
	# Thigh forward by theta, shin back by twice that, so the foot stays under
	# the hip rather than swinging out in front.
	var hip_base := theta
	var knee_base := -2.0 * theta
	# Crouched strides are shorter as well as slower.
	swing *= 1.0 - 0.45 * crouch

	var target := {}
	if on_floor:
		target["left_hip"] = hip_base + sin(phase) * swing
		target["right_hip"] = hip_base + sin(phase + PI) * swing
		# The knee only folds while the leg is travelling backward.
		target["left_knee"] = knee_base - maxf(-sin(phase - 0.7), 0.0) * bend
		target["right_knee"] = knee_base - maxf(-sin(phase + PI - 0.7), 0.0) * bend
	else:
		target["left_hip"] = deg_to_rad(12.0)
		target["right_hip"] = deg_to_rad(-8.0)
		target["left_knee"] = deg_to_rad(-40.0)
		target["right_knee"] = deg_to_rad(-18.0)

	# A collapsing body buckles rather than walks.
	if _death > 0.0:
		var slump := 1.0 - _death
		for key: String in target:
			target[key] = lerpf(target[key], _collapse_angle(key), _death)
		swing *= slump

	var t := minf(gait_blend * delta, 1.0)
	for key: String in _pose:
		_pose[key] = lerpf(_pose[key], target[key], t)
		_legs[key].rotation.x = _pose[key]

	# Keep the soles flat by cancelling the accumulated thigh+shin rotation.
	_boots[0].rotation.x = -(_pose["left_hip"] + _pose["left_knee"])
	_boots[1].rotation.x = -(_pose["right_hip"] + _pose["right_knee"])

	# Pelvis and everything above it ride down with the crouch.
	_legs["left_hip"].position.y = _hip_rest_y - drop
	_legs["right_hip"].position.y = _hip_rest_y - drop

	# Torso bounces twice per gait cycle, once per footfall.
	var bob := sin(phase * 2.0) * torso_bob * intensity if on_floor else 0.0
	spine.position.y = _spine_rest_y - drop + bob


## Legs buckle under the body as it goes down.
func _collapse_angle(key: String) -> float:
	if key.ends_with("_knee"):
		return deg_to_rad(-62.0) if key.begins_with("left") else deg_to_rad(-48.0)
	return deg_to_rad(28.0) if key.begins_with("left") else deg_to_rad(18.0)


## First person hides the body but keeps its shadow, so the player sees their
## own silhouette without seeing themselves from the inside.
func set_shadow_only(enabled: bool) -> void:
	# Never hidden: invisible geometry casts no shadow, which is the whole point
	# of this mode. Visibility of individual meshes is the cast_shadow flag's job.
	visible = true
	var mode := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if enabled
		else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	)
	for mesh: MeshInstance3D in find_children("*", "MeshInstance3D", true):
		if mesh == weapon_shadow_proxy:
			continue
		mesh.cast_shadow = mode
	# Stands in for the real weapon's shadow while the real one is up at the
	# camera. Invisible geometry casts nothing, so visibility is the switch.
	weapon_shadow_proxy.visible = enabled
