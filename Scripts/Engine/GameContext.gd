class_name GameContext
extends RefCounted

# ── GameContext ───────────────────────────────────────────────────────────────
# Owns all mutable game state. The AbilityInterpreter and RunStateMachine
# read and write this object. The game engine syncs it to the UI after
# each state change.

# ── Credits ───────────────────────────────────────────────────────────────────
var corp_credits:   int = 5
var runner_credits: int = 5

# ── Tags and bad publicity ────────────────────────────────────────────────────
var runner_tags:    int = 0
var corp_bad_pub:   int = 0

# ── Click tracking ────────────────────────────────────────────────────────────
var corp_clicks:    int = 0
var runner_clicks:  int = 0

# ── Decision-makers────────────────────────────────────────────────────────────
var corp_decision_maker:  Object = null
var runner_decision_maker:  Object = null

# ── Hands ─────────────────────────────────────────────────────────────────────
# Each entry: {"card_id": String, "card_record": CardRecord}
var corp_hand:   Array = []
var runner_hand: Array = []   # runner's "grip"

# ── Decks ─────────────────────────────────────────────────────────────────────
var corp_deck: Array[CardRecord] = []
var runner_deck: Array[CardRecord] = []
var corp_discard: Array[CardRecord] = []
var runner_discard: Array[CardRecord] = []
# Remove-from-game zone: cards sent here by effects like Plutus can never be accessed.
var corp_rfg: Array[CardRecord] = []
# Runner remove-from-game zone. Events that say "remove this event from the game" land here.
var runner_rfg: Array = []   # Array[CardRecord]
# Cards in Archives that were installed unrezzed when trashed — facedown until accessed.
var corp_discard_facedown: Dictionary = {}
# Instance IDs of cards the Corp installed this turn (for Seamless Launch restriction)
var corp_installed_this_turn: Array = []

# ── Score areas ───────────────────────────────────────────────────────────────
var corp_score_area: Array[CardRecord] = []
# Parallel array to corp_score_area — stores the InstalledCard objects so Dividends
# abilities can read/write counters on scored agendas after they leave the server.
var corp_score_area_cards: Array = []   # Array[InstalledCard]
var runner_score_area: Array[CardRecord] = []
# Parallel array to runner_score_area — InstalledCard objects so agendas with Corp
# click actions (e.g. Next Big Thing) can store and spend counters after being stolen.
var runner_score_area_cards: Array = []   # Array[InstalledCard]

# ── Servers ───────────────────────────────────────────────────────────────────
var servers: Dictionary = {}

# ── Runner rig ────────────────────────────────────────────────────────────────
var runner_rig: Array = []   # Array[InstalledCard]

# ── Deferred modifiers ───────────────────────────────────────────────────────
# Click penalties applied at the start of the next turn.
# Keys: "corp" | "runner", values: int (clicks to subtract)
var pending_click_penalties: Dictionary = {"corp": 0, "runner": 0}
# Click bonuses applied at the start of the next turn (e.g. Aggressive Trendsetting).
# Keys: "corp" | "runner", values: int (clicks to add)
var pending_click_bonuses: Dictionary = {"corp": 0, "runner": 0}

# ── Run state ─────────────────────────────────────────────────────────────────
var run_active:         bool   = false
var run_ended:          bool   = false
var run_successful:     bool   = false
var run_target_server:  String = ""
var accessed_card_id:   String = ""
# Tracks whether the runner has made a successful run this turn.
# Used by conditional install costs (e.g. Carmen: costs 3 instead of 5).
# Cleared at the start of each runner turn.
var runner_made_successful_run_this_turn: bool = false
# Tracks whether the runner made a successful run during their previous turn.
# Saved at the start of each Corp turn, used by Public Trail's play condition.
var runner_made_successful_run_last_turn: bool = false
# Tracks whether the runner stole an agenda during the current run.
# Set in RunStateMachine._steal_agenda; cleared at the start of each run.
# Used by AMAZE Amusements run_end trigger.
var runner_stole_agenda_this_run: bool = false
# NBN: Reality Plus — once per turn the Corp gains 2 cr or draws 2 cards when the
# Runner takes a tag. Cleared at the start of each Corp turn.
var corp_used_reality_plus_this_turn: bool = false
# Tracks which central server IDs the runner has already attempted this turn.
# Used by Red Team to enforce "a central you have not already run this turn".
# Cleared at the start of each runner turn.
var runner_centrals_run_this_turn: Array = []
# Tracks how many times the runner has used click-draw this turn (for Verbal Plasticity)
var runner_click_draws_this_turn: int = 0
# Tracks which cards have already fired their "first HQ breach" bonus this turn (Docklands Pass)
var runner_hq_breached_this_turn: bool = false
# Tracks whether runner has already trashed during a breach this turn (Loup trigger guard)
var runner_trashed_during_breach_this_turn: bool = false
# Tracks whether DZMZ Optimizer discount has been used this turn
var runner_program_install_discounted_this_turn: bool = false
# Tracks whether Carnivore has been used this turn (once per turn)
var runner_carnivore_used_this_turn: bool = false
# Tracks whether Corp has already gained Built-to-Last advance credits this turn
var corp_gained_advance_credits_this_turn: bool = false
# Petty Cash: tracks whether the Corp has completed at least one click action this turn.
# Reset at the start of each Corp turn.  Petty Cash can only be played when this is false.
var corp_finished_an_action_this_turn: bool = false
# Set by TurnManager around on_play/on_steal execution to indicate where the operation
# originated.  Values: "hq" | "archives" | "".  Used by Petty Cash to decide whether
# to grant a bonus click.
var current_operation_play_source: String = ""
# Remove-from-game zone.  Cards placed here are out of the game permanently.
var corp_removed_from_game: Array = []   # Array[CardRecord]
# Tracks whether Corp discarded to hand limit last turn (Restoring Humanity)
var corp_discarded_to_hand_limit_last_turn: bool = false
# Agenda points on the last agenda the Corp scored this turn (0 if none yet).
# Used by Neurospike to determine both play legality and damage amount.
# Cleared at the start of each Corp turn.
var corp_last_scored_agenda_points: int = 0
# Counts agendas scored this Corp turn. Used to gate "first agenda" triggers.
var corp_agendas_scored_this_turn: int = 0
# Run modifiers: set by run-initiating events, cleared when the run ends.
# Supported keys:
#   "extra_rez_cost"    : int — Corp pays extra to rez ice (Tread Lightly)
#   "bonus_access"      : int — Runner accesses extra cards on breach (Jailbreak, Conduit)
#   "icebreaker_credits": int — Credits usable only on icebreakers this run (Overclock)
var run_modifiers: Dictionary = {}
# Identity flip state — overrides the CardRecord title when a flip-identity is on its
# secondary face.  Empty string = primary face (use CardRecord title normally).
var runner_identity_face_title: String = ""
var corp_identity_face_title:   String = ""
# Tracks whether the Corp played at least one operation this turn (for Nebula Making Stars).
# Cleared at the start of each Corp turn.
var corp_played_operation_this_turn: bool = false
# Tracks card IDs accessed during an Archives breach this run (for Charm Offensive).
# Cleared at the start of each run by RunStateMachine.execute().
var run_accessed_archives_card_ids: Array = []
# Tracks whether the runner has made a successful run on HQ this turn (for Détente).
# Cleared at the start of each runner turn.
var runner_hq_successful_run_this_turn: bool = false
# Tracks whether the runner made a successful run on R&D this turn (VP1 Chain Reaction).
# Cleared at the start of each runner turn.
var runner_successful_run_on_rd_this_turn: bool = false
# Tracks whether the runner made a successful run on Archives this turn (VP1 Chain Reaction).
# Cleared at the start of each runner turn.
var runner_successful_run_on_archives_this_turn: bool = false
# Accumulated icebreaker strength boosts that persist for the current run (GAMEDRAGON Pro).
# Keys: icebreaker runtime_instance_id → total accumulated boost.
# Cleared at the start of each run by RunStateMachine.execute().
var run_level_strength_boosts: Dictionary = {}
# Tracks whether at least one subroutine resolved during the current run (Ryo "Phoenix" Ōno).
# Cleared at the start of each run by RunStateMachine.execute().
var run_had_subroutine_resolve: bool = false
# Prevents the runner from stealing or trashing cards during this run (VP31 Vertigo).
# Set by Vertigo's pass_ice trigger; cleared at the start of each run.
var runner_cannot_steal_or_trash_this_run: bool = false
# Global ICE strength bonus applied to all ice encountered this run (VP39 ezaM sub 2).
# Cleared at the start of each run.
var global_ice_strength_bonus_this_run: int = 0
# Instance ID of the program installed by Beta Build (VP19) this run.
# RSM reads this at run end to return the card to the top of the runner's deck.
# Cleared at the start of each run.
var beta_build_installed_card_id: String = ""
# Card IDs the Runner cannot steal or trash during this run (VP35 Perfect Recall).
# Populated by Perfect Recall paw_action; cleared at the start of each run.
var runner_steal_trash_blocked_card_ids: Array = []
# VP64 Flagship: when set, _phase_success() runs the breach but skips run_successful
# and the successful_run event.  Cleared at the start of each run.
var run_success_suppressed: bool = false
# VP65 Shackleton Grid: credits spent from outside the runner's own pool (stealth,
# Overclock, recurring) in the current action.  Set by spend helpers; checked and
# reset by async callers to fire runner_spends_outside_credits event.
var runner_outside_credits_spent_pending: int = 0
# VP36 Méliès U: which central server the Corp secretly predicted ("hq", "rd", "archives").
# Set by corp_secretly_select_melies_side at corp_discard_phase_ends; read by flip_melies_u.
# Empty string means no prediction has been made yet (before Corp's first discard phase).
var melies_u_secret_side: String = ""
# VP36 Méliès U: true when the identity is on its back side (any of the three flip faces).
# Set by flip_melies_u on successful_run; cleared by flip_melies_u_back at runner_discard_phase_ends.
var melies_u_flipped: bool = false
# Tracks whether the Corp rezzed at least one piece of ice this turn (VP16 Underdome Irregulars).
# Cleared at the start of each Corp turn.
var ice_rezzed_this_turn: bool = false
# Tracks how many double operations the Corp has played this turn (VP27 Synchrocyclotron).
# Cleared at the start of each Corp turn.
var doubles_played_this_turn: int = 0
# Tracks whether the Runner stole an agenda this turn (VP55 Hype Machine rez discount).
# Cleared at the start of each player's turn.
var runner_stole_agenda_this_turn: bool = false
# True when the Corp scored an agenda this turn that was NOT installed this turn.
# Checked by VP61 Myōshu play condition.  Cleared at the start of each Corp turn.
var corp_scored_agenda_not_installed_this_turn: bool = false

# Transient event payload accessible by the AbilityInterpreter during execution
var current_event_data: Dictionary = {}

# Set by TurnManager to the card_type of the card whose ability is currently executing.
# Used by AbilityInterpreter to tag Corp credit gains as "from an agenda/operation ability"
# so The Zwicky Group's trigger can fire correctly.  Values: "operation", "agenda", or "".
var current_ability_source_card_type: String = ""

# Once-per-turn trigger guard.
# Key: "<card_instance_id>:<once_per_turn_key>" → true when this trigger has already
# fired this turn.  Cleared at the start of each player's turn by TurnManager.
# Enables the JSON "once_per_turn_key" field on event blocks.
var once_per_turn_triggered: Dictionary = {}

# ── Game state ────────────────────────────────────────────────────────────────
var turn_number:   int    = 1


# Hand size modifiers — adjusted by scored agendas, installed cards, etc.
var corp_hand_size_bonus:   int = 0   # added to base of 5
var runner_hand_size_bonus: int = 0   # added to base of 5
# Core damage permanently reduces the runner's maximum hand size by 1 per point.
# Flatline occurs if runner_max_hand_size() drops below 0.
var runner_core_damage_taken: int = 0
var active_player:   String = "corp"
var game_over:       bool   = false
var winner:          String = ""
# Set to true on contexts produced by clone_for_sim().
# Used by TurnManager and GameContext to suppress UI signals and frame waits.
var simulation_mode: bool   = false

# ── Identities ────────────────────────────────────────────────────────────────
var corp_identity:   CardRecord = null
var runner_identity: CardRecord = null
# Counter storage for identity cards (bare CardRecord, not InstalledCard).
# Keys: counter type ("power" etc.) → int count.
var corp_identity_counters:   Dictionary = {}
var runner_identity_counters: Dictionary = {}

# Convenience helpers — return the short name from the identity title,
# or a generic fallback if no identity is set.
# Identity titles are typically "Faction: Short Name", e.g.
# "Haas-Bioroid: Precision Design" → "Precision Design"
# "The Catalyst: Convention Breaker" → "The Catalyst"
func corp_name() -> String:
	var title: String
	if corp_identity_face_title != "":
		title = corp_identity_face_title
	elif corp_identity != null:
		title = corp_identity.title
	else:
		return "Corp"
	var colon: int = title.find(": ")
	return title.substr(colon + 2) if colon >= 0 else title

func runner_name() -> String:
	var title: String
	if runner_identity_face_title != "":
		title = runner_identity_face_title
	elif runner_identity != null:
		title = runner_identity.title
	else:
		return "Runner"
	var colon: int = title.find(": ")
	return title.substr(colon + 2) if colon >= 0 else title

func player_name(player: String) -> String:
	return corp_name() if player == "corp" else runner_name()

# ── Faceup hosting helpers ────────────────────────────────────────────────────

# Returns all faceup-hosted CardRecords across all runner rig cards,
# wrapped as hand-entry Dicts with an extra "hosted_on" key pointing to the
# hosting InstalledCard's runtime_instance_id.  Used by effects that treat
# hosted cards "as if they were in the grip."
func get_runner_effective_hand() -> Array:
	var result: Array = runner_hand.duplicate()
	for rig_c in runner_rig:
		var ic: InstalledCard = rig_c as InstalledCard
		if ic == null or ic.faceup_hosted_cards.is_empty():
			continue
		for hosted_cr in ic.faceup_hosted_cards:
			var cr: CardRecord = hosted_cr as CardRecord
			if cr == null:
				continue
			result.append({"card_id": cr.id, "card_record": cr, "hosted_on": ic.runtime_instance_id})
	return result


# Remove a CardRecord from either the runner_hand or faceup_hosted_cards of
# any rig card.  Prefers hand; falls back to hosted.
func remove_from_runner_effective_hand(record: CardRecord) -> void:
	for i in range(runner_hand.size()):
		var entry: Dictionary = runner_hand[i] as Dictionary
		if entry.get("card_id", "") == record.id:
			runner_hand.remove_at(i)
			return
	for rig_c in runner_rig:
		var ic: InstalledCard = rig_c as InstalledCard
		if ic == null:
			continue
		for i in range(ic.faceup_hosted_cards.size()):
			var cr: CardRecord = ic.faceup_hosted_cards[i] as CardRecord
			if cr != null and cr.id == record.id:
				ic.faceup_hosted_cards.remove_at(i)
				return


# ── GAMEDRAGON Pro helpers ────────────────────────────────────────────────────

# Returns true if at least one GAMEDRAGON Pro in the rig is attached to this breaker.
func has_gamedragon_attached(breaker: InstalledCard) -> bool:
	for rig_c in runner_rig:
		var ic: InstalledCard = rig_c as InstalledCard
		if ic != null and ic.card_id == "gamedragon_pro" \
				and ic.hosted_on_id == breaker.runtime_instance_id:
			return true
	return false


# Returns the total +strength bonus granted to a breaker by attached GAMEDRAGON Pros.
func gamedragon_breaker_bonus(breaker: InstalledCard) -> int:
	var bonus := 0
	for rig_c in runner_rig:
		var ic: InstalledCard = rig_c as InstalledCard
		if ic != null and ic.card_id == "gamedragon_pro" \
				and ic.hosted_on_id == breaker.runtime_instance_id:
			bonus += 1
	return bonus


# Returns the run-level accumulated strength boost for a specific icebreaker.
func get_run_level_boost(breaker_instance_id: String) -> int:
	return run_level_strength_boosts.get(breaker_instance_id, 0)


# ── Memory Unit tracking ───────────────────────────────────────────────────────

# Base MU from runner identity (default 4 per rules if identity has none set)
func runner_base_mu() -> int:
	if runner_identity != null and runner_identity.memory_limit > 0:
		return runner_identity.memory_limit
	return 4   # default per rules

# Additional MU granted by installed hardware/resources (e.g. Pennyshaver +1)
func runner_mu_bonus() -> int:
	var bonus := 0
	for mod in _state_modifiers.get("mu_bonus", []):
		bonus += (mod as Dictionary).get("value", 0) as int
	return bonus

# Total MU the runner has available
func runner_total_mu() -> int:
	return runner_base_mu() + runner_mu_bonus()

# MU currently consumed by installed programs (including those hosted on ice)
func runner_mu_used() -> int:
	var used := 0
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c != null and c.card_record != null and c.card_record.memory_cost > 0:
			used += c.card_record.memory_cost
	# Also count programs hosted on ice
	for server in servers.values():
		for ice in (server as Server).ice:
			for hosted in (ice as InstalledCard).hosted_cards:
				var h: InstalledCard = hosted as InstalledCard
				if h != null and h.card_record != null and h.card_record.memory_cost > 0:
					used += h.card_record.memory_cost
	return used

# MU still available for programs
func runner_mu_available() -> int:
	return runner_total_mu() - runner_mu_used()

func runner_link_bonus() -> int:
	var bonus := 0
	for mod in _state_modifiers.get("link_bonus", []):
		bonus += (mod as Dictionary).get("value", 0) as int
	return bonus

func runner_total_link() -> int:
	var base: int = runner_identity.base_link if runner_identity != null and runner_identity.base_link >= 0 else 0
	return base + runner_link_bonus()

# Set by TurnManager at game start based on identities (6 for starters, 7 otherwise)
var agenda_points_to_win: int = 7

# ── Event log ─────────────────────────────────────────────────────────────────
var event_log: Array = []

# Holds active structural events. Format: {"event_name": Array[Dictionary]}
var _event_listeners: Dictionary = {}

# Holds constant environmental modifications. Format: {"modifier_type": Array[Dictionary]}
var _state_modifiers: Dictionary = {}


# ── Initialisation ────────────────────────────────────────────────────────────

func _init() -> void:
	for id in ["hq", "rd", "archives"]:
		servers[id] = Server.make(id)


# ── Server management ─────────────────────────────────────────────────────────

func get_server(server_id: String) -> Server:
	return servers.get(server_id, null)

func remove_meta_if_exists(key: String) -> void:
	if has_meta(key):
		remove_meta(key)

# Returns all programs available during an encounter with a specific ice:
# the normal rig PLUS any programs hosted on that ice (Botulus, Tranquilizer).
func all_programs_for_encounter(ice_card: InstalledCard) -> Array:
	var result: Array = runner_rig.duplicate()
	if ice_card != null:
		for hosted in ice_card.hosted_cards:
			if not result.has(hosted):
				result.append(hosted)
	return result

# Find a piece of ice anywhere in the Corp's servers by instance_id.
func get_ice_by_instance_id(instance_id: String) -> InstalledCard:
	for server in servers.values():
		var s: Server = server as Server
		for ice in s.ice:
			var c: InstalledCard = ice as InstalledCard
			if c.runtime_instance_id == instance_id:
				return c
	return null

func create_remote_server() -> Server:
	var idx := 0
	while servers.has("remote_%d" % idx):
		idx += 1
	var id     := "remote_%d" % idx
	var server := Server.make(id)
	servers[id] = server
	return server

func get_remote_servers() -> Array:
	var result: Array = []
	for key in servers:
		if (servers[key] as Server).is_remote():
			result.append(servers[key])
	return result

func remove_empty_remote_servers() -> void:
	var to_remove: Array = []
	for key in servers:
		var s: Server = servers[key] as Server
		if s.is_remote() and s.is_empty():
			to_remove.append(key)
	for key in to_remove:
		servers.erase(key)


# ── Installed card queries ────────────────────────────────────────────────────

func all_installed() -> Array:
	var result: Array = []
	for server in servers.values():
		var s: Server = server as Server
		result.append_array(s.ice)
		result.append_array(s.root)
	return result

func get_runner_installed_by_type(card_type: String) -> Array:
	return runner_rig.filter(func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == card_type)

# Query by static database card slug (e.g. "sure-gamble", "tollbooth")
func get_installed_card_by_id(card_id: String) -> InstalledCard:
	for card in all_installed():
		var c: InstalledCard = card as InstalledCard
		if c.card_id == card_id:
			return c
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c.card_id == card_id:
			return c
	return null

# Query by unique engine board instance id (e.g. "ice_1749204")
func get_installed_card_by_instance_id(instance_id: String) -> InstalledCard:
	for card in all_installed():
		var c: InstalledCard = card as InstalledCard
		if c.runtime_instance_id == instance_id:
			return c
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c.runtime_instance_id == instance_id:
			return c
	# Also check programs hosted on ice (Botulus, Tranquilizer) — these are stored
	# in ice_card.hosted_cards, not in runner_rig.
	for server in servers.values():
		for ice_card in (server as Server).ice:
			for hosted in (ice_card as InstalledCard).hosted_cards:
				var hc: InstalledCard = hosted as InstalledCard
				if hc != null and hc.runtime_instance_id == instance_id:
					return hc
	# Also check scored agendas — needed for Dividends counter effects that fire
	# during on_score (the card has already been removed from its server by then).
	for card in corp_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c != null and c.runtime_instance_id == instance_id:
			return c
	return null


# Find a scored Corp agenda by runtime_instance_id.
func get_scored_agenda_by_instance_id(instance_id: String) -> InstalledCard:
	for card in corp_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c != null and c.runtime_instance_id == instance_id:
			return c
	# Also search runner's score area (for Corp abilities usable after steal, e.g. Next Big Thing)
	for card in runner_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c != null and c.runtime_instance_id == instance_id:
			return c
	return null


# ── Registry Mutators ─────────────────────────────────────────────────────────

func register_listener(event_type: String, instance_id: String, ability_def: Dictionary) -> void:
	if not _event_listeners.has(event_type):
		_event_listeners[event_type] = []
	# Guard against duplicate registration for the same card instance
	for existing in _event_listeners[event_type]:
		if (existing as Dictionary).get("card_instance_id", "") == instance_id:
			return
	_event_listeners[event_type].append({
		"card_instance_id": instance_id,
		"ability_def": ability_def
	})

func register_modifier(mod_type: String, instance_id: String, value_modifier: int, conditions: Dictionary = {}, extra: Dictionary = {}) -> void:
	if not _state_modifiers.has(mod_type):
		_state_modifiers[mod_type] = []
	# Guard against duplicate registration
	for existing in _state_modifiers[mod_type]:
		if (existing as Dictionary).get("card_instance_id", "") == instance_id:
			return
	var entry := {
		"card_instance_id": instance_id,
		"value": value_modifier,
		"conditions": conditions
	}
	# Merge any extra fields (e.g. card_id, method for dynamic_base_strength)
	for key in extra:
		entry[key] = extra[key]
	_state_modifiers[mod_type].append(entry)

func unregister_all_card_effects(instance_id: String) -> void:
	for event_type in _event_listeners:
		var list: Array = _event_listeners[event_type]
		for i in range(list.size() - 1, -1, -1):
			if list[i]["card_instance_id"] == instance_id:
				list.remove_at(i)
				
	for mod_type in _state_modifiers:
		var list: Array = _state_modifiers[mod_type]
		for i in range(list.size() - 1, -1, -1):
			if list[i]["card_instance_id"] == instance_id:
				list.remove_at(i)

# Like unregister_all_card_effects but preserves a single event type's listener.
# Used by trash_self_on_use (Boomerang) to keep run_end alive until after the run.
func unregister_card_effects_except_event(instance_id: String, keep_event: String) -> void:
	for event_type in _event_listeners:
		if event_type == keep_event:
			continue
		var list: Array = _event_listeners[event_type]
		for i in range(list.size() - 1, -1, -1):
			if list[i]["card_instance_id"] == instance_id:
				list.remove_at(i)
	for mod_type in _state_modifiers:
		var list: Array = _state_modifiers[mod_type]
		for i in range(list.size() - 1, -1, -1):
			if list[i]["card_instance_id"] == instance_id:
				list.remove_at(i)


# ── Dynamic Cost and Value Queries ────────────────────────────────────────────

func query_rez_cost(card: InstalledCard) -> int:
	var base_cost: int = card.card_record.cost if card.card_record else 0
	base_cost = max(0, base_cost)
	
	var modifiers: Array = _state_modifiers.get("rez_cost", [])
	var total_mod := 0
	for mod in modifiers:
		if _evaluate_modifier_condition(mod["conditions"] as Dictionary, card):
			total_mod += mod["value"] as int
			
	return max(0, base_cost + total_mod)

func _evaluate_modifier_condition(cond: Dictionary, card: InstalledCard) -> bool:
	if cond.is_empty():
		return true
	if cond.has("card_type") and card.card_record.card_type != cond["card_type"]:
		return false
	if cond.has("zone") and card.zone != cond["zone"]:
		return false
	return true


# ── Event Dispatching Engine ──────────────────────────────────────────────────

func notify_event(event_type: String, event_data: Dictionary, interpreter: AbilityInterpreter) -> void:
	if not _event_listeners.has(event_type):
		return
		
	var active_triggers: Array = _event_listeners[event_type]
	var corp_triggers: Array[Dictionary] = []
	var runner_triggers: Array[Dictionary] = []
	
	for trigger in active_triggers:
		var owner = get_card_owner_by_instance_id(trigger["card_instance_id"] as String)
		if owner == "corp":
			corp_triggers.append(trigger)
		else:
			runner_triggers.append(trigger)
			
	if active_player == "corp":
		await _execute_player_trigger_queue(corp_triggers, "corp", event_data, interpreter)
		await _execute_player_trigger_queue(runner_triggers, "runner", event_data, interpreter)
	else:
		await _execute_player_trigger_queue(runner_triggers, "runner", event_data, interpreter)
		await _execute_player_trigger_queue(corp_triggers, "corp", event_data, interpreter)


func _execute_player_trigger_queue(triggers: Array[Dictionary], player: String, event_data: Dictionary, interpreter: Object) -> void:
	if triggers.is_empty():
		return
		
	var dm = corp_decision_maker if player == "corp" else runner_decision_maker
	
	# While simultaneous triggers exist, let the choice maker pick execution order
	while not triggers.is_empty():
		var chosen_idx := 0
		if not simulation_mode and triggers.size() > 1 and dm != null and dm.has_method("choose_trigger_order"):
			chosen_idx = await dm.choose_trigger_order(triggers, self)
			
		# pop_at removes the element AND returns it cleanly
		var targeting_trigger: Dictionary = triggers.pop_at(chosen_idx)

		# Once-per-turn guard: if the ability block carries "once_per_turn_key",
		# skip firing if this card has already fired that key this turn.
		var opt_key: String = (targeting_trigger["ability_def"] as Dictionary).get("once_per_turn_key", "")
		if opt_key != "":
			var opt_iid: String = targeting_trigger.get("card_instance_id", "")
			var opt_full_key := "%s:%s" % [opt_iid, opt_key]
			if once_per_turn_triggered.get(opt_full_key, false):
				continue   # already fired this turn — skip
			once_per_turn_triggered[opt_full_key] = true

		# Set transient variable — merge card's own instance_id so self-referencing
		# effects (add_self_counters, etc.) can find the owning card
		var merged_data: Dictionary = event_data.duplicate()
		merged_data["card_instance_id"] = targeting_trigger.get("card_instance_id", "")
		self.current_event_data = merged_data
		await interpreter.execute_trigger(targeting_trigger["ability_def"] as Dictionary, self)


# Explicit board state scan to determine whether the Corp or Runner controls the effect
func get_card_owner_by_instance_id(instance_id: String) -> String:
	# 1. Check Corp servers
	for server in servers.values():
		var s: Server = server as Server
		for c in s.ice:
			if (c as InstalledCard).runtime_instance_id == instance_id:
				return "corp"
		for c in s.root:
			if (c as InstalledCard).runtime_instance_id == instance_id:
				return "corp"
	# 2. Check Runner Rig
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c.runtime_instance_id == instance_id:
			return "runner"
	# 3. Scored agendas (Dividends click actions)
	for card in corp_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c != null and c.runtime_instance_id == instance_id:
			return "corp"
	# 4. Identity fallbacks
	if instance_id == "identity_runner" or instance_id.begins_with("runner_identity"):
		return "runner"
	if instance_id == "identity_corp":
		return "corp"
	return "corp"


# ── Score queries ─────────────────────────────────────────────────────────────

func corp_agenda_points() -> int:
	var total := 0
	for card in corp_score_area:
		total += (card as CardRecord).agenda_points
	return total

func runner_agenda_points() -> int:
	var total := 0
	for card in runner_score_area:
		total += (card as CardRecord).agenda_points
	return total

# ── Threat ────────────────────────────────────────────────────────────────────
# "Threat level" is the runner's current agenda point total.
# Cards with "threat X" abilities are active whenever threat_level() >= X.
# All threat checks go through this single function so the definition stays
# consistent and can be extended later (e.g. threat bonuses from identity
# abilities) without touching every card.
func threat_level() -> int:
	return runner_agenda_points()


# ── Credit helpers ────────────────────────────────────────────────────────────

func query_breaker_strength_bonus() -> int:
	# Sum all active breaker_strength modifiers (e.g. Turbine)
	var total := 0
	var mods: Array = _state_modifiers.get("breaker_strength", [])
	for mod in mods:
		total += mod.get("value", 0) as int
	return total


func query_ice_strength_modifier() -> int:
	# Sum all active ice_strength modifiers (e.g. The Tungsten Tailor: -1 to all ice).
	# Returns a negative number when reductions are active.
	var total := 0
	var mods: Array = _state_modifiers.get("ice_strength", [])
	for mod in mods:
		total += mod.get("value", 0) as int
	return total


func query_dynamic_breaker_base(breaker: InstalledCard) -> int:
	# Returns a dynamic base strength for a specific breaker, or -1 if none applies.
	if breaker.card_record == null:
		return -1
	var mods: Array = _state_modifiers.get("dynamic_base_strength", [])
	for mod in mods:
		var d := mod as Dictionary
		if d.get("card_id", "") != breaker.card_id:
			continue
		var method: String = d.get("method", "")
		match method:
			"installed_icebreaker_count":
				# Both Unity and Echelon count all installed icebreakers including themselves
				return count_installed_icebreakers()
			"fracter_in_heap_count":
				# Rising Tide: +1 strength per fracter in the heap
				return count_fracters_in_heap()
	return -1


func count_installed_icebreakers() -> int:
	var count := 0
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c == null or c.card_record == null:
			continue
		if c.card_record.has_subtype("icebreaker") or \
		   c.card_record.subtypes.any(func(s): return s in ["fracter", "decoder", "killer", "ai"]):
			count += 1
	return count


func count_fracters_in_heap() -> int:
	# Count fracter icebreakers in the runner's discard pile (heap).
	# Used by Rising Tide's dynamic base-strength modifier.
	var count := 0
	for card in runner_discard:
		var r: CardRecord = card as CardRecord
		if r == null:
			continue
		if r.has_subtype("fracter") or r.subtypes.any(func(s): return s == "fracter"):
			count += 1
	return count


func corp_max_hand_size() -> int:
	return 5 + corp_hand_size_bonus

func runner_max_hand_size() -> int:
	return 5 + runner_hand_size_bonus - runner_core_damage_taken + query_hackerspace_hand_size_bonus()


# Hackerspace (VP6): +2 max hand size while it hosts at least one companion AND one connection.
func query_hackerspace_hand_size_bonus() -> int:
	for rig_entry in runner_rig:
		var ic: InstalledCard = rig_entry as InstalledCard
		if ic == null or ic.card_id != "hackerspace":
			continue
		var has_companion := false
		var has_connection := false
		for hosted in ic.hosted_runner_resources:
			var h: InstalledCard = hosted as InstalledCard
			if h == null or h.card_record == null:
				continue
			if h.card_record.has_subtype("companion"):
				has_companion = true
			if h.card_record.has_subtype("connection"):
				has_connection = true
		if has_companion and has_connection:
			return 2
	return 0


func get_credits(subject: String) -> int:
	match subject:
		"corp":   return corp_credits
		"runner": return runner_credits
	push_error("GameContext: unknown subject '%s'" % subject)
	return 0

# Total credits available to the runner including any Overclock pool
func runner_available_credits() -> int:
	return runner_credits + run_modifiers.get("overclock_credits", 0)

# Spend runner credits, drawing from Overclock pool first, then own pool.
# Returns false if insufficient total credits.
func runner_spend_credits(amount: int) -> bool:
	var overclock: int = run_modifiers.get("overclock_credits", 0)
	var total: int     = runner_credits + overclock
	if total < amount:
		return false
	var from_overclock: int = min(amount, overclock)
	var from_own: int       = amount - from_overclock
	run_modifiers["overclock_credits"] = overclock - from_overclock
	runner_credits -= from_own
	# VP65 Shackleton Grid: Overclock is "outside the credit pool"
	if from_overclock > 0 and run_active:
		runner_outside_credits_spent_pending += from_overclock
	return true


# ── Recurring credit helpers ──────────────────────────────────────────────────

# Total credits available for trash costs: regular pool + Overclock + Azimat recurring credits.
func runner_trash_credits_available() -> int:
	var total: int = runner_credits + run_modifiers.get("overclock_credits", 0)
	for mod in _state_modifiers.get("runner_trash_recurring_credits", []):
		var d := mod as Dictionary
		var iid: String = d.get("card_instance_id", "")
		var card := get_installed_card_by_instance_id(iid)
		if card != null:
			total += card.get_counter("recurring_credits")
	return total


# Spend credits for a trash cost: drain Azimat recurring credits first, then Overclock, then pool.
func runner_spend_for_trash(amount: int) -> bool:
	if runner_trash_credits_available() < amount:
		return false
	var remaining := amount
	# Drain recurring trash credits first (e.g. Azimat)
	for mod in _state_modifiers.get("runner_trash_recurring_credits", []):
		if remaining <= 0:
			break
		var d := mod as Dictionary
		var iid: String = d.get("card_instance_id", "")
		var card := get_installed_card_by_instance_id(iid)
		if card != null:
			var avail: int = card.get_counter("recurring_credits")
			var spend: int = min(avail, remaining)
			if spend > 0:
				card.remove_counter("recurring_credits", spend)
				send_log("%s: spends %d recurring credit(s) on trash (%d remaining)." % [
					card.display_name(), spend, card.get_counter("recurring_credits")
				])
				remaining -= spend
				# VP65 Shackleton Grid: recurring credits are "outside the credit pool"
				if run_active:
					runner_outside_credits_spent_pending += spend
	# Then drain Overclock pool
	if remaining > 0:
		var overclock: int = run_modifiers.get("overclock_credits", 0)
		var from_oc: int = min(remaining, overclock)
		if from_oc > 0:
			run_modifiers["overclock_credits"] = overclock - from_oc
			remaining -= from_oc
			# VP65 Shackleton Grid: Overclock is "outside the credit pool"
			if run_active:
				runner_outside_credits_spent_pending += from_oc
	# Finally drain runner's own credits
	if remaining > 0:
		runner_credits -= remaining
	return true


# Total credits Corp can use to rez a card on a specific server: corp pool + Mahkota recurring.
func corp_rez_credits_available(server_id: String) -> int:
	var total: int = corp_credits
	for mod in _state_modifiers.get("corp_rez_recurring_credits", []):
		var d := mod as Dictionary
		if d.get("server_id", "") == server_id:
			var iid: String = d.get("card_instance_id", "")
			var card := get_installed_card_by_instance_id(iid)
			if card != null and card.is_rezzed:
				total += card.get_counter("recurring_credits")
	return total


# Spend credits for a rez cost: drain Mahkota recurring credits first, then corp pool.
func corp_spend_for_rez(amount: int, server_id: String) -> bool:
	if corp_rez_credits_available(server_id) < amount:
		return false
	var remaining := amount
	# Drain Mahkota recurring credits first
	for mod in _state_modifiers.get("corp_rez_recurring_credits", []):
		if remaining <= 0:
			break
		var d := mod as Dictionary
		if d.get("server_id", "") == server_id:
			var iid: String = d.get("card_instance_id", "")
			var card := get_installed_card_by_instance_id(iid)
			if card != null and card.is_rezzed:
				var avail: int = card.get_counter("recurring_credits")
				var spend: int = min(avail, remaining)
				if spend > 0:
					card.remove_counter("recurring_credits", spend)
					send_log("%s: spends %d recurring credit(s) on rez (%d remaining)." % [
						card.display_name(), spend, card.get_counter("recurring_credits")
					])
					remaining -= spend
	# Then drain corp's own credits
	if remaining > 0:
		corp_credits -= remaining
	return true


func set_credits(subject: String, amount: int) -> void:
	match subject:
		"corp":   corp_credits   = max(0, amount)
		"runner": runner_credits = max(0, amount)
		_: push_error("GameContext: unknown subject '%s'" % subject)

func runner_is_tagged() -> bool:
	return runner_tags > 0


# ── Stealth credits ───────────────────────────────────────────────────────────

# Sum of all stealth credits hosted on installed stealth hardware/programs,
# plus any transient stealth credits placed into run_modifiers for this run.
func runner_stealth_credits() -> int:
	var total := 0
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c != null and c.card_record != null and c.card_record.has_subtype("stealth"):
			total += c.get_counter("stealth_credits")
	total += run_modifiers.get("stealth_credits", 0)
	return total


# Spend stealth credits, draining transient run_modifiers pool first, then
# hosted credits from the rig in order.  Returns false if insufficient credits.
func runner_spend_stealth_credits(amount: int) -> bool:
	if runner_stealth_credits() < amount:
		return false
	var remaining := amount
	# Drain transient pool first (run_modifiers["stealth_credits"])
	var run_stealth: int = run_modifiers.get("stealth_credits", 0)
	if run_stealth > 0 and remaining > 0:
		var from_run: int = mini(run_stealth, remaining)
		run_modifiers["stealth_credits"] = run_stealth - from_run
		remaining -= from_run
	# Then drain stealth counters from installed rig cards
	for card in runner_rig:
		if remaining <= 0:
			break
		var c: InstalledCard = card as InstalledCard
		if c == null or c.card_record == null:
			continue
		if not c.card_record.has_subtype("stealth"):
			continue
		var avail: int = c.get_counter("stealth_credits")
		if avail <= 0:
			continue
		var spend: int = mini(avail, remaining)
		c.remove_counter("stealth_credits", spend)
		send_log("%s: spends %d stealth credit(s) (%d remaining)." % [
			c.display_name(), spend, c.get_counter("stealth_credits")])
		remaining -= spend
	# VP65 Shackleton Grid: all stealth credits are "outside the credit pool"
	if run_active:
		runner_outside_credits_spent_pending += amount
	return true


# ── Counter helper ────────────────────────────────────────────────────────────

func get_counters_on_accessed_card(counter_type: String) -> int:
	var card := get_installed_card_by_instance_id(accessed_card_id)
	if card == null:
		# Fall back to slug search if accessed_card_id was a fallback slug
		card = get_installed_card_by_id(accessed_card_id)
	if card == null:
		return 0
	return card.get_counter(counter_type)


# ── Shackleton Grid helper ────────────────────────────────────────────────────

# Called by async contexts (process_encounter_action, _offer_trash) after any
# spend that may have drawn from outside-pool credits.  If the pending counter is
# positive it fires the runner_spends_outside_credits event and then resets the
# counter so the same spend does not fire Shackleton twice.
func check_outside_credits_trigger(interpreter: Object) -> void:
	if runner_outside_credits_spent_pending <= 0 or not run_active:
		runner_outside_credits_spent_pending = 0
		return
	runner_outside_credits_spent_pending = 0
	await notify_event("runner_spends_outside_credits", {}, interpreter)


# ── Log ───────────────────────────────────────────────────────────────────────

func send_log(message: String) -> void:
	if simulation_mode:
		return
	event_log.append(message)
	print("[GameContext] " + message)


# ── Simulation clone ──────────────────────────────────────────────────────────

# Returns a fully independent copy of this context suitable for headless simulation.
# CardRecord objects are shared (they are immutable card data).
# decision_makers are left null — the caller injects sim AIs before running.
# _event_listeners and _state_modifiers are deep-copied so the clone's listener
# registry matches its cloned installed cards without re-running registration.
func clone_for_sim() -> GameContext:
	var c := GameContext.new()

	# ── Economy / click state ──────────────────────────────────────────────────
	c.corp_credits   = corp_credits
	c.runner_credits = runner_credits
	c.runner_tags    = runner_tags
	c.corp_bad_pub   = corp_bad_pub
	c.corp_clicks    = corp_clicks
	c.runner_clicks  = runner_clicks

	# ── Hands (dict entries share immutable CardRecord refs) ──────────────────
	c.corp_hand   = corp_hand.duplicate(true)
	c.runner_hand = runner_hand.duplicate(true)

	# ── Decks / discards / RFG (CardRecord arrays — shared refs are fine) ─────
	c.corp_deck               = corp_deck.duplicate()
	c.runner_deck             = runner_deck.duplicate()
	c.corp_discard            = corp_discard.duplicate()
	c.runner_discard          = runner_discard.duplicate()
	c.corp_rfg                = corp_rfg.duplicate()
	c.runner_rfg              = runner_rfg.duplicate()
	c.corp_discard_facedown   = corp_discard_facedown.duplicate()
	c.corp_removed_from_game  = corp_removed_from_game.duplicate()

	# ── Score areas ────────────────────────────────────────────────────────────
	c.corp_score_area    = corp_score_area.duplicate()
	c.runner_score_area  = runner_score_area.duplicate()
	c.corp_score_area_cards = []
	for ic in corp_score_area_cards:
		c.corp_score_area_cards.append((ic as InstalledCard).clone())
	c.runner_score_area_cards = []
	for ic in runner_score_area_cards:
		c.runner_score_area_cards.append((ic as InstalledCard).clone())

	# ── Servers ────────────────────────────────────────────────────────────────
	c.servers = {}
	for key in servers:
		c.servers[key] = (servers[key] as Server).clone()

	# ── Runner rig ─────────────────────────────────────────────────────────────
	c.runner_rig = []
	for ic in runner_rig:
		c.runner_rig.append((ic as InstalledCard).clone())

	# ── Per-turn install tracking ──────────────────────────────────────────────
	c.corp_installed_this_turn = corp_installed_this_turn.duplicate()

	# ── Deferred click modifiers ───────────────────────────────────────────────
	c.pending_click_penalties = pending_click_penalties.duplicate()
	c.pending_click_bonuses   = pending_click_bonuses.duplicate()

	# ── Run state ──────────────────────────────────────────────────────────────
	c.run_active                                  = run_active
	c.run_ended                                   = run_ended
	c.run_successful                              = run_successful
	c.run_target_server                           = run_target_server
	c.accessed_card_id                            = accessed_card_id
	c.runner_made_successful_run_this_turn        = runner_made_successful_run_this_turn
	c.runner_made_successful_run_last_turn        = runner_made_successful_run_last_turn
	c.runner_stole_agenda_this_run                = runner_stole_agenda_this_run
	c.corp_used_reality_plus_this_turn            = corp_used_reality_plus_this_turn
	c.runner_centrals_run_this_turn               = runner_centrals_run_this_turn.duplicate()
	c.runner_click_draws_this_turn                = runner_click_draws_this_turn
	c.runner_hq_breached_this_turn                = runner_hq_breached_this_turn
	c.runner_trashed_during_breach_this_turn      = runner_trashed_during_breach_this_turn
	c.runner_program_install_discounted_this_turn = runner_program_install_discounted_this_turn
	c.runner_carnivore_used_this_turn             = runner_carnivore_used_this_turn
	c.runner_stole_agenda_this_turn               = runner_stole_agenda_this_turn
	c.runner_successful_run_on_rd_this_turn       = runner_successful_run_on_rd_this_turn
	c.runner_successful_run_on_archives_this_turn = runner_successful_run_on_archives_this_turn
	c.run_level_strength_boosts                   = run_level_strength_boosts.duplicate()
	c.run_had_subroutine_resolve                  = run_had_subroutine_resolve
	c.runner_cannot_steal_or_trash_this_run       = runner_cannot_steal_or_trash_this_run
	c.global_ice_strength_bonus_this_run          = global_ice_strength_bonus_this_run
	c.beta_build_installed_card_id                = beta_build_installed_card_id
	c.runner_steal_trash_blocked_card_ids         = runner_steal_trash_blocked_card_ids.duplicate()
	c.run_accessed_archives_card_ids              = run_accessed_archives_card_ids.duplicate()
	c.run_modifiers                               = run_modifiers.duplicate()
	c.runner_hq_successful_run_this_turn          = runner_hq_successful_run_this_turn

	# ── Per-turn Corp flags ────────────────────────────────────────────────────
	c.ice_rezzed_this_turn                        = ice_rezzed_this_turn
	c.doubles_played_this_turn                    = doubles_played_this_turn
	c.corp_scored_agenda_not_installed_this_turn  = corp_scored_agenda_not_installed_this_turn
	c.corp_played_operation_this_turn             = corp_played_operation_this_turn
	c.corp_finished_an_action_this_turn           = corp_finished_an_action_this_turn
	c.corp_gained_advance_credits_this_turn       = corp_gained_advance_credits_this_turn
	c.corp_last_scored_agenda_points              = corp_last_scored_agenda_points
	c.corp_agendas_scored_this_turn               = corp_agendas_scored_this_turn
	c.corp_discarded_to_hand_limit_last_turn      = corp_discarded_to_hand_limit_last_turn

	# ── Identity state ─────────────────────────────────────────────────────────
	c.corp_identity          = corp_identity
	c.runner_identity        = runner_identity
	c.corp_identity_counters  = corp_identity_counters.duplicate()
	c.runner_identity_counters = runner_identity_counters.duplicate()
	c.runner_identity_face_title = runner_identity_face_title
	c.corp_identity_face_title   = corp_identity_face_title

	# ── Game state ─────────────────────────────────────────────────────────────
	c.turn_number              = turn_number
	c.corp_hand_size_bonus     = corp_hand_size_bonus
	c.runner_hand_size_bonus   = runner_hand_size_bonus
	c.runner_core_damage_taken = runner_core_damage_taken
	c.active_player            = active_player
	c.game_over                = game_over
	c.winner                   = winner
	c.agenda_points_to_win     = agenda_points_to_win
	c.once_per_turn_triggered  = once_per_turn_triggered.duplicate()

	# Transient execution fields — always reset for sim
	c.current_event_data              = {}
	c.current_ability_source_card_type = ""
	c.current_operation_play_source    = ""

	# ── Listener registry — deep-copy so sim mutations don't bleed back ────────
	# ability_def dicts are pure JSON data; sharing refs is safe (never mutated).
	c._event_listeners = {}
	for event_type in _event_listeners:
		var cloned_list: Array[Dictionary] = []
		for entry in (_event_listeners[event_type] as Array):
			cloned_list.append((entry as Dictionary).duplicate())
		c._event_listeners[event_type] = cloned_list

	c._state_modifiers = {}
	for mod_type in _state_modifiers:
		var cloned_mods: Array[Dictionary] = []
		for mod in (_state_modifiers[mod_type] as Array):
			cloned_mods.append((mod as Dictionary).duplicate())
		c._state_modifiers[mod_type] = cloned_mods

	c.simulation_mode = true
	return c
