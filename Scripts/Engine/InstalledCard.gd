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

# Game turn number on which this card was installed (Uprising: Penrose).
var installed_turn: int = -1
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
# Corp cards (CardRecord objects) captured during breach and hosted on this runner program.
# Used by Cupellation: spending 1cr during access stores the accessed corp card here instead
# of accessing it normally. Cleared when this program is trashed.
var hosted_corp_cards: Array = []   # Array[CardRecord]
# Parhelion: Matryoshka — when this InstalledCard is hosted on another card,
# tracks whether this copy is face-down (spent as a break payment) or face-up.
# Only meaningful for Matryoshka copies hosted on an installed Matryoshka.
# Reset to false (faceup) at the start of each Runner turn.
var is_facedown: bool = false

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
	c.hosted_corp_cards = []
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
	# NSG uses both phrasings: "can be advanced" (assets/upgrades) and "can advance this" (Logjam-style ice).
	return card_record.is_agenda() \
		or card_record.text.contains("can be advanced") \
		or card_record.text.contains("can advance this")

func meets_advancement_requirement() -> bool:
	if card_record == null:
		return false
	return get_counter("advancement") >= card_record.advancement_requirement

func display_name() -> String:
	if card_record != null:
		return card_record.title
	return "(%s)" % card_id


# Produces a fully independent copy for simulation.
# CardRecord references are shared (CardRecords are immutable data).
# hosted_runner_resources are cloned independently of runner_rig — the sim does not
# maintain cross-list identity between a Hackerspace's hosted list and runner_rig.
func clone() -> InstalledCard:
	var c                          := InstalledCard.new()
	c.card_id                      = card_id
	c.card_record                  = card_record
	c.is_rezzed                    = is_rezzed
	c.is_face_up                   = is_face_up
	c.counters                     = counters.duplicate()
	c.server_id                    = server_id
	c.zone                         = zone
	c.runtime_instance_id          = runtime_instance_id
	c.hosted_on_id                 = hosted_on_id
	c.target_id                    = target_id
	c.extra_subtypes               = extra_subtypes.duplicate()
	c.granted_subtypes_to_host     = granted_subtypes_to_host.duplicate()
	c.faceup_hosted_cards          = faceup_hosted_cards.duplicate()
	c.hosted_grip_cards            = hosted_grip_cards.duplicate()
	c.hosted_cards = []
	for h in hosted_cards:
		c.hosted_cards.append((h as InstalledCard).clone())
	c.hosted_runner_resources = []
	for r in hosted_runner_resources:
		c.hosted_runner_resources.append((r as InstalledCard).clone())
	c.hosted_corp_cards = hosted_corp_cards.duplicate()   # CardRecord refs shared (immutable)
	return c


# Returns true if this installed card (typically ice) has the given subtype considering
# both its printed subtypes and any dynamically granted extra_subtypes.
func has_effective_subtype(st: String) -> bool:
	var normalized: String = st.to_lower().replace(" ", "_")
	if card_record != null and card_record.subtypes.has(normalized):
		return true
	return extra_subtypes.has(normalized)
