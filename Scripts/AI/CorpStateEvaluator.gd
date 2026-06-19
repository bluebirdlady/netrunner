class_name CorpStateEvaluator
extends RefCounted

# ── CorpStateEvaluator ────────────────────────────────────────────────────────
# Converts a live GameContext into a lightweight SimState snapshot and
# evaluates it from the Corp's perspective.  All projection methods are
# approximate first-order effects — they do not invoke the real TurnManager.
#
# SimState Dictionary schema
# ─────────────────────────────────────────────────────────────────────────────
#   corp_credits    : int
#   runner_credits  : int
#   corp_score      : int   — agenda points
#   runner_score    : int
#   pts_to_win      : int
#   turn_number     : int
#   runner_hand     : int   — grip size
#   corp_hand       : int
#   corp_hand_limit : int   — max hand size (identity-aware)
#   corp_deck       : int
#   runner_deck     : int
#   runner_tags     : int
#   runner_rig      : int   — total installed runner cards
#   runner_breaker_count  : int   — installed icebreakers only
#   runner_has_fracter    : bool
#   runner_has_killer     : bool
#   runner_has_decoder    : bool
#   runner_has_ai_breaker : bool
#   hq_ice          : int
#   hq_ice_barrier  : bool
#   hq_ice_sentry   : bool
#   hq_ice_code_gate: bool
#   rd_ice          : int
#   rd_ice_barrier  : bool
#   rd_ice_sentry   : bool
#   rd_ice_code_gate: bool
#   corp_identity   : String  — identity card ID
#   corp_discard_sz : int   — size of Archives
#   corp_net_damage_potential : int  — damage ops in hand + Shock in Archives
#   tag_package_strength    : float — max exploit-card strength in deck+hand+identity (0=none)
#   tag_exploit_in_hand     : bool  — an exploit card is available right now
#   expected_runner_tags    : float — fractional tags expected from installed tagging ice
#   remotes         : Array[Dictionary]
#                     each: { server_id, ice_count, has_agenda, adv, req,
#                             has_barrier, has_sentry, has_code_gate }

const WIN_VALUE  :=  10000.0
const LOSE_VALUE := -10000.0

# Operations that deal direct damage — used when computing corp_net_damage_potential.
const DAMAGE_OP_IDS := ["neurospike", "measured_response", "punitive_counterstrike", "boom", "scorched_earth",
	"end_of_the_line",
	# Midnight Sun
	"mutually_assured_destruction"]   # creates tags that enable kill lines

# ── Tag exploitation registry ─────────────────────────────────────────────────
# Cards that the Corp can USE when the runner is tagged.
# Strength 0.0–2.0: how powerfully the card exploits the tagged state.
# • 1.5  — game-swinging (recover stolen agenda, instant win condition)
# • 1.0–1.2 — high impact (trash rig, heavy credit drain)
# • 0.5–0.7 — medium impact (modest credit gain, conditional recovery)
const TAG_EXPLOIT_CARD_STRENGTH: Dictionary = {
	"ip_enforcement":  1.5,   # recover stolen agenda
	"bigger_picture":  1.2,   # drain 5cr × tags, Corp gains equal
	"retribution":     1.0,   # trash runner program or hardware
	# Parhelion
	"end_of_the_line":            1.2,   # 4 meat damage, removes 1 tag as cost
	"shipment_from_vladisibirsk": 1.0,   # 4 advancements if runner has 2+ tags
	"hypoxia":                    0.8,   # 1 core damage + −1 click next turn (tagged)
	# Midnight Sun
	"backroom_machinations":      0.8,   # costs 1 runner tag → Corp gains 1 agenda point
	"trust_operation":            0.7,   # install+rez from Archives + trash runner resource
	"artificial_cryptocrash":     0.9,   # on score: runner loses 7cr — devastating credit swing
	"mutually_assured_destruction": 0.6, # iterative rezzed-card trash gives runner tags; feeds kill lines
}
const TAG_EXPLOIT_IDENTITY_STRENGTH: Dictionary = {
	"synapse_global_faster_than_thought":       0.7,   # click + tag → 2cr + free install
	# Midnight Sun
	"ob_superheavy_logistics_extract_export_excel": 0.3, # Ob enables fast board recovery; minor tag synergy via MAD
	"pravdivost_consulting_political_solutions":     0.2, # advancement identity; minor tag relevance
}

# ── Tag-producing ice registry ────────────────────────────────────────────────
# Ice that give the runner tags when encountered (or rezzed).
# Used in project_corp_action to add a fractional "expected_runner_tags" signal
# to the snapshot so the MCTS can plan "install tagging ice + hold exploit" lines.
#
# Each entry:
#   base_yield  : float  — expected tags per encounter if no relevant breaker present
#   breaker_type: String — if runner has this breaker, reduce yield by BREAK_YIELD_FACTOR
#                          "" means no break-based reduction (passive/on-rez effects)
#   mechanism   : String — "sub" | "passive" | "on_rez"
#     "sub"    : subroutine-based; runner can break with the right breaker
#     "passive": fires when runner passes/encounters regardless of breaking
#     "on_rez" : fires when Corp rezzes, before runner can break (most reliable)
const TAG_ICE_YIELD: Dictionary = {
	# Subroutine-based ─────────────────────────────────────────────────────────
	"doomscroll":            {"base_yield": 1.0, "breaker_type": "killer",  "mechanism": "sub"},
	"jaguarundi":            {"base_yield": 1.5, "breaker_type": "killer",  "mechanism": "sub"},   # sub + Threat-4 encounter trigger
	"pharos":                {"base_yield": 1.0, "breaker_type": "",        "mechanism": "sub"},   # neutral (no standard breaker applies)
	"hammer":                {"base_yield": 1.0, "breaker_type": "killer",  "mechanism": "sub"},   # break-limit makes sub reliable even vs killers
	"cloud_eater":           {"base_yield": 1.8, "breaker_type": "killer",  "mechanism": "sub"},   # 2-tag sub + rezzed-this-turn trigger
	"seraph":                {"base_yield": 0.5, "breaker_type": "killer",  "mechanism": "sub"},   # runner often pays credits or takes net damage instead
	"vicsek":                {"base_yield": 0.7, "breaker_type": "killer",  "mechanism": "sub"},   # sub2: 1 tag (sub1 scales with existing tags)
	# Passive ──────────────────────────────────────────────────────────────────
	"virtual_service_agent": {"base_yield": 0.8, "breaker_type": "decoder", "mechanism": "passive"},  # tag if no decoder broke
	"phoneutria":            {"base_yield": 0.5, "breaker_type": "",        "mechanism": "passive"},  # tag if runner grip >= 4
	"lethe":                 {"base_yield": 0.8, "breaker_type": "",        "mechanism": "passive"},  # tag when bypassed OR fully broken — fires for skilled runners
	# On-rez ───────────────────────────────────────────────────────────────────
	"ping":                  {"base_yield": 1.0, "breaker_type": "",        "mechanism": "on_rez"},   # tag fires immediately on rez, unbreakable
	# Midnight Sun
	"vasilisa":              {"base_yield": 1.0, "breaker_type": "decoder", "mechanism": "sub"},      # sub: give Runner 1 tag; advanceable for extra counter income
}

# When the runner has the relevant breaker type, scale yield down by this factor.
# (Runner can break the tag sub but may choose not to every run.)
const BREAK_YIELD_FACTOR := 0.15

# Base run-probability estimates per server type, used when live ctx is unavailable.
const SERVER_RUN_PROB_FALLBACK: Dictionary = {
	"hq":       0.40,
	"rd":       0.50,
	"archives": 0.10,
}


# ── Private helpers ───────────────────────────────────────────────────────────

# Compute the positional value of `tags` runner tags, given the Corp's
# tag-exploitation package.  Returns 0 when the Corp has no exploiters.
#
# Design:
#   • No package → 0  (irrelevant for this Corp build)
#   • Has package in deck only → base value, future payoff discount
#   • Has package in hand → 1.5× bonus, payoff is immediate
#
# Diminishing returns:
#   • Tag 1 → full per-tag value
#   • Tag 2 → 55%  (still useful: bigger_picture drains more, ip_enforcement covers 2-pt agendas)
#   • Tags 3+ → 25%  (law-of-large-tags: already have surplus; marginal value low)
func _tag_value(tags: int, s: Dictionary) -> float:
	if tags <= 0:
		return 0.0
	var pkg_strength: float = s.get("tag_package_strength", 0.0) as float
	if pkg_strength <= 0.0:
		return 0.0   # this Corp build doesn't exploit tags

	# Base value per first tag scales with how powerful the exploiters are.
	var base: float = 3.5 * pkg_strength

	# Accumulate with diminishing multipliers.
	var total: float = 0.0
	for i in range(tags):
		var mult: float
		if   i == 0: mult = 1.00
		elif i == 1: mult = 0.55
		else:        mult = 0.25
		total += base * mult

	# Immediate vs. future: exploitation in hand spikes current value because
	# the Corp can punish THIS turn rather than waiting for the right draw.
	var in_hand: bool = s.get("tag_exploit_in_hand", false) as bool
	if in_hand:
		total *= 1.5

	return total


# Float variant of _tag_value — used when blending confirmed + expected tags.
# Identical logic but accepts a fractional tag count.
func _tag_value_float(tags: float, s: Dictionary) -> float:
	if tags <= 0.0:
		return 0.0
	var pkg_strength: float = s.get("tag_package_strength", 0.0) as float
	if pkg_strength <= 0.0:
		return 0.0
	var base: float = 3.5 * pkg_strength
	var total: float = 0.0
	var remaining: float = tags
	var i: int = 0
	while remaining > 0.0:
		var mult: float
		if   i == 0: mult = 1.00
		elif i == 1: mult = 0.55
		else:        mult = 0.25
		var portion: float = minf(remaining, 1.0)
		total    += base * mult * portion
		remaining -= portion
		i        += 1
	var in_hand: bool = s.get("tag_exploit_in_hand", false) as bool
	if in_hand:
		total *= 1.5
	return total


# Returns {barrier, sentry, code_gate} presence flags for all ice on a server.
func _server_ice_subtypes(server: Server) -> Dictionary:
	var result := {"barrier": false, "sentry": false, "code_gate": false}
	if server == null:
		return result
	for ic in server.ice:
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		if c.card_record.has_subtype("barrier"):
			result["barrier"] = true
		if c.card_record.has_subtype("sentry"):
			result["sentry"] = true
		if c.card_record.has_subtype("code_gate"):
			result["code_gate"] = true
	return result


# Returns a unique projected server ID for newly-created remote entries.
# Uses remotes.size() as the suffix so IDs never collide with "remote_N"
# (which the live game uses) or each other within a single projection chain.
static func _next_proj_server_id(remotes: Array) -> String:
	return "proj_remote_%d" % remotes.size()


# Operations currently in the Corp's discard pile that may be played from
# archives (e.g. Petty Cash).  Returns Array[CardRecord].
static func _snap_archives_ops(ctx: GameContext, ab_reg: AbilityRegistry) -> Array:
	var result: Array = []
	for discard_entry in ctx.corp_discard:
		var dc: CardRecord = discard_entry as CardRecord
		if dc == null or dc.card_type != "operation":
			continue
		# Check for explicit "play_from_archives" flag in ability registry,
		# or match the known Petty Cash card directly.
		var is_playable := dc.id == "petty_cash"
		if not is_playable and ab_reg != null:
			is_playable = (ab_reg._abilities.get(dc.id, {}) as Dictionary
				).get("play_from_archives", false) as bool
		if not is_playable:
			continue
		# Exclude ops that require the first action this turn once that window has passed.
		if ctx.corp_finished_an_action_this_turn and ab_reg != null:
			var op_def: Dictionary = ab_reg._abilities.get(dc.id, {}) as Dictionary
			if op_def.get("requires_first_action_this_turn", false):
				continue
		result.append(dc)
	return result


# Rezzed installed assets that still have an available click ability this turn.
# Returns Array[Dictionary]: each entry has instance_id, card_id, server_id.
static func _snap_click_assets(ctx: GameContext, ab_reg: AbilityRegistry) -> Array:
	var result: Array = []
	if ab_reg == null:
		return result
	for srv_key in ctx.servers:
		var srv: Server = ctx.servers[srv_key] as Server
		if srv == null:
			continue
		for root_c in srv.root:
			var ic: InstalledCard = root_c as InstalledCard
			if ic == null or not ic.is_rezzed or ic.card_record == null:
				continue
			if ic.card_record.card_type != "asset":
				continue
			var ic_def: Dictionary = ab_reg._abilities.get(ic.card_id, {}) as Dictionary
			var ca_def: Dictionary = ic_def.get("click_action", {}) as Dictionary
			if ca_def.is_empty():
				continue
			# Respect once-per-turn guard.
			var opt_key: String = ca_def.get("once_per_turn_key", "") as String
			if opt_key != "":
				var full_key := "%s:%s" % [ic.runtime_instance_id, opt_key]
				if ctx.once_per_turn_triggered.get(full_key, false):
					continue
			result.append({
				"instance_id": ic.runtime_instance_id,
				"card_id":     ic.card_id,
				"server_id":   srv_key,
			})
	return result


# Total virus counters on all installed runner virus programs.
# Used by SCG to decide whether to generate a purge_virus candidate.
static func _snap_runner_virus_total(ctx: GameContext) -> int:
	var total := 0
	for r in ctx.runner_rig:
		var ic: InstalledCard = r as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		if ic.card_record.has_subtype("virus"):
			total += ic.get_counter("virus")
	return total


# Installed runner resources visible to the Corp (all installed resources).
# Returns Array[{instance_id, card_id, cost}] for SCG trash-resource candidates.
static func _snap_runner_resources(ctx: GameContext) -> Array:
	var result: Array = []
	for r in ctx.runner_rig:
		var ic: InstalledCard = r as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		if ic.card_record.card_type == "resource":
			result.append({
				"instance_id": ic.runtime_instance_id,
				"card_id":     ic.card_id,
				"cost":        max(0, ic.card_record.cost),
			})
	return result


# ── Snapshot ──────────────────────────────────────────────────────────────────

func snapshot(ctx: GameContext) -> Dictionary:
	var hq_server: Server = ctx.get_server("hq")
	var rd_server: Server = ctx.get_server("rd")
	var identity_id: String = ctx.corp_identity.id if ctx.corp_identity != null else ""

	# ── Remote server entries (include ice subtype flags) ─────────────────────
	var remotes: Array = []
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if not s.is_remote():
			continue
		var agenda_ic: InstalledCard = null
		for c in s.root:
			var ic: InstalledCard = c as InstalledCard
			if ic != null and ic.card_record != null and ic.card_record.is_agenda():
				agenda_ic = ic
				break
		# Find any advanceable non-agenda (trap) in this server's root.
		var trap_ic: InstalledCard = null
		for c in s.root:
			var ic: InstalledCard = c as InstalledCard
			if ic != null and ic.card_record != null \
					and not ic.card_record.is_agenda() and ic.can_be_advanced():
				trap_ic = ic
				break
		# Find any asset in this server's root.
		var asset_ic: InstalledCard = null
		for c in s.root:
			var aic: InstalledCard = c as InstalledCard
			if aic != null and aic.card_record != null and aic.card_record.is_asset():
				asset_ic = aic
				break
		# root_type: what occupies the root slot (for install-slot legality in SCG).
		var root_type_s: String = ""
		if   agenda_ic != null: root_type_s = "agenda"
		elif trap_ic   != null: root_type_s = "trap"
		elif asset_ic  != null: root_type_s = "asset"
		var s_sub := _server_ice_subtypes(s)
		remotes.append({
			"server_id":       key,
			"ice_count":       s.ice.size(),
			"has_agenda":      agenda_ic != null,
			"adv":             agenda_ic.get_counter("advancement") if agenda_ic != null else 0,
			"req":             agenda_ic.card_record.advancement_requirement if agenda_ic != null else 0,
			"agenda_card_id":  agenda_ic.card_id if agenda_ic != null else "",
			"agenda_points":   agenda_ic.card_record.agenda_points if agenda_ic != null else 0,
			"root_type":       root_type_s,
			"has_trap":        trap_ic != null,
			"trap_adv":        trap_ic.get_counter("advancement") if trap_ic != null else 0,
			"asset_card_id":   asset_ic.card_id if asset_ic != null else "",
			"asset_is_rezzed": asset_ic.is_rezzed if asset_ic != null else false,
			"has_barrier":     s_sub["barrier"],
			"has_sentry":      s_sub["sentry"],
			"has_code_gate":   s_sub["code_gate"],
		})

	# ── Central ice subtype presence ──────────────────────────────────────────
	var hq_sub := _server_ice_subtypes(hq_server)
	var rd_sub := _server_ice_subtypes(rd_server)

	# ── Runner rig quality ────────────────────────────────────────────────────
	var runner_breaker_count := 0
	var runner_has_fracter   := false
	var runner_has_killer    := false
	var runner_has_decoder   := false
	var runner_has_ai        := false
	for ic in ctx.runner_rig:
		var rr: InstalledCard = ic as InstalledCard
		if rr == null or rr.card_record == null:
			continue
		var cr: CardRecord = rr.card_record
		if cr.has_subtype("ai"):
			runner_has_ai         = true
			runner_breaker_count += 1
		elif cr.has_subtype("fracter"):
			runner_has_fracter    = true
			runner_breaker_count += 1
		elif cr.has_subtype("killer"):
			runner_has_killer     = true
			runner_breaker_count += 1
		elif cr.has_subtype("decoder"):
			runner_has_decoder    = true
			runner_breaker_count += 1

	# ── Installed upgrades ───────────────────────────────────────────────────
	var upgrade_count := 0
	for srv_entry in ctx.servers.values():
		var usrv: Server = srv_entry as Server
		if usrv == null:
			continue
		for uc in usrv.root:
			var uic: InstalledCard = uc as InstalledCard
			if uic != null and uic.card_record != null and uic.card_record.card_type == "upgrade":
				upgrade_count += 1

	# ── Corp damage potential ─────────────────────────────────────────────────
	var corp_dmg_potential := 0
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card != null and card.id in DAMAGE_OP_IDS:
			corp_dmg_potential += 1
	for discard_entry in ctx.corp_discard:
		var card: CardRecord = discard_entry as CardRecord
		if card != null and card.id == "shock":
			corp_dmg_potential += 1

	# ── Tag exploitation package ─────────────────────────────────────────────
	# Scan the Corp's full accessible card pool (deck + hand + identity) to
	# determine whether the Corp can exploit a tagged runner at all.
	# Results are baked into the snapshot so every evaluate() call is free.
	var tag_pkg_strength:   float = 0.0
	var tag_exploit_in_hand: bool = false
	# Identity check (always "in deck" level)
	if identity_id != "":
		var id_str: float = TAG_EXPLOIT_IDENTITY_STRENGTH.get(identity_id, 0.0) as float
		tag_pkg_strength = max(tag_pkg_strength, id_str)
	# Deck scan — establishes the baseline "package" for the whole game
	for deck_entry in ctx.corp_deck:
		var dc: CardRecord = deck_entry as CardRecord
		if dc == null:
			continue
		var d_str: float = TAG_EXPLOIT_CARD_STRENGTH.get(dc.id, 0.0) as float
		if d_str > 0.0:
			tag_pkg_strength = max(tag_pkg_strength, d_str)
	# Hand scan — exploit available immediately bumps the in-hand flag
	for hand_entry in ctx.corp_hand:
		var hc: CardRecord = (hand_entry as Dictionary).get("card_record", null) as CardRecord
		if hc == null:
			continue
		var h_str: float = TAG_EXPLOIT_CARD_STRENGTH.get(hc.id, 0.0) as float
		if h_str > 0.0:
			tag_pkg_strength    = max(tag_pkg_strength, h_str)
			tag_exploit_in_hand = true
	# Oracle Thinktank in runner's score area counts as in-hand exploit
	# (available as a Corp click action) when the runner has scored agendas.
	if not ctx.runner_score_area_cards.is_empty():
		for sac in ctx.runner_score_area_cards:
			var sc: InstalledCard = sac as InstalledCard
			if sc == null or sc.card_record == null:
				continue
			if sc.card_record.id == "oracle_thinktank":
				tag_pkg_strength    = max(tag_pkg_strength, 0.5)
				tag_exploit_in_hand = true
				break

	# ── Corp hand cards + pre-play conditions (for SnapshotCandidateGenerator) ──
	# corp_hand_cards: Array[CardRecord] — object references, treated as immutable.
	# corp_hand_ppc:   Dictionary — card_id → bool (pre_play_condition met?).
	var hand_cards: Array      = []
	var hand_ppc:   Dictionary = {}
	var snap_ab_reg: AbilityRegistry = null
	if ctx.has_meta("ability_registry"):
		snap_ab_reg = ctx.get_meta("ability_registry") as AbilityRegistry
	for snap_he in ctx.corp_hand:
		var snap_hc: CardRecord = (snap_he as Dictionary).get("card_record", null) as CardRecord
		if snap_hc == null:
			continue
		hand_cards.append(snap_hc)
		var snap_ppc: String = ""
		if snap_ab_reg != null:
			snap_ppc = (snap_ab_reg._abilities.get(snap_hc.id, {}) as Dictionary
				).get("pre_play_condition", "") as String
		var snap_met: bool
		match snap_ppc:
			"": snap_met = true
			"runner_stole_or_trashed_last_runner_turn":
				snap_met = ctx.runner_stole_or_trashed_last_runner_turn
			"corp_scored_non_installed_agenda_this_turn":
				snap_met = ctx.corp_scored_agenda_not_installed_this_turn
			"runner_made_successful_run_last_turn":
				snap_met = ctx.runner_made_successful_run_last_turn
			# Parhelion
			"runner_stole_agenda_last_runner_turn":
				snap_met = ctx.runner_stole_agenda_last_runner_turn
			"runner_tags_gte_2":
				snap_met = ctx.runner_tags >= 2
			"runner_is_tagged":
				snap_met = ctx.runner_tags > 0
			_: snap_met = false   # unknown condition — conservative
		hand_ppc[snap_hc.id] = snap_met

	# ── Identity click action availability ────────────────────────────────────
	var id_click_avail := false
	if ctx.corp_identity != null and snap_ab_reg != null:
		var id_def2: Dictionary = snap_ab_reg._abilities.get(ctx.corp_identity.id, {}) as Dictionary
		var ca_def: Dictionary  = id_def2.get("identity_click_action",
			id_def2.get("click_action", {})) as Dictionary
		if not ca_def.is_empty():
			var snap_opt_key: String = ca_def.get("once_per_turn_key", "") as String
			var snap_used := false
			if snap_opt_key != "":
				snap_used = ctx.once_per_turn_triggered.get(
					"identity_corp:%s" % snap_opt_key, false)
			if not snap_used:
				var id_cond: Dictionary = ca_def.get("condition", {}) as Dictionary
				if id_cond.is_empty():
					id_click_avail = true
				else:
					match id_cond.get("type", ""):
						"runner_is_tagged": id_click_avail = ctx.runner_tags > 0
						_: id_click_avail = false   # unknown condition — conservative

	return {
		"corp_credits":    ctx.corp_credits,
		"runner_credits":  ctx.runner_credits,
		"corp_score":      ctx.corp_agenda_points(),
		"runner_score":    ctx.runner_agenda_points(),
		"pts_to_win":      ctx.agenda_points_to_win,
		"turn_number":     ctx.turn_number,
		"runner_hand":     ctx.runner_hand.size(),
		"corp_hand":       ctx.corp_hand.size(),
		"corp_hand_limit": ctx.corp_max_hand_size(),
		"corp_deck":       ctx.corp_deck.size(),
		"runner_deck":     ctx.runner_deck.size(),
		"runner_tags":     ctx.runner_tags,
		"runner_rig":      ctx.runner_rig.size(),
		"runner_breaker_count":    runner_breaker_count,
		"runner_has_fracter":      runner_has_fracter,
		"runner_has_killer":       runner_has_killer,
		"runner_has_decoder":      runner_has_decoder,
		"runner_has_ai_breaker":   runner_has_ai,
		"hq_ice":           hq_server.ice.size() if hq_server != null else 0,
		"hq_ice_barrier":   hq_sub["barrier"],
		"hq_ice_sentry":    hq_sub["sentry"],
		"hq_ice_code_gate": hq_sub["code_gate"],
		"rd_ice":           rd_server.ice.size() if rd_server != null else 0,
		"rd_ice_barrier":   rd_sub["barrier"],
		"rd_ice_sentry":    rd_sub["sentry"],
		"rd_ice_code_gate": rd_sub["code_gate"],
		"corp_identity":   identity_id,
		"corp_discard_sz": ctx.corp_discard.size(),
		"corp_net_damage_potential": corp_dmg_potential,
		"corp_installed_upgrades":   upgrade_count,
		"corp_clicks_left":               ctx.corp_clicks,
		"tag_package_strength":           tag_pkg_strength,
		"tag_exploit_in_hand":            tag_exploit_in_hand,
		"expected_runner_tags":           0.0,   # accumulated by project_corp_action ice installs
		"corp_hand_cards":                hand_cards,
		"corp_hand_ppc":                  hand_ppc,
		"corp_identity_click_available":  id_click_avail,
		"corp_archives_ops":              _snap_archives_ops(ctx, snap_ab_reg),
		"corp_installed_click_assets":    _snap_click_assets(ctx, snap_ab_reg),
		"runner_virus_total":             _snap_runner_virus_total(ctx),
		"runner_resources":               _snap_runner_resources(ctx),
		"runner_core_damage":             ctx.runner_core_damage_taken,
		"corp_identity_power_counters":   ctx.corp_identity_counters.get("power", 0),
		"remotes":                        remotes,
	}


# ── Evaluation ────────────────────────────────────────────────────────────────

# Returns a float score from the Corp's perspective.  Higher = better for Corp.
func evaluate(s: Dictionary) -> float:
	var corp_score:   int = s.get("corp_score",   0) as int
	var runner_score: int = s.get("runner_score", 0) as int
	var pts_to_win:   int = s.get("pts_to_win",   7) as int

	var identity: String = s.get("corp_identity", "") as String

	# ── Issuaq Adaptics: Sustaining Diversity — effective win threshold ────────
	# Power counters on the identity reduce the agenda points the Corp needs to win.
	var effective_corp_pts: int = pts_to_win
	if identity == "issuaq_adaptics_sustaining_diversity":
		var isq_pw: int = s.get("corp_identity_power_counters", 0) as int
		effective_corp_pts = max(1, pts_to_win - isq_pw)

	# Terminal check
	if corp_score   >= effective_corp_pts: return WIN_VALUE
	if runner_score >= pts_to_win:         return LOSE_VALUE

	var score := 0.0

	# ── Near-loss stall detection ──────────────────────────────────────────────
	# When the runner is one steal from winning and the Corp has no protected
	# installed agenda, apply a heavy penalty so the evaluator still
	# differentiates between "ice the naked remote" and "gain a credit"
	# rather than collapsing both to the same flat near-LOSE value.
	if runner_score >= pts_to_win - 1 and corp_score < pts_to_win:
		var has_scoring_agenda := false
		for remote in s.get("remotes", []) as Array:
			var r: Dictionary = remote as Dictionary
			if r.get("has_agenda", false) and (r.get("ice_count", 0) as int) > 0:
				has_scoring_agenda = true
				break
		if not has_scoring_agenda:
			score -= 300.0

	# ── Game-phase multipliers ─────────────────────────────────────────────────
	var turn: int = s.get("turn_number", 1) as int
	var phase_econ_mult:  float = 1.0   # applied to economy and ice coverage
	var phase_score_mult: float = 1.0   # applied to score-progress component
	var late_penalty:     float = 0.0   # extra cost for falling behind late

	if turn <= 6:
		# Setup phase: economy and ice are the foundations; score urgency is low.
		phase_econ_mult  = 1.3
		phase_score_mult = 0.7
	elif turn >= 14:
		# Late game: urgency spikes; falling behind compounds each turn.
		phase_score_mult = 1.4
		var pts_behind: int = pts_to_win - corp_score
		late_penalty = float(pts_behind) * float(turn - 13) * 0.3

	# ── Progress toward winning ────────────────────────────────────────────────
	# Runner penalty is steeper — losing is worse than not winning yet.
	score += float(corp_score)   / float(pts_to_win) * 30.0 * phase_score_mult
	score -= float(runner_score) / float(pts_to_win) * 42.0 * phase_score_mult
	score -= late_penalty

	# ── Economy ────────────────────────────────────────────────────────────────
	# Corp credits have diminishing returns above ~10; capped so a large pile
	# does not dominate all other factors.
	var corp_cr: int = s.get("corp_credits", 0) as int
	score += (minf(float(corp_cr), 15.0) * 0.5 + maxf(float(corp_cr) - 15.0, 0.0) * 0.1) * phase_econ_mult
	score -= float(s.get("runner_credits", 0)) * 0.3

	# ── Ice coverage on centrals ───────────────────────────────────────────────
	score += float(s.get("hq_ice", 0)) * 1.5 * phase_econ_mult
	score += float(s.get("rd_ice", 0)) * 1.5 * phase_econ_mult

	# ── Remote scoring opportunities ───────────────────────────────────────────
	# clicks_left: Corp clicks remaining in the snapshot (decremented by
	# project_corp_action so urgency reflects the current position in the turn).
	var clicks_left: int = s.get("corp_clicks_left", 0) as int

	# ── Scoring urgency multiplier ─────────────────────────────────────────────
	# Scale advancement bonuses by how much pressure exists:
	#   • runner_fraction: how close is the runner to winning?
	#   • corp_lag: how far is the Corp from winning?
	# Multiplier grows as the race tightens, capped so it doesn't dominate
	# other signal completely.
	var runner_fraction: float = float(runner_score) / float(pts_to_win)
	var corp_lag:        float = 1.0 - (float(corp_score) / float(pts_to_win))
	var urgency_mult:    float = clampf(
		1.0 + runner_fraction * 1.5 + corp_lag * 0.5, 1.0, 3.0)

	# Count ICE in hand once so the per-agenda loop can track how many
	# naked agendas have "consumed" a mitigation slot.  One ICE in hand
	# can only protect one server this turn; a second naked agenda beyond
	# what the Corp can protect in remaining clicks still deserves the
	# full −25 penalty.
	var ice_in_hand_count: int = 0
	for nhic in s.get("corp_hand_cards", []) as Array:
		if (nhic as CardRecord) != null and (nhic as CardRecord).is_ice():
			ice_in_hand_count += 1
	var mitigated_naked: int = 0   # naked agendas that consumed a mitigation slot

	for remote in s.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if not r.get("has_agenda", false):
			continue
		var req:    int = r.get("req", 1) as int
		var adv:    int = r.get("adv", 0) as int
		var ice:    int = r.get("ice_count", 0) as int
		var needed: int = req - adv

		# ── Naked-agenda penalty ───────────────────────────────────────────────
		# An agenda with zero ice is trivially stolen on the runner's next turn.
		# Full −25 when no ice is available to fix it.
		#
		# Reduced to −5 when the Corp still has ice in hand AND this is the
		# first naked agenda (i.e. there is a free ICE slot to protect it):
		# within a single Corp turn the runner cannot act, so "advance → install
		# ice" is just as safe as "install ice → advance" for runner-access
		# purposes.  But the second naked agenda — beyond what the Corp's hand
		# can protect — always gets the full −25, even if ICE exists in hand,
		# because only one server can be protected per ICE installed.
		if ice == 0:
			# Mitigation is only valid while clicks remain — if the turn is already
			# over (clicks_left == 0) the ICE in hand cannot be installed and the
			# runner will steal the agenda freely on their very next action.
			var can_mitigate: bool = clicks_left > 0 and mitigated_naked < ice_in_hand_count
			if can_mitigate:
				mitigated_naked += 1
			# Scale penalty by advancement: a 2/4 naked agenda is far more dangerous
			# than a 0/4 one — the runner has every reason to run it immediately.
			# adv=0 → ×1.0,  adv=1 → ×2.5,  adv=2 → ×4.0,  adv=3 → ×5.5
			var adv_danger: float = 1.0 + float(adv) * 1.5
			score -= (5.0 if can_mitigate else 25.0) * adv_danger

		# ── Scoring urgency (clicks-aware, pressure-scaled) ────────────────────
		# Base urgency depends on how many advances remain vs. clicks available;
		# then multiplied by urgency_mult so the Corp feels the ticking clock.
		var base_urgency: float
		if needed <= 0:
			# Agenda ready to score — highest priority.
			base_urgency = 30.0
		elif needed <= clicks_left:
			# Can finish scoring this turn with remaining clicks.
			base_urgency = 22.0
		elif needed == 1:
			# One advance to scoring: top of next turn.
			base_urgency = 15.0
		elif needed == 2:
			base_urgency = 9.0
		elif needed == 3:
			base_urgency = 5.0
		else:
			base_urgency = 3.0

		score += base_urgency * urgency_mult

		# ── Partial advancement bonus ──────────────────────────────────────────────
		# Each advancement counter on an installed agenda represents concrete progress
		# toward scoring.  Without this, the evaluator treats a 0/5 agenda and a 3/5
		# agenda identically (both just get the base_urgency for "needed > 2").
		# Multiplied by urgency_mult so the bonus spikes when the runner is close to
		# winning — matching the urgency of completing the plan quickly.
		#
		# Requires ice > 0: advancing a naked agenda has no stable value because the
		# runner will steal it the next turn regardless of how many counters are on it.
		# Without this guard the naked-advancement penalty (above) is still outweighed
		# by the partial bonus once the Corp has ice in hand (−5 × adv_danger vs +bonus).
		if adv > 0 and req > 0 and ice > 0:
			var partial_frac: float = float(adv) / float(req)
			score += 6.0 * partial_frac * urgency_mult

		# Ice protection bonus (up to 2 layers) — scales with runner rig strength.
		# A second ice layer matters far more against a fully-rigged runner than
		# against an unrigged one.  Higher per-layer bonus makes the beam prefer
		# adding protection over pure advancement when the runner has a complete rig.
		var rhs_full_rig: bool = \
			(s.get("runner_has_fracter", false) as bool) and \
			(s.get("runner_has_killer",  false) as bool) and \
			(s.get("runner_has_decoder", false) as bool)
		var rhs_bc: int = s.get("runner_breaker_count", 0) as int
		var ice_bonus_per_layer: float
		if identity == "jinteki_replicating_perfection":
			ice_bonus_per_layer = 0.8   # central-run tax compensates; remote ice less vital
		elif rhs_full_rig:
			ice_bonus_per_layer = 3.5   # 2nd layer critical — full rig breaks anything
		elif rhs_bc >= 2:
			ice_bonus_per_layer = 2.5   # partial rig — extra layer still meaningful
		else:
			ice_bonus_per_layer = 1.5   # unrigged runner — baseline protection value
		score += float(min(ice, 2)) * ice_bonus_per_layer

		# ── Stacking depth bonus ───────────────────────────────────────────────
		# Two ice layers are disproportionately harder to breach than one: the
		# runner must break both (doubles credit and click cost) and can no longer
		# rely on burst economy to cover a single encounter.  This non-linear bonus
		# makes the beam explicitly prefer stacking a 2nd layer over a pure
		# advancement when the runner has a partial or complete rig.
		if ice >= 2:
			var stack_bonus: float
			if identity == "jinteki_replicating_perfection":
				stack_bonus = 1.0   # safer identity — modest stacking reward
			elif rhs_full_rig:
				stack_bonus = 4.0   # full rig breaks anything: 2nd layer critical
			elif rhs_bc >= 2:
				stack_bonus = 2.5   # partial rig — meaningful extra cost to runner
			else:
				stack_bonus = 1.0   # unrigged runner — small bonus
			score += stack_bonus

	# ── Scoring infrastructure ───────────────────────────────────────────────
	# When no protected scoring agenda is currently on the board, reward building
	# the infrastructure needed to install one:
	#
	#   • Iced empty remote  → +2.0 per ice layer (≤2 layers, one remote only)
	#     Without this bonus, the beam assigns 0 value to "install ice in new_remote"
	#     and never builds a scoring slot — the Corp just accumulates credits forever.
	#
	#   • Stagnation penalty → −0.25 per credit above 10
	#     Excess credits have no strategic value when there is nothing to spend them on.
	#     This breaks the "gain_credits × 3 every turn" loop by making each credit
	#     above the threshold worth less than building scoring infrastructure.
	var has_protected_board_agenda: bool = false
	for si_remote in s.get("remotes", []) as Array:
		var si_r: Dictionary = si_remote as Dictionary
		if si_r.get("has_agenda", false) and (si_r.get("ice_count", 0) as int) > 0:
			has_protected_board_agenda = true
			break
	if not has_protected_board_agenda:
		# Bonus for the first iced empty slot (scoring infrastructure).
		for si_remote in s.get("remotes", []) as Array:
			var si_r: Dictionary = si_remote as Dictionary
			if si_r.get("root_type", "") == "" \
					and (si_r.get("ice_count", 0) as int) >= 1:
				score += float(min(si_r.get("ice_count", 0) as int, 2)) \
					* 2.0 * phase_score_mult
				break   # one protected slot is enough
		# Stagnation penalty for excess credits.
		if corp_cr > 10:
			score -= float(corp_cr - 10) * 0.25

	# ── Near-win idle penalty ──────────────────────────────────────────────────
	# When the runner is within 2 points of winning AND a protected agenda is on
	# board with zero advancement, the Corp is wasting time building credits it
	# cannot convert into a win.  Apply the same stagnation rate on top of the
	# normal evaluation so "advance" consistently beats "gain 1cr" under pressure.
	# (When adv > 0, the partial advancement bonus already captures this urgency;
	# this penalty handles the "agenda exists but nobody is advancing it" case.)
	elif runner_score >= pts_to_win - 2 and corp_cr > 10:
		var board_idle := true
		for si_idle in s.get("remotes", []) as Array:
			var si_ir: Dictionary = si_idle as Dictionary
			if si_ir.get("has_agenda", false) and \
					(si_ir.get("ice_count", 0) as int) > 0 and \
					(si_ir.get("adv", 0) as int) > 0:
				board_idle = false
				break
		if board_idle:
			score -= float(corp_cr - 10) * 0.25

	# ── Draw urgency: slot-readiness hand bonus ───────────────────────────────
	# When a protected empty scoring slot exists and there are cards left to draw,
	# each additional card held above a floor of 2 is worth more than usual —
	# it may be the agenda needed to fill the slot.
	#
	# Design (per user spec):
	#   + Scales with slot ice depth  (deeper slot = more confident the Corp can protect
	#     whatever it installs → higher value for drawing into that agenda)
	#   + Scales with Corp credits    (richer Corp can act on a drawn agenda immediately)
	#   - Respects hand-size limit    (bonus cannot accumulate beyond limit − 1)
	#
	# Net effect: draw_card scores +1–3 more than gain_credits when the slot is ready
	# and the Corp can afford to use what it draws.  Gain_credits still wins when
	# the Corp is poor (cr_ready ≈ 0) or the slot is thin (1 ice, low multiplier).
	var du_slot_ice: int = 0
	if not has_protected_board_agenda and (s.get("corp_deck", 0) as int) > 0:
		for du_r in s.get("remotes", []) as Array:
			var du_rd: Dictionary = du_r as Dictionary
			if du_rd.get("root_type", "") == "" \
					and (du_rd.get("ice_count", 0) as int) >= 1:
				du_slot_ice = max(du_slot_ice, \
					min(du_rd.get("ice_count", 0) as int, 2))
	if du_slot_ice > 0:
		var du_hand:  int   = s.get("corp_hand",       0) as int
		var du_limit: int   = s.get("corp_hand_limit", 5) as int
		# Cards in hand above a floor of 1, capped at 3.  Floor lowered from 2→1
		# so drawing from a 2-card hand (the typical state after mandatory draw only)
		# produces a positive marginal score signal rather than 0.  Cap raised to 3
		# so the incentive persists across 2→3 and 3→4 card draws.
		# Coefficient raised to 1.5 so draw beats gain-credit by a clear margin
		# (~1.3 vs ~0.65 at 7cr) rather than a coin-flip that rollout noise can invert.
		var du_extra: int = min(max(du_hand - 1, 0), 3)
		# Only apply when hand is below the limit (can still gain from drawing).
		if du_hand < du_limit and du_extra >= 0:
			var du_cr_ready: float = minf(float(corp_cr) / 8.0, 1.0)
			score += float(du_slot_ice) * float(du_extra) * du_cr_ready * 1.5

	# ── Advancement trap threat ───────────────────────────────────────────────
	# Trap cards (Clearinghouse, Urtica Cipher, etc.) in iced remotes build
	# kill potential.  Score based on proximity to the runner's grip size.
	var runner_grip_t: int = s.get("runner_hand", 5) as int
	for remote in s.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if not r.get("has_trap", false) or (r.get("ice_count", 0) as int) == 0:
			continue
		var trap_adv: int = r.get("trap_adv", 0) as int
		if trap_adv <= 0:
			continue
		var threat: int = trap_adv - runner_grip_t
		if   threat >= 0:  score += 50.0                      # activatable for kill now
		elif threat == -1: score += 20.0                      # one advance from kill
		elif threat == -2: score += 8.0                       # two advances away
		else:              score += float(trap_adv) * 1.5     # building threat

	# ── Runner tags ────────────────────────────────────────────────────────────
	# Value is conditional on the Corp having tag-exploitation cards.
	# Confirmed tags (runner_tags) are scored at full value; expected tags from
	# installed tagging ice are scored at 50% — they're probabilistic and won't
	# land until the runner's next run.
	var runner_tags: int  = s.get("runner_tags", 0) as int
	score += _tag_value(runner_tags, s)
	var expected_tags: float = s.get("expected_runner_tags", 0.0) as float
	if expected_tags > 0.0:
		# Evaluate the expected tags as if they were 0.5 certain tags each,
		# blended into the existing confirmed-tag pool for diminishing-returns calc.
		var blended_tags: float = float(runner_tags) + expected_tags * 0.5
		var blended_value: float = _tag_value_float(blended_tags, s)
		var confirmed_value: float = _tag_value(runner_tags, s)
		score += maxf(blended_value - confirmed_value, 0.0)

	# ── Installed upgrades ─────────────────────────────────────────────────────
	# Upgrades (Anoetic Void, Manegarm Skunkworks, etc.) provide run-time
	# defensive value that the runner response projector can't directly model.
	# Approximate as a flat per-upgrade bonus consistent with one ice layer.
	score += float(s.get("corp_installed_upgrades", 0)) * 1.5

	# ── Kill / flatline detection ──────────────────────────────────────────────
	# A runner with very few cards is vulnerable to a flatline.  Scale the bonus
	# by corp_net_damage_potential: tools in hand make the window exploitable now;
	# without them it is still a structurally dangerous state worth valuing.
	var runner_grip: int = s.get("runner_hand",               5) as int
	var corp_dmg:    int = s.get("corp_net_damage_potential",  0) as int

	if runner_grip <= 1:
		# Near-flatline: baseline 100 + up to 400 more with damage tools ready.
		score += 100.0 + 400.0 * clampf(float(corp_dmg) / 3.0, 0.0, 1.0)
	elif runner_grip <= 3 and runner_tags >= 1:
		# Tagged runner with low grip — punishment operations become decisive.
		score += 15.0

	# ── Corp hand size ─────────────────────────────────────────────────────────
	# Reward a healthy hand (more options), penalise a thin grip.
	var hand_limit: int = s.get("corp_hand_limit", 5) as int
	var corp_hand:  int = min(s.get("corp_hand", 0) as int, hand_limit)
	var hand_full_threshold := 3
	if corp_hand < hand_full_threshold:
		score -= float(hand_full_threshold - corp_hand) * 1.0
	elif corp_hand <= hand_limit:
		score += float(corp_hand - hand_full_threshold) * 0.4

	# ── Identity-specific bonuses ──────────────────────────────────────────────

	match identity:

		"weyland_consortium_built_to_last":
			for remote in s.get("remotes", []) as Array:
				var r: Dictionary = remote as Dictionary
				if r.get("has_agenda", false) and (r.get("adv", 0) as int) == 0:
					score += 1.5
			if corp_cr >= 4:
				score += 0.5

		"haas_bioroid_precision_design":
			score += float(corp_score) * 0.5
			var discard_sz: int = s.get("corp_discard_sz", 0) as int
			if discard_sz > 0:
				score += 0.4

		"jinteki_replicating_perfection":
			score += float(s.get("hq_ice", 0)) * 0.5
			score += float(s.get("rd_ice", 0)) * 0.5

		"jinteki_restoring_humanity":
			var discard_sz: int = s.get("corp_discard_sz", 0) as int
			if discard_sz > 0:
				score += 0.7

		# ── Parhelion identities ──────────────────────────────────────────────

		"issuaq_adaptics_sustaining_diversity":
			# Each power counter reduces the win threshold — enormous strategic value.
			var isq_pw2: int = s.get("corp_identity_power_counters", 0) as int
			score += float(isq_pw2) * 8.0
			# Scoring without advancing this turn triggers the counter.
			# Reward having installed agendas with 0 advancement (setup for the mechanic).
			for remote in s.get("remotes", []) as Array:
				var r: Dictionary = remote as Dictionary
				if r.get("has_agenda", false) and (r.get("adv", 0) as int) == 0 \
						and (r.get("ice_count", 0) as int) > 0:
					score += 1.5   # protected 0-adv agenda = potential free counter

		"thule_subsea_safety_below":
			# Whenever the runner steals an agenda, they take 1 core damage unless
			# they spend [click]+2cr.  This makes naked agendas less catastrophic
			# and each stacked core damage weakens the runner.
			var thule_core: int = s.get("runner_core_damage", 0) as int
			if thule_core >= 1:
				score += float(thule_core) * 2.0   # stacked core damage is dangerous
			# Partially offset the naked-agenda penalty: runner always pays to steal.
			for remote in s.get("remotes", []) as Array:
				var r: Dictionary = remote as Dictionary
				if r.get("has_agenda", false) and (r.get("ice_count", 0) as int) == 0:
					score += 6.0   # mitigate −25 → net ≈ −19 still bad but less dire

	return score


# ── Corp action projection ────────────────────────────────────────────────────

# Returns a new SimState after the Corp plays one click action.
# Does NOT create or modify live GameContext state.
func project_corp_action(s: Dictionary, action: GameAction, _ctx: GameContext) -> Dictionary:
	var ns: Dictionary = s.duplicate(true)
	var identity: String = s.get("corp_identity", "") as String

	# Every Corp action costs 1 click — track remaining clicks in the snapshot
	# so evaluate() can compute scoring urgency correctly.
	ns["corp_clicks_left"] = max(0, (s.get("corp_clicks_left", 0) as int) - 1)

	match action.type:
		"gain_credits":
			ns["corp_credits"] = (s.get("corp_credits", 0) as int) + 1

		"draw_card":
			var hand_limit: int = s.get("corp_hand_limit", 5) as int
			ns["corp_hand"] = min((s.get("corp_hand", 0) as int) + 1, hand_limit)
			ns["corp_deck"] = max(0, (s.get("corp_deck", 0) as int) - 1)

		"install":
			var card:      CardRecord = action.params.get("card_record", null) as CardRecord
			var server_id_i: String   = action.params.get("server_id",   "") as String
			var zone_i:      String   = action.params.get("zone",        "") as String

			if card == null:
				# Symbolic ice install from MCTS deep candidates.
				if zone_i == "root" and server_id_i != "":
					# Symbolic agenda install: null card + zone="root" means the Corp
					# is installing an agenda into an already-iced remote.
					# Use req=3 as the average advancement requirement.
					ns["corp_hand"] = max(0, (s.get("corp_hand", 0) as int) - 1)
					var remotes_sym_a: Array = (ns.get("remotes", []) as Array).duplicate(true)
					for i in range(remotes_sym_a.size()):
						var r: Dictionary = (remotes_sym_a[i] as Dictionary).duplicate()
						if r.get("server_id", "") == server_id_i:
							r["has_agenda"] = true
							r["adv"]        = 0
							r["req"]        = 3
							remotes_sym_a[i] = r
							break
					ns["remotes"] = remotes_sym_a
					return ns

				if zone_i != "ice" or server_id_i == "":
					return ns
				ns["corp_hand"] = max(0, (s.get("corp_hand", 0) as int) - 1)
				var sym_cost: int = 0
				match server_id_i:
					"hq":
						sym_cost = s.get("hq_ice", 0) as int
						ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - sym_cost)
						ns["hq_ice"] = sym_cost + 1
					"rd":
						sym_cost = s.get("rd_ice", 0) as int
						ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - sym_cost)
						ns["rd_ice"] = sym_cost + 1
					_:
						var remotes_sym: Array = (ns.get("remotes", []) as Array).duplicate(true)
						for i in range(remotes_sym.size()):
							var r: Dictionary = (remotes_sym[i] as Dictionary).duplicate()
							if r.get("server_id", "") == server_id_i:
								sym_cost = r.get("ice_count", 0) as int
								ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - sym_cost)
								r["ice_count"] = sym_cost + 1
								remotes_sym[i] = r
								break
						ns["remotes"] = remotes_sym
				return ns

			ns["corp_hand"] = max(0, (s.get("corp_hand", 0) as int) - 1)
			# Remove the specific card from corp_hand_cards (object identity match).
			var rhcc: Array = (ns.get("corp_hand_cards", []) as Array).duplicate()
			for rhcc_i in range(rhcc.size()):
				if rhcc[rhcc_i] == card:
					rhcc.remove_at(rhcc_i)
					break
			ns["corp_hand_cards"] = rhcc

			if card.is_ice():
				var server_id: String = action.params.get("server_id", "") as String
				var ice_install_cost: int = 0
				match server_id:
					"hq": ice_install_cost = s.get("hq_ice", 0) as int
					"rd": ice_install_cost = s.get("rd_ice", 0) as int
					_:
						for remote in s.get("remotes", []) as Array:
							if (remote as Dictionary).get("server_id", "") == server_id:
								ice_install_cost = (remote as Dictionary).get("ice_count", 0) as int
								break
				ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - ice_install_cost)
				# Update ice count and subtype flags for the target server.
				match server_id:
					"hq":
						ns["hq_ice"] = (s.get("hq_ice", 0) as int) + 1
						if card.has_subtype("barrier"):   ns["hq_ice_barrier"]   = true
						if card.has_subtype("sentry"):    ns["hq_ice_sentry"]    = true
						if card.has_subtype("code_gate"): ns["hq_ice_code_gate"] = true
					"rd":
						ns["rd_ice"] = (s.get("rd_ice", 0) as int) + 1
						if card.has_subtype("barrier"):   ns["rd_ice_barrier"]   = true
						if card.has_subtype("sentry"):    ns["rd_ice_sentry"]    = true
						if card.has_subtype("code_gate"): ns["rd_ice_code_gate"] = true
					_:
						var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
						if server_id == "new_remote":
							# Create a new remote entry with this ice as its first layer.
							remotes_copy.append({
								"server_id":       _next_proj_server_id(remotes_copy),
								"ice_count":       1,
								"has_agenda":      false,
								"adv":             0,
								"req":             0,
								"agenda_card_id":  "",
								"agenda_points":   0,
								"root_type":       "",
								"has_trap":        false,
								"trap_adv":        0,
								"asset_card_id":   "",
								"asset_is_rezzed": false,
								"has_barrier":     card.has_subtype("barrier"),
								"has_sentry":      card.has_subtype("sentry"),
								"has_code_gate":   card.has_subtype("code_gate"),
							})
						else:
							for i in range(remotes_copy.size()):
								var r: Dictionary = (remotes_copy[i] as Dictionary).duplicate()
								if r.get("server_id", "") == server_id:
									r["ice_count"] = (r.get("ice_count", 0) as int) + 1
									if card.has_subtype("barrier"):   r["has_barrier"]   = true
									if card.has_subtype("sentry"):    r["has_sentry"]    = true
									if card.has_subtype("code_gate"): r["has_code_gate"] = true
									remotes_copy[i] = r
									break
						ns["remotes"] = remotes_copy

				# ── Prospective tag yield ──────────────────────────────────────────
				# If this ice produces runner tags (sub, passive, or on-rez), accumulate
				# a fractional expected-tag signal so the evaluator can value the plan
				# "install tagging ice → exploit later" before the tag actually lands.
				var ity: Dictionary = TAG_ICE_YIELD.get(card.id, {}) as Dictionary
				if not ity.is_empty():
					var base_yield: float  = ity.get("base_yield",   0.0) as float
					var breaker_t:  String = ity.get("breaker_type", "")  as String
					var mechanism:  String = ity.get("mechanism",    "sub") as String

					# On-rez ice fires during approach before breaking — very reliable.
					var run_prob: float
					if mechanism == "on_rez":
						run_prob = 0.90
					elif server_id in SERVER_RUN_PROB_FALLBACK:
						run_prob = SERVER_RUN_PROB_FALLBACK[server_id] as float
					else:
						# Remote: higher run probability when an agenda is present.
						var has_agenda_r: bool = false
						for rr in s.get("remotes", []) as Array:
							if (rr as Dictionary).get("server_id", "") == server_id and \
							   (rr as Dictionary).get("has_agenda", false):
								has_agenda_r = true
								break
						run_prob = 0.35 if has_agenda_r else 0.12

					# Reduce yield when the runner already has the counter-breaker.
					var yield_adj: float = base_yield
					if breaker_t != "":
						if _ctx != null:
							for rig_ic in _ctx.runner_rig:
								var rr: InstalledCard = rig_ic as InstalledCard
								if rr != null and rr.card_record != null and \
								   rr.card_record.has_subtype(breaker_t):
									yield_adj = base_yield * BREAK_YIELD_FACTOR
									break
						else:
							yield_adj = base_yield * 0.5   # conservative fallback

					ns["expected_runner_tags"] = \
						(s.get("expected_runner_tags", 0.0) as float) + (yield_adj * run_prob)

			elif card.is_agenda():
				var ag_server: String = action.params.get("server_id", "new_remote") as String
				# New agenda remotes always start naked (ice_count=0).
				# The evaluator's can_mitigate logic reduces the naked penalty to −5
				# when ICE is in hand and clicks remain, so Install-Agenda→Install-ICE
				# sequences still look attractive without phantom projected ICE.
				# The old proj_ice optimization was causing two bugs:
				#   1. Overcounting: phantom +1 then real install +1 = 2 layers reported.
				#   2. has_naked_agenda bypass: the projected remote appeared protected,
				#      so the candidate gen would offer a second new_remote install
				#      without detecting the first agenda was still naked.
				var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
				if ag_server == "new_remote" or ag_server == "projected":
					# Create a new projected remote entry — always naked at creation.
					remotes_copy.append({
						"server_id":       _next_proj_server_id(remotes_copy),
						"ice_count":       0,
						"has_agenda":      true,
						"adv":             0,
						"req":             card.advancement_requirement,
						"agenda_card_id":  card.id,
						"agenda_points":   card.agenda_points,
						"root_type":       "agenda",
						"has_trap":        false,
						"trap_adv":        0,
						"asset_card_id":   "",
						"asset_is_rezzed": false,
						"has_barrier":     false,
						"has_sentry":      false,
						"has_code_gate":   false,
					})
				else:
					# Install into an existing named remote (SCG-generated target).
					for agi in range(remotes_copy.size()):
						var agr: Dictionary = (remotes_copy[agi] as Dictionary).duplicate()
						if agr.get("server_id", "") == ag_server:
							agr["has_agenda"]     = true
							agr["adv"]            = 0
							agr["req"]            = card.advancement_requirement
							agr["agenda_card_id"] = card.id
							agr["agenda_points"]  = card.agenda_points
							agr["root_type"]      = "agenda"
							remotes_copy[agi] = agr
							break
				ns["remotes"] = remotes_copy

			elif card.card_type == "upgrade":
				# Upgrades install for free (rez cost is separate).
				# Record the new upgrade so evaluate() can credit its defensive value.
				ns["corp_installed_upgrades"] = (s.get("corp_installed_upgrades", 0) as int) + 1

		"advance":
			var adv_cost: int = 1
			var credit_gain: int = 0
			if identity == "weyland_consortium_built_to_last":
				for remote in s.get("remotes", []) as Array:
					var r: Dictionary = remote as Dictionary
					if r.get("has_agenda", false) and (r.get("adv", 0) as int) == 0:
						credit_gain = 2
						break
			ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - adv_cost + credit_gain)
			var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
			# Target a specific remote by the agenda card_id when available.
			# Symbolic IDs ("__sim_agenda__", "") fall back to the first agenda remote.
			var adv_target_id: String = action.params.get("card_id", "") as String
			var advanced := false
			for adv_i in range(remotes_copy.size()):
				var adv_r: Dictionary = remotes_copy[adv_i] as Dictionary
				var adv_match: bool
				if adv_target_id == "__sim_trap__":
					adv_match = adv_r.get("has_trap", false) \
						and (adv_r.get("ice_count", 0) as int) > 0
				elif adv_target_id != "" and adv_target_id != "__sim_agenda__":
					adv_match = adv_r.get("agenda_card_id", "") == adv_target_id
				else:
					adv_match = adv_r.get("has_agenda", false)
				if not adv_match:
					continue
				if adv_target_id == "__sim_trap__":
					var new_r := adv_r.duplicate()
					new_r["trap_adv"] = (adv_r.get("trap_adv", 0) as int) + 1
					remotes_copy[adv_i] = new_r
				else:
					var new_adv: int = (adv_r.get("adv", 0) as int) + 1
					var adv_req: int = adv_r.get("req", 1) as int
					if new_adv >= adv_req:
						# Agenda is scored — update corp_score and remove the remote.
						var pts: int = adv_r.get("agenda_points", 2) as int
						ns["corp_score"] = (ns.get("corp_score", 0) as int) + pts
						remotes_copy.remove_at(adv_i)
					else:
						var new_r := adv_r.duplicate()
						new_r["adv"] = new_adv
						remotes_copy[adv_i] = new_r
				advanced = true
				break
			# Fallback: advance the first available trap if no agenda matched.
			if not advanced:
				for adv_fi in range(remotes_copy.size()):
					var adv_fr: Dictionary = remotes_copy[adv_fi] as Dictionary
					if adv_fr.get("has_trap", false) and (adv_fr.get("ice_count", 0) as int) > 0:
						var new_r := adv_fr.duplicate()
						new_r["trap_adv"] = (adv_fr.get("trap_adv", 0) as int) + 1
						remotes_copy[adv_fi] = new_r
						break
			ns["remotes"] = remotes_copy

		"play_from_archives":
			var pfa_id: String = action.params.get("card_id", "") as String
			ns["corp_discard_sz"] = max(0, (ns.get("corp_discard_sz", 0) as int) - 1)
			# Remove from corp_archives_ops so it is not generated again this turn.
			var pfa_ops: Array = (ns.get("corp_archives_ops", []) as Array).duplicate()
			for pfa_i in range(pfa_ops.size()):
				if (pfa_ops[pfa_i] as CardRecord) != null and \
						(pfa_ops[pfa_i] as CardRecord).id == pfa_id:
					pfa_ops.remove_at(pfa_i)
					break
			ns["corp_archives_ops"] = pfa_ops
			match pfa_id:
				"petty_cash":
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 3

		"purge_virus":
			# Costs 3 Corp clicks (already decremented × 3 by the caller iterating).
			# Projected effect: virus counters on runner rig go to zero.
			ns["runner_virus_total"] = 0
			# Clear runner_rig virus info (approximation — rig count unchanged)

		"trash_runner_resource":
			# Costs 1 Corp click (decremented above) + 2cr.
			ns["corp_credits"] = max(0, (ns.get("corp_credits", 0) as int) - 2)
			# Remove the target resource from runner_resources snapshot
			var trr_iid: String = action.params.get("card_instance_id", "") as String
			var trr_res: Array = (ns.get("runner_resources", []) as Array).duplicate()
			for trr_i in range(trr_res.size()):
				if (trr_res[trr_i] as Dictionary).get("instance_id", "") == trr_iid:
					trr_res.remove_at(trr_i)
					break
			ns["runner_resources"] = trr_res
			ns["runner_rig"] = max(0, (ns.get("runner_rig", 0) as int) - 1)

		"use_installed_card":
			var uic_card_id: String = action.params.get("card_id", "") as String
			# Remove the used asset from corp_installed_click_assets so SCG does not
			# offer it again in subsequent clicks of the same projected turn.
			var uic_inst: String = action.params.get("card_instance_id", "") as String
			var uic_ica: Array = (ns.get("corp_installed_click_assets", []) as Array).duplicate()
			for uic_i in range(uic_ica.size()):
				if (uic_ica[uic_i] as Dictionary).get("instance_id", "") == uic_inst:
					uic_ica.remove_at(uic_i)
					break
			ns["corp_installed_click_assets"] = uic_ica
			match uic_card_id:
				"rashida_jaheem":
					# Click, Trash: draw 3 cards, gain 2 credits.
					var rj_limit: int = ns.get("corp_hand_limit", 5) as int
					ns["corp_hand"]    = min((ns.get("corp_hand", 0) as int) + 3, rj_limit)
					ns["corp_deck"]    = max(0, (ns.get("corp_deck", 0) as int) - 3)
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 2
				_:
					# Generic approximation for unknown installed click abilities.
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 2

		"play_operation":
			var card: CardRecord = action.params.get("card_record", null) as CardRecord
			if card == null:
				return ns
			var cost: int = max(0, card.cost)
			ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - cost)
			ns["corp_hand"]    = max(0, (s.get("corp_hand",    0) as int) - 1)
			# Remove the played operation from corp_hand_cards.
			var opcc: Array = (ns.get("corp_hand_cards", []) as Array).duplicate()
			for opcc_i in range(opcc.size()):
				if opcc[opcc_i] == card:
					opcc.remove_at(opcc_i)
					break
			ns["corp_hand_cards"] = opcc
			match card.id:
				"hedge_fund":
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 9
				"government_subsidy":
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 14
				"predictive_planogram":
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 3
				"hansei_review":
					ns["corp_hand"]      = (ns.get("corp_hand",      0) as int) + 4
					ns["runner_credits"] = (ns.get("runner_credits",  0) as int) + 2
				"spin_doctor":
					ns["corp_hand"] = (ns.get("corp_hand", 0) as int) + 2
					ns["corp_deck"] = (ns.get("corp_deck", 0) as int) + 2
				"neurospike":
					var dmg: int = ns.get("corp_score", 0) as int
					ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - dmg)
				"ip_enforcement":
					# Remove X runner tags (at X cr cost already deducted above from card.cost=0),
					# then recover the highest-AP matching agenda from runner's score area.
					# Net effect: corp_score +X, runner_score -X, runner_tags -X.
					# The base card cost is 0 (variable cost is paid separately in effects);
					# we approximate the tag-removal credit cost inline.
					var ipe_tags: int = s.get("runner_tags", 0) as int
					var ipe_cred: int = ns.get("corp_credits", 0) as int
					var ipe_max_x: int = min(ipe_tags, ipe_cred)
					# Find highest AP available in runner score area (uses live ctx if present).
					var ipe_x: int = 0
					if _ctx != null:
						for ipe_ic in _ctx.runner_score_area_cards:
							var ipe_c: InstalledCard = ipe_ic as InstalledCard
							if ipe_c == null or ipe_c.card_record == null:
								continue
							var ipe_ap: int = ipe_c.card_record.agenda_points
							if ipe_ap <= ipe_max_x and ipe_ap > ipe_x:
								ipe_x = ipe_ap
					else:
						ipe_x = min(ipe_max_x, 2)   # fallback: assume a 2-pt agenda
					if ipe_x > 0:
						ns["corp_credits"] = max(0, (ns.get("corp_credits", 0) as int) - ipe_x)
						ns["runner_tags"]  = max(0, ipe_tags - ipe_x)
						ns["corp_score"]   = (s.get("corp_score",   0) as int) + ipe_x
						ns["runner_score"] = max(0, (s.get("runner_score", 0) as int) - ipe_x)
				"retribution":
					# Remove 1 tag, trash 1 runner program or hardware.
					var ret_tags: int = ns.get("runner_tags", 0) as int
					if ret_tags > 0:
						ns["runner_tags"]          = ret_tags - 1
						ns["runner_rig"]           = max(0, (ns.get("runner_rig",           0) as int) - 1)
						ns["runner_breaker_count"] = max(0, (ns.get("runner_breaker_count", 0) as int) - 1)
				"bigger_picture":
					# Drain 5cr × runner_tags from runner, Corp gains equal amount.
					var bp_tags:  int = s.get("runner_tags",    0) as int
					var bp_drain: int = bp_tags * 5
					ns["runner_credits"] = max(0, (ns.get("runner_credits", 0) as int) - bp_drain)
					ns["corp_credits"]   = (ns.get("corp_credits",   0) as int) + bp_drain
				"boom":
					# 7 net damage.
					ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - 7)
				"scorched_earth":
					# 4 meat damage.
					ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - 4)
				"punitive_counterstrike":
					# Net damage equal to runner_score (approximate).
					var pun_dmg: int = s.get("runner_score", 0) as int
					ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - pun_dmg)
				# ── Parhelion operations ──────────────────────────────────────────
				"end_of_the_line":
					# Additional cost: remove 1 tag. Do 4 meat damage.
					var eotl_tags: int = ns.get("runner_tags", 0) as int
					if eotl_tags > 0:
						ns["runner_tags"] = eotl_tags - 1
						ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - 4)
				"distributed_tracing":
					# Additional cost: [click] (model as −2cr opportunity cost already in card.cost).
					# Gives the runner 1 tag when played.
					ns["runner_tags"] = (ns.get("runner_tags", 0) as int) + 1
				"shipment_from_vladisibirsk":
					# Play only if runner has ≥ 2 tags. Place 4 advancements on installed cards.
					if (ns.get("runner_tags", 0) as int) >= 2:
						var svl_remain := 4
						var svl_remotes: Array = (ns.get("remotes", []) as Array).duplicate(true)
						for svl_i in range(svl_remotes.size()):
							if svl_remain <= 0:
								break
							var svl_r: Dictionary = (svl_remotes[svl_i] as Dictionary).duplicate()
							if not svl_r.get("has_agenda", false):
								continue
							var svl_cur: int = svl_r.get("adv", 0) as int
							var svl_req: int = svl_r.get("req",  1) as int
							var svl_put: int = min(svl_remain, max(0, svl_req - svl_cur) + 1)
							var svl_new: int = svl_cur + svl_put
							svl_remain -= svl_put
							if svl_new >= svl_req:
								var svl_pts: int = svl_r.get("agenda_points", 2) as int
								ns["corp_score"] = (ns.get("corp_score", 0) as int) + svl_pts
								svl_remotes.remove_at(svl_i)
							else:
								svl_r["adv"] = svl_new
								svl_remotes[svl_i] = svl_r
							break   # concentrate counters on one agenda
						ns["remotes"] = svl_remotes
				"hypoxia":
					# Play only if runner is tagged. 1 core damage + −1 click next turn.
					# Approximate as reducing runner hand size by 1.
					if (ns.get("runner_tags", 0) as int) > 0:
						ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - 1)
				"nonequivalent_exchange":
					# Gain 5cr. Optional: each player gains 2cr (model as always taking it).
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 5
				"simulation_reset":
					# 4cr cost (deducted above). Trashes up to 5 HQ, shuffles Archives→R&D, draws.
					# Net: hand size roughly unchanged; deck refreshed from Archives.
					# Approximate as neutral hand effect (cost is the 4cr).
					pass
				_:
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 2

	return ns


# ── Runner response projection ────────────────────────────────────────────────

# Returns a new SimState after the runner attempts to run threat_server.
func project_runner_response(s: Dictionary, threat_server: String, _ctx: GameContext) -> Dictionary:
	var ns: Dictionary = s.duplicate(true)
	var identity: String = s.get("corp_identity", "") as String

	# ── Naked-agenda override ──────────────────────────────────────────────────
	# If any remote holds an agenda behind zero ice, the runner will run that
	# server in preference to any defended central — it is a free steal.
	# This includes "projected" remotes when the Corp had no ice in hand
	# (proj_ice == 0 in project_corp_action), so naked installs are always caught.
	for remote in s.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if r.get("has_agenda", false) and (r.get("ice_count", 0) as int) == 0:
			threat_server = r.get("server_id", "") as String
			break

	# Determine ice count on target server
	var ice_count: int = 0
	if threat_server == "hq":
		ice_count = s.get("hq_ice", 0) as int
	elif threat_server == "rd":
		ice_count = s.get("rd_ice", 0) as int
	else:
		for remote in s.get("remotes", []) as Array:
			if (remote as Dictionary).get("server_id", "") == threat_server:
				ice_count = (remote as Dictionary).get("ice_count", 0) as int
				break

	var runner_cr: int = s.get("runner_credits", 0) as int

	# ── Zero-ice short-circuit ─────────────────────────────────────────────────
	# A server with no ice is always accessible: the runner spends no credits
	# and steals any agenda present with certainty.
	if ice_count == 0:
		var has_agenda_0 := false
		if threat_server in ["hq", "rd"]:
			has_agenda_0 = (s.get("corp_deck", 0) as int) > 0
		else:
			for remote in s.get("remotes", []) as Array:
				if (remote as Dictionary).get("server_id", "") == threat_server:
					has_agenda_0 = (remote as Dictionary).get("has_agenda", false) as bool
					break
		if has_agenda_0:
			ns["runner_score"] = (s.get("runner_score", 0) as int) + 2
			if threat_server not in ["hq", "rd"]:
				var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
				for i in range(remotes_copy.size()):
					var r: Dictionary = remotes_copy[i] as Dictionary
					if r.get("server_id", "") == threat_server:
						var new_r := r.duplicate()
						new_r["has_agenda"] = false
						remotes_copy[i] = new_r
						break
				ns["remotes"] = remotes_copy
		return ns

	# ── Rig-quality-aware success probability ──────────────────────────────────
	var runner_breakers: int = s.get("runner_breaker_count", 0) as int
	var has_fracter: bool    = s.get("runner_has_fracter",    false) as bool
	var has_killer:  bool    = s.get("runner_has_killer",     false) as bool
	var has_decoder: bool    = s.get("runner_has_decoder",    false) as bool
	var has_ai:      bool    = s.get("runner_has_ai_breaker", false) as bool

	# Base probability from rig completeness.
	# AI breakers cover all ice types so they rate the same as a full rig.
	var base_prob: float
	if   has_ai:                base_prob = 0.80
	elif runner_breakers == 0:  base_prob = 0.15
	elif runner_breakers == 1:  base_prob = 0.45
	elif runner_breakers == 2:  base_prob = 0.65
	else:                       base_prob = 0.85   # >= 3 dedicated breakers

	# Scale by ice count and available credits.
	base_prob = clampf(base_prob - float(ice_count) * 0.12 + float(runner_cr) * 0.015, 0.05, 0.95)

	# Subtype penalty: for each ice type on this server the runner cannot break,
	# reduce success probability by 0.15.  AI breakers skip this check entirely.
	if not has_ai and runner_breakers > 0:
		var svr_barrier:   bool = false
		var svr_sentry:    bool = false
		var svr_code_gate: bool = false
		if threat_server == "hq":
			svr_barrier   = s.get("hq_ice_barrier",   false) as bool
			svr_sentry    = s.get("hq_ice_sentry",    false) as bool
			svr_code_gate = s.get("hq_ice_code_gate", false) as bool
		elif threat_server == "rd":
			svr_barrier   = s.get("rd_ice_barrier",   false) as bool
			svr_sentry    = s.get("rd_ice_sentry",    false) as bool
			svr_code_gate = s.get("rd_ice_code_gate", false) as bool
		else:
			for remote in s.get("remotes", []) as Array:
				if (remote as Dictionary).get("server_id", "") == threat_server:
					svr_barrier   = (remote as Dictionary).get("has_barrier",   false) as bool
					svr_sentry    = (remote as Dictionary).get("has_sentry",    false) as bool
					svr_code_gate = (remote as Dictionary).get("has_code_gate", false) as bool
					break
		if svr_barrier   and not has_fracter: base_prob -= 0.20
		if svr_sentry    and not has_killer:  base_prob -= 0.20
		if svr_code_gate and not has_decoder: base_prob -= 0.20
		base_prob = maxf(base_prob, 0.05)

	var success_prob: float = base_prob

	# ── Jinteki: Replicating Perfection ──────────────────────────────────────
	# Runner must run a central before accessing any remote — model as a large
	# penalty on remote success probability.
	var is_remote_target := (threat_server not in ["hq", "rd"] and threat_server != "")
	if identity == "jinteki_replicating_perfection" and is_remote_target:
		success_prob = clampf(success_prob - 0.35, 0.0, 0.50)

	# Runner spends credits breaking ice
	var expected_spend: int = int(float(ice_count) * 2.5)
	ns["runner_credits"] = max(0, runner_cr - expected_spend)

	# On successful run, runner may steal an agenda.
	if success_prob > 0.5:
		var has_agenda := false
		if threat_server in ["hq", "rd"]:
			has_agenda = (s.get("corp_deck", 0) as int) > 0
		else:
			for remote in s.get("remotes", []) as Array:
				if (remote as Dictionary).get("server_id", "") == threat_server:
					has_agenda = (remote as Dictionary).get("has_agenda", false) as bool
					break

		if has_agenda:
			ns["runner_score"] = (s.get("runner_score", 0) as int) + 2
			if threat_server not in ["hq", "rd"]:
				var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
				for i in range(remotes_copy.size()):
					var r: Dictionary = remotes_copy[i] as Dictionary
					if r.get("server_id", "") == threat_server:
						var new_r := r.duplicate()
						new_r["has_agenda"] = false
						remotes_copy[i] = new_r
						break
				ns["remotes"] = remotes_copy

	return ns
