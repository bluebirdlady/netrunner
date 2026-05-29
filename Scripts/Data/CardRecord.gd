class_name CardRecord
extends RefCounted

# ── Immutable data record for a single Netrunner card. ────────────────────────
# Populated by CardImporter from NetrunnerDB API v2 JSON.
# No game logic lives here — this is pure data.

# Core identity
var id:          String  # "hedge_fund" — stable slug, used as primary key everywhere
var title:       String  # "Hedge Fund"
var side:        String  # "corp" | "runner"
var faction:     String  # "haas_bioroid" | "jinteki" | "nbn" | "weyland" |
						 # "anarch" | "criminal" | "shaper" |
						 # "neutral_corp" | "neutral_runner" | "mini" etc.
var card_type:   String  # "agenda" | "asset" | "ice" | "operation" | "upgrade" |
						 # "identity" | "event" | "program" | "hardware" | "resource"
var subtypes:    Array   # ["barrier"] | ["sentry", "destroyer"] | [] etc.

# Costs and stats
var cost:                   int   # play/rez cost (-1 = null/variable)
var advancement_requirement:int   # agendas only (-1 = not applicable)
var agenda_points:          int   # agendas only (-1 = not applicable)
var strength:               int   # ice and icebreakers (-1 = null/variable)
var trash_cost:             int   # assets and upgrades (-1 = not trashable)
var memory_cost:            int   # programs only (-1 = not applicable)
var memory_limit:           int   # runner identities only (-1 = not applicable; from card_abilities.mu_provided)
var base_link:              int   # runner identities only (-1 = not applicable)

# Deckbuilding
var influence_cost:     int   # 0 = in-faction or identity
var influence_limit:    int   # identities only (-1 = unlimited, e.g. mini-factions)
var minimum_deck_size:  int   # identities only (-1 = not applicable)
var deck_limit:         int   # usually 3; some are 1 (e.g. Government Takeover)

# Text
var text:         String  # raw text with [credit] [click] markup
var stripped_text:String  # plain text with symbols replaced by words
var flavor_text:  String  # italic lore text (not always present)

# Set membership — v3 API "card_set_ids" attribute, e.g. ["system_gateway"], ["elevation"]
var card_set_ids: Array = []

# Flags
var is_unique:    bool    # black diamond next to title

# Art
var printing_id:  String  # first printing id — used to construct image URL
var image_url:    String  # constructed: https://card-images.netrunnerdb.com/v1/large/{printing_id}.jpg


# ── Constructor ───────────────────────────────────────────────────────────────

static func from_api_data(data: Dictionary) -> CardRecord:
	var r := CardRecord.new()
	# v3: id is top-level, everything else under "attributes"
	# v2: everything is flat with "code" as the id
	var attrs: Dictionary = data.get("attributes", data) as Dictionary

	# id: v3 has slug at top level, v2 has numeric "code"
	# Normalize to underscore form so abilities.json and deck lists can use
	# stable human-readable keys regardless of API version.
	# v3 slugs are hyphenated ("hedge-fund"), v2 codes are numeric ("30064").
	# We convert hyphens → underscores; numeric codes are left as-is (they
	# won't match any ability definition, but they'll still load as CardRecords).
	var raw_id: String = data.get("id", data.get("code", ""))
	r.id = raw_id.replace("-", "_")
	r.title        = attrs.get("title", "")
	r.side         = attrs.get("side_code", attrs.get("side_id", ""))
	r.faction      = attrs.get("faction_code", attrs.get("faction_id", ""))
	var raw_type: String = attrs.get("type_code", attrs.get("card_type_id", ""))
	# v3 API prefixes types with faction: "corp_agenda" → "agenda", "runner_program" → "program"
	# Strip the prefix so is_agenda(), is_ice() etc. work correctly.
	for prefix in ["corp_", "runner_"]:
		if raw_type.begins_with(prefix):
			raw_type = raw_type.substr(prefix.length())
			break
	r.card_type = raw_type

	# Subtypes: v2 uses "keywords" string "Barrier - Destroyer", v3 uses "card_subtype_ids" array
	var keywords: String = attrs.get("keywords", "")
	if keywords != "":
		r.subtypes = Array(keywords.split(" - ")).map(func(s): return s.to_lower().replace(" ", "_"))
	else:
		r.subtypes = attrs.get("card_subtype_ids", [])

	r.cost                    = _int_or(attrs.get("cost", null), -1)
	r.advancement_requirement = _int_or(attrs.get("advancement_cost", attrs.get("advancement_requirement", null)), -1)
	r.agenda_points           = _int_or(attrs.get("agenda_points", null), -1)
	r.strength                = _int_or(attrs.get("strength", null), -1)
	r.trash_cost              = _int_or(attrs.get("trash_cost", null), -1)
	r.memory_cost             = _int_or(attrs.get("memory_cost", null), -1)
	# Identity memory limit lives under card_abilities.mu_provided in v3 API
	var card_abilities: Dictionary = attrs.get("card_abilities", {}) as Dictionary
	r.memory_limit            = _int_or(card_abilities.get("mu_provided", null), -1)
	r.base_link               = _int_or(attrs.get("base_link", null), -1)

	r.influence_cost    = _int_or(attrs.get("faction_cost", attrs.get("influence_cost", null)), 0)
	r.influence_limit   = _int_or(attrs.get("influence_limit", null), -1)
	r.minimum_deck_size = _int_or(attrs.get("minimum_deck_size", null), -1)
	r.deck_limit        = _int_or(attrs.get("deck_limit", null), 3)

	r.text         = attrs.get("text", "") if attrs.get("text", null) != null else ""
	r.stripped_text= attrs.get("stripped_text", "") if attrs.get("stripped_text", null) != null else ""
	r.flavor_text  = attrs.get("flavor_text", "") if attrs.get("flavor_text", null) != null else ""

	r.is_unique    = attrs.get("uniqueness", attrs.get("is_unique", false))
	r.card_set_ids = attrs.get("card_set_ids", [])

	# Printing id for image URL
	# v3: first entry of "printing_ids" array
	# v2: "code" is the printing id
	var printing_ids: Array = attrs.get("printing_ids", []) as Array
	r.printing_id = printing_ids[0] if not printing_ids.is_empty() else r.id
	r.image_url   = "https://card-images.netrunnerdb.com/v1/large/%s.jpg" % r.printing_id

	return r


# ── Helpers ───────────────────────────────────────────────────────────────────

static func _int_or(value, default_value: int) -> int:
	if value == null:
		return default_value
	return int(value)


# ── Convenience queries ───────────────────────────────────────────────────────

func is_corp() -> bool:
	return side == "corp"

func is_runner() -> bool:
	return side == "runner"

func is_ice() -> bool:
	return card_type == "ice"

func is_agenda() -> bool:
	return card_type == "agenda"

func is_asset() -> bool:
	return card_type == "asset"

func is_identity() -> bool:
	return card_type == "identity" or card_type == "corp_identity" or card_type == "runner_identity"

func has_subtype(subtype: String) -> bool:
	return subtypes.has(subtype.to_lower().replace(" ", "_"))

func has_trash_cost() -> bool:
	return trash_cost >= 0

func has_strength() -> bool:
	return strength >= 0

func display_cost() -> String:
	if cost < 0:
		return "X"
	return str(cost)

func display_strength() -> String:
	if strength < 0:
		return "X"
	return str(strength)
