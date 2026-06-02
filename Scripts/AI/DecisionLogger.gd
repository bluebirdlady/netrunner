class_name DecisionLogger
extends RefCounted

# ── DecisionLogger ────────────────────────────────────────────────────────────
# Writes Corp AI decision records to user://logs/ on the host filesystem.
# One timestamped file per process start; all four AI levels share it.
#
# All log methods must only be called when ctx.simulation_mode is false —
# callers are responsible for that gate.
#
# Set ENABLED = false to silence all output without removing call sites.

const ENABLED := true

static var _file: FileAccess = null


# ── File lifecycle ────────────────────────────────────────────────────────────

static func _ensure_open() -> bool:
	if not ENABLED:
		return false
	if _file != null:
		return true

	# Use the absolute OS path — avoids any user:// resolution ambiguity.
	var user_dir := OS.get_user_data_dir()
	var logs_dir := user_dir.path_join("logs")
	print("[DecisionLogger] user data dir : %s" % user_dir)
	print("[DecisionLogger] logs dir      : %s" % logs_dir)

	# Create logs directory if needed.
	if not DirAccess.dir_exists_absolute(logs_dir):
		var err := DirAccess.make_dir_recursive_absolute(logs_dir)
		if err != OK:
			print("[DecisionLogger] ERROR: could not create logs dir (err %d)" % err)
			return false

	var dt := Time.get_datetime_dict_from_system()
	var y  := int(dt.get("year",   2000))
	var mo := int(dt.get("month",  1))
	var d  := int(dt.get("day",    1))
	var h  := int(dt.get("hour",   0))
	var mi := int(dt.get("minute", 0))
	var s  := int(dt.get("second", 0))
	var ts := "%04d%02d%02d_%02d%02d%02d" % [y, mo, d, h, mi, s]
	var path := logs_dir.path_join("corp_ai_%s.log" % ts)
	print("[DecisionLogger] opening       : %s" % path)

	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		print("[DecisionLogger] ERROR: FileAccess.open failed (err %d)" % FileAccess.get_open_error())
		return false

	print("[DecisionLogger] log file ready.")
	var headline := "Corp AI Decision Log  %04d-%02d-%02d %02d:%02d:%02d" % [
		y, mo, d, h, mi, s
	]
	_file.store_line(headline)
	_file.store_line("----------------------------------------------------------------")
	_file.store_line("")
	_file.flush()
	return true


# Optional explicit close — not required; OS flushes on process exit.
static func close() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null


# ── Context summary helpers ───────────────────────────────────────────────────

static func _ap_line(ctx: GameContext) -> String:
	return "corp %d/%dap  runner %d/%dap" % [
		ctx.corp_agenda_points(), ctx.agenda_points_to_win,
		ctx.runner_agenda_points(), ctx.agenda_points_to_win,
	]


static func _board_line(ctx: GameContext) -> String:
	var out := ""

	# Centrals — only show when iced
	for id in ["hq", "rd", "archives"]:
		var srv: Server = ctx.get_server(id)
		if srv != null and srv.ice_count() > 0:
			if out != "":
				out += "  "
			out += "%s[%di]" % [id, srv.ice_count()]

	# Remote servers
	for key in ctx.servers:
		var srv: Server = ctx.servers[key] as Server
		if not srv.is_remote():
			continue
		if out != "":
			out += "  "
		var desc := "%s[%di" % [key, srv.ice_count()]
		for card in srv.root:
			var ic: InstalledCard = card as InstalledCard
			if ic == null or ic.card_record == null:
				desc += " ?"
			elif ic.card_record.is_agenda():
				desc += " ag%d/%d" % [
					ic.get_counter("advancement"),
					ic.card_record.advancement_requirement
				]
			else:
				desc += " %s" % ic.card_id
		desc += "]"
		out += desc

	# Runner rig — one letter per breaker type installed (f/k/d/a)
	var rig_str := ""
	for rig_card in ctx.runner_rig:
		var ic: InstalledCard = rig_card as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		for sub in ["fracter", "killer", "decoder", "ai"]:
			if ic.card_record.has_subtype(sub):
				rig_str += sub.left(1)
				break

	if out != "":
		out += "  "
	if rig_str != "":
		out += "rig[%s]" % rig_str
	else:
		out += "rig:0"

	return out


static func _ctx_header(ctx: GameContext, label: String) -> String:
	return "[T%02d] %s  corp%3dcr  runner%3dcr  grip:%d  %s" % [
		ctx.turn_number, label,
		ctx.corp_credits, ctx.runner_credits,
		ctx.runner_hand.size(),
		_ap_line(ctx)
	]


# ── Public entry points ───────────────────────────────────────────────────────

# Level 0 — heuristic waterfall.
static func log_heuristic(ctx: GameContext, action: GameAction) -> void:
	if not _ensure_open():
		return
	_file.store_line(_ctx_header(ctx, "L0-Heuristic "))
	_file.store_line("  board: %s" % _board_line(ctx))
	_file.store_line("  ->  %s" % action.describe())
	_file.store_line("")
	_file.flush()


# Levels 1 (Tactical) and 2 (Strategic) — full scored candidate list.
# entries: Array of {"action": GameAction, "score": float}
static func log_scored(
		ctx:     GameContext,
		chosen:  GameAction,
		entries: Array,
		level:   int) -> void:
	if not _ensure_open():
		return
	var label: String
	if level == 1:
		label = "L1-Tactical  "
	elif level == 2:
		label = "L2-Strategic "
	else:
		label = "L%d-Scored   " % level
	_file.store_line(_ctx_header(ctx, label))
	_file.store_line("  board: %s" % _board_line(ctx))

	# Sort descending by score without lambdas — sort a parallel array of floats
	var scores: Array = []
	var actions: Array = []
	for entry in entries:
		scores.append(float(entry.get("score", 0.0)))
		actions.append(entry.get("action") as GameAction)

	# Insertion sort (candidate lists are short — typically < 15 entries)
	for i in range(1, scores.size()):
		var key_s: float    = scores[i]
		var key_a: GameAction = actions[i]
		var j := i - 1
		while j >= 0 and scores[j] < key_s:
			scores[j + 1]  = scores[j]
			actions[j + 1] = actions[j]
			j -= 1
		scores[j + 1]  = key_s
		actions[j + 1] = key_a

	for i in range(scores.size()):
		var a: GameAction = actions[i]
		var sc: float     = scores[i]
		var mark: String  = "(*)" if a == chosen else "   "
		_file.store_line("  %s [%9.3f]  %s" % [mark, sc, a.describe()])

	_file.store_line("")
	_file.flush()


# Level 3 — MCTS synchronous search.
static func log_mcts(
		ctx:        GameContext,
		chosen:     GameAction,
		elapsed_ms: int) -> void:
	if not _ensure_open():
		return
	_file.store_line(_ctx_header(ctx, "L3-MCTS      "))
	_file.store_line("  board: %s" % _board_line(ctx))
	_file.store_line("  ->  %s  (%d ms)" % [chosen.describe(), elapsed_ms])
	_file.store_line("")
	_file.flush()
