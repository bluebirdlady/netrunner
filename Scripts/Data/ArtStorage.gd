class_name ArtStorage
extends Node

# ── ArtCache ──────────────────────────────────────────────────────────────────
# Fetches card art from NetrunnerDB and caches it to disk.
# Returns a placeholder texture immediately; emits texture_ready when art loads.
#
# Add to autoloads as "ArtStorage".
#
# Usage:
#   var tex = ArtStorage.get_texture(printing_id)   # placeholder or cached texture
#   ArtStorage.texture_ready.connect(_on_art_ready)  # fires when fetch completes
#
#   func _on_art_ready(printing_id: String, texture: Texture2D):
#       if printing_id == my_card.printing_id:
#           art_rect.texture = texture

const CACHE_DIR     := "user://art_storage/"
const IMAGE_URL     := "https://card-images.netrunnerdb.com/v1/large/%s.jpg"
const PLACEHOLDER_COLOR := Color(0.15, 0.15, 0.2, 1.0)

signal texture_ready(printing_id: String, texture: Texture2D)

# In-memory cache: printing_id -> Texture2D
var _memory_cache: Dictionary = {}

# Printing ids currently being fetched (avoid duplicate requests)
var _pending: Dictionary = {}

# Placeholder texture — generated once and reused
var _placeholder: Texture2D = null


func _ready() -> void:
	_ensure_cache_dir()
	_placeholder = _make_placeholder()


# ── Public API ────────────────────────────────────────────────────────────────

# Returns a texture immediately (placeholder or cached).
# If the art isn't cached, starts an async fetch and emits texture_ready later.
func get_texture(printing_id: String) -> Texture2D:
	if printing_id == "":
		return _placeholder

	# Memory cache hit
	if _memory_cache.has(printing_id):
		return _memory_cache[printing_id]

	# Disk cache hit
	var disk_tex := _load_from_disk(printing_id)
	if disk_tex != null:
		_memory_cache[printing_id] = disk_tex
		return disk_tex

	# Not cached — fetch asynchronously
	if not _pending.has(printing_id):
		_pending[printing_id] = true
		_fetch.call_deferred(printing_id)

	return _placeholder


func clear_memory_cache() -> void:
	_memory_cache.clear()


# ── Fetching ──────────────────────────────────────────────────────────────────

func _fetch(printing_id: String) -> void:
	var url := IMAGE_URL % printing_id
	var http := HTTPRequest.new()
	add_child(http)

	var err := http.request(url)
	if err != OK:
		push_error("ArtStorage: HTTP request failed for %s" % printing_id)
		http.queue_free()
		_pending.erase(printing_id)
		return

	var response = await http.request_completed
	http.queue_free()
	_pending.erase(printing_id)

	var http_code: int        = response[1]
	var body: PackedByteArray = response[3]

	if http_code != 200:
		push_warning("ArtStorage: got HTTP %d for %s" % [http_code, printing_id])
		return

	# Write to disk
	_write_to_disk(printing_id, body)

	# Create texture from bytes
	var image := Image.new()
	var image_err := image.load_jpg_from_buffer(body)
	if image_err != OK:
		push_warning("ArtStorage: could not decode image for %s" % printing_id)
		return

	var texture := ImageTexture.create_from_image(image)
	_memory_cache[printing_id] = texture
	emit_signal("texture_ready", printing_id, texture)


# ── Disk cache ────────────────────────────────────────────────────────────────

func _load_from_disk(printing_id: String) -> Texture2D:
	var path := CACHE_DIR + printing_id + ".jpg"
	if not FileAccess.file_exists(path):
		return null

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null

	var bytes := file.get_buffer(file.get_length())
	file.close()

	var image := Image.new()
	var err   := image.load_jpg_from_buffer(bytes)
	if err != OK:
		return null

	return ImageTexture.create_from_image(image)


func _write_to_disk(printing_id: String, bytes: PackedByteArray) -> void:
	var path := CACHE_DIR + printing_id + ".jpg"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("ArtStorage: could not write to %s" % path)
		return
	file.store_buffer(bytes)
	file.close()


func _ensure_cache_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("art_storage"):
		dir.make_dir("art_storage")


# ── Placeholder ───────────────────────────────────────────────────────────────

func _make_placeholder() -> Texture2D:
	var image := Image.create(130, 90, false, Image.FORMAT_RGB8)
	image.fill(PLACEHOLDER_COLOR)
	return ImageTexture.create_from_image(image)
