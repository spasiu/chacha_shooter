class_name LoadoutConfig

## The catalogue of everything that can be carried into a match, and which of it
## the player picked on the select screen.
##
## Static rather than an autoload: the picks are one small piece of state that
## has to survive the change from the menu scene to the world, and nothing else
## in the game needs to reach them. The defaults are what you deploy with if the
## world scene is run directly, which is how the test harnesses drive it.

## The most that can be taken into a match. Slots 1..SLOTS map onto the picks
## in order, so this is also how many weapon slots the player ends up with.
## Fewer is allowed -- deploying only needs one thing in hand.
const SLOTS := 4

## Longest name the scoreboard would ever want to show.
const NAME_LIMIT := 16
const DEFAULT_NAME := "SOLDIER"

## Menu order. `key` is what the player's own table of equipment is keyed by;
## everything else on the entry is for the card that presents it.
const ITEMS: Array[Dictionary] = [
	{
		"key": &"thompson",
		"name": "M1A1 THOMPSON",
		"kind": "SUBMACHINE GUN",
		"blurb": "Seven hundred rounds a minute and thirty in the magazine. Forgiving up close; walks off target if you lean on the trigger.",
		"stats": "100 / 50 / 25 DMG  ·  30 × 3 ROUNDS  ·  AUTO",
		"accent": Color(0.56, 0.59, 0.35, 1.0),
	},
	{
		"key": &"shotgun",
		"name": "PUMP SHOTGUN",
		"kind": "SCATTERGUN",
		"blurb": "Eight pellets a shell from a six-round tube. Lethal inside a few paces, and increasingly theoretical past twenty.",
		"stats": "100 / 50 / 25 DMG  ·  6 × 3 SHELLS  ·  PUMP",
		"accent": Color(0.68, 0.37, 0.22, 1.0),
	},
	{
		"key": &"garand",
		"name": "M1D GARAND",
		"kind": "SNIPER RIFLE",
		"blurb": "Scoped and slow. One centre-mass hit ends anything that walks, provided you can hold the crosshair still.",
		"stats": "100 / 100 / 100 DMG  ·  8 × 3 ROUNDS  ·  SCOPED",
		"accent": Color(0.42, 0.55, 0.63, 1.0),
	},
	{
		"key": &"carbine",
		"name": "M1 CARBINE",
		"kind": "LIGHT RIFLE",
		"blurb": "Light, quick to the shoulder and flat out to fifty yards. Semi-automatic, so every round costs a trigger pull.",
		"stats": "100 / 100 / 50 DMG  ·  15 × 3 ROUNDS  ·  SEMI",
		"accent": Color(0.5, 0.42, 0.28, 1.0),
	},
	{
		"key": &"bazooka",
		"name": "M1A1 BAZOOKA",
		"kind": "ROCKET LAUNCHER",
		"blurb": "One rocket in the tube and a long wait for the next. The blast does not care what you were hiding behind, and neither does the ground.",
		"stats": "1000 / 100 / 10 BLAST  ·  3 ROCKETS  ·  1/3/9 YD",
		"accent": Color(0.6, 0.42, 0.26, 1.0),
	},
	{
		"key": &"bar",
		"name": "M1918A2 BAR",
		"kind": "AUTOMATIC RIFLE",
		"blurb": "Twenty rounds of rifle calibre on full automatic, and a bipod for when you can lie down behind it. Heavy to carry and heavier to hold on target.",
		"stats": "100 / 100 / 100 DMG  ·  20 × 3 ROUNDS  ·  AUTO",
		"accent": Color(0.5, 0.54, 0.33, 1.0),
	},
	{
		"key": &"johnson",
		"name": "M1941 JOHNSON",
		"kind": "LIGHT MACHINE GUN",
		"blurb": "Feeds from the side and shoots flatter than it has any right to. Holds its own out to the far side of the field.",
		"stats": "100 / 100 / 50 DMG  ·  20 × 3 ROUNDS  ·  AUTO",
		"accent": Color(0.45, 0.5, 0.45, 1.0),
	},
	{
		"key": &"m1911",
		"name": "M1911A1",
		"kind": "SIDEARM",
		"blurb": "Seven of the heaviest pistol rounds going. Comes up fast and hits hard in a room, and is honest about being useless past one.",
		"stats": "100 / 50 / 25 DMG  ·  7 × 3 ROUNDS  ·  SEMI",
		"accent": Color(0.5, 0.45, 0.4, 1.0),
	},
	{
		"key": &"shovel",
		"name": "TRENCH SHOVEL",
		"kind": "TOOL",
		"blurb": "Swing it and something either loses a hundred health or stops being a piece of ground. Raise it and the same swing packs earth back instead.",
		"stats": "100 DMG  ·  DIG / BUILD  ·  MELEE",
		"accent": Color(0.45, 0.36, 0.22, 1.0),
	},
	{
		"key": &"jumpjet",
		"name": "JUMP JET",
		"kind": "MOBILITY",
		"blurb": "Worn, not carried: there is no slot for it and nothing to draw. Jump to climb, crouch to come down, and a minute of burn that only runs while your boots are off the ground. Filled at your own base, like everything else.",
		"stats": "60s AIR TIME  ·  JUMP UP  ·  CROUCH DOWN",
		"accent": Color(0.68, 0.46, 0.2, 1.0),
	},
	{
		"key": &"medic",
		"name": "MEDIC PACK",
		"kind": "AID",
		"blurb": "Four dressings. Patches a man on his feet back to full, and carries one who is down back to his own base -- and his side never loses the man for him.",
		"stats": "4 USES  ·  HEALS / REVIVES  ·  4 YD",
		"accent": Color(0.82, 0.82, 0.8, 1.0),
	},
	{
		"key": &"smoke",
		"name": "SMOKE GRENADES",
		"kind": "THROWN",
		"blurb": "Three canisters. Pours cover for a quarter of a minute; rounds go through it as happily as air, so it hides you rather than protecting you.",
		"stats": "3 CARRIED  ·  15 SEC SCREEN",
		"accent": Color(0.72, 0.73, 0.76, 1.0),
	},
	{
		"key": &"tnt",
		"name": "TNT CHARGE",
		"kind": "DEMOLITION",
		"blurb": "Stick it to something and get fifteen seconds of distance. Nothing within a yard survives, and the whole field feels it go.",
		"stats": "10000 / 1000 / 10 DMG  ·  3 CARRIED  ·  15s FUSE",
		"accent": Color(0.62, 0.24, 0.18, 1.0),
	},
	{
		"key": &"grenade",
		"name": "FRAG GRENADES",
		"kind": "THROWN",
		"blurb": "Three of them. Fragments do not care what they hit, so mind the walls and mind yourself.",
		"stats": "3 CARRIED  ·  FRAGMENTATION",
		"accent": Color(0.62, 0.53, 0.25, 1.0),
	},
]

## What the select screen last confirmed, in the order it was picked, so slot 1
## is whatever was chosen first.
## What the player is called. Set on the join screen and kept for the session,
## which is as long as it needs to live for.
static var player_name := ""


## Trims and caps whatever was typed, and falls back to something rather than
## letting an empty name through.
static func set_player_name(raw: String) -> void:
	var clean := raw.strip_edges()
	if clean.length() > NAME_LIMIT:
		clean = clean.substr(0, NAME_LIMIT)
	player_name = clean if not clean.is_empty() else DEFAULT_NAME


static var chosen: Array[StringName] = [&"thompson", &"shotgun", &"garand", &"grenade"]


## The catalogue entry for a key, or an empty dictionary if there is none.
static func item(key: StringName) -> Dictionary:
	for entry: Dictionary in ITEMS:
		if entry["key"] == key:
			return entry
	return {}
