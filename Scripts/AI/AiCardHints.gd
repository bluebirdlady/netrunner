extends RefCounted

# ── AiCardHints ────────────────────────────────────────────────────────────────
# Data-driven hints for runner events whose on_play effects are too complex to
# auto-derive from abilities.json.  RunnerCandidateGenerator calls condition_met()
# to decide whether to offer the card; RunnerStateEvaluator calls get_hint() and
# _apply_hint_delta() to project its effect in the beam search.
#
# Hint schema per card (all fields optional):
#   conditions : Dictionary — all must be true for the card to be offered
#   snap_delta : Dictionary — applied by RunnerStateEvaluator._apply_hint_delta()
#   value_bonus: float      — extra evaluator score (wired up in P4)
#
# ── snap_delta keys ───────────────────────────────────────────────────────────
#   credits_delta          int    GROSS credit gain (card cost already deducted)
#   cards_drawn            int    net cards added to grip
#   clicks_delta           int    extra click adjustment (negative = costs more)
#   runs_server            String "rd","hq","archives","any","any_central"
#   installs_program       bool   generic program install (increments prg_count)
#   installs_breaker_if_need bool  tutor: install missing breaker type from deck
#   installs_resource      bool   generic resource install (no prg metrics)
#   install_from_deck      bool   also deduct 1 card from runner_deck
#
# ── condition keys ────────────────────────────────────────────────────────────
#   runner_tags_eq         int    runner_tags == N
#   runner_tags_gte        int    runner_tags >= N
#   runner_heap_size_gte   int    runner_heap_size >= N
#   runner_heap_has_program bool
#   runner_deck_size_gte   int    runner_deck >= N
#   runner_deck_size_lt    int    runner_deck < N
#   runner_installable_hand_gte int  runner_installable_hand_count >= N
#   runner_hand_has_prg_hw bool   hand contains program or hardware
#   runner_hand_has_resource bool
#   runner_prg_count_gte   int    runner_prg_count >= N
#   runner_clicks_gte      int    runner_clicks_left >= N
#   runner_stole_agenda    bool   agenda stolen this projected turn
#   runner_max_cost_gte    int    runner_max_cost_installed >= N (Khusyuk)
#   runner_centrals_all_run bool  rd + hq + archives all in centrals_run
#   needs_breaker          bool   runner lacks all breaker types
# ─────────────────────────────────────────────────────────────────────────────

static func has_hint(card_id: String) -> bool:
	return HINTS.has(card_id)


static func get_hint(card_id: String) -> Dictionary:
	return HINTS.get(card_id, {}) as Dictionary


static func condition_met(card_id: String, snap: Dictionary) -> bool:
	if not HINTS.has(card_id):
		return false
	return _check_conditions(HINTS[card_id] as Dictionary, snap)


# ── Condition evaluator ───────────────────────────────────────────────────────

static func _check_conditions(hint: Dictionary, snap: Dictionary) -> bool:
	var conds: Dictionary = hint.get("conditions", {}) as Dictionary
	for key in conds:
		if not _eval_condition(key as String, conds[key], snap):
			return false
	# If the hint initiates a run, verify a valid target exists.
	var delta: Dictionary = hint.get("snap_delta", {}) as Dictionary
	var runs: String = delta.get("runs_server", "") as String
	if runs != "" and not _has_run_target(runs, snap):
		return false
	return true


static func _eval_condition(key: String, expected, snap: Dictionary) -> bool:
	match key:
		"runner_tags_eq":
			return (snap.get("runner_tags", 0) as int) == (expected as int)
		"runner_tags_gte":
			return (snap.get("runner_tags", 0) as int) >= (expected as int)
		"runner_heap_size_gte":
			return (snap.get("runner_heap_size", 0) as int) >= (expected as int)
		"runner_heap_has_program":
			return (snap.get("runner_heap_has_program", false) as bool) == (expected as bool)
		"runner_deck_size_gte":
			return (snap.get("runner_deck", 0) as int) >= (expected as int)
		"runner_deck_size_lt":
			return (snap.get("runner_deck", 0) as int) < (expected as int)
		"runner_installable_hand_gte":
			return (snap.get("runner_installable_hand_count", 0) as int) >= (expected as int)
		"runner_hand_has_prg_hw":
			return (snap.get("runner_hand_has_prg_hw", false) as bool) == (expected as bool)
		"runner_hand_has_resource":
			return (snap.get("runner_hand_has_resource", false) as bool) == (expected as bool)
		"runner_prg_count_gte":
			return (snap.get("runner_prg_count", 0) as int) >= (expected as int)
		"runner_clicks_gte":
			return (snap.get("runner_clicks_left", 0) as int) >= (expected as int)
		"runner_stole_agenda":
			return (snap.get("runner_stole_agenda_this_turn", false) as bool) == (expected as bool)
		"runner_max_cost_gte":
			return (snap.get("runner_max_cost_installed", 0) as int) >= (expected as int)
		"runner_centrals_all_run":
			var ran: Array = snap.get("centrals_run", []) as Array
			var all_run: bool = ("rd" in ran) and ("hq" in ran) and ("archives" in ran)
			return all_run == (expected as bool)
		"needs_breaker":
			var nb: bool = not (snap.get("runner_has_fracter", false) as bool) \
				and not (snap.get("runner_has_decoder", false) as bool) \
				and not (snap.get("runner_has_killer",  false) as bool) \
				and not (snap.get("runner_has_ai",      false) as bool)
			return nb == (expected as bool)
		"corp_central_has_rezzed_ice":
			var has_ice: bool = (snap.get("hq_rezzed", 0) as int) > 0 \
				or (snap.get("rd_rezzed", 0) as int) > 0
			return has_ice == (expected as bool)
	return true  # unknown condition key — pass through


static func _has_run_target(runs: String, snap: Dictionary) -> bool:
	var ran: Array = snap.get("centrals_run", []) as Array
	match runs:
		"rd":       return "rd" not in ran
		"hq":       return "hq" not in ran
		"archives": return true
		"any_central":
			# Only valid if at least one unrun central has breakable rezzed ICE.
			if "rd" not in ran and _snap_central_breakable("rd", snap): return true
			if "hq" not in ran and _snap_central_breakable("hq", snap): return true
			return false
		"any":
			# Archives is always reachable and has no ICE — always a valid target.
			return true
	return true


static func _snap_central_breakable(server_id: String, snap: Dictionary) -> bool:
	var types_key: String = "hq_rezzed_types" if server_id == "hq" else "rd_rezzed_types"
	var rezzed_types: Array = snap.get(types_key, []) as Array
	if rezzed_types.is_empty():
		return true
	if snap.get("runner_has_ai", false) as bool:
		return true
	var has_fracter: bool = snap.get("runner_has_fracter", false) as bool
	var has_decoder: bool = snap.get("runner_has_decoder", false) as bool
	var has_killer:  bool = snap.get("runner_has_killer",  false) as bool
	for sub in rezzed_types:
		match sub:
			"barrier":   if not has_fracter: return false
			"code_gate": if not has_decoder: return false
			"sentry":    if not has_killer:  return false
	return true


# ─── Hint table ───────────────────────────────────────────────────────────────

const HINTS: Dictionary = {

	# ── Staple events (no abilities.json on_play entry) ──────────────────────
	# These were previously handled by hardcoded ECONOMY_NET / DRAW_NET /
	# RUN_EVENT_SERVER dicts in the evaluator.  Hints here replace those dicts
	# once the unified projection dispatch (P4) is active.

	# Diesel: draw 3 cards
	"diesel": {
		"conditions": {},
		"snap_delta": {"cards_drawn": 3},
		"value_bonus": 0.0,
	},

	# Quality Time: draw 5 cards (costs 3[c])
	"quality_time": {
		"conditions": {},
		"snap_delta": {"cards_drawn": 5},
		"value_bonus": 0.0,
	},

	# Lucky Find: as an additional cost, lose [click]; gain 9[c]
	"lucky_find": {
		"conditions": {},
		"snap_delta": {"credits_delta": 9, "clicks_delta": -1},
		"value_bonus": 0.0,
	},

	# Bravado: make a run on a protected server; if successful, gain 6[c]
	"bravado": {
		"conditions": {},
		"snap_delta": {"runs_server": "any", "credits_delta": 6},
		"value_bonus": 0.0,
	},

	# Legwork: run HQ; if successful, access 2 additional cards
	"legwork": {
		"conditions": {},
		"snap_delta": {"runs_server": "hq"},
		"value_bonus": 8.0,
	},

	# The Maker's Eye: run RD; if successful, access 2 additional cards
	"the_makers_eye": {
		"conditions": {},
		"snap_delta": {"runs_server": "rd"},
		"value_bonus": 8.0,
	},

	# Wanton Destruction: run HQ; if successful, spend [click]s to force Corp discards
	"wanton_destruction": {
		"conditions": {},
		"snap_delta": {"runs_server": "hq"},
		"value_bonus": 5.0,
	},

	# Dirty Laundry: make a run; if successful, gain 5[c]
	"dirty_laundry": {
		"conditions": {},
		"snap_delta": {"runs_server": "any", "credits_delta": 5},
		"value_bonus": 0.0,
	},

	# ── Economy ──────────────────────────────────────────────────────────────

	# Easy Mark: gain 3[c]
	"easy_mark": {
		"conditions": {},
		"snap_delta": {"credits_delta": 3},
		"value_bonus": 0.0,
	},

	# Process Automation: gain 2[c] and draw 1
	"process_automation": {
		"conditions": {},
		"snap_delta": {"credits_delta": 2, "cards_drawn": 1},
		"value_bonus": 0.0,
	},

	# Wildcat Strike: Corp chooses — runner gains 6[c] or draws 4; positive either way
	"wildcat_strike": {
		"conditions": {},
		"snap_delta": {"credits_delta": 3},
		"value_bonus": 3.0,
	},

	# Stimhack: place 9[c] on this card, make a run; suffer 1 core damage after
	"stimhack": {
		"conditions": {},
		"snap_delta": {"runs_server": "any", "credits_delta": 9},
		"value_bonus": -1.0,
	},

	# ── Run events (fixed target) ─────────────────────────────────────────────

	# Jailbreak: run HQ or RD, gain 1 additional access; draw 1 if successful
	"jailbreak": {
		"conditions": {},
		"snap_delta": {"runs_server": "any_central", "cards_drawn": 1},
		"value_bonus": 4.0,
	},

	# Joy Ride: run RD; if successful, draw 5
	"joy_ride": {
		"conditions": {},
		"snap_delta": {"runs_server": "rd", "cards_drawn": 5},
		"value_bonus": 0.0,
	},

	# Indexing: run RD; if successful, see top 5 and rearrange
	"indexing": {
		"conditions": {},
		"snap_delta": {"runs_server": "rd"},
		"value_bonus": 10.0,
	},

	# Trick Shot: place 4[c] on this, run RD
	"trick_shot": {
		"conditions": {},
		"snap_delta": {"runs_server": "rd", "credits_delta": 4},
		"value_bonus": 0.0,
	},

	# Khusyuk: run RD; if successful, access = count of same-cost installed cards
	"khusyuk": {
		"conditions": {"runner_max_cost_gte": 3},
		"snap_delta": {"runs_server": "rd"},
		"value_bonus": 8.0,
	},

	# Finality: suffer 1 core damage, run RD — only when stack is safe
	"finality": {
		"conditions": {"runner_deck_size_gte": 4},
		"snap_delta": {"runs_server": "rd"},
		"value_bonus": 6.0,
	},

	# Deep Dive: run RD, see top 5 and access 1 — requires all 3 centrals run this turn
	"deep_dive": {
		"conditions": {"runner_centrals_all_run": true, "runner_deck_size_gte": 5},
		"snap_delta": {"runs_server": "rd"},
		"value_bonus": 15.0,
	},

	# Burner: run HQ; if successful, see 3 HQ cards, add 1 to grip
	"burner": {
		"conditions": {},
		"snap_delta": {"runs_server": "hq", "cards_drawn": 1},
		"value_bonus": 3.0,
	},

	# Chastushka: run HQ; if successful, sabotage 4
	"chastushka": {
		"conditions": {},
		"snap_delta": {"runs_server": "hq"},
		"value_bonus": 5.0,
	},

	# Transfer of Wealth: run HQ, take 1 tag, Corp loses 3[c] — only when clean
	"transfer_of_wealth": {
		"conditions": {"runner_tags_eq": 0},
		"snap_delta": {"runs_server": "hq", "credits_delta": 2},
		"value_bonus": 3.0,
	},

	# Eye for an Eye: run HQ, take 1 tag, trash rezzed ICE — only when untagged
	"eye_for_an_eye": {
		"conditions": {"runner_tags_eq": 0},
		"snap_delta": {"runs_server": "hq"},
		"value_bonus": 3.0,
	},

	# Illumination: run RD; if successful, install up to 3 from grip at -2[c] each
	"illumination": {
		"conditions": {"runner_installable_hand_gte": 2},
		"snap_delta": {"runs_server": "rd", "installs_program": true},
		"value_bonus": 6.0,
	},

	# Maintenance Access: run Archives, treat as a successful HQ run
	"maintenance_access": {
		"conditions": {},
		"snap_delta": {"runs_server": "archives"},
		"value_bonus": 4.0,
	},

	# Charm Offensive: run Archives; if successful, sabotage effects
	"charm_offensive": {
		"conditions": {},
		"snap_delta": {"runs_server": "archives"},
		"value_bonus": 4.0,
	},

	# Privileged Access: run Archives; if successful, install up to 3 heap cards free
	"privileged_access": {
		"conditions": {"runner_tags_eq": 0, "runner_heap_size_gte": 1},
		"snap_delta": {"runs_server": "archives"},
		"value_bonus": 8.0,
	},

	# ── Run events (any server) ───────────────────────────────────────────────

	# Inside Job: make a run, bypass the first piece of ICE encountered
	"inside_job": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 4.0,
	},

	# Overclock: place 5[c] on this card, make a run
	"overclock": {
		"conditions": {},
		"snap_delta": {"runs_server": "any", "credits_delta": 5},
		"value_bonus": 0.0,
	},

	# Tread Lightly: make a run; each Corp rez costs +3[c] during this run
	"tread_lightly": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 3.0,
	},

	# Clean Getaway: make a run; if successful, gain 6[c]
	"clean_getaway": {
		"conditions": {},
		"snap_delta": {"runs_server": "any", "credits_delta": 6},
		"value_bonus": 0.0,
	},

	# Spree: place 3[c] on this card, make a run
	"spree": {
		"conditions": {},
		"snap_delta": {"runs_server": "any", "credits_delta": 3},
		"value_bonus": 0.0,
	},

	# Bahia Bands: make a run; if successful, choose 2 of draw 2 / gain 2[c] / install
	"bahia_bands": {
		"conditions": {},
		"snap_delta": {"runs_server": "any", "credits_delta": 2, "cards_drawn": 2},
		"value_bonus": 2.0,
	},

	# S-Dobrado: make a run on a central server, bypass the first ICE
	"s_dobrado": {
		"conditions": {},
		"snap_delta": {"runs_server": "any_central"},
		"value_bonus": 3.0,
	},

	# Pinhole Threading: make a run; if successful, access 1 card in the root
	"pinhole_threading": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 4.0,
	},

	# Direct Access: make a run, ignoring runner identity abilities during it
	"direct_access": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 3.0,
	},

	# Always Have a Backup Plan: make a run; if unsuccessful, run the same server again
	"always_have_a_backup_plan": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 4.0,
	},

	# Into the Depths: make a run; choose an effect for each ICE you pass
	"into_the_depths": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 4.0,
	},

	# Raindrops Cut Stone: make a run; gain credits for each subroutine that fires
	"raindrops_cut_stone": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 4.0,
	},

	# Shred: make a run; prevent the first end-the-run subroutine from resolving
	"shred": {
		"conditions": {},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 5.0,
	},

	# Katorga Breakout: make a run; if successful, add top heap card to grip
	"katorga_breakout": {
		"conditions": {"runner_heap_size_gte": 1},
		"snap_delta": {"runs_server": "any", "cards_drawn": 1},
		"value_bonus": 1.0,
	},

	# Window of Opportunity: install a program or hardware, then make a run
	"window_of_opportunity": {
		"conditions": {"runner_hand_has_prg_hw": true},
		"snap_delta": {"runs_server": "any", "installs_program": true},
		"value_bonus": 2.0,
	},

	# ── Tutor / search events ─────────────────────────────────────────────────

	# Test Run: search for a program, install it (returned to top of stack at turn end)
	"test_run": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"installs_breaker_if_need": true, "install_from_deck": true},
		"value_bonus": 8.0,
	},

	# Special Order: search for an icebreaker; add it to your grip
	"special_order": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"cards_drawn": 1, "install_from_deck": true},
		"value_bonus": 6.0,
	},

	# Spark of Inspiration: flip cards until you find a program; install it free
	"spark_of_inspiration": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"installs_breaker_if_need": true, "install_from_deck": true},
		"value_bonus": 8.0,
	},

	# Beta Build: search for a non-virus program; install it ignoring all costs
	"beta_build": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"installs_breaker_if_need": true, "install_from_deck": true},
		"value_bonus": 10.0,
	},

	# Meeting of Minds: search for a connection or virtual resource; install it
	"meeting_of_minds": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"installs_resource": true, "install_from_deck": true},
		"value_bonus": 5.0,
	},

	# The Price: trash top 4 of stack; may install 1 of them paying 3[c] less
	"the_price": {
		"conditions": {"runner_deck_size_gte": 4},
		"snap_delta": {"installs_breaker_if_need": true, "install_from_deck": true},
		"value_bonus": 4.0,
	},

	# Scrounge: install a program from your heap, paying 3[c] less
	"scrounge": {
		"conditions": {"runner_heap_has_program": true},
		"snap_delta": {"installs_breaker_if_need": true},
		"value_bonus": 4.0,
	},

	# ── Install-discount events ───────────────────────────────────────────────

	# Rigging Up: install a program or piece of hardware, paying 3[c] less
	"rigging_up": {
		"conditions": {"runner_hand_has_prg_hw": true},
		"snap_delta": {"installs_program": true, "credits_delta": 3},
		"value_bonus": 2.0,
	},

	# Career Fair: install a resource, paying 3[c] less
	"career_fair": {
		"conditions": {"runner_hand_has_resource": true},
		"snap_delta": {"installs_resource": true, "credits_delta": 3},
		"value_bonus": 0.0,
	},

	# Modded: install a program or piece of hardware, paying 3[c] less
	"modded": {
		"conditions": {"runner_hand_has_prg_hw": true},
		"snap_delta": {"installs_program": true, "credits_delta": 3},
		"value_bonus": 0.0,
	},

	# ── Draw events (not covered by DRAW_NET) ────────────────────────────────

	# Ritual: draw 1 card for each remaining click (conservative: assume 2)
	"ritual": {
		"conditions": {"runner_clicks_gte": 2},
		"snap_delta": {"cards_drawn": 2},
		"value_bonus": 1.0,
	},

	# Blueberry! Diesel: look at top 2 of stack; keep or bottom 1; then draw 1
	"blueberry_diesel": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"cards_drawn": 1},
		"value_bonus": 2.0,
	},

	# Chrysopoeian Skimming: Corp reveals an agenda or runner gains a click and draws 1
	"chrysopoeian_skimming": {
		"conditions": {},
		"snap_delta": {"cards_drawn": 1},
		"value_bonus": 2.0,
	},

	# Lie Low: draw 4 OR remove up to 2 tags — model as draw (most common use)
	"lie_low": {
		"conditions": {},
		"snap_delta": {"cards_drawn": 4},
		"value_bonus": 0.0,
	},

	# ── Auto (partial) corrections ───────────────────────────────────────────
	# These cards have a partial auto-projection from abilities.json that already
	# models the primary economic effect.  The hint fills in what the auto-
	# projection misses (click penalties, run side-effects, tutor installs, etc.).

	# Creative Commission: gain 5cr — but lose 1 click next turn.
	# Auto-proj captures +5cr; hint corrects for the hidden click cost (~2cr value).
	"creative_commission": {
		"conditions": {},
		"snap_delta": {},
		"value_bonus": -2.0,
	},

	# VRcation: draw 4 cards — but lose 1 click next turn.
	# Auto-proj captures +4 draws; hint corrects for the hidden click cost.
	"vrcation": {
		"conditions": {"runner_deck_size_gte": 4},
		"snap_delta": {},
		"value_bonus": -2.0,
	},

	# Mutual Favor: search stack for any icebreaker; add to grip; if successful
	# run this turn, may install it for free.
	# Auto-proj partial on search_deck; hint models the key install-from-deck value.
	"mutual_favor": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"installs_breaker_if_need": true, "install_from_deck": true},
		"value_bonus": 8.0,
	},

	# Aircheck: gain 4cr; run HQ or R&D; if successful, may run a remote (RFG self).
	# Auto-proj captures +4cr; hint adds the mandatory central run component.
	"aircheck": {
		"conditions": {},
		"snap_delta": {"runs_server": "any_central"},
		"value_bonus": 4.0,
	},

	# Carpe Diem: identify mark; gain 4cr; may run mark server.
	# Auto-proj captures +4cr; hint adds the optional run on a central mark.
	"carpe_diem": {
		"conditions": {},
		"snap_delta": {"runs_server": "any_central"},
		"value_bonus": 3.0,
	},

	# Ashen Epilogue: shuffle grip + heap into stack; RFG top 5; draw 5; RFG self.
	# Only worth playing when the heap is substantial and the stack is running low.
	"ashen_epilogue": {
		"conditions": {"runner_heap_size_gte": 5, "runner_deck_size_lt": 15},
		"snap_delta": {"cards_drawn": 5},
		"value_bonus": 3.0,
	},

	# ── Complex events from spec ──────────────────────────────────────────────

	# Harmony AR Therapy: shuffle up to 5 named cards from heap back into stack
	"harmony_ar_therapy": {
		"conditions": {"runner_heap_size_gte": 5, "runner_deck_size_lt": 15},
		"snap_delta": {},
		"value_bonus": 5.0,
	},

	# In the Groove: for rest of turn, each install costs 2[c] less (not unique)
	"in_the_groove": {
		"conditions": {"runner_clicks_gte": 3, "runner_installable_hand_gte": 3},
		"snap_delta": {"installs_program": true},
		"value_bonus": 6.0,
	},

	# Khusyuk: already defined above in run events section

	# Rejig: trash an installed program or hardware; install a card from grip ignoring cost
	"rejig": {
		"conditions": {"runner_hand_has_prg_hw": true, "runner_prg_count_gte": 1},
		"snap_delta": {"installs_program": true},
		"value_bonus": 3.0,
	},

	# Concerto: reveal top card of stack; place credits equal to its cost on this; draw 1
	"concerto": {
		"conditions": {"runner_deck_size_gte": 1},
		"snap_delta": {"cards_drawn": 1, "credits_delta": 3},
		"value_bonus": 1.0,
	},

	# Reprise: only useful immediately after stealing an agenda this turn
	"reprise": {
		"conditions": {"runner_stole_agenda": true},
		"snap_delta": {},
		"value_bonus": 8.0,
	},

	# ── Vantage Point runner events ───────────────────────────────────────────

	# Chain Reaction: trash 2 Corp installed cards; Corp trashes 1 runner installed card
	# Requires successful runs on HQ, R&D, and Archives this turn.
	# Play whenever all three centrals have been successfully run (the demanding gate
	# implies late-game; Corp almost certainly has 2+ installed cards worth trashing).
	"chain_reaction": {
		"conditions": {"runner_centrals_all_run": true},
		"snap_delta": {},
		"value_bonus": 12.0,
	},

	# Kompromat: run any iced server; Corp must derez 1 ice on that server or take 1 bad pub
	# Corp will almost always derez rather than accept bad pub, weakening their ice stack.
	# Gate on the Corp having rezzed ice on a central — that's where the derez is most painful.
	"kompromat": {
		"conditions": {"corp_central_has_rezzed_ice": true},
		"snap_delta": {"runs_server": "any"},
		"value_bonus": 6.0,
	},

	# Tailgate: run HQ; if successful, access 2 additional cards (same as Legwork)
	# Play cost decreases by 1 per ice on HQ; value is pure HQ multiaccess.
	"tailgate": {
		"conditions": {},
		"snap_delta": {"runs_server": "hq"},
		"value_bonus": 8.0,
	},

	# Take a Dive: run HQ or R&D; if successful AND a subroutine resolved, Corp gets 1 bad pub
	# Play when a central has rezzed ice so a subroutine can fire. The runner deliberately
	# lets a non-punitive sub resolve. Breakable ice is a reasonable proxy — if the runner
	# can break it, the sub is likely taxing but not devastating.
	"take_a_dive": {
		"conditions": {"corp_central_has_rezzed_ice": true},
		"snap_delta": {"runs_server": "any_central"},
		"value_bonus": 8.0,
	},
}
