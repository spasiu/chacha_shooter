#!/usr/bin/env python3
"""Builds every map the game ships with.

    python3 tools/make_map.py            # all of them
    python3 tools/make_map.py arena      # or just the ones named

Writes maps/<name>_terrain.png and maps/<name>_structures.json for each. Nothing
here is random in the sense of being different next time -- every wobble comes
out of a hash of its own coordinates, so running this again produces the same
maps, and a change to one layout leaves the others exactly as they were.

There are five, and four of them are the same four layouts twice over:

    arena        224m  all four grounds at once, blended into one landscape
    nuketown      64m  two houses and the street between them
    crossfire     80m  a village street with a base at each end
    shipment      40m  a container yard with no sightline worth the name
    blood_gulch  120m  a canyon, two bases, two tanks

The arena is the big one, laid out as you would see it from above:

    Crossfire (blue base, tank) | Nuketown (capturable)
    ----------------------------+----------------------------
    Shipment  (capturable)      | Blood Gulch (red base, tank)

The two team bases sit on one diagonal and the two capturable objectives on the
other, which is what makes the sides roughly equal: neither team is nearer to
both objectives, and the shortest road between the bases runs through the middle
where everybody else is.

A layout is written once and used twice -- `build_nuketown` puts the same two
houses down whether it is being asked for a corner of the arena or for the whole
of the small map. What differs is what goes around it: the arena blends its
corners into open country and hands out one base per diagonal, while a small map
flattens the ground, walls itself in and gives each side its own end.

Heights are in blocks. Ground level is GROUND (world y = 0) and one block is
0.25m, so a number here divided by four is metres.
"""

import json
import struct
import sys
import zlib
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
MAPS = PROJECT / "maps"

BLOCK = 0.25

# Vertical budget, shared by every map. The ground sits at GROUND with DEPTH
# blocks of diggable earth beneath it; everything above is airspace to build in.
# The gulch walls are what set the ceiling -- a canyon you can see over is not a
# canyon.
DEPTH = 16
GROUND = DEPTH
BUILD_HEIGHT = 48          # 12m of headroom
CEILING = DEPTH + BUILD_HEIGHT

# Surface block codes, matching VoxelWorld's enum.
GRASS, DIRT, CONCRETE = 1, 2, 3
ASPHALT, SAND, STONE = 7, 8, 9
GRAVEL = 16


# --- small maths ---------------------------------------------------------

def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def smoothstep(edge0, edge1, x):
    if edge1 <= edge0:
        return 0.0 if x < edge0 else 1.0
    t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def hashed(x, z, salt=0):
    """Deterministic 0..1 from a pair of integers."""
    n = (x * 374761393 + z * 668265263 + salt * 2147483647) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFFFFFF) / 0xFFFFFFFF


def noise(x, z, cell, salt=0):
    """Smoothed value noise on a grid of `cell` blocks."""
    gx, gz = x / cell, z / cell
    x0, z0 = int(gx // 1), int(gz // 1)
    fx, fz = gx - x0, gz - z0
    sx, sz = smoothstep(0.0, 1.0, fx), smoothstep(0.0, 1.0, fz)
    a = hashed(x0, z0, salt)
    b = hashed(x0 + 1, z0, salt)
    c = hashed(x0, z0 + 1, salt)
    d = hashed(x0 + 1, z0 + 1, salt)
    return (a * (1 - sx) + b * sx) * (1 - sz) + (c * (1 - sx) + d * sx) * sz


def pad(x, z, centre, half_x, half_z, feather):
    """Weight of a rectangular area, 1 inside and easing to 0 over `feather`
    blocks outside it. This is what lets a flat parade ground meet rolling
    country without a step in the ground at the join."""
    dx = abs(x - centre[0]) - half_x
    dz = abs(z - centre[1]) - half_z
    return (1.0 - smoothstep(0.0, feather, dx)) * (1.0 - smoothstep(0.0, feather, dz))


def blend(value, target, weight):
    return value * (1.0 - weight) + target * weight


def to_segment(x, z, ax, az, bx, bz):
    """Distance from a column to a line segment, and how far along it that was.
    Used both for valleys and for roads, which are the same shape problem: a
    long thin thing that bends."""
    vx, vz = bx - ax, bz - az
    length = vx * vx + vz * vz
    t = 0.0 if length == 0 else clamp(((x - ax) * vx + (z - az) * vz) / length, 0.0, 1.0)
    nx, nz = ax + vx * t, az + vz * t
    return ((x - nx) ** 2 + (z - nz) ** 2) ** 0.5, t


# --- a map under construction --------------------------------------------

class Layout:
    """One map: its terrain, everything built on it, and everything standing on
    top of that.

    The terrain is described rather than drawn. Callers register flat pads,
    roads, painted surfaces and a canyon, and the height and material at any one
    column are worked out from that list when the image is finally written. That
    ordering is what makes corners blend: two pads whose feathers overlap
    average into each other instead of one overwriting the other.
    """

    def __init__(self, name, size, title, blurb):
        self.name = name
        self.size = size
        self.half = size // 2
        self.title = title
        self.blurb = blurb
        self.structures = []
        self.pads = []        # (centre, half_x, half_z, feather, level)
        self.paints = []      # (centre, half_x, half_z, feather, block, threshold)
        self.roads = []       # (a, b, half, feather)
        self.canyon = None    # (a, b, floor_half, corner, half_x, half_z, feather, rise)
        self.bare = []        # (centre, half_x, half_z, feather) -- no trees here
        self.spawns = {}
        # The ground inside each side's own walls, as (x0, z0, x1, z1) in
        # blocks. What a spawn is allowed to use: a base is a room, and coming
        # into the world behind it or in the street in front of it is not
        # spawning at your base, it is spawning near it.
        self.spawn_zones = {}
        self.captures = []
        self.tanks = []
        self.ammo_anchors = []
        self.wooded = True

    # -- terrain ----------------------------------------------------------

    def flatten(self, centre, half_x, half_z, feather, level=GROUND):
        self.pads.append((centre, half_x, half_z, feather, level))
        self.bare.append((centre, half_x + 18, half_z + 18, 30))

    def paint(self, centre, half_x, half_z, feather, block, threshold=0.5):
        self.paints.append((centre, half_x, half_z, feather, block, threshold))

    def road(self, a, b, half=15.0, feather=9.0):
        self.roads.append((a, b, half, feather))

    def road_weight(self, x, z, shrink=0.0, feather=None):
        best = 0.0
        for (ax, az), (bx, bz), half, soft in self.roads:
            across, _ = to_segment(x, z, ax, az, bx, bz)
            edge = half - shrink
            best = max(best, 1.0 - smoothstep(edge, edge + (feather or soft), across))
        return best

    def canyon_walls(self, x, z):
        """A valley floor with cliffs down both long sides.

        The rise happens over six blocks: a metre and a half of ground for six
        of height, which is a wall. Spread it over the thirty-odd that look
        natural in a heightmap and you get a slope a soldier can walk up, at
        which point the valley stops being a valley and the layout is just
        terrain.
        """
        if self.canyon is None:
            return 0.0
        (ax, az), (bx, bz), floor_half, corner, chx, chz, feather, rise = self.canyon
        across, t = to_segment(x, z, ax, az, bx, bz)
        wall = smoothstep(floor_half, floor_half + 6.0, across)
        # Fade the walls in from the open end, so a canyon that has to join the
        # rest of a map opens toward it instead of being corked by a cliff face.
        presence = smoothstep(0.0, 0.22, t) if corner else 1.0
        # And keep them inside the ground the canyon is meant to occupy.
        # Without this every column far from the centre line counts as "outside
        # the valley" and rises, which turns the whole map into a plateau with a
        # trench cut through it.
        held = pad(x, z, corner, chx, chz, feather) if corner else 1.0
        crag = noise(x, z, 26, 7) * 6.0
        return wall * presence * held * (rise + crag)

    def surface(self, x, z):
        """Ground height in blocks at one column, everything blended together."""
        # Rolling country underneath the lot, so joins between areas are never
        # flat plains meeting flat plains.
        h = GROUND + noise(x, z, 90, 1) * 5.0 - 1.5 + noise(x, z, 31, 2) * 1.5
        for centre, hx, hz, feather, level in self.pads:
            h = blend(h, float(level), pad(x, z, centre, hx, hz, feather))
        road = self.road_weight(x, z)
        if road > 0.0:
            h = blend(h, GROUND - 0.5, road * 0.85)
        h += self.canyon_walls(x, z) * (1.0 - road)
        return int(clamp(round(h), 2, CEILING - 2))

    def material(self, x, z, h):
        """Surface block type. Read straight into the map's green channel."""
        # Anything high up a cliff is bare rock, whatever is painted below it.
        if h > GROUND + 8:
            return STONE
        if h > GROUND + 5:
            return STONE if hashed(x, z, 11) > 0.35 else DIRT

        found = None
        for centre, hx, hz, feather, block, threshold in self.paints:
            w = pad(x, z, centre, hx, hz, feather)
            if w > threshold or (w > threshold * 0.35 and hashed(x, z, 3) < w):
                found = block
        if self.road_weight(x, z, 2.0, 4.0) > 0.5:
            found = ASPHALT
        if found is not None:
            return found

        # Worn patches, so nothing is an unbroken sheet of one colour.
        if noise(x, z, 17, 5) > 0.78:
            return DIRT
        return GRASS

    def tree(self, x, z, h, block):
        """Sparse woodland, kept off built-up ground and off the roads."""
        if not self.wooded or block != GRASS or h > GROUND + 5:
            return 0
        for centre, hx, hz, feather in self.bare:
            if pad(x, z, centre, hx, hz, feather) > 0.3:
                return 0
        if self.road_weight(x, z, -5.0, 10.0) > 0.2:
            return 0
        # Roughly one column in nine hundred, clumped by the coarse noise.
        return 1 if hashed(x, z, 21) > 0.9988 and noise(x, z, 60, 9) > 0.45 else 0

    # -- structures -------------------------------------------------------

    def box(self, name, x0, z0, x1, z1, height, kind="concrete", frm=0, flat=None):
        entry = {
            "name": name, "x0": int(x0), "z0": int(z0), "x1": int(x1), "z1": int(z1),
            "from": int(frm), "height": int(height), "type": kind,
        }
        if flat is not None:
            entry["flat"] = True
            entry["gy"] = int(flat)
        self.structures.append(entry)

    def hollow(self, name, x0, z0, x1, z1, frm, height, gy):
        """Empties a box out. Used to put the inside back into a building."""
        self.structures.append({
            "name": name, "x0": int(x0), "z0": int(z0), "x1": int(x1), "z1": int(z1),
            "from": int(frm), "height": int(height), "clear": True,
            "flat": True, "gy": int(gy),
        })

    def wall(self, name, x0, z0, x1, z1, height=6, kind="concrete", cap="stone"):
        """A wall, with a course of something else laid along the top of it.
        One block of coping is the difference between a wall and a slab."""
        self.box(name, x0, z0, x1, z1, height, kind)
        if cap and height > 2:
            self.box(name + " coping", x0 - 1, z0 - 1, x1 + 1, z1 + 1, 1, cap,
                     flat=GROUND + height)

    # Ways a house can be dressed, picked per building from its own position so
    # a street is not one colour and is the same street every time it is built.
    #
    # Each is (walls, roof, trim, roof style). Trim is the plinth, the quoins on
    # the corners and the band under the eaves -- the parts that stand a block
    # proud of the wall, which is what puts a shadow line on a flat face and
    # stops a building reading as a painted box.
    LIVERIES = [
        # walls, roof, trim, roof style, the second roof block
        ("whitewash", "tile", "brick", "gable", "brick"),
        ("ochre", "slate", "brick", "gable", "steel"),
        ("plaster", "tile", "stone", "flat", "brick"),
        ("brick", "slate", "stone", "gable", "tin"),
        ("whitewash", "tin", "timber", "corrugated", "slate"),
        ("plaster", "slate", "brick", "flat", "tin"),
        ("ochre", "tin", "timber", "corrugated", "steel"),
        ("sand", "tile", "brick", "gable", "ochre"),
    ]

    def livery(self, x0, z0):
        return self.LIVERIES[int(hashed(x0, z0, 71) * len(self.LIVERIES)) % len(self.LIVERIES)]

    def building(self, name, x0, z0, x1, z1, storeys=2, walls=None,
                 roof=None, gy=GROUND + 1, door=None, windows=(), trim=None,
                 roof_style=None, chimney=True):
        """A rendered box with floors in it, a roof on top and a way in.

        Built flat rather than following the ground: a house on a slope with its
        floors stepped is a house nobody can move around inside.

        Windows are holes rather than glass. Every one is a firing position and
        a way for a grenade to arrive, which is most of what makes a building
        worth entering rather than worth walking round. Each gets a sill under
        it and a lintel over it, both a block proud: at this block size that is
        the difference between a window and a hole.

        Everything else here is relief. A plinth at the foot, quoins up the
        corners, a band under the eaves, a ridged or pitched roof and a chimney
        off one corner -- none of it changes how the building plays, and all of
        it changes whether the map looks built or extruded.
        """
        chosen = self.livery(x0, z0)
        walls = walls or chosen[0]
        roof = roof or chosen[1]
        trim = trim or chosen[2]
        roof_style = roof_style or chosen[3]
        second = chosen[4]

        storey = 11                      # 2.75m, enough to stand and shoot in
        total = storey * storeys
        self.box(name, x0, z0, x1, z1, total, walls, flat=gy)
        for s in range(storeys):
            base = s * storey
            self.hollow(name + " inside %d" % s, x0 + 2, z0 + 2, x1 - 2, z1 - 2,
                        base + 1, base + storey, gy)

        # Plinth: a course at the foot, standing a block out all round. Reads as
        # the building sitting on the ground rather than being pushed into it.
        self.box(name + " plinth", x0 - 1, z0 - 1, x1 + 1, z1 + 1, 4, trim, flat=gy)
        # Quoins up each corner, and a band under the eaves.
        for i, (qx, qz) in enumerate([(x0 - 1, z0 - 1), (x1 - 3, z0 - 1),
                                      (x0 - 1, z1 - 3), (x1 - 3, z1 - 3)]):
            self.box(name + " quoin %d" % i, qx, qz, qx + 4, qz + 4, total, trim,
                     flat=gy)
        self.box(name + " cornice", x0 - 1, z0 - 1, x1 + 1, z1 + 1, 3, trim,
                 flat=gy + total - 3)
        # And a string course between storeys, on anything tall enough to have
        # somewhere to put one.
        for s in range(1, storeys):
            self.box(name + " course %d" % s, x0 - 1, z0 - 1, x1 + 1, z1 + 1, 2,
                     trim, flat=gy + s * storey - 1)

        if door is not None:
            dx0, dz0, dx1, dz1 = door
            self.hollow(name + " door", dx0, dz0, dx1, dz1, 0, 9, gy)
            # Frame round it, so a doorway is a doorway and not a missing block.
            self.box(name + " door frame", dx0 - 2, dz0 - 1, dx1 + 2, dz1 + 1, 11,
                     trim, flat=gy)
            self.hollow(name + " door void", dx0, dz0 - 2, dx1, dz1 + 2, 0, 9, gy)

        for i, (wx0, wz0, wx1, wz1, sill) in enumerate(windows):
            self.hollow(name + " window %d" % i, wx0, wz0, wx1, wz1,
                        sill, sill + 6, gy)
            self.box(name + " sill %d" % i, wx0 - 1, wz0 - 1, wx1 + 1, wz1 + 1, 1,
                     trim, flat=gy + sill - 1)
            self.box(name + " lintel %d" % i, wx0 - 1, wz0 - 1, wx1 + 1, wz1 + 1, 2,
                     trim, flat=gy + sill + 6)

        self._roof(name, x0, z0, x1, z1, gy + total, roof, roof_style, second)
        if chimney:
            along_x = (x1 - x0) >= (z1 - z0)
            if along_x:
                cx0 = x0 + 6 if hashed(x0, z0, 83) < 0.5 else x1 - 12
                cz0 = (z0 + z1) // 2 - 3
            else:
                cx0 = (x0 + x1) // 2 - 3
                cz0 = z0 + 6 if hashed(x0, z0, 83) < 0.5 else z1 - 12
            # Started below the eaves so it is built into the roof rather than
            # resting on top of whatever the pitch happened to leave there.
            self.box(name + " stack", cx0, cz0, cx0 + 6, cz0 + 6, 20, trim,
                     flat=gy + total - 6)
            self.box(name + " pot", cx0 + 1, cz0 + 1, cx0 + 5, cz0 + 5, 3, "tile",
                     flat=gy + total + 14)

    def _roof(self, name, x0, z0, x1, z1, gy, roof, style, second=None):
        """The lid, and the most patterned thing on the map.

        A roof is the one big surface everybody sees from everywhere, and one
        block type across the whole of it is what makes a village look printed.
        So every roof here is laid in courses of two materials, the way a real
        one is laid in courses of tile: bands two blocks deep, alternating, with
        a capping course along the ridge and a darker one at the eaves. A few
        patches of the second material are scattered over it as well -- a roof
        somebody has had to repair.

        Three kinds. Flat is a deck inside a parapet; gable is a pitch built as
        steps, which at a quarter of a metre a step is what a pitched roof looks
        like in blocks anyway; corrugated lays ridges across the deck in the
        lighter of the two, so the light catches it one strip at a time.
        """
        second = second or roof
        along_x = (x1 - x0) >= (z1 - z0)

        if style == "gable":
            span = (z1 - z0) if along_x else (x1 - x0)
            steps = max(min(span // 10, 5), 2)
            for i in range(steps):
                inset = i * max(span // (3 * steps), 2)
                # Courses alternate up the pitch, so the slope is banded the way
                # a tiled roof is.
                kind = roof if i % 2 == 0 else second
                if along_x:
                    self.box(name + " roof %d" % i, x0 - 1 + i, z0 - 1 + inset,
                             x1 + 1 - i, z1 + 1 - inset, 2, kind, flat=gy + i)
                else:
                    self.box(name + " roof %d" % i, x0 - 1 + inset, z0 - 1 + i,
                             x1 + 1 - inset, z1 + 1 - i, 2, kind, flat=gy + i)
            # Ridge cap along the apex, in the other material.
            top = gy + steps
            if along_x:
                mid = (z0 + z1) // 2
                self.box(name + " ridge", x0 - 1, mid - 2, x1 + 1, mid + 2, 2,
                         second if steps % 2 == 0 else roof, flat=top)
            else:
                mid = (x0 + x1) // 2
                self.box(name + " ridge", mid - 2, z0 - 1, mid + 2, z1 + 1, 2,
                         second if steps % 2 == 0 else roof, flat=top)
            self._roof_patches(name, x0, z0, x1, z1, gy, second)
            return

        # Both of the others start from a deck with an eaves overhang, laid in
        # alternating courses.
        step = 4
        if along_x:
            for i, z in enumerate(range(z0 - 1, z1 + 1, step)):
                self.box(name + " course %d" % i, x0 - 1, z, x1 + 1,
                         min(z + step, z1 + 1), 2, roof if i % 2 == 0 else second,
                         flat=gy)
        else:
            for i, x in enumerate(range(x0 - 1, x1 + 1, step)):
                self.box(name + " course %d" % i, x, z0 - 1,
                         min(x + step, x1 + 1), z1 + 1, 2,
                         roof if i % 2 == 0 else second, flat=gy)

        if style == "corrugated":
            # Ridges every fourth block across the short way, standing one
            # proud. The gaps between them are the whole effect.
            if along_x:
                for i, z in enumerate(range(z0 - 2, z1 + 2, 4)):
                    self.box(name + " rib %d" % i, x0 - 2, z, x1 + 2, z + 2, 1,
                             second, flat=gy + 2)
            else:
                for i, x in enumerate(range(x0 - 2, x1 + 2, 4)):
                    self.box(name + " rib %d" % i, x, z0 - 2, x + 2, z1 + 2, 1,
                             second, flat=gy + 2)
            self._roof_patches(name, x0, z0, x1, z1, gy + 2, roof)
            return

        # Flat: a parapet round the edge with the deck sitting inside it.
        self.box(name + " parapet", x0 - 2, z0 - 2, x1 + 2, z1 + 2, 5, second,
                 flat=gy + 2)
        self.hollow(name + " roof well", x0, z0, x1, z1, 0, 4, gy + 3)
        self._roof_patches(name, x0, z0, x1, z1, gy, second)

    def _roof_patches(self, name, x0, z0, x1, z1, gy, kind):
        """Two or three squares of the other material dropped on the roof: the
        bit that was patched after something came through it. Placed off a hash
        of the building's own corner, so a roof is patched the same way every
        time the map is built."""
        for i in range(3):
            if hashed(x0 + i, z0 - i, 91) < 0.45:
                continue
            px = x0 + 2 + int(hashed(x0, z0 + i, 93) * max(x1 - x0 - 10, 1))
            pz = z0 + 2 + int(hashed(x0 - i, z0, 97) * max(z1 - z0 - 10, 1))
            size = 4 + int(hashed(px, pz, 101) * 6)
            self.box(name + " patch %d" % i, px, pz, px + size, pz + size, 1, kind,
                     flat=gy + 2)

    def compound(self, name, side, cx, cz, half_x, half_z, open_side="south",
                 gy=GROUND, height=14):
        """A walled base with its floor painted in its side's colour.

        One wall is left mostly open rather than doored: a base with a single
        entrance is a base that one machine gun closes, and a respawn nobody can
        walk out of is worse than no respawn at all.
        """
        x0, z0, x1, z1 = cx - half_x, cz - half_z, cx + half_x, cz + half_z
        # The floor is laid rather than poured: a checker of the side's colour
        # and bare concrete, eight blocks to a square. A base seen from a roof
        # is one of the biggest flat surfaces on the map, and one flat colour
        # over the whole of it is the thing that most says "untextured".
        self.box("%s floor" % name, x0, z0, x1, z1, 1, "concrete", flat=gy + 1)
        tile = 8
        for i, tx in enumerate(range(x0, x1, tile)):
            for j, tz in enumerate(range(z0, z1, tile)):
                if (i + j) % 2:
                    continue
                self.box("%s tile %d %d" % (name, i, j), tx, tz,
                         min(tx + tile, x1), min(tz + tile, z1), 1, side,
                         flat=gy + 1)
        # A band of the side's colour round the edge, so the checker reads as a
        # floor with a border rather than as a chessboard somebody left out.
        self.box("%s apron" % name, x0, z0, x1, z0 + 4, 1, side, flat=gy + 1)
        self.box("%s apron s" % name, x0, z1 - 4, x1, z1, 1, side, flat=gy + 1)
        self.box("%s apron w" % name, x0, z0, x0 + 4, z1, 1, side, flat=gy + 1)
        self.box("%s apron e" % name, x1 - 4, z0, x1, z1, 1, side, flat=gy + 1)
        faces = {
            "north": (x0, z0, x1, z0 + 6),
            "south": (x0, z1 - 6, x1, z1),
            "west": (x0, z0, x0 + 6, z1),
            "east": (x1 - 6, z0, x1, z1),
        }
        for face, rect in faces.items():
            ax0, az0, ax1, az1 = rect
            if face != open_side:
                self.wall("%s wall %s" % (name, face), ax0, az0, ax1, az1,
                          height, "concrete")
                continue
            # Leave the corners of the open face standing, so it reads as a
            # mouth rather than as a wall somebody forgot.
            if face in ("north", "south"):
                run = max((ax1 - ax0) // 3, 4)
                self.wall("%s wall %s a" % (name, face), ax0, az0, ax0 + run, az1,
                          height, "concrete")
                self.wall("%s wall %s b" % (name, face), ax1 - run, az0, ax1, az1,
                          height, "concrete")
            else:
                run = max((az1 - az0) // 3, 4)
                self.wall("%s wall %s a" % (name, face), ax0, az0, ax1, az0 + run,
                          height, "concrete")
                self.wall("%s wall %s b" % (name, face), ax0, az1 - run, ax1, az1,
                          height, "concrete")
        # A band of colour along the inside of the back wall and a mast over it,
        # both readable from the far end of the map, which is what a base is for.
        if open_side in ("north", "south"):
            band = z1 - 10 if open_side == "north" else z0 + 6
            self.box("%s colours" % name, x0 + 6, band, x1 - 6, band + 4,
                     height + 2, side)
        else:
            band = x1 - 10 if open_side == "west" else x0 + 6
            self.box("%s colours" % name, band, z0 + 6, band + 4, z1 - 6,
                     height + 2, side)
        self.box("%s mast" % name, cx - 2, cz - 2, cx + 2, cz + 2, height + 14, side)
        # Inside the walls, kept a couple of blocks off them so nobody arrives
        # with a shoulder in the concrete. The stores, the crates and the mast
        # are still in there; the spawn tries several spots and takes one with
        # room to stand, so they thin the room out rather than block it.
        if side.startswith("team_"):
            self.spawn_zone(side[5:], x0 + 9, z0 + 9, x1 - 9, z1 - 9)
        # Buttresses up the outside of the walls, every eight blocks. Cheap
        # relief on the biggest flat faces on any map.
        for i, x in enumerate(range(x0 + 8, x1 - 6, 16)):
            self.box("%s pier n %d" % (name, i), x, z0 - 2, x + 5, z0 + 2,
                     height - 2, "stone")
            self.box("%s pier s %d" % (name, i), x, z1 - 2, x + 5, z1 + 2,
                     height - 2, "stone")
        for i, z in enumerate(range(z0 + 8, z1 - 6, 16)):
            self.box("%s pier w %d" % (name, i), x0 - 2, z, x0 + 2, z + 5,
                     height - 2, "stone")
            self.box("%s pier e %d" % (name, i), x1 - 2, z, x1 + 2, z + 5,
                     height - 2, "stone")
        # A coping course along the top of the wall, in the side's own colour,
        # so a base is capped rather than cut off.
        self.box("%s coping" % name, x0 - 2, z0 - 2, x1 + 2, z1 + 2, 2, side,
                 flat=gy + height)
        # And a corrugated lean-to over the stores in the corner.
        self._roof("%s stores roof" % name, x0 + 10, z0 + 10, x0 + 32, z0 + 28,
                   gy + 8, "tin", "corrugated", "slate")
        # Stores under canvas, so a base has something in it at ground level to
        # take cover behind on the way out.
        self.box("%s stores" % name, x0 + 12, z0 + 12, x0 + 30, z0 + 26, 7, "canvas",
                 flat=gy + 1)
        self.box("%s crates" % name, x1 - 30, z0 + 14, x1 - 14, z0 + 24, 6, "wood",
                 flat=gy + 1)

    # -- things standing on it --------------------------------------------

    def spawn(self, side, x, z):
        self.spawns[side] = (x, z)


    def spawn_zone(self, side, x0, z0, x1, z1):
        self.spawn_zones[side] = (int(x0), int(z0), int(x1), int(z1))

    def capture(self, name, x, z, radius=10.0):
        self.captures.append((name, x, z, radius))

    def tank(self, x, z, yaw=0.0):
        self.tanks.append((x, z, yaw))

    def ammo(self, *anchors):
        self.ammo_anchors.extend(anchors)

    def on_a_tank(self, x, z, extra=0):
        """A hull is 2.8m wide and 5.6m long, so a rubble pile it half-overlaps
        leaves it sitting a metre and a half in the air on top of the scenery,
        which reads as a bug however correct it is."""
        return any(abs(x - tx) < 26 + extra and abs(z - tz) < 26 + extra
                   for tx, tz, _ in self.tanks)

    # -- writing it out ---------------------------------------------------

    def world(self, bx, bz):
        return [round((bx - self.half) * BLOCK, 2), round((bz - self.half) * BLOCK, 2)]

    def solid_at(self, x, z, margin):
        """True if this spot is inside something built, walls included. Hollowed
        volumes do not count as solid, but the footprint they were cut out of
        does, so this keeps boxes out of houses rather than burying them in the
        wall of one."""
        for entry in self.structures:
            if entry.get("clear"):
                continue
            if (entry["x0"] - margin <= x <= entry["x1"] + margin
                    and entry["z0"] - margin <= z <= entry["z1"] + margin):
                return True
        return False

    def resolve_ammo(self):
        """Nudges each ammunition anchor off whatever it landed in and drops any
        that cannot be placed at all. Deterministic and in a fixed order, so
        every run and every client puts the box in the same spot."""
        nudges = [
            (0, 0), (10, 0), (-10, 0), (0, 10), (0, -10), (10, 10), (-10, -10),
            (10, -10), (-10, 10), (20, 0), (-20, 0), (0, 20), (0, -20), (22, 22),
            (-22, -22), (22, -22), (-22, 22), (34, 0), (-34, 0), (0, 34), (0, -34),
        ]
        # A base restocks you already, so a box inside one is a box wasted.
        keepout = 60 if self.size > 300 else 34
        out = []
        for ax, az in self.ammo_anchors:
            for dx, dz in nudges:
                x, z = ax + dx, az + dz
                if not (8 < x < self.size - 8 and 8 < z < self.size - 8):
                    continue
                if self.solid_at(x, z, 7) or self.on_a_tank(x, z):
                    continue
                if any(abs(x - sx) < keepout and abs(z - sz) < keepout
                       for sx, sz in self.spawns.values()):
                    continue
                out.append((x, z))
                break
        return out

    def write(self):
        rows = []
        for z in range(self.size):
            row = bytearray(self.size * 3)
            for x in range(self.size):
                h = self.surface(x, z)
                m = self.material(x, z, h)
                row[x * 3] = h
                row[x * 3 + 1] = m
                row[x * 3 + 2] = self.tree(x, z, h, m)
            rows.append(row)

        MAPS.mkdir(exist_ok=True)
        write_png(MAPS / ("%s_terrain.png" % self.name), rows, self.size)
        write_keep_import("%s_terrain.png" % self.name, self.name)

        ammo = self.resolve_ammo()
        meta = {
            "name": self.name,
            "title": self.title,
            "blurb": self.blurb,
            "size": self.size,
            "block": BLOCK,
            "metres": round(self.size * BLOCK, 2),
            "depth_blocks": DEPTH,
            "build_height": BUILD_HEIGHT,
            "team_spawns": {
                side: self.world(x, z) for side, (x, z) in self.spawns.items()
            },
            "spawn_zones": {
                side: {
                    "x0": self.world(z[0], z[1])[0], "z0": self.world(z[0], z[1])[1],
                    "x1": self.world(z[2], z[3])[0], "z1": self.world(z[2], z[3])[1],
                }
                for side, z in self.spawn_zones.items()
            },
            "capture_points": [
                {"name": n, "x": self.world(x, z)[0], "z": self.world(x, z)[1],
                 "radius": r}
                for n, x, z, r in self.captures
            ],
            "tanks": [
                {"x": self.world(x, z)[0], "z": self.world(x, z)[1], "yaw": yaw}
                for x, z, yaw in self.tanks
            ],
            "ammo_boxes": [self.world(bx, bz) for bx, bz in ammo],
            "structures": self.structures,
        }
        (MAPS / ("%s_structures.json" % self.name)).write_text(
            json.dumps(meta, indent=1))
        print("  %-12s %4d blocks (%6.1fm)  %3d structures  %2d ammo  %d tanks" % (
            self.name, self.size, self.size * BLOCK, len(self.structures),
            len(ammo), len(self.tanks)))


# --- the four layouts ----------------------------------------------------
#
# Each takes the map it is being built into and where its centre goes, so the
# same code serves a corner of the arena and a map of its own.

def build_nuketown(m, cx, cz, level=GROUND):
    """Two houses either side of a short street, and a bus in the middle of it.

    The ground worth holding is the road, which is the whole point of Nuketown:
    the only place to stand is the place both houses overlook. Everything else
    exists to make crossing it survivable -- the bus, the garden walls, the
    porches you can duck onto.
    """
    m.flatten((cx, cz), 132, 100, 80, level)
    m.paint((cx, cz), 132, 96, 20, GRAVEL, 0.85)    # the yards either side
    m.paint((cx, cz), 128, 12, 6, ASPHALT)          # the street

    # Bungalows, set diagonally opposite so neither overlooks the other's door.
    m.building("nuketown house north", cx - 96, cz - 78, cx - 16, cz - 22,
               storeys=2, walls="plaster", roof="tile",
               door=(cx - 60, cz - 24, cx - 46, cz - 22),
               windows=[
                   (cx - 90, cz - 24, cx - 74, cz - 22, 4),
                   (cx - 38, cz - 24, cx - 22, cz - 22, 4),
                   (cx - 90, cz - 24, cx - 74, cz - 22, 15),
                   (cx - 38, cz - 24, cx - 22, cz - 22, 15),
                   (cx - 98, cz - 62, cx - 96, cz - 46, 4),
               ])
    m.building("nuketown house south", cx + 16, cz + 22, cx + 96, cz + 78,
               storeys=2, walls="brick", roof="tile",
               door=(cx + 46, cz + 20, cx + 60, cz + 22),
               windows=[
                   (cx + 22, cz + 20, cx + 38, cz + 22, 4),
                   (cx + 74, cz + 20, cx + 90, cz + 22, 4),
                   (cx + 22, cz + 20, cx + 38, cz + 22, 15),
                   (cx + 74, cz + 20, cx + 90, cz + 22, 15),
                   (cx + 96, cz + 46, cx + 98, cz + 62, 4),
               ])

    # Porches: a step up out of the street and under cover, on each house's
    # street face. The bit of Nuketown everybody uses without noticing.
    m.box("nuketown porch north", cx - 66, cz - 22, cx - 40, cz - 14, 1, "concrete",
          flat=level + 1)
    m.box("nuketown porch north roof", cx - 68, cz - 24, cx - 38, cz - 12, 2, "wood",
          flat=level + 12)
    m.box("nuketown porch north post a", cx - 67, cz - 16, cx - 65, cz - 14, 12, "wood")
    m.box("nuketown porch north post b", cx - 41, cz - 16, cx - 39, cz - 14, 12, "wood")
    m.box("nuketown porch south", cx + 40, cz + 14, cx + 66, cz + 22, 1, "concrete",
          flat=level + 1)
    m.box("nuketown porch south roof", cx + 38, cz + 12, cx + 68, cz + 24, 2, "wood",
          flat=level + 12)
    m.box("nuketown porch south post a", cx + 39, cz + 14, cx + 41, cz + 16, 12, "wood")
    m.box("nuketown porch south post b", cx + 65, cz + 14, cx + 67, cz + 16, 12, "wood")

    # Garden walls: the cover that makes crossing the road survivable.
    m.wall("nuketown wall north", cx - 110, cz - 16, cx - 30, cz - 12, 5, "brick")
    m.wall("nuketown wall south", cx + 30, cz + 12, cx + 110, cz + 16, 5, "brick")
    m.wall("nuketown wall west", cx - 118, cz - 16, cx - 114, cz + 40, 5, "brick")
    m.wall("nuketown wall east", cx + 114, cz - 40, cx + 118, cz + 16, 5, "brick")

    # The bus, stopped across the middle of the road for ever, and a car at each
    # end of the street nosed into the kerb.
    m.box("nuketown bus", cx - 18, cz - 7, cx + 18, cz + 7, 11, "rust")
    m.box("nuketown bus roof", cx - 18, cz - 7, cx + 18, cz + 7, 1, "steel", frm=11)
    m.hollow("nuketown bus inside", cx - 16, cz - 5, cx + 16, cz + 5, 3, 10, level + 1)
    m.box("nuketown car west", cx - 76, cz - 11, cx - 58, cz - 2, 6, "steel")
    m.box("nuketown car east", cx + 58, cz + 2, cx + 76, cz + 11, 6, "rust")

    # The objective: a sandbagged post in the road between the two houses.
    m.box("nuketown post", cx - 34, cz - 6, cx - 26, cz + 6, 4, "sand")
    m.box("nuketown post mast", cx - 31, cz - 1, cx - 29, cz + 1, 14, "wood")
    m.capture("NUKETOWN", cx, cz, 10.0)

    m.ammo((cx - 70, cz + 20), (cx + 66, cz - 26), (cx + 4, cz + 74),
           (cx - 100, cz - 6), (cx + 100, cz + 6))


def build_crossfire(m, cx, cz, level=GROUND, blue_base=True, reach=96):
    """A street with a wall of buildings down each side. Long sightlines one
    way, nothing but doorways the other -- which is the trade the whole layout
    is built on: cross the street and everybody sees you, work the buildings and
    you see nobody until you are on top of them."""
    m.flatten((cx, cz), 150, 120, 90, level)
    m.paint((cx, cz), 150, 120, 110, SAND, 0.55)
    m.paint((cx, cz), 16, 150, 10, ASPHALT)     # the street itself

    # Terraces either side, stepped so the roofline is never one flat run.
    for i, off in enumerate(range(-reach, reach + 1, 64)):
        m.building("crossfire west %d" % i, cx - 128, cz + off, cx - 58, cz + off + 46,
                   storeys=2 + (i % 2), walls="plaster", roof="tile",
                   door=(cx - 60, cz + off + 18, cx - 58, cz + off + 30),
                   windows=[
                       (cx - 60, cz + off + 4, cx - 58, cz + off + 16, 4),
                       (cx - 60, cz + off + 32, cx - 58, cz + off + 42, 4),
                       (cx - 60, cz + off + 8, cx - 58, cz + off + 20, 15),
                   ])
        m.building("crossfire east %d" % i, cx + 58, cz + off + 20,
                   cx + 128, cz + off + 66,
                   storeys=2 + ((i + 1) % 2), walls="brick", roof="tile",
                   door=(cx + 58, cz + off + 38, cx + 60, cz + off + 50),
                   windows=[
                       (cx + 58, cz + off + 24, cx + 60, cz + off + 34, 4),
                       (cx + 58, cz + off + 54, cx + 60, cz + off + 64, 4),
                       (cx + 58, cz + off + 28, cx + 60, cz + off + 38, 15),
                   ])

    # Rubble in the street: the cover that makes the long shot survivable.
    for i, off in enumerate(range(-reach + 16, reach - 15, 40)):
        side = -18 if i % 2 else 14
        if m.on_a_tank(cx + side + 8, cz + off + 6):
            continue
        m.box("crossfire rubble %d" % i, cx + side, cz + off, cx + side + 16,
              cz + off + 12, 4 + (i % 3) * 2, "sand")
    # A burnt-out lorry down at the far end, the one piece of hard cover in the
    # open stretch.
    m.box("crossfire lorry", cx - 10, cz + 100, cx + 10, cz + 126, 9, "rust")
    m.box("crossfire lorry cab", cx - 10, cz + 92, cx + 10, cz + 102, 12, "steel")

    if blue_base:
        m.compound("blue base", "team_blue", cx, cz - 145, 66, 33,
                   open_side="south", gy=level, height=14)
    m.ammo((cx - 62, cz + 48), (cx + 58, cz - 40), (cx + 8, cz + 78),
           (cx - 30, cz - 96), (cx + 40, cz + 110))


def build_shipment(m, cx, cz, level=GROUND):
    """Twenty-odd containers in a yard the size of a tennis court. Every
    sightline is short and every corner has somebody round it, which is the
    entire joke and the reason it is the smallest ground here."""
    m.flatten((cx, cz), 66, 66, 70, level)
    m.paint((cx, cz), 74, 74, 18, GRAVEL, 0.8)
    m.paint((cx, cz), 62, 62, 26, ASPHALT)
    yard = 62
    m.wall("shipment wall n", cx - yard, cz - yard, cx + yard, cz - yard + 5, 12,
           "concrete")
    m.wall("shipment wall s", cx - yard, cz + yard - 5, cx + yard, cz + yard, 12,
           "concrete")
    m.wall("shipment wall w", cx - yard, cz - yard, cx - yard + 5, cz + yard, 12,
           "concrete")
    m.wall("shipment wall e", cx + yard - 5, cz - yard, cx + yard, cz + yard, 12,
           "concrete")

    # Containers: 6m x 2.4m, so 24 x 10 blocks, 10 blocks tall.
    def container(name, x, z, turned, kind, stacked=False):
        """A box, ribbed the way a real one is: corrugation up the long sides
        every four blocks and a capping course along the top. Ten blocks of flat
        steel is the one shape on this map that most needs breaking up, because
        there are twenty of them and they are all anybody sees."""
        def one(tag, bx, bz, bw, bd, base):
            m.box(tag, bx, bz, bx + bw, bz + bd, 10, kind, flat=base)
            # Ribs: proud strips up the long faces.
            if bw >= bd:
                for i, rx in enumerate(range(bx + 2, bx + bw - 2, 4)):
                    m.box("%s rib %d" % (tag, i), rx, bz - 1, rx + 2, bz + bd + 1,
                          8, kind, flat=base + 1)
            else:
                for i, rz in enumerate(range(bz + 2, bz + bd - 2, 4)):
                    m.box("%s rib %d" % (tag, i), bx - 1, rz, bx + bw + 1, rz + 2,
                          8, kind, flat=base + 1)
            # Capping rail, and the doors at one end in a darker sheet.
            m.box(tag + " cap", bx - 1, bz - 1, bx + bw + 1, bz + bd + 1, 1, "steel",
                  flat=base + 10)
            if bw >= bd:
                m.box(tag + " doors", bx + bw - 2, bz, bx + bw + 1, bz + bd, 9,
                      "rust" if kind != "rust" else "steel", flat=base + 1)
            else:
                m.box(tag + " doors", bx, bz + bd - 2, bx + bw, bz + bd + 1, 9,
                      "rust" if kind != "rust" else "steel", flat=base + 1)

        if turned:
            one(name, x, z, 10, 24, level + 1)
            if stacked:
                one(name + " upper", x, z, 10, 24, level + 11)
        else:
            one(name, x, z, 24, 10, level + 1)
            if stacked:
                one(name + " upper", x, z, 24, 10, level + 11)

    kinds = ["rust", "team_red", "steel", "team_blue", "concrete", "rust"]
    # The four in the middle, boxing in the objective.
    container("ship mid nw", cx - 30, cz - 32, False, "rust")
    container("ship mid ne", cx + 6, cz - 32, False, "steel")
    container("ship mid sw", cx - 30, cz + 22, False, "steel")
    container("ship mid se", cx + 6, cz + 22, False, "rust")
    # The ring round the outside, alternating turned and stacked.
    spots = [
        (-52, -50, True), (-52, 4, True), (42, -50, True), (42, 4, True),
        (-20, -52, False), (12, -52, False), (-20, 44, False), (12, 44, False),
    ]
    for i, (dx, dz, turned) in enumerate(spots):
        container("ship edge %d" % i, cx + dx, cz + dz, turned,
                  kinds[i % len(kinds)], stacked=(i % 3 == 0))

    # The objective: an open square dead in the centre with a mast on it.
    m.box("shipment post", cx - 6, cz - 6, cx + 6, cz + 6, 2, "concrete")
    m.box("shipment mast", cx - 2, cz - 2, cx + 2, cz + 2, 18, "wood")
    m.capture("SHIPMENT", cx, cz, 9.0)

    m.ammo((cx - 54, cz - 58), (cx + 62, cz + 34), (cx - 12, cz + 76),
           (cx + 40, cz - 46), (cx - 44, cz + 30))


def build_gulch(m, ax, az, bx, bz, level=GROUND - 1, red=None, blue=None,
                half_x=68, half_z=46):
    """A canyon with a base at the end of it and open floor between.

    The cliffs are terrain rather than structures, so they cannot be blown
    through and the fight stays in the canyon. Rocks on the floor, and no
    teleporters: crossing it is meant to cost you something, which is what the
    tanks are for.
    """
    for name, base in (("red base", red), ("blue base", blue)):
        if base is None:
            continue
        bcx, bcz, side, facing = base
        m.compound(name, side, bcx, bcz, half_x, half_z, open_side=facing,
                   gy=level, height=16)

    span_x, span_z = bx - ax, bz - az
    for i in range(16):
        t = (i + 0.5) / 16.0
        rx = int(ax + span_x * t + (hashed(i, 3, 31) - 0.5) * 110)
        rz = int(az + span_z * t + (hashed(i, 7, 37) - 0.5) * 110)
        s = 6 + int(hashed(i, 11, 41) * 12)
        if m.on_a_tank(rx + s // 2, rz + s // 2, s) or m.solid_at(rx, rz, 12):
            continue
        m.box("gulch rock %d" % i, rx, rz, rx + s, rz + s,
              4 + int(hashed(i, 13, 43) * 10), "stone")
        if i % 5 == 0:
            m.ammo((rx - 16, rz - 16))


# --- the maps ------------------------------------------------------------

def make_arena():
    """All four grounds at once, blended into one landscape."""
    m = Layout("arena", 896, "ARENA",
               "All four grounds at once, joined by the roads between them.")
    crossfire, nuketown = (224, 224), (672, 224)
    shipment, gulch = (224, 672), (672, 672)

    m.tank(224, 210, 0.0)
    m.tank(640, 640, 45.0)
    # The armoured route. Crossfire's tank has to be able to get down to the
    # gulch, which on a map this size means a made road rather than an implied
    # one: a tank will cross open country perfectly well, but nobody reads open
    # country as a way through, so both sides end up fighting over ground
    # neither of them meant to.
    m.road((300, 300), (448, 448))
    m.road((448, 448), (560, 560))
    m.road((560, 560), (700, 700))
    # And the two straight roads through the middle, joining the other corners.
    m.flatten((448, 448), 190, 26, 40, GROUND)
    m.flatten((448, 448), 26, 190, 40, GROUND)
    m.paint((448, 448), 186, 10, 8, ASPHALT)
    m.paint((448, 448), 10, 186, 8, ASPHALT)

    build_crossfire(m, *crossfire, GROUND, blue_base=True)
    build_nuketown(m, *nuketown, GROUND)
    build_shipment(m, *shipment, GROUND)
    m.flatten(gulch, 120, 120, 90, GROUND - 1)
    m.canyon = ((470.0, 470.0), (830.0, 830.0), 70.0, gulch, 116, 116, 56, 26.0)
    build_gulch(m, 500, 500, 800, 800, GROUND - 1,
                red=(742, 742, "team_red", "north"))

    # Where the sides come into the world: one diagonal, so neither is nearer to
    # both of the capturable objectives.
    m.spawn("blue", crossfire[0], crossfire[1] - 145)
    m.spawn("red", 742, 742)

    # The middle: enough cover to cross, not enough to hold. It is meant to be
    # dangerous, not a fifth position.
    for i in range(18):
        x = 300 + int(hashed(i, 2, 51) * 300)
        z = 300 + int(hashed(i, 5, 53) * 300)
        if abs(x - 448) < 30 and abs(z - 448) < 30:
            continue
        if m.road_weight(x, z, -7.0, 6.0) > 0.15 or m.on_a_tank(x, z, 20):
            continue
        s = 8 + int(hashed(i, 9, 59) * 14)
        m.box("middle cover %d" % i, x, z, x + s, z + s // 2,
              5 + int(hashed(i, 17, 61) * 6), "sand" if i % 2 else "concrete")
    # A crossroads marker, so the middle has a landmark to call.
    m.box("crossroads block", 440, 440, 456, 456, 3, "concrete")
    m.box("crossroads mast", 446, 446, 450, 450, 22, "wood")

    m.ammo((400, 400), (496, 496), (404, 500), (500, 396),
           (448, 224), (448, 672), (224, 448), (672, 448))
    return m


# Every mini is the same 256 blocks square -- 64m, about a minute's walk corner
# to corner -- so that picking one is a choice about what the ground is like
# rather than about how far you have to run.
MINI = 256


def make_nuketown():
    m = Layout("nuketown", MINI, "NUKETOWN",
               "Two houses, one street, and a bus stopped across the middle of it.")
    m.wooded = False
    # Armour at each end of the street, nosed at the other side's ground.
    m.tank(92, 40, 0.0)
    m.tank(164, 216, 180.0)
    build_nuketown(m, 128, 128, GROUND)
    # A side at each end of the street rather than behind a house: both come out
    # onto the same road at the same moment, which is the whole map.
    m.compound("blue base", "team_blue", 128, 26, 46, 20, open_side="south")
    m.compound("red base", "team_red", 128, 230, 46, 20, open_side="north")
    m.spawn("blue", 128, 28)
    m.spawn("red", 128, 228)
    return m


def make_crossfire():
    m = Layout("crossfire", MINI, "CROSSFIRE",
               "A village street. Long one way, blind the other, and armour in it.")
    m.wooded = False
    m.tank(128, 62, 0.0)
    m.tank(128, 194, 180.0)
    build_crossfire(m, 128, 128, GROUND, blue_base=False, reach=32)
    m.compound("blue base", "team_blue", 128, 26, 46, 20, open_side="south")
    m.compound("red base", "team_red", 128, 230, 46, 20, open_side="north")
    m.spawn("blue", 128, 28)
    m.spawn("red", 128, 228)
    m.ammo((72, 128), (184, 128))
    return m


def make_shipment():
    m = Layout("shipment", MINI, "SHIPMENT",
               "A container yard, and the armour parked outside it.")
    m.wooded = False
    # The tanks sit outside the yard walls, because a tank inside Shipment would
    # be a tank that owns Shipment. Out here they cover the ground between each
    # base and the way in, which is the only open ground on the map.
    m.tank(60, 40, 30.0)
    m.tank(196, 216, 210.0)
    build_shipment(m, 128, 128, GROUND)
    m.compound("blue base", "team_blue", 128, 26, 40, 18, open_side="south")
    m.compound("red base", "team_red", 128, 230, 40, 18, open_side="north")
    m.spawn("blue", 128, 28)
    m.spawn("red", 128, 228)
    m.ammo((60, 128), (196, 128))
    return m


def make_blood_gulch():
    m = Layout("blood_gulch", MINI, "BLOOD GULCH",
               "A canyon, a base at each end, and a tank apiece to cross it with.")
    m.flatten((128, 128), 96, 96, 40, GROUND - 1)
    m.canyon = ((60.0, 60.0), (196.0, 196.0), 46.0, None, 0, 0, 0, 30.0)
    m.tank(92, 72, 45.0)
    m.tank(164, 184, 225.0)
    build_gulch(m, 70, 70, 186, 186, GROUND - 1,
                red=(190, 190, "team_red", "north"),
                blue=(66, 66, "team_blue", "south"), half_x=44, half_z=26)
    m.spawn("blue", 66, 66)
    m.spawn("red", 190, 190)
    m.ammo((128, 84), (128, 172), (84, 128), (172, 128), (128, 128))
    return m


# The four the game offers. The big arena the layouts came from is still here
# and still builds -- `python3 tools/make_map.py arena` -- but it is not one of
# the maps on the menu any more: four 64m grounds fill up and start faster than
# one 224m one ever did.
MINIS = ["nuketown", "crossfire", "shipment", "blood_gulch"]

MAKERS = {
    "arena": make_arena,
    "nuketown": make_nuketown,
    "crossfire": make_crossfire,
    "shipment": make_shipment,
    "blood_gulch": make_blood_gulch,
}


# --- writing PNGs --------------------------------------------------------

def write_png(path, rows, size):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def write_keep_import(png_name, key):
    """A .import that tells Godot to leave these pixels alone. They are height
    data; a compressed texture is a corrupted map."""
    stem = png_name.replace(".png", "").replace("_", "")
    text = f"""[remap]

importer="image"
type="Image"
uid="uid://bqxv{stem}map"
path="res://.godot/imported/{png_name}-keep.image"

[deps]

source_file="res://maps/{png_name}"
dest_files=["res://.godot/imported/{png_name}-keep.image"]

[params]

compress/mode=0
"""
    (MAPS / (png_name + ".import")).write_text(text)


def main():
    wanted = sys.argv[1:] or MINIS
    unknown = [w for w in wanted if w not in MAKERS]
    if unknown:
        print("unknown map(s): %s\nknown: %s" % (", ".join(unknown), ", ".join(MAKERS)))
        return 1
    print("building %d map(s)" % len(wanted))
    for name in wanted:
        MAKERS[name]().write()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
