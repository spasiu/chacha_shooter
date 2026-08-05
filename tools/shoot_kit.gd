extends Node3D

## Renders a soldier wearing or holding a piece of kit, so what a thing looks
## like on a man can be looked at rather than imagined. Companion to
## shoot_guns.tscn, which does the same for what is in his hands.

const OUT := "user://shots"

func _ready() -> void:
	var out_dir: String = ProjectSettings.globalize_path(OUT)
	DirAccess.make_dir_recursive_absolute(out_dir)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_horizon_color = Color(0.646, 0.656, 0.671)
	sky_mat.ground_horizon_color = Color(0.646, 0.656, 0.671)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	var cam := Camera3D.new()
	cam.environment = env
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.5
	add_child(cam)
	# Three-quarter front, a little above the belt: the angle a soldier is
	# actually seen from across a field.
	cam.global_position = Vector3(1.7, 1.5, -2.5)
	cam.look_at(Vector3(0.0, 0.95, 0.0))

	var key := DirectionalLight3D.new()
	key.light_energy = 1.6
	add_child(key)
	key.rotation_degrees = Vector3(-38, 28, 0)

	for shot in [["plain", false, false, false],
			["armour", true, false, false],
			["shieldclub_down", false, true, false],
			["shieldclub_up", false, true, true]]:
		var man: CharacterModel = load("res://scenes/character_body.tscn").instantiate()
		add_child(man)
		await get_tree().process_frame
		if shot[1]:
			var plate: Node3D = load("res://scenes/weapon_body_armour.tscn").instantiate()
			man.get_node("Spine").add_child(plate)
			plate.position = Vector3(0.0, 0.2, 0.0)
			plate.visible = true
		if shot[2]:
			var kit: ShieldClub = load("res://scenes/weapon_shield_club.tscn").instantiate()
			man.weapon_socket.add_child(kit)
			kit.visible = true
			await get_tree().process_frame
			kit.set_aiming(shot[3])
			# The raise is tweened; let it finish before the shutter.
			for i in 30:
				await get_tree().process_frame
		for i in 3:
			await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		img.save_png("%s/soldier_%s.png" % [out_dir, shot[0]])
		print("wrote soldier_%s.png" % shot[0])
		man.queue_free()
		await get_tree().process_frame
	get_tree().quit()
