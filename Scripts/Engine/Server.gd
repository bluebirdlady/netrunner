class_name Server
extends RefCounted

# ── Server ────────────────────────────────────────────────────────────────────
# Represents a Corp server: an ordered array of protecting ice (outermost first)
# and a root containing at most one agenda/asset plus any number of upgrades.
#
# Central servers (hq, rd, archives) always exist.
# Remote servers are created dynamically and may become empty.

var server_id: String = ""

# Ice protecting this server, ordered outermost first (index 0 = outermost).
# The runner encounters ice from index 0 inward.
var ice: Array = []    # Array[InstalledCard]

# Cards in the root: agendas, assets, upgrades.
var root: Array = []   # Array[InstalledCard]


# ── Construction ──────────────────────────────────────────────────────────────

static func make(id: String) -> Server:
	var s      := Server.new()
	s.server_id = id
	return s


# ── Ice management ────────────────────────────────────────────────────────────

# Install a piece of ice at the outermost position (index 0).
func install_ice(card: InstalledCard) -> void:
	card.server_id = server_id
	card.zone      = "ice"
	ice.insert(0, card)

# Returns the ice at a given position (0 = outermost).
func get_ice_at(position: int) -> InstalledCard:
	if position < 0 or position >= ice.size():
		return null
	return ice[position]

func ice_count() -> int:
	return ice.size()

func has_ice() -> bool:
	return not ice.is_empty()

func remove_ice(card: InstalledCard) -> void:
	ice.erase(card)

# Cost to install another piece of ice here (1 credit per existing ice).
func ice_install_cost() -> int:
	return ice.size()


# ── Root management ───────────────────────────────────────────────────────────

func install_in_root(card: InstalledCard) -> void:
	card.server_id = server_id
	card.zone      = "root"
	root.append(card)

func remove_from_root(card: InstalledCard) -> void:
	root.erase(card)

# The single agenda or asset in this server's root (null if none).
func get_agenda_or_asset() -> InstalledCard:
	for card in root:
		var r: CardRecord = card.card_record
		if r != null and (r.is_agenda() or r.is_asset()):
			return card
	return null

# All upgrades in this server's root.
func get_upgrades() -> Array:
	var result: Array = []
	for card in root:
		var r: CardRecord = card.card_record
		if r != null and r.card_type == "upgrade":
			result.append(card)
	return result

func is_empty() -> bool:
	return ice.is_empty() and root.is_empty()

func is_remote() -> bool:
	return server_id.begins_with("remote_")


# ── Runner access ─────────────────────────────────────────────────────────────

# Returns all cards the runner accesses when breaching this server's root.
# Does not include the central server bonus (that's handled by RunStateMachine).
func get_root_access_cards() -> Array:
	return root.duplicate()


# ── Display ───────────────────────────────────────────────────────────────────

func display_name() -> String:
	match server_id:
		"hq":       return "HQ"
		"rd":       return "R&D"
		"archives": return "Archives"
		_:
			var num: String = server_id.replace("remote_", "")
			return "Server %s" % num
