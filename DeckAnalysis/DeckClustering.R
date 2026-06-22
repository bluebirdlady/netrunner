###############################################################################
# Clustering Standard-format Runner Decks (from cached data)
# - Uses cosine distance, silhouette selection
# - Loads cached decks from cache/[faction]_standard_decks.rds
# - Exports JSON models
###############################################################################

library(httr)
library(jsonlite)
library(cluster)

# -----------------------------------------------------------------------------
# 1. Settings
# -----------------------------------------------------------------------------

REMOVE_UBIQ <- 0.60   # remove cards in >60% of decks
REMOVE_RARE <- 0.01   # remove cards in <1% of decks
K_MIN <- 2
K_MAX <- 10
CACHE_DIR <- "cache"

FACTIONS <- c("anarch", "criminal", "shaper")

# -----------------------------------------------------------------------------
# 2. Helper: Cosine distance (1 - cosine similarity)
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
# 3. Clustering function (cosine + silhouette)
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
  
  # Build presence matrix (0/1)
  all_card_ids <- unique(unlist(lapply(deck_slots, names)))
  presence <- matrix(0, nrow = length(deck_slots), ncol = length(all_card_ids))
  colnames(presence) <- all_card_ids
  for (i in seq_along(deck_slots)) {
    vec <- deck_slots[[i]]
    if (length(vec) > 0) presence[i, names(vec)] <- 1
  }
  cat("Initial matrix dimensions:", dim(presence), "\n")
  
  # Filter ubiquitous (> ubiqu threshold) and rare (< rare threshold)
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
  
  # Remove empty rows (shouldn't happen)
  row_sums <- rowSums(presence)
  if (any(row_sums == 0)) {
    presence <- presence[row_sums > 0, ]
  }
  if (nrow(presence) < 2) {
    cat("Not enough decks to cluster (need ≥2).\n")
    return(NULL)
  }
  
  # TF‑IDF
  N <- nrow(presence)
  idf <- log(N / colSums(presence))
  tfidf <- sweep(presence, 2, idf, FUN = "*")
  
  # Cosine distance
  dist_matrix <- cosine_dist(tfidf)
  if (any(is.na(dist_matrix))) {
    cat("NA values in distance matrix – skipping.\n")
    return(NULL)
  }
  
  # Hierarchical clustering with complete linkage (appropriate for cosine)
  hc <- hclust(dist_matrix, method = "complete")
  
  # --- Select k via silhouette ---
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
    chosen_k <- 5  # fallback
    warning("Silhouette could not be computed – using fixed k = 5")
  }
  cat("Silhouette scores:\n")
  print(round(silhouette_scores, 3))
  cat("Selected k =", chosen_k, "(highest silhouette)\n")
  
  # Cut dendrogram
  clusters <- cutree(hc, k = chosen_k)
  
  # Signatures: top 10 most frequent cards per cluster (using filtered presence)
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
# 4. Export model to JSON
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
# 5. Main: Load cached decks and cluster
# -----------------------------------------------------------------------------

results <- list()

for (fac in FACTIONS) {
  cat("\n========================================\n")
  cat("FACTION:", toupper(fac), "\n")
  cat("========================================\n")
  
  cache_file <- file.path(CACHE_DIR, paste0(fac, "_standard_decks.rds"))
  if (!file.exists(cache_file)) {
    cat("Cache file not found:", cache_file, "\n")
    next
  }
  
  cached <- readRDS(cache_file)
  cat("Loaded", length(cached), "decks from cache\n")
  
  # Convert to slots list
  deck_slots <- list()
  deck_meta <- list()
  for (uuid in names(cached)) {
    deck <- cached[[uuid]]
    deck_slots <- c(deck_slots, list(deck$slots))
    deck_meta <- c(deck_meta, list(deck$meta))
  }
  
  if (length(deck_slots) == 0) {
    cat("No decks found.\n")
    next
  }
  
  # Cluster
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
  
  # Print cluster sizes
  cat("\nCluster sizes (k =", cluster_res$chosen_k, "):\n")
  print(table(cluster_res$clusters))
  
  # Print signatures
  cat("\nTop signature cards per cluster:\n")
  for (cl in names(cluster_res$signatures)) {
    cat("  Cluster", cl, ":\n")
    print(cluster_res$signatures[[cl]])
  }
  
  # Export model
  export_model_json(cluster_res, fac)
  
  results[[fac]] <- list(
    clustering = cluster_res,
    metadata = deck_meta
  )
}

cat("\nAll done.\n")