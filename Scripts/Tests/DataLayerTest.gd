extends Control

# ── DataLayerTest ─────────────────────────────────────────────────────────────
# Tests the data layer and prints cost/stat diagnostics for deck cards.
# Scene setup: same as before (StatusLabel, FetchButton, TestButton, OutputLabel)

@onready var status_label: Label         = $VBoxContainer/StatusLabel
@onready var fetch_button: Button        = $VBoxContainer/FetchButton
@onready var test_button:  Button        = $VBoxContainer/TestButton
@onready var output_label: RichTextLabel = $VBoxContainer/OutputLabel

var _importer: CardImporter

# Cards to inspect — all cards in both starter decks
const INSPECT_IDS := [
	# Corp
	"luminal_transubstantiation", "offworld_office", "send_a_message",
	"superconducting_hub", "nico_campaign", "urtica_cipher",
	"government_subsidy", "hedge_fund", "predictive_planogram",
	"seamless_launch", "sprint", "manegarm_skunkworks",
	"bran_1_0", "palisade", "whitespace", "ansel_1_0", "tithe",
	# Runner
	"jailbreak", "mutual_favor", "overclock", "sure_gamble",
	"tread_lightly", "vrcation", "conduit", "turbine",
	"cleaver", "unity", "carmen", "leech",
	"daily_casts", "earthrise_hotel", "creative_commission",
]


func _ready() -> void:
	fetch_button.pressed.connect(_on_fetch_pressed)
	test_button.pressed.connect(_on_test_pressed)
	if CardImporter.cache_exists():
		var meta := CardImporter.cache_metadata()
		status_label.text = "Cache: %d cards, fetched %s" % [
			meta.get("card_count", "?"), meta.get("fetched_at", "unknown")
		]
	else:
		status_label.text = "No cache. Fetch first."
	if CardRegistry.is_loaded:
		_log("[color=green]Registry loaded: %d cards[/color]" % CardRegistry.all_cards().size())


func _on_fetch_pressed() -> void:
	fetch_button.disabled = true
	test_button.disabled  = true
	status_label.text     = "Fetching..."
	output_label.clear()
	_importer = CardImporter.new()
	_importer.progress.connect(func(msg): status_label.text = msg)
	_importer.completed.connect(_on_import_completed)
	await _importer.fetch_and_cache()


func _on_import_completed(result: Dictionary) -> void:
	fetch_button.disabled = false
	test_button.disabled  = false
	if result["success"]:
		CardRegistry.reload()
		status_label.text = "Ready. %d cards." % CardRegistry.all_cards().size()
		_log("[color=green]Import successful.[/color]")
	else:
		status_label.text = "Import failed."
		_log("[color=red]%s[/color]" % result["error"])


func _on_test_pressed() -> void:
	output_label.clear()
	if not CardRegistry.is_loaded:
		_log("[color=red]Registry not loaded.[/color]")
		return

	_log("[b]── Registry summary ──[/b]")
	_log("Total: %d  Corp: %d  Runner: %d  Ice: %d  Agendas: %d" % [
		CardRegistry.all_cards().size(),
		CardRegistry.get_corp_cards().size(),
		CardRegistry.get_runner_cards().size(),
		CardRegistry.get_ice().size(),
		CardRegistry.get_agendas().size(),
	])
	_log("")

	_log("[b]── Deck card cost/stat diagnostics ──[/b]")
	_log("%-30s %-6s %-6s %-6s %-8s %s" % ["ID", "cost", "str", "trash", "mem/adv", "type"])
	_log("─".repeat(75))

	var missing: Array = []
	for card_id in INSPECT_IDS:
		var card: CardRecord = CardRegistry.get_card(card_id)
		if card == null:
			missing.append(card_id)
			_log("[color=red]%-30s NOT FOUND[/color]" % card_id)
			continue
		var cost_str   := str(card.cost)   if card.cost   >= 0 else "null"
		var str_str    := str(card.strength) if card.strength >= 0 else "-"
		var trash_str  := str(card.trash_cost) if card.trash_cost >= 0 else "-"
		var extra_str  := ""
		if card.memory_cost >= 0:
			extra_str = "MU:%d" % card.memory_cost
		elif card.advancement_requirement >= 0:
			extra_str = "adv:%d pts:%d" % [card.advancement_requirement, card.agenda_points]
		_log("%-30s %-6s %-6s %-6s %-8s %s" % [
			card_id, cost_str, str_str, trash_str, extra_str, card.card_type
		])

	if not missing.is_empty():
		_log("")
		_log("[color=yellow]Missing (%d): %s[/color]" % [missing.size(), ", ".join(missing)])

	_log("")
	_log("[color=green]Done.[/color]")


func _log(text: String) -> void:
	output_label.append_text(text + "\n")
