###############################################################################
# Fetch Standard-format Corp Decks from NetrunnerDB
# - Scrapes search results page for deck UUIDs
# - Fetches each deck via the API
# - Caches results locally
# - Clusters and exports JSON models
###############################################################################

library(httr)
library(jsonlite)
library(rvest)
library(dplyr)
library(purrr)
library(stringr)
library(cluster)

# -----------------------------------------------------------------------------
# 1. User Settings
# -----------------------------------------------------------------------------

# Corp factions to process
FACTIONS <- c("haas-bioroid", "jinteki", "nbn", "weyland-consortium")

# Scraping settings
MAX_PAGES <- 10
CACHE_DIR <- "cache"
if (!dir.exists(CACHE_DIR)) dir.create(CACHE_DIR)

# Clustering settings
REMOVE_UBIQ <- 0.60
REMOVE_RARE <- 0.01
K_MIN <- 2
K_MAX <- 10

# Standard-legal pack codes (same as Runner)
PACKS <- c("vp", "elev", "rwr", "tai", "ph", "ms", "msbp", "su21", "sg", 
           "sm", "mor", "ur", "urbp", "df", "sc19", "napd", "mo", "rar",
           "ka", "win", "tdatd", "cotc", "dtwn", "ss", "core2", "tdc", 
           "td", "cd", "fm", "baw", "eas", "so", "dc", "qu", "ml", "in",
           "es", "bm", "23s", "ftm", "tlm", "si", "dag", "bf", "kg",
           "dad", "uot", "oh", "uw", "cc", "bb", "val", "oac", "ts",
           "atr", "uao", "fc", "tsb", "up", "hap", "dt", "fal", "tc",
           "mt", "st", "om", "cac", "fp", "hs", "asis", "ce", "ta",
           "wla", "core")

# -----------------------------------------------------------------------------
# 2. Build search URL (Corp version)
# -----------------------------------------------------------------------------

build_search_url <- function(faction, page = 1) {
  base <- "https://netrunnerdb.com/en/decklists/find"
  
  params <- list(
    faction = faction,
    sort = "popularity",
    rotation_id = "7",
    author = "",
    title = "",
    is_legal = "1",
    mwl_code = "standard-ban-list-26-05",
    page = page
  )
  
  query_parts <- list()
  for (name in names(params)) {
    query_parts <- c(query_parts, paste0(name, "=", URLencode(as.character(params[[name]]), reserved = TRUE)))
  }
  for (pack in PACKS) {
    query_parts <- c(query_parts, paste0("packs[]=", URLencode(pack, reserved = TRUE)))
  }
  
  paste0(base, "?", paste(query_parts, collapse = "&"))
}

# -----------------------------------------------------------------------------
# 3. Scrape deck UUIDs
# -----------------------------------------------------------------------------

scrape_page_uuids <- function(url) {
  cat("  Scraping URL:", url, "\n")
  
  page_html <- tryCatch(
    read_html(url),
    error = function(e) {
      cat("Error:", e$message, "\n")
      return(NULL)
    }
  )
  
  if (is.null(page_html)) return(list(uuids = character(0), next_url = NULL))
  
  links <- page_html %>%
    html_nodes("a[href^='/en/decklist/']") %>%
    html_attr("href")
  
  uuids <- links %>%
    stringr::str_extract("/en/decklist/[a-f0-9-]+") %>%
    stringr::str_replace("/en/decklist/", "") %>%
    unique() %>%
    na.omit()
  
  next_link <- page_html %>%
    html_node("ul.pagination li:last-child a") %>%
    html_attr("href")
  
  if (is.na(next_link) || length(next_link) == 0) {
    next_link <- page_html %>%
      html_node("ul.pagination a:contains('»')") %>%
      html_attr("href")
  }
  
  if (!is.na(next_link) && length(next_link) > 0 && nchar(next_link) > 0) {
    next_url <- paste0("https://netrunnerdb.com", next_link)
  } else {
    next_url <- NULL
  }
  
  cat("  Found", length(uuids), "decks, next_url:", if (!is.null(next_url)) next_url else "none\n")
  
  return(list(uuids = uuids, next_url = next_url))
}

# -----------------------------------------------------------------------------
# 4. Fetch deck via API (reuse from Runner script)
# -----------------------------------------------------------------------------

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
  
  slots <- deck$attributes$card_slots
  
  if (is.null(slots) || length(slots) == 0) {
    return(list(uuid = uuid, slots = numeric(0), meta = deck$attributes))
  }
  
  if (is.data.frame(slots)) {
    vec <- as.numeric(slots[1, ])
    names(vec) <- colnames(slots)
  } else if (is.list(slots) && !is.data.frame(slots)) {
    vec <- unlist(slots)
  } else {
    vec <- tryCatch(as.numeric(slots), error = function(e) numeric(0))
    if (length(vec) > 0 && is.null(names(vec))) {
      return(list(uuid = uuid, slots = numeric(0), meta = deck$attributes))
    }
  }
  
  vec <- vec[!is.na(vec) & vec > 0]
  
  return(list(
    uuid = uuid,
    slots = vec,
    meta = deck$attributes
  ))
}

# -----------------------------------------------------------------------------
# 5. Cosine distance (for clustering)
# -----------------------------------------------------------------------------

cosine_dist <- function(mat) {
  norm <- sqrt(rowSums(mat^2))
  norm[norm == 0] <- 1e-10
  mat_norm <- mat / norm
  sim <- tcrossprod(mat_norm)
  dist_mat <- as.dist(1 - pmax(pmin(sim, 1), -1))
  return(dist_mat)
}

# -----------------------------------------------------------------------------
# 6. Clustering function (same as Runner)
# -----------------------------------------------------------------------------

cluster_faction_cosine <- function(deck_slots,
                                   remove_ubiq = REMOVE_UBIQ,
                                   remove_rare = REMOVE_RARE,
                                   k_min = K_MIN,
                                   k_max = K_MAX) {
  
  if (length(deck_slots) == 0) {
    cat("No decks to cluster.\n")
    return(NULL)
  }
  
  all_card_ids <- unique(unlist(lapply(deck_slots, names)))
  presence <- matrix(0, nrow = length(deck_slots), ncol = length(all_card_ids))
  colnames(presence) <- all_card_ids
  for (i in seq_along(deck_slots)) {
    vec <- deck_slots[[i]]
    if (length(vec) > 0) presence[i, names(vec)] <- 1
  }
  cat("Initial matrix dimensions:", dim(presence), "\n")
  
  freq <- colSums(presence) / nrow(presence)
  keep_ubiq <- freq < remove_ubiq
  presence <- presence[, keep_ubiq, drop = FALSE]
  cat("After removing ubiquitous (>", remove_ubiq*100, "%):", ncol(presence), "cards\n")
  
  card_count <- colSums(presence)
  min_freq <- remove_rare * nrow(presence)
  keep_rare <- card_count >= min_freq
  presence <- presence[, keep_rare, drop = FALSE]
  cat("After removing rare (<", remove_rare*100, "%):", ncol(presence), "cards\n")
  
  if (ncol(presence) == 0) {
    cat("No cards left after filtering.\n")
    return(NULL)
  }
  
  row_sums <- rowSums(presence)
  if (any(row_sums == 0)) {
    presence <- presence[row_sums > 0, ]
  }
  if (nrow(presence) < 2) {
    cat("Not enough decks to cluster (need ≥2).\n")
    return(NULL)
  }
  
  N <- nrow(presence)
  idf <- log(N / colSums(presence))
  tfidf <- sweep(presence, 2, idf, FUN = "*")
  
  dist_matrix <- cosine_dist(tfidf)
  if (any(is.na(dist_matrix))) {
    cat("NA values in distance matrix – skipping.\n")
    return(NULL)
  }
  
  hc <- hclust(dist_matrix, method = "complete")
  
  k_range <- k_min:k_max
  sil_scores <- numeric(length(k_range))
  for (i in seq_along(k_range)) {
    k <- k_range[i]
    clusters <- cutree(hc, k = k)
    if (k > 1 && length(unique(clusters)) == k && min(table(clusters)) > 1) {
      sil <- silhouette(clusters, dist_matrix)
      sil_scores[i] <- mean(sil[, 3])
    } else {
      sil_scores[i] <- NA
    }
  }
  silhouette_scores <- setNames(sil_scores, k_range)
  valid <- !is.na(silhouette_scores)
  if (any(valid)) {
    chosen_k <- as.integer(names(which.max(silhouette_scores[valid])))
  } else {
    chosen_k <- 5
    warning("Silhouette could not be computed – using fixed k = 5")
  }
  cat("Silhouette scores:\n")
  print(round(silhouette_scores, 3))
  cat("Selected k =", chosen_k, "(highest silhouette)\n")
  
  clusters <- cutree(hc, k = chosen_k)
  
  signatures <- list()
  for (cl in sort(unique(clusters))) {
    idx <- which(clusters == cl)
    if (length(idx) > 0) {
      freq <- colSums(presence[idx, , drop = FALSE])
      top <- sort(freq, decreasing = TRUE)[1:10]
      signatures[[as.character(cl)]] <- top
    }
  }
  
  return(list(
    clusters = clusters,
    signatures = signatures,
    presence = presence,
    tfidf = tfidf,
    idf = idf,
    hc = hc,
    dist_matrix = dist_matrix,
    chosen_k = chosen_k,
    silhouette_scores = silhouette_scores,
    n_decks = nrow(presence),
    n_cards = ncol(presence)
  ))
}

# -----------------------------------------------------------------------------
# 7. Export model to JSON
# -----------------------------------------------------------------------------

export_model_json <- function(cluster_res, faction_name) {
  vocab <- colnames(cluster_res$presence)
  idf_vec <- cluster_res$idf
  k <- cluster_res$chosen_k
  centroids <- matrix(0, nrow = k, ncol = length(vocab))
  colnames(centroids) <- vocab
  for (cl in 1:k) {
    idx <- which(cluster_res$clusters == cl)
    if (length(idx) > 0) {
      centroids[cl, ] <- colMeans(cluster_res$tfidf[idx, , drop = FALSE])
    }
  }
  export_data <- list(
    vocab = vocab,
    idf = as.numeric(idf_vec),
    centroids = centroids,
    cluster_sizes = as.numeric(table(cluster_res$clusters))
  )
  json_str <- toJSON(export_data, digits = 5, auto_unbox = TRUE, pretty = TRUE)
  write(json_str, file = paste0("model_", faction_name, "_standard.json"))
  cat("  Exported to model_", faction_name, "_standard.json\n", sep="")
}

# -----------------------------------------------------------------------------
# 8. Main loop: process each Corp faction
# -----------------------------------------------------------------------------

results <- list()

for (fac in FACTIONS) {
  cat("\n========================================\n")
  cat("FACTION:", toupper(fac), "\n")
  cat("========================================\n")
  
  # ---- Scrape UUIDs ----
  first_url <- build_search_url(fac, page = 1)
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
    Sys.sleep(1)
  }
  
  all_uuids <- unique(all_uuids)
  cat("\nTotal unique decks found:", length(all_uuids), "\n")
  
  # ---- Fetch decks ----
  cache_file <- file.path(CACHE_DIR, paste0(fac, "_standard_decks.rds"))
  if (file.exists(cache_file)) {
    cached <- readRDS(cache_file)
    fetched_uuids <- names(cached)
    cat("Loaded", length(fetched_uuids), "cached decks\n")
  } else {
    cached <- list()
    fetched_uuids <- character(0)
  }
  
  new_uuids <- setdiff(all_uuids, fetched_uuids)
  cat("Fetching", length(new_uuids), "new decks...\n")
  
  for (i in seq_along(new_uuids)) {
    uuid <- new_uuids[i]
    cat("  ", i, "/", length(new_uuids), ": ", uuid, "... ", sep = "")
    deck <- fetch_deck_api(uuid)
    if (!is.null(deck)) {

      # Faction ID mapping: URL-friendly -> API-friendly
      faction_map <- list(
        "haas-bioroid"      = "haas_bioroid",
        "jinteki"           = "jinteki",
        "nbn"               = "nbn",
        "weyland-consortium" = "weyland_consortium"   # hyphen in key, underscore in value
      )
      
      # Verify faction matches (using the mapped API ID)
      api_faction <- faction_map[[fac]]
      if (deck$meta$faction_id != api_faction) {
        cat("WRONG FACTION (", deck$meta$faction_id, ") - skipping\n", sep="")
        next
      }      
       
      cached[[uuid]] <- deck
      cat("OK\n")
    } else {
      cat("FAILED\n")
    }
    Sys.sleep(0.3)
  }
  
  saveRDS(cached, file = cache_file)
  cat("Cache saved to", cache_file, "\n")
  
  # ---- Prepare for clustering ----
  deck_slots <- list()
  deck_meta <- list()
  for (uuid in names(cached)) {
    deck <- cached[[uuid]]
    deck_slots <- c(deck_slots, list(deck$slots))
    deck_meta <- c(deck_meta, list(deck$meta))
  }
  
  cat("Total decks available for clustering:", length(deck_slots), "\n")
  if (length(deck_slots) == 0) {
    cat("No decks – skipping clustering.\n")
    next
  }
  
  # ---- Cluster ----
  cluster_res <- cluster_faction_cosine(
    deck_slots = deck_slots,
    remove_ubiq = REMOVE_UBIQ,
    remove_rare = REMOVE_RARE,
    k_min = K_MIN,
    k_max = K_MAX
  )
  
  if (is.null(cluster_res)) {
    cat("Clustering failed.\n")
    next
  }
  
  cat("\nCluster sizes (k =", cluster_res$chosen_k, "):\n")
  print(table(cluster_res$clusters))
  
  cat("\nTop signature cards per cluster:\n")
  for (cl in names(cluster_res$signatures)) {
    cat("  Cluster", cl, ":\n")
    print(cluster_res$signatures[[cl]])
  }
  
  # ---- Export model ----
  export_model_json(cluster_res, fac)
  
  results[[fac]] <- list(
    clustering = cluster_res,
    metadata = deck_meta
  )
}

cat("\nAll done.\n")