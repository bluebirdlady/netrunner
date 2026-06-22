fetch_deck_api <- function(uuid) {
  url <- paste0("https://api-preview.netrunnerdb.com/api/v3/public/decklists/", uuid)
  
  resp <- GET(url, add_headers(`User-Agent` = "R Netrunner Client"))
  if (status_code(resp) != 200) {
    warning("Failed to fetch deck ", uuid, ": ", status_code(resp))
    return(NULL)
  }
  
  text <- content(resp, as = "text", encoding = "UTF-8")
  parsed <- fromJSON(text, simplifyVector = TRUE)
  
  deck <- parsed$data
  if (is.null(deck)) return(NULL)
  
  # Extract card slots – could be a data frame or a list
  slots <- deck$attributes$card_slots
  
  # If slots is NULL or empty, return empty
  if (is.null(slots) || length(slots) == 0) {
    return(list(uuid = uuid, slots = numeric(0), meta = deck$attributes))
  }
  
  # Handle different possible structures
  if (is.data.frame(slots)) {
    # Preview API returns a one-row data frame with card IDs as columns
    vec <- as.numeric(slots[1, ])
    names(vec) <- colnames(slots)
  } else if (is.list(slots) && !is.data.frame(slots)) {
    # Could be a named list of card counts (from v2 or other formats)
    vec <- unlist(slots)
    # names(vec) should already be card IDs
  } else {
    # Fallback – try to convert
    vec <- tryCatch(as.numeric(slots), error = function(e) numeric(0))
    if (length(vec) > 0 && is.null(names(vec))) {
      # If no names, we can't map to card IDs – return empty
      return(list(uuid = uuid, slots = numeric(0), meta = deck$attributes))
    }
  }
  
  # Keep only cards with count > 0 (drop NA and zero)
  vec <- vec[!is.na(vec) & vec > 0]
  
  return(list(
    uuid = uuid,
    slots = vec,
    meta = deck$attributes
  ))
}

# -----------------------------------------------------------------------------
# 3. Scrape deck UUIDs with pagination via "next" link
# -----------------------------------------------------------------------------

scrape_page_uuids <- function(url, page_num = NULL) {
  cat("  Scraping URL:", url, "\n")
  
  page_html <- tryCatch(
    read_html(url),
    error = function(e) {
      cat("Error:", e$message, "\n")
      return(NULL)
    }
  )
  
  if (is.null(page_html)) return(list(uuids = character(0), next_url = NULL))
  
  # Extract deck UUIDs
  links <- page_html %>%
    html_nodes("a[href^='/en/decklist/']") %>%
    html_attr("href")
  
  uuids <- links %>%
    stringr::str_extract("/en/decklist/[a-f0-9-]+") %>%
    stringr::str_replace("/en/decklist/", "") %>%
    unique() %>%
    na.omit()
  
  # Try to find the "next" (») link
  next_link <- page_html %>%
    html_node("ul.pagination li:last-child a") %>%
    html_attr("href")
  
  # If that fails, try by text
  if (is.na(next_link) || length(next_link) == 0) {
    next_link <- page_html %>%
      html_node("ul.pagination a:contains('»')") %>%
      html_attr("href")
  }
  
  # If we found a next link, make it absolute
  if (!is.na(next_link) && length(next_link) > 0 && nchar(next_link) > 0) {
    next_url <- paste0("https://netrunnerdb.com", next_link)
  } else {
    next_url <- NULL
  }
  
  cat("  Found", length(uuids), "decks, next_url:", if (!is.null(next_url)) next_url else "none\n")
  
  return(list(uuids = uuids, next_url = next_url))
}
# -----------------------------------------------------------------------------
# 4. Main scraping loop using pagination links
# -----------------------------------------------------------------------------

cat("=== Scraping deck UUIDs for faction:", FACTION, "===\n")

# Start with the first page URL
first_url <- build_search_url(page = 1)
current_url <- first_url
all_uuids <- character()
page_num <- 0

while (!is.null(current_url) && page_num < MAX_PAGES) {
  page_num <- page_num + 1
  cat("\nPage", page_num, ":\n")
  
  result <- scrape_page_uuids(current_url)
  if (length(result$uuids) == 0) break
  
  all_uuids <- c(all_uuids, result$uuids)
  current_url <- result$next_url
  
  Sys.sleep(1)  # be polite
}

# Remove duplicates across pages (if any)
all_uuids <- unique(all_uuids)

cat("\nTotal unique decks found:", length(all_uuids), "\n")

# Load existing cache (if any)
cache_file <- file.path(CACHE_DIR, paste0(FACTION, "_standard_decks.rds"))
if (file.exists(cache_file)) {
  cached <- readRDS(cache_file)
  fetched_uuids <- names(cached)
  cat("Loaded", length(fetched_uuids), "cached decks\n")
} else {
  cached <- list()
  fetched_uuids <- character(0)
}

# Determine which UUIDs are new
new_uuids <- setdiff(all_uuids, fetched_uuids)
cat("Fetching", length(new_uuids), "new decks...\n")

# Fetch each new deck
for (i in seq_along(new_uuids)) {
  uuid <- new_uuids[i]
  cat("  ", i, "/", length(new_uuids), ": ", uuid, "... ", sep = "")
  deck <- fetch_deck_api(uuid)   # your existing function
  if (!is.null(deck)) {
    cached[[uuid]] <- deck
    cat("OK\n")
  } else {
    cat("FAILED\n")
  }
  Sys.sleep(0.3)   # be polite to the API
}

# Save the updated cache
saveRDS(cached, file = cache_file)
cat("\nCache updated with", length(cached), "total decks.\n")

deck_slots <- list()
deck_meta <- list()
for (uuid in names(cached)) {
  deck <- cached[[uuid]]
  deck_slots <- c(deck_slots, list(deck$slots))
  deck_meta <- c(deck_meta, list(deck$meta))
}

cat("Total decks available for clustering:", length(deck_slots), "\n")