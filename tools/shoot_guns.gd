extends Node3D

## Renders each weapon in side elevation and writes it to a PNG, so the thing
## being built can actually be looked at instead of only measured.

## Written to the user data directory rather than anywhere in particular, so
## this leaves nothing behind and nothing machine-specific in the project.
const OUT := "user://shots"
const GUNS := ["garand", "thompson", "carbine", "m1911", "bar",
		"johnson", "shotgun", "bazooka"]

func _ready() -> void:
	var out_dir: String = ProjectSettings.globalize_path(OUT)
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("writing to ", out_dir)
	# A sky, because the game has one and metal with nothing to reflect renders
	# black. Judging blued steel against a flat colour background says the metal
	# is broken when what is broken is the picture of it.
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
	add_child(cam)

	var key := DirectionalLight3D.new()
	key.light_energy = 1.5
	add_child(key)
	key.rotation_degrees = Vector3(-35, 35, 0)

	for name in GUNS:
		var g: Node3D = load("res://scenes/weapon_%s.tscn" % name).instantiate()
		add_child(g)
		await get_tree().process_frame
		# Frame whatever it actually measures, seen from its right side.
		var b := AABB()
		var first := true
		for c in g.find_children("*", "MeshInstance3D", true, false):
			var m := c as MeshInstance3D
			var w: AABB = m.global_transform * m.get_aabb()
			b = w if first else b.merge(w)
			first = false
		var mid: Vector3 = b.position + b.size * 0.5
		# Fit whichever way the weapon is long. Framing a pistol by its length
		# runs it off the top of the frame; framing a rifle by its height makes it
		# a speck.
		var aspect: float = float(get_viewport().size.x) / float(get_viewport().size.y)
		cam.keep_aspect = Camera3D.KEEP_WIDTH
		cam.size = maxf(b.size.z, b.size.y * aspect) * 1.1
		cam.global_position = mid + Vector3(3.0, 0, 0)
		cam.look_at(mid)
		for i in 3:
			await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		img.save_png("%s/%s.png" % [out_dir, name])
		print("wrote %s.png  (%d x %d)" % [name, img.get_width(), img.get_height()])
		g.queue_free()
		await get_tree().process_frame
	get_tree().quit()
