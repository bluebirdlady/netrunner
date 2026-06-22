FACTION <- "shaper"   # or "criminal", "shaper"
cache_file <- file.path("cache", paste0(FACTION, "_standard_decks.rds"))

if (file.exists(cache_file)) {
  cached <- readRDS(cache_file)
  cat("Loaded", length(cached), "decks for", FACTION, "\n")
} else {
  stop("Cache file not found.")
}

# Convert to slots and meta
deck_slots <- list()
deck_meta <- list()
for (uuid in names(cached)) {
  deck <- cached[[uuid]]
  deck_slots <- c(deck_slots, list(deck$slots))
  deck_meta <- c(deck_meta, list(deck$meta))
}
cat("Total decks:", length(deck_slots), "\n")