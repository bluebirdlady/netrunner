class_name InstalledCard
extends RefCounted

# ── InstalledCard ─────────────────────────────────────────────────────────────
# Represents a single card installed in a server's ice or root zone.
# The Corp always knows what every card is. The Runner's information model
# (what they believe about unrezzed cards) is handled separately.

var card_id:     String     = ""    # stable slug from CardRegistry
var card_record: CardRecord = null  # null only transiently during construction
var is_rezzed:   bool       = false
# BANGUN: agenda installed faceup — visible to runner, but abilities are NOT active.
# Per rules: faceup agendas are "neither rezzed nor unrezzed".
var is_face_up:  bool       = false
var counters:    Dictionary = {}    # {"advancement": 0, "power": 0, "credits": 0}
var server_id:   String     = ""    # "hq" | "rd" | "archives" | "remote_0" etc.
var zone:        String     = ""    # "ice" | "root"
var runtime_instance_id: String = ""
# Programs hosted on this ice card (Botulus, Tranquilizer)
var hosted_cards: Array = []        # Array[InstalledCard]
# Cards hosted faceup on this card (Bling, Détente, Madani) — CardRecord objects, not installed
var faceup_hosted_cards: Array = [] # Array[CardRecord]
# If non-empty, this card is hosted on the ice with this instance_id
var hosted_on_id: String = ""
# If non-empty, this card has a chosen target ice (Boomerang: stored instance_id of target ice)
var target_id: String = ""
# Subtypes dynamically granted to this ice by hosted programs (e.g. Chromatophores → barrier, code_gate, sentry).
# Merged with card_record.subtypes during encounter/break resolution.
var extra_subtypes: Array = []
# Subtypes this program has granted to its host ice — stored for cleanup when this card is trashed.
var granted_subtypes_to_host: Array = []
# Facedown cards from the runner's grip hosted on this card (VP22 Read-Write Share).
# Array of CardRecord objects.  On trash, shuffled back into the runner's stack.
var hosted_grip_cards: Array = []
# Unique companion/connection resources hosted on this Hackerspace card (VP6).
# Array of InstalledCard objects.
var hosted_runner_resources: Array = []

static func make_runtime_instance(record: CardRecord, srv_id: String, srv_zone: String, rezzed: bool = false) -> InstalledCard:
	var c = InstalledCard.make(record, srv_id, srv_zone, rezzed)
	# Assign clean global UUID or structural numeric string
	c.runtime_instance_id = "%s_%d_%d" % [record.id, Time.get_ticks_msec(), randi() % 1000]
	return c

# ── Construction ──────────────────────────────────────────────────────────────

static func make(record: CardRecord, srv_id: String, srv_zone: String, rezzed: bool = false) -> InstalledCard:
	var c        := InstalledCard.new()
	c.card_id    = record.id
	c.card_record= record
	c.server_id  = srv_id
	c.zone       = srv_zone
	c.is_rezzed  = rezzed
	c.counters   = {"advancement": 0, "power": 0, "credits": 0}
	c.hosted_cards = []
	c.faceup_hosted_cards = []
	c.hosted_on_id = ""
	c.extra_subtypes = []
	c.granted_subtypes_to_host = []
	c.hosted_grip_cards = []
	c.hosted_runner_resources = []
	return c


# ── Counter helpers ───────────────────────────────────────────────────────────

func get_counter(counter_type: String) -> int:
	return counters.get(counter_type, 0)

func add_counter(counter_type: String, amount: int = 1) -> void:
	counters[counter_type] = get_counter(counter_type) + amount

func remove_counter(counter_type: String, amount: int = 1) -> void:
	counters[counter_type] = max(0, get_counter(counter_type) - amount)


# ── Convenience ───────────────────────────────────────────────────────────────

func is_ice() -> bool:
	return zone == "ice"

func is_in_root() -> bool:
	return zone == "root"

func can_be_advanced() -> bool:
	if card_record == null:
		return false
	return card_record.is_agenda() or card_record.text.contains("can be advanced")

func meets_advancement_requirement() -> bool:
	if card_record == null:
		return false
	return get_counter("advancement") >= card_record.advancement_requirement

func display_name() -> String:
	if card_record != null:
		return card_record.title
	return "(%s)" % card_id


# Returns true if this installed card (typically ice) has the given subtype considering
# both its printed subtypes and any dynamically granted extra_subtypes.
func has_effective_subtype(st: String) -> bool:
	var normalized: String = st.to_lower().replace(" ", "_")
	if card_record != null and card_record.subtypes.has(normalized):
		return true
	return extra_subtypes.has(normalized)
