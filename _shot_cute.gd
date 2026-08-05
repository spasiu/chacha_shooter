extends Node3D

const OUT := "/private/tmp/claude-501/-Users-anastasi-Documents-Claude-Projects-chacha-shooter/8c73e8d0-00db-4203-b02c-cc0f513efe48/scratchpad"
const SHOTS := [
	["full", Vector3(1.2, 1.0, -1.9), 0.8],
	["face", Vector3(0.3, 1.48, -0.62), 1.4],
	["pair", Vector3(0.0, 1.1, -2.6), 0.9],
]

func _ready() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.55, 0.66, 0.82)
	sky_mat.sky_horizon_color = Color(0.78, 0.80, 0.82)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.15
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 150, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	var grass := StandardMaterial3D.new()
	grass.albedo_color = Color(0.45, 0.58, 0.32)
	grass.roughness = 0.95
	plane.material = grass
	ground.mesh = plane
	add_child(ground)

	var scene: PackedScene = load("res://scenes/character_body.tscn")
	var a: Node3D = scene.instantiate()
	add_child(a)
	var b: Node3D = scene.instantiate()
	add_child(b)
	b.position = Vector3(0.9, 0, 0.35)
	b.rotation_degrees.y = -22.0

	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 55.0
	await get_tree().process_frame
	await get_tree().process_frame
	for shot: Array in SHOTS:
		cam.global_position = shot[1]
		cam.look_at(Vector3(0, shot[2], 0))
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/cute_%s.png" % [OUT, shot[0]])
	get_tree().quit()
