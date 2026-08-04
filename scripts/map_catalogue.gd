class_name MapCatalogue

## The grounds you can fight over.
##
## One entry per map the generator writes. The title, the description and how
## big it is are read out of the map's own file rather than repeated here, so
## `tools/make_map.py` stays the single place any of that is decided -- this
## list is only which of them the game offers and in what order.
##
## Everything is by id. The id is what the picker hands to the world, what the
## world loads its terrain from, and what the network uses to keep the people
## playing one map apart from the people playing another.

## In the order the picker shows them: smallest and fastest first, so the map
## somebody new to the game lands on is the one that explains itself quickest.
const IDS: Array[String] = ["shipment", "nuketown", "crossfire", "blood_gulch"]

## What the game falls back to when nobody has chosen: the first of them.
const DEFAULT_ID := "shipment"

## Parsed map files, by id. Read once and kept, because the picker asks for the
## same handful of numbers every time it draws a card.
static var _cache := {}


static func terrain_path(id: String) -> String:
	return "res://maps/%s_terrain.png" % id


static func structures_path(id: String) -> String:
	return "res://maps/%s_structures.json" % id


static func has(id: String) -> bool:
	return id in IDS


## The id to actually load for a possibly-unknown one. A client that has been
## told to play a map it does not have is better off on the default than on a
## black screen.
static func resolve(id: String) -> String:
	return id if has(id) else DEFAULT_ID


## The map's own metadata: title, blurb, size, spawns, the lot. Empty when the
## file is missing, which is the one case worth being quiet about -- a map that
## has not been generated yet should not stop the menu drawing.
static func meta(id: String) -> Dictionary:
	if _cache.has(id):
		return _cache[id]
	var path := structures_path(id)
	if not FileAccess.file_exists(path):
		_cache[id] = {}
		return _cache[id]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_cache[id] = parsed if parsed is Dictionary else {}
	return _cache[id]


static func title(id: String) -> String:
	return String(meta(id).get("title", id.to_upper().replace("_", " ")))


static func blurb(id: String) -> String:
	return String(meta(id).get("blurb", ""))


## How far it is across, in metres, for the picker to show.
static func metres(id: String) -> float:
	return float(meta(id).get("metres", 0.0))


## How many sides come into it, which is how the picker says "two bases".
static func spawn_count(id: String) -> int:
	return int((meta(id).get("team_spawns", {}) as Dictionary).size())


static func tank_count(id: String) -> int:
	return int((meta(id).get("tanks", []) as Array).size())
