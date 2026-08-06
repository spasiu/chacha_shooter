class_name Bot
extends CharacterBody3D

## An enemy soldier for when there is nobody else on the field.
##
## Bots exist to keep a map from being an empty field when you are the only one
## on it, and they are deliberately simple: they walk toward you, they take cover
## behind nothing, and they shoot when they can see you. What they are not is a
## simulation of a person. Anything cleverer would need a navigation mesh, and
## the ground here is destructible voxels -- a mesh baked at load would be wrong
## the first time somebody blew a hole in a wall.
##
## What they do have is the things that make an opponent feel like one:
##
##   they have to see you        a raycast from eye to chest, so a wall works
##   they are not instant        a reaction delay before the first shot, and a
##                               fresh one every time they lose sight of you
##   they miss                   accuracy falls off with range and with your
##                               speed, so moving is worth something
##   they can be flanked         they only know where you were when last seen
##
## They are entirely local. Nothing about a bot goes over the wire, because bots
## only exist when nobody else is on your field -- see BotCommand, which is what
## puts them out and takes them away again.

signal died

## Metres a bot can see and shoot. Well short of a rifle's real reach: a bot
## that engaged at two hundred metres would be shooting at you from somewhere
## you cannot pick it out of the scenery.
@export var sight_range := 55.0
## Metres it tries to close to before it stops advancing.
@export var stand_off := 14.0
@export var walk_speed := 4.6
@export var acceleration := 9.0
@export var gravity := 24.0
## Height that can be walked up without jumping, matching the player's.
@export var step_height := 0.28

@export_group("Fighting")
@export var max_health := 100.0
## Seconds between shots.
@export var fire_interval := 0.55
## Seconds after first seeing you before it fires. The single number that most
## decides whether a bot feels fair or feels like a turret.
@export var reaction := 0.55
## Damage bands out of 100, on the small-arms curve.
@export var damage_bands := [42.0, 26.0, 14.0, 7.0]
## Chance to hit a stationary target at point-blank, falling off with range.
@export var accuracy_near := 0.82
@export var accuracy_far := 0.24
## How much of that a sprinting target takes away.
@export var accuracy_vs_moving := 0.35
## Seconds it keeps walking to where it last saw you before giving up.
@export var memory := 6.0
## Seconds face-down before the body is cleared away.
@export var linger := 7.0

const GUNSHOT: AudioStream = preload("res://assets/audio/gunshot.wav")
const HIT_FLESH: AudioStream = preload("res://assets/audio/hit_flesh.wav")
const HIT_HEAD: AudioStream = preload("res://assets/audio/hit_head.wav")

## Matching TargetCharacter and RemotePlayer, so a head is a head wherever you
## shoot it.
const HEADSHOT_MULTIPLIER := 2.5
const HEAD_HEIGHT := 1.32

## How often the world is re-examined, in seconds. Four times a second is faster
## than anybody can cross a doorway and a fraction of the cost of doing it every
## frame for a dozen of them.
const LOOK_INTERVAL := 0.25

## Below this it has fallen out of the world rather than off something.
const VOID_DEPTH := -14.0

## Every bot on the field, so one can find the others without BotCommand having
## to tell each of them who else exists.
const BOTS := &"bots"

## Seconds between asking whether there is something better to be fighting.
## Slower than looking, because who you are fighting should not change every
## time somebody steps behind a tree.
const RETARGET_INTERVAL := 1.5

## How far behind the man it is escorting a bot is happy to be, and how far it
## will chase a fight from him before coming back. Without the second one a
## section strings out across the map one man at a time.
const ESCORT_SLACK := 7.0
const ESCORT_LEASH := 34.0

@onready var model: CharacterModel = $Model
@onready var label: Label3D = $NameTag
@onready var sound: AudioStreamPlayer3D = $Sound

## Who it is fighting. Chosen by the bot itself from whoever is on the other
## side; BotCommand only supplies the first one, to save a frame's hunting.
var target: Node3D
## Which side it is on, for its uniform and for who it shoots at.
var team := "red"
## Who it is looking after, if anybody. A bot with nothing to fight walks back
## to this man rather than standing where it last killed something, which is
## what makes a section feel like it is with you rather than merely nearby.
var escort: Node3D

var health := 0.0
var _down := false
var _seen := false
var _last_seen := Vector3.ZERO
var _seen_ago := 999.0
var _look_due := 0.0
var _aim_pitch := 0.0
var _fire_due := 0.0
var _settling := 0.0
var _gait := 0.0
## A sidestep, picked when it bumps into something and held for a moment so it
## walks around the obstacle rather than jittering against it.
var _slide := Vector3.ZERO
var _slide_for := 0.0
var _retarget_due := 0.0


func _ready() -> void:
	add_to_group(Lethality.DAMAGEABLE)
	add_to_group(BOTS)
	health = max_health
	# Staggered, so a section mustered on one frame does not all sweep the field
	# for a target on the same one for the rest of the match.
	_retarget_due = randf() * RETARGET_INTERVAL
	# Every soldier wears the same green, so the tag is the only thing saying
	# which of them this is.
	label.text = "%s SOLDIER" % team.to_upper()
	label.modulate = Net.team_colour(team).lightened(0.5)


func _physics_process(delta: float) -> void:
	if global_position.y < VOID_DEPTH:
		queue_free()
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	if _down:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	# Losing whoever it was fighting is re-asked at once rather than waited on:
	# standing about looking at a corpse is the one thing that reads as broken.
	_retarget_due -= delta
	if _retarget_due <= 0.0 or not _has_target():
		_retarget_due = RETARGET_INTERVAL
		_retarget()

	_look_due -= delta
	if _look_due <= 0.0:
		_look_due = LOOK_INTERVAL
		_look()
	_seen_ago += delta

	var wanted := _wanted_move(delta)
	velocity.x = move_toward(velocity.x, wanted.x, acceleration * delta * 10.0)
	velocity.z = move_toward(velocity.z, wanted.z, acceleration * delta * 10.0)

	var before := global_position
	move_and_slide()
	# Voxel ground is a staircase of quarter-metre blocks. Without this a bot
	# stops dead at every kerb, which is most of what makes one look broken.
	var travelled := global_position.distance_to(before)
	if travelled < walk_speed * delta * 0.4 and wanted.length() > 0.1:
		var step := Vector3(wanted.x, 0.0, wanted.z).normalized() * 0.4
		if not _try_step_up(step):
			_slide_for = 0.9
			_slide = Vector3(-wanted.z, 0.0, wanted.x).normalized()
			if randf() < 0.5:
				_slide = -_slide
	_slide_for = maxf(_slide_for - delta, 0.0)

	_animate(delta)
	_shoot(delta)


## Lifts the body a step, tries the move across, then drops it back down. Bails
## out unless all three succeed, which is what stops a bot climbing a wall a
## quarter of a metre at a time. The player does the same thing for the same
## reason -- see `Player._try_step_up`.
func _try_step_up(motion: Vector3) -> bool:
	var lift := Vector3.UP * step_height
	var start := global_transform
	if test_move(start, lift):
		return false
	var raised := start.translated(lift)
	if test_move(raised, motion):
		return false
	var across := raised.translated(motion)
	var landing := KinematicCollision3D.new()
	if not test_move(across, Vector3.DOWN * (step_height + 0.02), landing):
		# Nothing underneath: that was a gap, not a step.
		return false
	global_position = across.origin + landing.get_travel()
	return true


## Where it wants to go this frame. Toward you while it has not closed to its
## stand-off distance, toward where it last saw you for a while after that, and
## nowhere at all once it has forgotten.
func _wanted_move(_delta: float) -> Vector3:
	# Nothing to fight: fall in on whoever it is with. A bot without an escort
	# either has no orders at all or is a man walking at you, and both of those
	# are better standing still than wandering.
	if not _has_target():
		return _escort_move()
	# On a leash. Chasing a fight the length of the map is how a section that
	# was covering you ends up somewhere else entirely, so past this it breaks
	# off and comes back.
	if escort != null and is_instance_valid(escort) \
			and global_position.distance_to(escort.global_position) > ESCORT_LEASH \
			and not _seen:
		return _escort_move()

	# Three reasons to be walking somewhere, in order of how much it knows:
	# it can see you, it saw you a moment ago, or it is simply coming to find
	# you. The last one is what stops five men standing in their own base for
	# the whole match waiting to be shot at.
	var hunting := false
	var to_target := Vector3.ZERO
	if _seen:
		to_target = target.global_position - global_position
	elif _seen_ago < memory:
		to_target = _last_seen - global_position
	else:
		to_target = target.global_position - global_position
		hunting = true

	to_target.y = 0.0
	var away := to_target.length()
	if away < 0.5:
		return Vector3.ZERO
	# Close enough: stand and fight rather than walking into your muzzle.
	if _seen and away < stand_off:
		return _slide * walk_speed * 0.5 if _slide_for > 0.0 else Vector3.ZERO
	var heading := to_target / away
	if _slide_for > 0.0:
		heading = (heading + _slide * 1.4).normalized()
	# Coming to find you is a walk, not a charge.
	return heading * walk_speed * (0.72 if hunting else 1.0)


## Which side this bot is on, asked the same way of anything it might fight.
func team_name() -> String:
	return team


## Whether what it is fighting is still worth fighting.
func _has_target() -> bool:
	return (
		target != null
		and is_instance_valid(target)
		and not (target.has_method("is_dead") and target.is_dead())
	)


## Anything on the other side that is still standing. The player answers through
## Blast.VIEWERS, which holds exactly one node -- the local soldier -- because a
## camera shake belongs to whoever is looking and only one person ever is.
func _hostiles() -> Array[Node3D]:
	var found: Array[Node3D] = []
	for other: Node in get_tree().get_nodes_in_group(BOTS):
		var bot := other as Bot
		if bot != null and bot != self and bot.team != team and not bot.is_dead():
			found.append(bot)
	for who: Node in get_tree().get_nodes_in_group(Blast.VIEWERS):
		var body := who as Node3D
		if body == null or Net.my_team() == team:
			continue
		if body.has_method("is_dead") and body.is_dead():
			continue
		found.append(body)
	return found


## Picks something to fight: whoever on the other side it can actually see, and
## failing that whoever is nearest to go and look for. Sight wins over distance
## on purpose -- a man forty metres off across open ground is a better thing to
## be dealing with than one twenty metres away through a hill.
func _retarget() -> void:
	if _down:
		return
	var best: Node3D = null
	var best_score := INF
	for who: Node3D in _hostiles():
		var away := global_position.distance_to(who.global_position)
		if away > sight_range * 2.5:
			continue
		# Anything it cannot see is worth going to find, but only once there is
		# nothing in front of it: the penalty is bigger than the whole range.
		var score := away + (0.0 if _can_see(who) else sight_range * 4.0)
		if score < best_score:
			best_score = score
			best = who
	if best != null and best != target:
		target = best
		# A new man is a fresh sight picture, not a continuation of the old one.
		_seen = false
		_settling = reaction


## One ray, eye to chest. Shared by the target hunt and the look below, so a bot
## never picks somebody it would then decide it cannot see.
func _can_see(who: Node3D) -> bool:
	var eye := global_position + Vector3.UP * 1.5
	var chest := who.global_position + Vector3.UP * 1.1
	if eye.distance_to(chest) > sight_range:
		return false
	var query := PhysicsRayQueryParameters3D.create(eye, chest)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.get("collider") == who


## Back to the man being escorted, stopping a little short of him so a section
## spreads out around him rather than treading on his heels.
func _escort_move() -> Vector3:
	if escort == null or not is_instance_valid(escort):
		return Vector3.ZERO
	var to_him := escort.global_position - global_position
	to_him.y = 0.0
	var away := to_him.length()
	if away < ESCORT_SLACK:
		return _slide * walk_speed * 0.5 if _slide_for > 0.0 else Vector3.ZERO
	var heading := to_him / away
	if _slide_for > 0.0:
		heading = (heading + _slide * 1.4).normalized()
	# Hurrying only when actually left behind; otherwise it is a walk.
	return heading * walk_speed * (1.0 if away > ESCORT_LEASH * 0.5 else 0.8)


## Can it see you, and if so where are you. One ray, eye to chest, hitting
## anything solid on the way -- which is what makes a wall a wall to a bot.
func _look() -> void:
	var was := _seen
	_seen = false
	if _down or not _has_target():
		return
	if not _can_see(target):
		return
	_seen = true
	_seen_ago = 0.0
	_last_seen = target.global_position
	# Fresh eyes take a moment. Losing sight and finding you again costs the
	# reaction time over, which is what makes breaking line of sight useful.
	if not was:
		_settling = reaction


func _animate(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	_gait += delta * speed * 1.9
	model.set_gait(_gait, clampf(speed / walk_speed, 0.0, 1.0), is_on_floor(), 0.0, delta)

	# Face whatever it is dealing with: you, or where it is walking.
	var facing := Vector3.ZERO
	if _seen and target != null and is_instance_valid(target):
		facing = target.global_position - global_position
	elif Vector2(velocity.x, velocity.z).length() > 0.2:
		facing = Vector3(velocity.x, 0.0, velocity.z)
	if facing.length_squared() > 0.01:
		# Negated, because a Node3D's front is -Z: at a yaw of theta the front
		# points at (-sin theta, -cos theta), so facing a direction means
		# solving for its negative. Without the signs a bot walks and shoots
		# backwards -- which it will still do accurately, since the shot is a
		# roll against the target rather than a ray out of the muzzle.
		var want := atan2(-facing.x, -facing.z)
		rotation.y = lerp_angle(rotation.y, want, minf(delta * 7.0, 1.0))

	if _seen and target != null and is_instance_valid(target):
		var to_you: Vector3 = target.global_position + Vector3.UP * 1.1 \
			- (global_position + Vector3.UP * 1.5)
		var flat := Vector2(to_you.x, to_you.z).length()
		_aim_pitch = -atan2(to_you.y, maxf(flat, 0.01))
	model.spine_pitch = lerpf(model.spine_pitch, _aim_pitch * 0.6, minf(delta * 8.0, 1.0))
	label.position.y = 2.05


func _shoot(delta: float) -> void:
	_settling = maxf(_settling - delta, 0.0)
	_fire_due = maxf(_fire_due - delta, 0.0)
	if not _seen or _settling > 0.0 or _fire_due > 0.0:
		return
	if target == null or not is_instance_valid(target):
		return

	_fire_due = fire_interval * randf_range(0.85, 1.3)
	if model.weapon_socket.get_child_count() > 0:
		var gun: Node = model.weapon_socket.get_child(0)
		if gun.has_method("show_muzzle_flash"):
			gun.show_muzzle_flash()
	sound.stream = GUNSHOT
	sound.pitch_scale = randf_range(0.93, 1.07)
	sound.play()

	# Whether it lands is a roll rather than a ray. A bot that traced its shot
	# properly would hit every time from cover it can see out of, and being shot
	# by something you cannot see is not made better by it being accurate.
	var away := global_position.distance_to(target.global_position)
	var reach := clampf(away / sight_range, 0.0, 1.0)
	var chance := lerpf(accuracy_near, accuracy_far, reach)
	var moving := 0.0
	if target is CharacterBody3D:
		moving = clampf(Vector2(target.velocity.x, target.velocity.z).length() / 8.0,
						0.0, 1.0)
	chance *= 1.0 - accuracy_vs_moving * moving
	if randf() > chance:
		return
	# It picks its targets off the other side already, but the check belongs at
	# the moment damage is dealt rather than at the moment one is chosen: a bot
	# holding a target across a side switch would otherwise shoot a friend.
	if Lethality.friendly(team, target):
		return
	var hurt := Lethality.at_range(away, damage_bands)
	# Pointing back at the shooter, which is what weapon.gd and the vehicles all
	# report and what anything reading the direction has to be able to assume.
	# This used to hand over the direction of travel instead -- the opposite --
	# and nothing noticed until something needed to know which side it arrived on.
	target.take_damage(
		hurt, target.global_position + Vector3.UP * 1.1,
		(global_position - target.global_position).normalized(), Lethality.BULLET
	)


## Same signature as everything else that can be shot.
func take_damage(
	amount: float,
	hit_position: Vector3,
	from_shooter: Vector3,
	_kind: StringName = Lethality.BLAST
) -> void:
	if _down:
		return
	var headshot := hit_position.y - global_position.y > HEAD_HEIGHT
	if headshot:
		amount *= HEADSHOT_MULTIPLIER
	sound.stream = HIT_HEAD if headshot else HIT_FLESH
	sound.pitch_scale = randf_range(0.94, 1.08)
	sound.play()

	var from_behind := from_shooter.dot(-global_basis.z) < 0.0
	health = maxf(health - amount, 0.0)
	if health <= 0.0:
		_die(from_behind)
		return
	model.flinch(clampf(amount / 25.0, 0.3, 1.4), from_behind)
	# Being shot at from somewhere it was not looking is how a bot finds you.
	if not _seen:
		_last_seen = global_position - from_shooter * 12.0
		_seen_ago = 0.0


func _die(from_behind: bool) -> void:
	_down = true
	_seen = false
	model.die(from_behind)
	$CollisionShape3D.set_deferred("disabled", true)
	label.visible = false
	# One off his side's roll, the same as any other man lost. BotCommand will
	# put another out in a few seconds, and that replacement is exactly what the
	# count is measuring.
	Net.report_bot_death(team)
	died.emit()
	await get_tree().create_timer(linger).timeout
	if is_instance_valid(self):
		queue_free()


func is_dead() -> bool:
	return _down


## A fresh round takes the bodies away; BotCommand puts out new ones.
func round_reset() -> void:
	if _down:
		queue_free()
