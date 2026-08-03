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
const SLOTS := 5

## Menu order. `key` is what the player's own table of equipment is keyed by;
## everything else on the entry is for the card that presents it.
const ITEMS: Array[Dictionary] = [
	{
		"key": &"thompson",
		"name": "M1A1 THOMPSON",
		"kind": "SUBMACHINE GUN",
		"blurb": "Seven hundred rounds a minute and thirty in the magazine. Forgiving up close; walks off target if you lean on the trigger.",
		"stats": "100 / 50 / 25 DMG  ·  30 ROUNDS  ·  AUTO",
		"accent": Color(0.56, 0.59, 0.35, 1.0),
	},
	{
		"key": &"shotgun",
		"name": "PUMP SHOTGUN",
		"kind": "SCATTERGUN",
		"blurb": "Eight pellets a shell from a six-round tube. Lethal inside a few paces, and increasingly theoretical past twenty.",
		"stats": "100 / 50 / 25 DMG  ·  6 SHELLS  ·  PUMP",
		"accent": Color(0.68, 0.37, 0.22, 1.0),
	},
	{
		"key": &"garand",
		"name": "M1D GARAND",
		"kind": "SNIPER RIFLE",
		"blurb": "Scoped and slow. One centre-mass hit ends anything that walks, provided you can hold the crosshair still.",
		"stats": "100 / 100 / 100 DMG  ·  8 ROUNDS  ·  SCOPED",
		"accent": Color(0.42, 0.55, 0.63, 1.0),
	},
	{
		"key": &"carbine",
		"name": "M1 CARBINE",
		"kind": "LIGHT RIFLE",
		"blurb": "Light, quick to the shoulder and flat out to fifty yards. Semi-automatic, so every round costs a trigger pull.",
		"stats": "100 / 100 / 50 DMG  ·  15 ROUNDS  ·  SEMI",
		"accent": Color(0.5, 0.42, 0.28, 1.0),
	},
	{
		"key": &"bazooka",
		"name": "M1A1 BAZOOKA",
		"kind": "ROCKET LAUNCHER",
		"blurb": "One rocket in the tube and a long wait for the next. The blast does not care what you were hiding behind, and neither does the ground.",
		"stats": "1000 / 100 / 10 BLAST  ·  1 + 5  ·  1/3/9 YD",
		"accent": Color(0.6, 0.42, 0.26, 1.0),
	},
	{
		"key": &"bar",
		"name": "M1918A2 BAR",
		"kind": "AUTOMATIC RIFLE",
		"blurb": "Twenty rounds of rifle calibre on full automatic, and a bipod for when you can lie down behind it. Heavy to carry and heavier to hold on target.",
		"stats": "100 / 100 / 100 DMG  ·  20 ROUNDS  ·  AUTO",
		"accent": Color(0.5, 0.54, 0.33, 1.0),
	},
	{
		"key": &"johnson",
		"name": "M1941 JOHNSON",
		"kind": "LIGHT MACHINE GUN",
		"blurb": "Feeds from the side and shoots flatter than it has any right to. Holds its own out to the far side of the field.",
		"stats": "100 / 100 / 50 DMG  ·  20 ROUNDS  ·  AUTO",
		"accent": Color(0.45, 0.5, 0.45, 1.0),
	},
	{
		"key": &"m1911",
		"name": "M1911A1",
		"kind": "SIDEARM",
		"blurb": "Seven of the heaviest pistol rounds going. Comes up fast and hits hard in a room, and is honest about being useless past one.",
		"stats": "100 / 50 / 25 DMG  ·  7 ROUNDS  ·  SEMI",
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
		"key": &"grenade",
		"name": "FRAG GRENADES",
		"kind": "THROWN",
		"blurb": "Ten of them. Fragments do not care what they hit, so mind the walls and mind yourself.",
		"stats": "10 CARRIED  ·  FRAGMENTATION",
		"accent": Color(0.62, 0.53, 0.25, 1.0),
	},
]

## What the select screen last confirmed, in the order it was picked, so slot 1
## is whatever was chosen first.
static var chosen: Array[StringName] = [&"thompson", &"shotgun", &"garand", &"grenade"]


## The catalogue entry for a key, or an empty dictionary if there is none.
static func item(key: StringName) -> Dictionary:
	for entry: Dictionary in ITEMS:
		if entry["key"] == key:
			return entry
	return {}
