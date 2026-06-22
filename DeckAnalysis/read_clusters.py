import json, glob, os

def top_cards(centroid, vocab, n=12):
    scored = [(vocab[i], centroid[i]) for i in range(len(vocab)) if centroid[i] > 0]
    scored.sort(key=lambda x: -x[1])
    return [c[0] for c in scored[:n]]

for path in sorted(glob.glob("model_*.json")):
    with open(path) as f:
        m = json.load(f)
    faction = os.path.basename(path).replace("model_","").replace("_standard.json","")
    vocab = m["vocab"]
    centroids = m["centroids"]
    sizes = m["cluster_sizes"]
    print(f"\n=== {faction.upper()} ({len(centroids)} clusters) ===")
    for i, (c, sz) in enumerate(zip(centroids, sizes)):
        top = top_cards(c, vocab)
        print(f"  C{i} (n={sz:4d}): {top}")
