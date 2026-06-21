extends Node

# ── AICoverageAuditor ─────────────────────────────────────────────────────────
# Audits AI coverage for all cards in a set CSV file and writes a summary CSV.
#
# Usage:
#   godot --headless res://Scenes/CoverageAuditor.tscn -- <input.csv> <output.csv>
#
# Paths can be:
#   res://Sets/system_gateway.csv   (Godot resource path)
#   Sets/system_gateway.csv         (relative — resolved to res://)
#   C:/path/to/file.csv             (absolute)
#
# Defaults when no args given:
#   input  : res://Sets/system_gateway.csv
#   output : res://coverage_output.csv
#
# Coverage categories
# ─────────────────────────────────────────────────────────────────────────────
# Runner events:
#   Auto (full)     — AbilityRegistry.get_ai_projection() complete=true
#   Auto+Hint       — partial auto-projection supplemented by AiCardHints entry
#   Auto (partial)  — partial auto-projection, no hint
#   Hint            — modeled exclusively via AiCardHints
#   Legacy          — old hardcoded dict only; not yet in projection pipeline
#   Ignored         — no projection, no hint; never offered as a candidate
#
# Corp operations:
#   Explicit        — hardcoded case in project_corp_action match block
#   Explicit+Auto   — hardcoded AND also auto-derivable (redundant, no harm)
#   Auto (full)     — get_corp_ai_projection() complete=true
#   Auto (partial)  — partial auto-projection
#   Archives Op     — handled by play_from_archives branch
#   Stubbed         — none of the above; falls back to +2cr heuristic
#
# Other types:
#   Installable         — install/advance/score handled; no play-effect modeled
#   Installable+Click   — asset with click ability tracked in Corp snap
#   Identity            — identity abilities partially modeled in evaluator
# ─────────────────────────────────────────────────────────────────────────────

const AiCardHints = preload("res://Scripts/AI/AiCardHints.gd")

# ── Static coverage tables ────────────────────────────────────────────────────

# Corp operations with explicit projection in project_corp_action's match block.
const EXPLICIT_CORP_OPS: Array = [
	"hedge_fund", "government_subsidy", "predictive_planogram",
	"hansei_review", "spin_doctor",
	"neurospike", "ip_enforcement", "retribution", "bigger_picture",
	"boom", "scorched_earth", "punitive_counterstrike",
	"end_of_the_line", "distributed_tracing", "shipment_from_vladisibirsk",
	"hypoxia", "nonequivalent_exchange", "simulation_reset",
	"big_deal",
	"touch_ups",
	"flood_the_market",
	"sprint",
	"vulture_fund",
	"corporate_hospitality",
	"mitosis",
	"business_as_usual",
	"nanomanagement",
	"your_digital_life",
	"fully_operational",
	"oppo_research",
	"backroom_machinations",
	"complete_image",
	"measured_response",
	"bring_them_home",
	"public_trail",
	"scapenet",
	"trust_operation",
	"scapegoat",
	"realloc",
	"caveat_emptor",
	"active_policing",
	"game_over",
	"napd_cordon",
	"sync_rerouting",
	"next_activation_command",
	"argus_crackdown",
	"hyoubu_precog_manifold",
	"cultivate",
	"digital_rights_management",
	"retirement_plan",
	"reanimation_protocol",
	"secure_and_protect",
	"pivot",
	"myoshu",
	"kakurenbo",
	"focus_group",
	"mutually_assured_destruction",
	"unleash",
]

# Corp operations handled by the play_from_archives branch.
const CORP_ARCHIVES_OPS: Array = ["petty_cash"]

# Runner events still in the old hardcoded dicts in RunnerCandidateGenerator
# (legacy path; only reached when no projection and no hint exists).
const LEGACY_ECONOMY: Array = [
	"sure_gamble", "hedge_fund", "lucky_find", "bravado", "creative_commission",
]
const LEGACY_DRAW: Array = ["diesel", "quality_time"]
const LEGACY_RUN: Array  = [
	"legwork", "wanton_destruction", "the_makers_eye", "dirty_laundry",
]


# ── Entry point ───────────────────────────────────────────────────────────────

func _ready() -> void:
	var args: Array = OS.get_cmdline_user_args()
	var raw_in:  String = args[0] if args.size() >= 1 else "Sets/system_gateway.csv"
	var raw_out: String = args[1] if args.size() >= 2 else "coverage_output.csv"

	var input_path:  String = _resolve_path(raw_in)
	var output_path: String = _resolve_path(raw_out)

	print("AICoverageAuditor: reading  %s" % input_path)
	print("AICoverageAuditor: writing  %s" % output_path)

	var ab_reg := AbilityRegistry.new()
	ab_reg.load_from_file("res://Data/abilities.json")

	var cards: Array = _read_set_csv(input_path)
	if cards.is_empty():
		push_error("AICoverageAuditor: no cards loaded from %s" % input_path)
		get_tree().quit(1)
		return

	var rows: Array = []
	rows.append(["Name", "ID", "Type", "Side", "Coverage", "Notes"])

	for entry in cards:
		var card_id:   String = entry["id"]
		var card_name: String = entry["name"]

		var card: CardRecord = CardRegistry.get_card(card_id)
		if card == null:
			rows.append([card_name, card_id, "?", "?", "Unknown", "Not found in CardRegistry"])
			continue

		var result: Dictionary = _check_coverage(card, ab_reg)
		rows.append([
			card.title,
			card.id,
			card.card_type,
			card.side,
			result["status"],
			result["notes"],
		])

	_write_csv(output_path, rows)

	# Summary statistics
	var totals: Dictionary = {}
	for row in rows.slice(1):
		var status: String = row[4]
		totals[status] = (totals.get(status, 0) as int) + 1
	print("\nAICoverageAuditor: %d cards processed" % cards.size())
	var sorted_keys: Array = totals.keys()
	sorted_keys.sort()
	for k in sorted_keys:
		print("  %-22s %d" % [k + ":", totals[k]])

	get_tree().quit()


# ── Coverage dispatch ─────────────────────────────────────────────────────────

func _check_coverage(card: CardRecord, ab_reg: AbilityRegistry) -> Dictionary:
	match card.card_type:
		"event":
			return _check_runner_event(card.id, ab_reg)
		"operation":
			return _check_corp_operation(card.id, ab_reg)
		"program":
			return {"status": "Installable", "notes": "Runner install AI handles selection and MU tracking"}
		"hardware":
			return {"status": "Installable", "notes": "Runner install AI handles selection"}
		"resource":
			return {"status": "Installable", "notes": "Runner install AI handles selection"}
		"ice":
			return {"status": "Installable", "notes": "SCG installs; CorpRunAI handles encounters; subtype tracked in snap"}
		"asset":
			if _has_click_ability(card.id, ab_reg):
				return {"status": "Installable+Click", "notes": "SCG installs; click ability detected and offered in snap"}
			return {"status": "Installable", "notes": "SCG installs; no modeled click ability"}
		"upgrade":
			return {"status": "Installable", "notes": "SCG installs; defensive value approximated in evaluate()"}
		"agenda":
			return {"status": "Installable", "notes": "SCG installs, advances, scores; on-score effects not projected"}
		"identity":
			return {"status": "Identity", "notes": "Identity abilities partially modeled in evaluator match block"}
		_:
			return {"status": "Unknown", "notes": "Unrecognised card_type: " + card.card_type}


func _check_runner_event(card_id: String, ab_reg: AbilityRegistry) -> Dictionary:
	var proj: Variant  = ab_reg.get_ai_projection(card_id)
	var has_hint: bool = AiCardHints.has_hint(card_id)
	var in_legacy: bool = (card_id in LEGACY_ECONOMY) \
		or (card_id in LEGACY_DRAW) \
		or (card_id in LEGACY_RUN)

	if proj != null:
		var p: Dictionary  = proj as Dictionary
		var complete: bool = p.get("complete", false) as bool
		if complete:
			if has_hint:
				return {
					"status": "Auto (full)+Hint",
					"notes":  "Complete auto-projection; hint adds conditions/value_bonus",
				}
			return {
				"status": "Auto (full)",
				"notes":  "Complete projection auto-derived from abilities.json",
			}
		else:
			if has_hint:
				return {
					"status": "Auto+Hint",
					"notes":  "Partial auto-projection (complex effects) supplemented by AiCardHints",
				}
			return {
				"status": "Auto (partial)",
				"notes":  "Partial auto-projection; unmodelable effects not captured",
			}

	if has_hint:
		return {
			"status": "Hint",
			"notes":  "Fully modeled via AiCardHints snap_delta + conditions",
		}

	if in_legacy:
		var which: String = "ECONOMY_NET" if card_id in LEGACY_ECONOMY \
			else ("DRAW_NET" if card_id in LEGACY_DRAW else "RUN_EVENT_SERVER")
		return {
			"status": "Legacy",
			"notes":  "Old hardcoded %s dict; no projection or hint entry" % which,
		}

	return {
		"status": "Ignored",
		"notes":  "No projection, no hint — not offered as a candidate by _add_events()",
	}


func _check_corp_operation(card_id: String, ab_reg: AbilityRegistry) -> Dictionary:
	if card_id in CORP_ARCHIVES_OPS:
		return {
			"status": "Archives Op",
			"notes":  "Handled by play_from_archives branch (e.g. Petty Cash)",
		}

	var in_explicit: bool = card_id in EXPLICIT_CORP_OPS
	var proj: Variant     = ab_reg.get_corp_ai_projection(card_id)
	var proj_complete: bool = false
	var proj_partial:  bool = false
	if proj != null:
		var p: Dictionary = proj as Dictionary
		if p.get("complete", false) as bool:
			proj_complete = true
		else:
			proj_partial  = true

	if in_explicit:
		if proj_complete or proj_partial:
			return {
				"status": "Explicit+Auto",
				"notes":  "Hardcoded projection in match block; also auto-derivable (redundant, no conflict)",
			}
		return {
			"status": "Explicit",
			"notes":  "Specific projection in project_corp_action match block",
		}

	if proj_complete:
		return {
			"status": "Auto (full)",
			"notes":  "Complete projection auto-derived from abilities.json via get_corp_ai_projection()",
		}

	if proj_partial:
		return {
			"status": "Auto (partial)",
			"notes":  "Partial auto-projection; complex effects not captured",
		}

	return {
		"status": "Stubbed",
		"notes":  "No explicit case and no auto-projection; falls back to generic +2cr heuristic",
	}


# ── Helpers ───────────────────────────────────────────────────────────────────

func _has_click_ability(card_id: String, ab_reg: AbilityRegistry) -> bool:
	var abilities: Dictionary = ab_reg._abilities
	if not abilities.has(card_id):
		return false
	return (abilities[card_id] as Dictionary).has("click_action")


func _resolve_path(raw: String) -> String:
	if raw.begins_with("res://") or raw.begins_with("user://"):
		return raw
	if raw.is_absolute_path():
		return raw
	return "res://" + raw


func _read_set_csv(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_error("AICoverageAuditor: file not found: %s" % path)
		return []

	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("AICoverageAuditor: cannot open: %s (error %d)" % [path, FileAccess.get_open_error()])
		return []

	var result: Array = []
	var header := true
	while not f.eof_reached():
		var row: PackedStringArray = f.get_csv_line()
		# get_csv_line returns [""] on an empty line at EOF
		if row.size() < 3 or (row.size() == 1 and row[0] == ""):
			continue
		if header:
			header = false
			continue   # skip header row
		# CSV columns: index, text_code, name, text
		result.append({"id": row[1], "name": row[2]})
	f.close()
	return result


func _write_csv(path: String, rows: Array) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("AICoverageAuditor: cannot write: %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	for row in rows:
		var cells: Array[String] = []
		for cell in row:
			var s: String = str(cell).replace('"', '""')
			cells.append('"%s"' % s)
		f.store_line(",".join(cells))
	f.close()
