class_name SmokeGrenade
extends Grenade

## Smoke grenade. Everything about carrying, cooking and throwing it is the
## frag grenade's; all that differs is what leaves the hand and how the HUD
## names it.


func net_projectile_kind() -> int:
	return Net.PROJECTILE_SMOKE


func status_text() -> String:
	if _cooking:
		return "SMOKE  %.1f" % fuse_remaining()
	return "SMOKE  %d" % count
