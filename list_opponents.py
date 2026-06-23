import json
for fname, side in [("Campaign/campaign.json","corp"), ("Campaign/corp_campaign.json","runner")]:
    with open(fname) as f:
        d = json.load(f)
    opps = d.get("opponents", {})
    print("\n--- %s opponents (%s) ---" % (side, fname))
    for k, v in sorted(opps.items()):
        identity = v.get("identity", "")
        name = v.get("name", identity)
        print("  %-44s  %s" % (k, name))
