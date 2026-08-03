class_name ArmRig
extends Node3D

## A pair of two-bone arms that grip whatever weapon they are pointed at.
##
## The weapon exposes GripRight/GripLeft markers; the hands snap to those
## markers' transforms and the bones solve to follow. Nothing here knows what a
## Thompson is, so swapping in a different weapon needs no rig changes — only
## grip markers on the new weapon.

@export var weapon_path: NodePath

## Fallback grips used when no weapon is assigned, so a rig whose weapon has
## been taken away (e.g. the body's arms while the gun is on the first-person
## socket) holds a static carry pose instead of reaching off into space.
@export var idle_grip_right: NodePath
@export var idle_grip_left: NodePath

@export_group("Skeleton", "arm_")
## Shoulder anchors, in this rig's local space.
@export var arm_right_shoulder := Vector3(0.22, -0.3, 0.14)
@export var arm_left_shoulder := Vector3(-0.22, -0.3, 0.14)
## Bone lengths as (upper, forearm). The two sides differ because in first
## person the trigger hand sits close to the camera while the support hand is
## most of a weapon-length away.
@export var arm_right_lengths := Vector2(0.3, 0.26)
@export var arm_left_lengths := Vector2(0.46, 0.46)
## Direction the elbow is pushed toward when the arm bends.
@export var arm_right_pole := Vector3(0.8, -1.0, -0.2)
@export var arm_left_pole := Vector3(-0.8, -1.0, -0.2)

@onready var _bones := {
	"right_upper": $RightUpper,
	"right_fore": $RightFore,
	"right_hand": $RightHand,
	"left_upper": $LeftUpper,
	"left_fore": $LeftFore,
	"left_hand": $LeftHand,
}

var _weapon: Equipment
var _idle_right: Node3D
var _idle_left: Node3D


func _ready() -> void:
	_weapon = get_node_or_null(weapon_path) as Equipment
	_idle_right = get_node_or_null(idle_grip_right) as Node3D
	_idle_left = get_node_or_null(idle_grip_left) as Node3D


## Point the rig at a different weapon at runtime.
func set_weapon(weapon: Equipment) -> void:
	_weapon = weapon


func _process(_delta: float) -> void:
	# Note this deliberately does not test visibility: the body keeps posing
	# while invisible in first person, because it is still casting a shadow.
	var right_node: Node3D = _weapon.grip_right if _weapon != null else _idle_right
	var left_node: Node3D = _weapon.grip_left if _weapon != null else _idle_left
	if right_node == null or left_node == null:
		return

	var right_grip := right_node.global_transform
	var left_grip := left_node.global_transform
	# The left hand also carries the reload animation's offset; the right stays
	# put on the pistol grip throughout.
	if _weapon != null:
		left_grip = left_grip.translated_local(_weapon.left_hand_offset)

	_solve("right", right_grip, arm_right_shoulder, arm_right_pole, arm_right_lengths)
	_solve("left", left_grip, arm_left_shoulder, arm_left_pole, arm_left_lengths)


func _solve(
	side: String, grip: Transform3D, shoulder: Vector3, pole: Vector3, lengths: Vector2
) -> void:
	var hand: Node3D = _bones[side + "_hand"]
	hand.global_transform = grip

	var target := to_local(grip.origin)
	var elbow := _solve_elbow(shoulder, target, pole, lengths)
	_lay_bone(_bones[side + "_upper"], shoulder, elbow)
	_lay_bone(_bones[side + "_fore"], elbow, target)


## Two-bone IK. Returns the elbow position for a shoulder/hand pair, pushed
## toward `pole`. Overlong reaches straighten out rather than failing; the
## bones simply stretch, so the chain never visibly separates from the hand.
func _solve_elbow(
	shoulder: Vector3, target: Vector3, pole: Vector3, lengths: Vector2
) -> Vector3:
	var to_target := target - shoulder
	var dist := to_target.length()
	if is_zero_approx(dist):
		return shoulder + Vector3.DOWN * lengths.x

	var dir := to_target / dist
	var reach := lengths.x + lengths.y
	if dist >= reach:
		return shoulder + dir * lengths.x

	# Distance along the shoulder->target line to the elbow's projection.
	var along := (
		lengths.x * lengths.x - lengths.y * lengths.y + dist * dist
	) / (2.0 * dist)
	var height := sqrt(maxf(lengths.x * lengths.x - along * along, 0.0))

	# Component of the pole vector perpendicular to the arm line.
	var perp := pole - dir * pole.dot(dir)
	if perp.length_squared() < 0.0001:
		perp = dir.cross(Vector3.UP)
		if perp.length_squared() < 0.0001:
			perp = dir.cross(Vector3.RIGHT)
	return shoulder + dir * along + perp.normalized() * height


## Stretches a unit-height cylinder between two points in rig-local space.
func _lay_bone(bone: Node3D, from: Vector3, to: Vector3) -> void:
	var axis := to - from
	var length := axis.length()
	if is_zero_approx(length):
		return

	var y := axis / length
	var ref := Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT
	var x := y.cross(ref).normalized()
	var z := x.cross(y)
	bone.transform = Transform3D(Basis(x, y * length, z), (from + to) * 0.5)
