"""Extends Campaign/corp_campaign.json with Acts 5-10."""
import json, sys

# ── Runner opponent decks (Acts 5-10) ────────────────────────────────────────

opponents = {}

# ── Act 5 (Downfall runner cards) ────────────────────────────────────────────
opponents["runner_az_blueberry_breakers"] = {
    "name": "Blueberry Breakers",
    "identity": "az_mccaffrey_mechanical_prodigy",
    "description": "Az McCaffrey. Works smarter. Every install is a dividend.",
    "deck": (
        ["blueberry_diesel"]*3 + ["clean_getaway"]*3 + ["creative_commission"]*2 +
        ["kompromat"]*3 + ["mutual_favor"]*3 + ["sell_out"]*3 +
        ["sure_gamble"]*3 + ["transfer_of_wealth"]*3 +
        ["lucky_charm"]*2 + ["masterwork_v37"] +
        ["baklan_bochkin"] + ["fransofia_ward"] + ["open_market"]*2 +
        ["red_team"]*2 + ["the_class_act"] + ["underdome_irregulars"] +
        ["buzzsaw"] + ["carmen"] + ["echelon"] + ["marjanah"] +
        ["sang_kancil"] + ["unity"]*2 +
        ["fermenter"] + ["leech"]*3
    )
}

opponents["runner_lat_lateral_thinking"] = {
    "name": "Lateral Thinking",
    "identity": "lat_ethical_freelancer",
    "description": "Lat. Freelancer. Thinks sideways through your ICE.",
    "deck": (
        ["creative_commission"]*3 + ["jailbreak"]*3 + ["overclock"]*3 +
        ["ritual"]*3 + ["sure_gamble"]*3 + ["vrcation"]*3 +
        ["docklands_pass"] + ["dzmz_optimizer"]*3 + ["gamedragon_pro"] +
        ["madani"]*2 + ["t400_memory_diamond"]*3 +
        ["telework_contract"]*3 +
        ["echelon"]*2 + ["gauss"]*2 + ["unity"]*2 +
        ["conduit"]*2 + ["fermenter"]*2 + ["leech"]*2 + ["pelangi"]*2
    )
}

# ── Act 6 (Uprising runner cards) ────────────────────────────────────────────
opponents["runner_zahya_lucky_switch"] = {
    "name": "Lucky Switch",
    "identity": "zahya_sadeghi_versatile_smuggler",
    "description": "Zahya. Fast hands. She flips your ICE before it can fire.",
    "deck": (
        ["always_have_a_backup_plan"]*3 + ["blueberry_diesel"]*3 +
        ["creative_commission"]*2 + ["mutual_favor"]*3 + ["overclock"]*3 +
        ["sure_gamble"]*3 + ["vrcation"]*2 + ["wildcat_strike"] +
        ["flip_switch"]*3 + ["lucky_charm"]*3 + ["masterwork_v37"]*2 +
        ["baklan_bochkin"]*2 + ["the_class_act"]*2 +
        ["carmen"]*2 + ["marjanah"]*2 + ["sang_kancil"]*2 +
        ["tranquilizer"]*2
    )
}

opponents["runner_ryo_fizzy_phoenix"] = {
    "name": "Fizzy Phoenix",
    "identity": "ryo_phoenix_ono_out_of_the_ashes",
    "description": "Ryo. She comes back more dangerous each time. Plan accordingly.",
    "deck": (
        ["creative_commission"]*3 + ["isolation"]*3 + ["jailbreak"]*3 +
        ["overclock"]*3 + ["sure_gamble"]*3 +
        ["demolisher"]*2 + ["dzmz_optimizer"]*3 + ["the_tungsten_tailor"]*2 +
        ["cacophony"] + ["climactic_showdown"] + ["cookbook"] +
        ["fencer_fueno"] + ["the_nihilist"] + ["trickster_taka"] +
        ["buzzsaw"]*2 + ["echelon"] + ["rising_tide"]*2 + ["utae"] +
        ["botulus"] + ["chisel"]*3 + ["conduit"] +
        ["fermenter"]*3 + ["gourmand"]*2 + ["leech"]*2 + ["stargate"]*2
    )
}

opponents["runner_topan_demolished"] = {
    "name": "Demolished",
    "identity": "topan_ormas_leader",
    "description": "Topan. No more subtlety. She is tearing your walls down.",
    "deck": (
        ["chain_reaction"]*3 + ["creative_commission"]*2 + ["jailbreak"]*3 +
        ["overclock"]*3 + ["sure_gamble"]*3 + ["take_a_dive"]*3 +
        ["demolisher"]*2 + ["dzmz_optimizer"]*2 + ["the_tungsten_tailor"]*2 +
        ["cacophony"]*2 + ["cookbook"]*2 + ["telework_contract"] + ["verbal_plasticity"]*2 +
        ["buzzsaw"]*2 + ["echelon"] + ["rising_tide"]*2 + ["unity"]*2 +
        ["botulus"]*3 + ["fermenter"]*2 + ["leech"]*3
    )
}

opponents["runner_dewi_groovy"] = {
    "name": "Groovy Dewi",
    "identity": "dewi_subrotoputri_pedagogical_dhalang",
    "description": "Dewi. She has found her rhythm. Every run builds on the last.",
    "deck": (
        ["creative_commission"]*3 + ["in_the_groove"]*2 + ["jailbreak"]*3 +
        ["khusyuk"]*3 + ["overclock"]*3 + ["spec_work"]*3 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*3 + ["supercorridor"]*2 +
        ["telework_contract"]*3 + ["the_artist"] + ["verbal_plasticity"]*2 +
        ["buzzsaw"]*2 + ["echelon"]*2 + ["gauss"] + ["unity"]*2 +
        ["conduit"]*2 + ["fermenter"]*2 + ["leech"]*2 + ["pelangi"]
    )
}

opponents["runner_hiram_cybertrooper_pauli"] = {
    "name": "Cybertrooper Pauli",
    "identity": "hiram_0mission_svensson",
    "description": "Hiram. Ghost in the system. Cordyceps everywhere. Pull one thread and the network unravels.",
    "deck": (
        ["harmony_ar_therapy"]*3 + ["overclock"]*3 + ["sure_gamble"]*3 +
        ["aniccam"]*2 + ["dzmz_optimizer"]*3 +
        ["cybertrooper_talut"]*2 + ["daily_casts"]*3 + ["paules_cafe"] +
        ["telework_contract"]*3 + ["the_artist"] +
        ["echelon"]*2 + ["euler"]*2 + ["gauss"]*2 + ["principia"]*2 + ["unity"]*2 +
        ["conduit"]*3 + ["cordyceps"]*3 + ["fermenter"] +
        ["pelangi"]*2 + ["self_modifying_code"]*2
    )
}

opponents["runner_tao_daily_plasticity"] = {
    "name": "Daily Plasticity",
    "identity": "tao_salonga_telepresence_magician",
    "description": "Tao. Evolving. Every run she reconfigures. You cannot plan for her.",
    "deck": (
        ["creative_commission"]*3 + ["jailbreak"]*3 + ["overclock"]*3 +
        ["ritual"]*3 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*3 + ["simulchip"]*2 +
        ["daily_casts"]*3 + ["telework_contract"]*3 + ["verbal_plasticity"]*2 +
        ["buzzsaw"]*2 + ["echelon"]*2 + ["unity"]*2 +
        ["botulus"]*2 + ["conduit"]*2 + ["fermenter"]*2 + ["leech"]*2 +
        ["self_modifying_code"]*3
    )
}

# ── Act 7 (Midnight Sun runner cards) ────────────────────────────────────────
opponents["runner_az_prognostic_boomerang"] = {
    "name": "Prognostic Boomerang",
    "identity": "az_mccaffrey_mechanical_prodigy",
    "description": "Az. Every card she installs bounces back as a weapon.",
    "deck": (
        ["bravado"]*3 + ["clean_getaway"]*2 + ["mutual_favor"]*3 +
        ["sure_gamble"]*3 + ["transfer_of_wealth"]*3 + ["tread_lightly"]*3 +
        ["wildcat_strike"]*3 +
        ["boomerang"]*3 + ["borrowed_goods"]*2 + ["docklands_pass"]*2 +
        ["prognostic_q_loop"]*2 +
        ["daily_casts"]*3 + ["the_back"]*2 + ["the_class_act"] +
        ["afterimage"]*2 + ["carmen"]*2 + ["marjanah"]*2 + ["sang_kancil"]*2 +
        ["tranquilizer"]*2
    )
}

opponents["runner_barry_lucky_bravado"] = {
    "name": "Lucky Bravado",
    "identity": "barry_baz_wong_tri_maf_veteran",
    "description": "Barry. He runs like every score is a payday. Because it is.",
    "deck": (
        ["bravado"]*3 + ["jailbreak"]*3 + ["mutual_favor"]*3 +
        ["overclock"]*3 + ["sure_gamble"]*3 +
        ["boomerang"]*3 + ["docklands_pass"]*2 + ["lucky_charm"]*2 +
        ["maglectric_rapid_748_mod"]*2 + ["masterwork_v37"]*2 + ["prognostic_q_loop"]*2 +
        ["baklan_bochkin"]*2 + ["daily_casts"]*3 + ["fransofia_ward"]*2 +
        ["open_market"]*2 + ["red_team"]*3 + ["the_class_act"] +
        ["buzzsaw"]*2 + ["carmen"]*2 + ["unity"]*2
    )
}

opponents["runner_loup_trickster_paladin"] = {
    "name": "Trickster Paladin",
    "identity": "rene_loup_arcemont_party_animal",
    "description": "Loup. Running on faith and counters. The economy is somebody else's problem.",
    "deck": (
        ["sure_gamble"]*3 +
        ["boomerang"]*2 + ["carnivore"]*2 + ["gachapon"]*2 + ["keiko"] +
        ["daily_casts"]*3 + ["mystic_maemi"]*2 + ["paladin_poemu"] + ["trickster_taka"]*2 +
        ["buzzsaw"]*2 + ["marjanah"]*3 + ["odore"]*2 + ["rising_tide"]*3 +
        ["botulus"]*2 + ["chisel"]*3 + ["fermenter"]*3 + ["gourmand"]*2 + ["leech"]*3
    )
}

opponents["runner_topan_tide_of_omore"] = {
    "name": "Tide of Omore",
    "identity": "topan_ormas_leader",
    "description": "Topan. Militant. She brings the tide. Your ICE is temporary infrastructure.",
    "deck": (
        ["creative_commission"]*3 + ["overclock"] + ["scrounge"]*3 +
        ["sure_gamble"]*3 + ["vrcation"]*3 +
        ["demolisher"]*2 + ["devil_charm"]*2 + ["simulchip"] + ["the_tungsten_tailor"]*2 +
        ["climactic_showdown"]*3 + ["daily_casts"]*3 + ["paladin_poemu"] +
        ["buzzsaw"]*2 + ["echelon"] + ["odore"]*2 + ["rising_tide"]*2 +
        ["botulus"]*2 + ["chisel"]*2 + ["fermenter"]*3 + ["leech"]*2 + ["stargate"]*2
    )
}

opponents["runner_padma_threading"] = {
    "name": "Threading the Environment",
    "identity": "captain_padma_isbister_intrepid_explorer",
    "description": "Padma. Explorer. She charts routes through your architecture no one else has found.",
    "deck": (
        ["creative_commission"]*3 + ["deep_dive"]*3 + ["overclock"]*3 +
        ["pinhole_threading"]*3 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*2 + ["simulchip"]*3 +
        ["daily_casts"]*3 + ["environmental_testing"]*3 +
        ["stoneship_chart_room"]*3 + ["telework_contract"]*3 +
        ["echelon"]*2 + ["propeller"]*3 + ["unity"]*2 +
        ["conduit"]*2 + ["fermenter"]*2 + ["self_modifying_code"]*3
    )
}

opponents["runner_magdalene_fermented_future"] = {
    "name": "Fermented Future",
    "identity": "magdalene_keino_chemutai_cryptarchitect",
    "description": "Magdalene. Patient. She is cultivating access to something you have not noticed yet.",
    "deck": (
        ["creative_commission"]*3 + ["deep_dive"]*3 + ["pinhole_threading"]*2 +
        ["ritual"]*2 + ["spec_work"]*3 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*3 + ["simulchip"]*3 +
        ["daily_casts"]*3 + ["environmental_testing"]*3 +
        ["stoneship_chart_room"]*2 + ["telework_contract"]*3 +
        ["echelon"]*2 + ["propeller"]*2 + ["unity"]*2 +
        ["azimat"]*2 + ["conduit"]*2 + ["fermenter"]*2 + ["self_modifying_code"]*3
    )
}

# ── Act 8 (Parhelion runner cards) ────────────────────────────────────────────
opponents["runner_muslihat_cezve_revolver"] = {
    "name": "Cezve Revolver",
    "identity": "muslihat_multifarious_marketeer",
    "description": "MuslihaT. She has refined her trade. Every access point has a price.",
    "deck": (
        ["bravado"]*2 + ["clean_getaway"]*3 + ["jailbreak"]*2 +
        ["mutual_favor"]*3 + ["overclock"]*2 + ["pinhole_threading"]*3 +
        ["sure_gamble"]*3 + ["transfer_of_wealth"]*3 +
        ["boomerang"]*3 +
        ["backstitching"]*2 + ["daily_casts"]*3 + ["no_free_lunch"]*2 +
        ["red_team"]*3 + ["the_class_act"]*2 + ["the_twinning"]*2 +
        ["carmen"]*2 + ["cats_cradle"]*2 + ["marjanah"]*2 + ["revolver"]*2 +
        ["cezve"]*3
    )
}

opponents["runner_vic_red_act"] = {
    "name": "Red Act",
    "identity": "virtual_intelligence_p_i_you_can_call_me_vic",
    "description": "Vic. No hesitation. No wasted motion. A perfect run every time.",
    "deck": (
        ["bravado"]*3 + ["mutual_favor"]*3 + ["pinhole_threading"]*3 +
        ["sure_gamble"]*3 + ["transfer_of_wealth"]*3 +
        ["boomerang"]*3 + ["docklands_pass"]*2 +
        ["daily_casts"]*3 + ["open_market"]*3 + ["red_team"]*3 +
        ["the_class_act"] + ["the_twinning"]*2 +
        ["carmen"]*2 + ["marjanah"]*3 + ["sang_kancil"]*2 +
        ["cezve"]*3 + ["self_modifying_code"]*3
    )
}

opponents["runner_esa_steeling_keiko"] = {
    "name": "Steeling Keiko",
    "identity": "esa_afontov_eco_insurrectionist",
    "description": "Esa. Eco-insurrectionist. She runs on principle and spite.",
    "deck": (
        ["pinhole_threading"]*3 + ["steelskin_scarring"]*3 + ["sure_gamble"]*3 +
        ["boomerang"]*2 + ["gachapon"]*3 + ["keiko"]*2 + ["simulchip"]*2 +
        ["daily_casts"]*3 + ["fencer_fueno"]*2 + ["mystic_maemi"]*2 +
        ["paladin_poemu"]*2 + ["the_twinning"]*2 + ["trickster_taka"]*2 +
        ["buzzsaw"]*2 + ["echelon"]*2 + ["odore"]*2 + ["rising_tide"]*3 +
        ["botulus"]*3 + ["fermenter"]*2 + ["leech"]*2
    )
}

opponents["runner_ryo_classy_fire"] = {
    "name": "Classy Fire",
    "identity": "ryo_phoenix_ono_out_of_the_ashes",
    "description": "Ryo. Burning bright. Every server she cracks fuels the next.",
    "deck": (
        ["bravado"]*2 + ["pinhole_threading"]*2 + ["steelskin_scarring"]*3 +
        ["sure_gamble"]*3 +
        ["boomerang"]*2 + ["keiko"]*2 +
        ["daily_casts"]*3 + ["light_the_fire"]*3 + ["paladin_poemu"]*2 +
        ["the_class_act"] + ["the_twinning"]*2 + ["trickster_taka"]*2 +
        ["buzzsaw"]*3 + ["rising_tide"]*3 + ["utae"]*2 +
        ["botulus"]*3 + ["fermenter"]*2 + ["gourmand"]*3 + ["leech"]*2
    )
}

opponents["runner_padma_dr_nuka"] = {
    "name": "Dr. Nuka",
    "identity": "captain_padma_isbister_intrepid_explorer",
    "description": "Padma. She has a specialist now. Nuka closes gaps you did not know existed.",
    "deck": (
        ["creative_commission"]*3 + ["deep_dive"]*3 + ["pinhole_threading"]*2 +
        ["ritual"]*3 + ["spec_work"]*3 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*2 + ["simulchip"]*3 +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"]*2 + ["environmental_testing"]*3 +
        ["stoneship_chart_room"]*3 + ["telework_contract"]*3 +
        ["echelon"]*2 + ["propeller"]*2 + ["revolver"]*2 + ["unity"]*2 +
        ["azimat"]*3 + ["conduit"]*3 + ["fermenter"]*2 + ["self_modifying_code"]*3
    )
}

opponents["runner_dewi_self_modifying_pinhole"] = {
    "name": "Self-Modifying Pinhole",
    "identity": "dewi_subrotoputri_pedagogical_dhalang",
    "description": "Dewi. She adapts faster than your ICE can respond. The lesson is never free.",
    "deck": (
        ["creative_commission"]*3 + ["overclock"]*3 + ["pinhole_threading"]*3 +
        ["ritual"]*3 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*3 + ["simulchip"]*3 +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"]*2 + ["stoneship_chart_room"]*3 +
        ["telework_contract"]*3 +
        ["echelon"]*2 + ["propeller"]*3 + ["unity"]*2 +
        ["conduit"]*2 + ["fermenter"] + ["self_modifying_code"]*3
    )
}

# ── Act 9 (The Automata Initiative runner cards) ──────────────────────────────
opponents["runner_ryo_takas_cookbook"] = {
    "name": "Taka's Cookbook",
    "identity": "ryo_phoenix_ono_out_of_the_ashes",
    "description": "Ryo. Taka and Cookbook. She does not stop. She cannot be stopped.",
    "deck": (
        ["pinhole_threading"]*2 + ["raindrops_cut_stone"]*3 + ["steelskin_scarring"]*3 +
        ["strike_fund"]*3 + ["sure_gamble"]*3 +
        ["boomerang"]*2 + ["keiko"] + ["simulchip"]*2 +
        ["cookbook"]*2 + ["daily_casts"]*3 + ["dr_nuka_vrolyck"] + ["fencer_fueno"] +
        ["mystic_maemi"]*2 + ["paladin_poemu"]*2 + ["the_twinning"] + ["trickster_taka"] +
        ["buzzsaw"]*2 + ["echelon"]*2 + ["rising_tide"]*3 +
        ["botulus"]*2 + ["fermenter"]*2 + ["leech"]*2
    )
}

opponents["runner_esa_tungsten_carnivore"] = {
    "name": "Tungsten Carnivore",
    "identity": "esa_afontov_eco_insurrectionist",
    "description": "Esa. Steel and biology. Your ICE is infrastructure. She unmakes infrastructure.",
    "deck": (
        ["pinhole_threading"] + ["raindrops_cut_stone"]*3 + ["steelskin_scarring"]*3 +
        ["strike_fund"]*3 + ["sure_gamble"]*3 +
        ["carnivore"]*3 + ["demolisher"]*2 + ["simulchip"]*2 + ["the_tungsten_tailor"]*3 +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"] + ["paladin_poemu"] + ["the_twinning"]*2 +
        ["buzzsaw"]*2 + ["echelon"]*2 + ["rising_tide"]*3 +
        ["botulus"]*2 + ["fermenter"]*2 + ["leech"]*2 + ["self_modifying_code"]*2
    )
}

opponents["runner_barry_sang_curu"] = {
    "name": "Sang Curu",
    "identity": "barry_baz_wong_tri_maf_veteran",
    "description": "Barry. New tools. Same business model. Run, score, repeat.",
    "deck": (
        ["bravado"]*3 + ["creative_commission"]*3 + ["mutual_favor"]*3 +
        ["overclock"]*3 + ["pinhole_threading"]*3 + ["sure_gamble"]*3 +
        ["boomerang"]*3 + ["docklands_pass"]*2 +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"] + ["the_class_act"] +
        ["carmen"]*2 + ["curupira"]*3 + ["echelon"] + ["marjanah"]*2 +
        ["revolver"]*2 + ["sang_kancil"]*2 +
        ["cezve"]*3 + ["self_modifying_code"]*2
    )
}

opponents["runner_mercury_mystic_shibboleth"] = {
    "name": "Mystic Shibboleth",
    "identity": "mercury_chrome_libertador",
    "description": "Mercury. Fastest runner on the network. She does not wait for ICE to fire.",
    "deck": (
        ["bravado"]*3 + ["carpe_diem"]*2 + ["clean_getaway"]*3 +
        ["mutual_favor"]*3 + ["pinhole_threading"]*3 + ["sure_gamble"]*3 +
        ["transfer_of_wealth"] +
        ["boomerang"]*3 + ["docklands_pass"]*2 + ["hermes"]*3 +
        ["wake_implant_v2a_jrj"]*2 +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"] + ["mystic_maemi"] +
        ["the_class_act"] + ["the_twinning"] +
        ["carmen"]*2 + ["curupira"]*3 + ["shibboleth"]*2 +
        ["cezve"]*3
    )
}

opponents["runner_magdalene_future_freedom_flow"] = {
    "name": "Future Freedom Flow",
    "identity": "magdalene_keino_chemutai_cryptarchitect",
    "description": "Magdalene. She has seen the architecture. She is building a door.",
    "deck": (
        ["creative_commission"]*3 + ["overclock"]*3 + ["pinhole_threading"]*2 +
        ["ritual"]*3 + ["spec_work"]*3 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*3 + ["lilypad"]*2 + ["simulchip"]*3 +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"] + ["environmental_testing"]*3 +
        ["stoneship_chart_room"]*3 + ["telework_contract"]*3 +
        ["echelon"]*2 + ["propeller"]*2 + ["unity"]*2 +
        ["azimat"]*2 + ["conduit"]*2 + ["fermenter"]*2 + ["self_modifying_code"]*3
    )
}

opponents["runner_arissana_lilypad_gamble"] = {
    "name": "The Lilypad Gamble",
    "identity": "arissana_rocha_nahu_street_artist",
    "description": "Arissana. Street artist. She tags your servers with programs you cannot see until they fire.",
    "deck": (
        ["creative_commission"]*3 + ["deep_dive"]*3 + ["overclock"]*3 +
        ["pinhole_threading"]*2 + ["sure_gamble"]*3 +
        ["dzmz_optimizer"]*3 + ["lilypad"]*2 + ["simulchip"]*3 +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"] + ["environmental_testing"]*3 +
        ["telework_contract"]*3 +
        ["echelon"]*2 + ["propeller"]*3 + ["unity"]*2 +
        ["conduit"]*2 + ["fermenter"]*2 + ["self_modifying_code"]*3
    )
}

# ── Act 10 (Rebellion without Rehearsal runner cards) ────────────────────────
opponents["runner_hiram_nosferatu"] = {
    "name": "Nosferatu",
    "identity": "hiram_0mission_svensson",
    "description": "Hiram. He has been inside your systems longer than you know. He is ending this himself.",
    "deck": (
        ["burner"] + ["creative_commission"]*3 + ["deep_dive"] + ["harmony_ar_therapy"] +
        ["overclock"]*3 + ["pinhole_threading"]*2 + ["rigging_up"]*2 +
        ["ritual"]*2 + ["steelskin_scarring"]*3 + ["strike_fund"]*3 + ["sure_gamble"]*3 +
        ["aniccam"]*3 + ["buffer_drive"] + ["dzmz_optimizer"]*2 +
        ["simulchip"]*3 + ["touchstone"] +
        ["dr_nuka_vrolyck"] +
        ["audrey_v2"] + ["echelon"] + ["pressure_spike"] + ["propeller"] + ["unity"] +
        ["azimat"] + ["pichacao"] + ["self_modifying_code"]*3
    )
}

opponents["runner_loup_midnight_wolf"] = {
    "name": "Midnight Wolf",
    "identity": "rene_loup_arcemont_party_animal",
    "description": "Loup. In the dark. He does not need to see the ICE to break it.",
    "deck": (
        ["pinhole_threading"]*2 + ["privileged_access"]*3 + ["raindrops_cut_stone"]*3 +
        ["steelskin_scarring"]*3 + ["strike_fund"]*3 + ["sure_gamble"]*3 +
        ["gachapon"]*3 + ["touchstone"]*2 +
        ["daily_casts"]*3 + ["fencer_fueno"] + ["mystic_maemi"] + ["paladin_poemu"] +
        ["penumbral_toolkit"]*2 + ["the_twinning"]*2 + ["trickster_taka"]*2 +
        ["afterimage"] + ["corsair"] + ["penrose"] +
        ["fermenter"]*3
    )
}

opponents["runner_vic_courage"] = {
    "name": "Courage",
    "identity": "virtual_intelligence_p_i_you_can_call_me_vic",
    "description": "Vic. She has been watching the Syndicate for years. This is the final accounting.",
    "deck": (
        ["bravado"]*3 + ["clean_getaway"]*3 + ["kompromat"]*2 +
        ["privileged_access"] + ["sure_gamble"]*3 + ["transfer_of_wealth"]*3 +
        ["docklands_pass"] + ["hermes"]*2 + ["wake_implant_v2a_jrj"]*2 +
        ["baklan_bochkin"] + ["arruaceiras_crew"]*3 + ["daily_casts"]*3 +
        ["dreamnet"]*3 + ["dr_nuka_vrolyck"] + ["open_market"]*3 + ["the_class_act"]*3 +
        ["carmen"] + ["curupira"]*2 + ["revolver"] + ["shibboleth"]*2 +
        ["leech"]*2
    )
}

opponents["runner_loup_devil_wears_chisel"] = {
    "name": "This Devil Wears Chisel",
    "identity": "rene_loup_arcemont_party_animal",
    "description": "Loup. Dressed to kill. Every program he wears is a weapon.",
    "deck": (
        ["pinhole_threading"]*2 + ["raindrops_cut_stone"]*3 + ["steelskin_scarring"]*3 +
        ["sure_gamble"]*3 +
        ["airbladex_jsrf_ed"] + ["devil_charm"]*2 + ["gachapon"]*3 +
        ["hermes"]*2 + ["simulchip"] + ["the_tungsten_tailor"] +
        ["daily_casts"]*3 + ["dr_nuka_vrolyck"] + ["eru_ayase_pessoa"] +
        ["fencer_fueno"] + ["paladin_poemu"]*2 + ["the_twinning"]*2 + ["trickster_taka"] +
        ["buzzsaw"]*2 + ["echelon"]*2 + ["rising_tide"]*2 +
        ["chisel"]*2 + ["fermenter"]*3
    )
}

opponents["runner_esa_face"] = {
    "name": "Face",
    "identity": "esa_afontov_eco_insurrectionist",
    "description": "Esa. The last runner standing. She is not running for profit. She is running for everyone.",
    "deck": (
        ["bahia_bands"]*2 + ["chastushka"]*2 + ["finality"]*2 +
        ["katorga_breakout"]*2 + ["pinhole_threading"]*2 + ["raindrops_cut_stone"]*3 +
        ["running_hot"]*3 + ["steelskin_scarring"]*3 + ["strike_fund"]*3 +
        ["sure_gamble"]*3 + ["wildcat_strike"]*3 +
        ["ghosttongue"]*3 + ["hippocampic_mechanocytes"] + ["marrow"]*3 +
        ["dr_nuka_vrolyck"]*3 + ["fencer_fueno"] + ["mystic_maemi"] + ["nurse_hanh"] +
        ["abaasy"] + ["begemot"]*2 + ["revolver"] +
        ["botulus"]*3 + ["fermenter"]*3
    )
}

opponents["runner_arissana_trojan_exe"] = {
    "name": "Trojan.Exe",
    "identity": "arissana_rocha_nahu_street_artist",
    "description": "Arissana. Her art lives in your servers now. You cannot remove it without crashing everything.",
    "deck": (
        ["creative_commission"]*3 + ["deep_dive"] + ["illumination"] +
        ["ritual"]*3 + ["sure_gamble"]*2 +
        ["dzmz_optimizer"] + ["lilypad"]*2 + ["lucky_charm"] + ["simulchip"]*3 +
        ["wake_implant_v2a_jrj"] +
        ["dr_nuka_vrolyck"]*3 + ["environmental_testing"]*3 +
        ["hannah_wheels_pilintra"] + ["urban_art_vernissage"]*2 +
        ["echelon"] + ["propeller"]*3 + ["unity"] +
        ["coalescence"]*3 + ["cupellation"] + ["fermenter"] + ["hush"] +
        ["muse"]*3 + ["physarum_entangler"] + ["pichacao"] + ["stowaway"]*2
    )
}

# ── Corp card unlocks per act ─────────────────────────────────────────────────
# Act 5: 35 Downfall Corp cards in 2 missions
act5_cards = ['afshar','architect_deployment_test','calvin_b4l3y','cold_site_server','complete_image',
              'congratulations','csr_campaign','daily_quest','divested_trust','focus_group',
              'fully_operational','game_over','hagen','hyoubu_institute_absolute_clarity',
              'increased_drop_rates','letheia_nisei','loot_box','mirrormorph_endless_iteration',
              'nanoetching_matrix','project_yagi_uda','public_health_portal','red_level_clearance',
              'reduced_service','remastered_edition','rime','roughneck_repair_squad','saisentan',
              'sandstone','sds_drone_deployment','secure_and_protect','sting','storgotic_resonator',
              'tiered_subscription','trebuchet','vulnerability_audit']
act5_unlocks = [act5_cards[:18], act5_cards[18:]]

# Act 6: 35 Uprising Corp cards in 6 missions
act6_cards = ['akhet','argus_crackdown','bass_ch1r180g4','bellona','cayambe_grid',
              'cerebral_overwriter','colossus','cyberdex_sandbox','digital_rights_management',
              'drafter','earth_station_sea_headquarters','engram_flush','f2p','false_lead',
              'flower_sermon','gamenet_where_dreams_are_real','ganked','gold_farmer',
              'hyoubu_precog_manifold','kakurenbo','konjin','la_costa_grid','megaprix_qualifier',
              'napd_cordon','next_activation_command','prana_condenser','project_vacheron',
              'scapenet','sync_rerouting','tranquility_home_grid','transport_monopoly',
              'tyr','vaporframe_fabricator','wall_to_wall','winchester']
act6_unlocks = [act6_cards[i*6:i*6+6] for i in range(5)] + [act6_cards[30:]]

# Act 7: 35 Midnight Sun Corp cards in 6 missions
act7_cards = ['anemone','artificial_cryptocrash','azef_protocol','backroom_machinations',
              'bathynomus','big_deal','bladderwort','blood_in_the_water','chekist_scion',
              'drago_ivanov','echo','elivagar_bifurcation','envelopment','extract','hakarl_1_0',
              'ivik','maskirovka','mavirus','mestnichestvo','midnight_3_arcology','mitosis',
              'moon_pool','mutually_assured_destruction',
              'ob_superheavy_logistics_extract_export_excel','pravdivost_consulting_political_solutions',
              'refuge_campaign','regenesis','stavka','svyatogor_excavator','trieste_model_bioroids',
              'trust_operation','ubiquitous_vig','vasilisa','vladisibirsk_city_grid','wave']
act7_unlocks = [act7_cards[i*6:i*6+6] for i in range(5)] + [act7_cards[30:]]

# Act 8: 34 Parhelion Corp cards in 6 missions
act8_cards = ['ampere_cybernetics_for_anyone','anvil','bloop','distributed_tracing','djupstad_grid',
              'dr_vientiane_keeling','end_of_the_line','freedom_of_information','gaslight','hafrun',
              'hostile_architecture','hybrid_release','hypoxia','issuaq_adaptics_sustaining_diversity',
              'kimberlite_field','klevetnik','mr_hendrik','nanisivik_grid','nightmare_archive',
              'nonequivalent_exchange','ontological_dependence','post_truth_dividend','pulse',
              'reaper_function','regulatory_capture','shipment_from_vladisibirsk','simulation_reset',
              'superdeep_borehole','thule_subsea_safety_below','unsmiling_tsarevna','vampyronassa',
              'vera_ivanovna_shuyskaya','yakov_erikovich_avdakov','zato_city_grid']
act8_unlocks = [act8_cards[i*6:i*6+6] for i in range(5)] + [act8_cards[30:]]

# Act 9: 35 TAI Corp cards in 6 missions
act9_cards = ['a_teia_ip_recovery','ablative_barrier','adrian_seis','angelique_garza_correa',
              'armed_asset_protection','attini','b_1001','balanced_coverage','behold',
              'cybersand_harvester','daniela_jorge_inacio','epiphany_analytica_nations_undivided',
              'federal_fundraising','front_company','fujii_asset_retrieval','greasing_the_palm',
              'jaguarundi','m_i_c','mindscaping','oppo_research','oracle_thinktank','phoneutria',
              'pivot','salvo_testing','slash_and_burn_agriculture','starlit_knight','stegodon_mk_iv',
              'tatu_bola','tree_line','tucana','valentao','virtual_service_agent','vovo_ozetti',
              'wage_workers','your_digital_life']
act9_unlocks = [act9_cards[i*6:i*6+6] for i in range(5)] + [act9_cards[30:]]

# Act 10: 35 RwR Corp cards in 6 missions
act10_cards = ['active_policing','boto','brasilia_government_grid','bring_them_home',
               'business_as_usual','capacitor','charlotte_cacador','cloud_eater',
               'cohort_guidance_program','corporate_hospitality','descent','eminent_domain',
               'hammer','hearts_and_minds','isaac_liberdade','janaina_jk_dumont_kindelan',
               'kingmaking','lightning_laboratory','logjam','lycian_multi_munition',
               'nuvem_sa_law_of_the_land','piranhas','see_how_they_run','seraph',
               'sisyphus_protocol','sorocaban_blade','stoke_the_embers','sudden_commandment',
               'the_basalt_spire','the_holo_man','the_powers_that_be',
               'thunderbolt_armaments_peace_through_power','tributary','warm_reception',
               'working_prototype']
act10_unlocks = [act10_cards[i*6:i*6+6] for i in range(5)] + [act10_cards[30:]]

# Validate unlock counts
assert sum(len(b) for b in act5_unlocks) == 35
assert sum(len(b) for b in act6_unlocks) == 35
assert sum(len(b) for b in act7_unlocks) == 35
assert sum(len(b) for b in act8_unlocks) == 34
assert sum(len(b) for b in act9_unlocks) == 35
assert sum(len(b) for b in act10_unlocks) == 35

# ── Mission builder ───────────────────────────────────────────────────────────
def make_mission(mid, title, subtitle, act, ai_level, fiction_pre, fiction_post,
                 opponent_id, unlocks_missions, unlocks_cards, prereqs):
    return {
        "id": mid,
        "title": title,
        "subtitle": subtitle,
        "act": act,
        "ai_level": ai_level,
        "fiction_pre": fiction_pre,
        "fiction_post": fiction_post,
        "opponent_id": opponent_id,
        "unlocks_missions": unlocks_missions,
        "unlocks_cards": unlocks_cards,
        "prerequisite_missions": prereqs,
    }

new_missions = []

# Act 5 (2 missions, ai_level 3)
act5_data = [
    ("corp_act5a", "Downfall Cascade",   "Syndicate Server Farm, Heinlein High Orbit",        "runner_az_blueberry_breakers"),
    ("corp_act5b", "Below the Horizon",  "Syndicate Cold Storage Node, Heinlein Deep Core",   "runner_lat_lateral_thinking"),
]
for i, (mid, title, subtitle, opp_id) in enumerate(act5_data):
    next_m = ["corp_act5b"] if i == 0 else ["corp_act6a"]
    prereqs = ["corp_act4g"] if i == 0 else ["corp_act5a"]
    new_missions.append(make_mission(mid, title, subtitle, 5, 3,
        f"{mid}_pre", f"{mid}_post", opp_id, next_m, act5_unlocks[i], prereqs))

# Act 6 (6 missions, ai_level 3)
act6_data = [
    ("corp_act6a", "Upswing",             "Syndicate Relay Tower 4, Heinlein Equatorial Ring", "runner_zahya_lucky_switch"),
    ("corp_act6b", "Ash and Signal",      "Phoenix Rising Data Hub, Heinlein Sublevel 8",      "runner_ryo_fizzy_phoenix"),
    ("corp_act6c", "Structural Damage",   "Syndicate Infrastructure Grid, Heinlein Surface",   "runner_topan_demolished"),
    ("corp_act6d", "The Learning Curve",  "Syndicate Research Campus, Heinlein Station",        "runner_dewi_groovy"),
    ("corp_act6e", "Ghost Protocol",      "Syndicate Comms Dark Node, Heinlein Core",           "runner_hiram_cybertrooper_pauli"),
    ("corp_act6f", "Fluid Architecture",  "Syndicate Mobile Server, Heinlein Upper Ring",       "runner_tao_daily_plasticity"),
]
for i, (mid, title, subtitle, opp_id) in enumerate(act6_data):
    next_m = [f"corp_act6{chr(ord('a')+i+1)}"] if i < 5 else ["corp_act7a"]
    if i == 0:
        prereqs = ["corp_act5b"]
    else:
        prereqs = [f"corp_act6{chr(ord('a')+i-1)}"]
    new_missions.append(make_mission(mid, title, subtitle, 6, 3,
        f"{mid}_pre", f"{mid}_post", opp_id, next_m, act6_unlocks[i], prereqs))

# Act 7 (6 missions, ai_level 3)
act7_data = [
    ("corp_act7a", "Midnight Approach",   "Syndicate Dark Server One, Heinlein High Orbit",    "runner_az_prognostic_boomerang"),
    ("corp_act7b", "Lucky Strike",        "Syndicate Prize Data Vault, Heinlein Belt Rim",     "runner_barry_lucky_bravado"),
    ("corp_act7c", "The Pack",            "Syndicate Perimeter Node, Heinlein Surface",         "runner_loup_trickster_paladin"),
    ("corp_act7d", "Tide Warning",        "Syndicate Coastal Relay, Heinlein Equatorial",       "runner_topan_tide_of_omore"),
    ("corp_act7e", "True North",          "Syndicate Navigation Grid, Heinlein Deep Core",      "runner_padma_threading"),
    ("corp_act7f", "Cultivation",         "Syndicate Agri-Data Archive, Heinlein Ring 3",       "runner_magdalene_fermented_future"),
]
for i, (mid, title, subtitle, opp_id) in enumerate(act7_data):
    next_m = [f"corp_act7{chr(ord('a')+i+1)}"] if i < 5 else ["corp_act8a"]
    if i == 0:
        prereqs = ["corp_act6f"]
    else:
        prereqs = [f"corp_act7{chr(ord('a')+i-1)}"]
    new_missions.append(make_mission(mid, title, subtitle, 7, 3,
        f"{mid}_pre", f"{mid}_post", opp_id, next_m, act7_unlocks[i], prereqs))

# Act 8 (6 missions, ai_level 3)
act8_data = [
    ("corp_act8a", "Pressure Front",      "Syndicate Tactical Array, Heinlein High Orbit",     "runner_muslihat_cezve_revolver"),
    ("corp_act8b", "Act of Will",         "Syndicate Legal Division Server, Heinlein Tower",    "runner_vic_red_act"),
    ("corp_act8c", "Steel and Soil",      "Syndicate Ecology Research Node, Heinlein Park",     "runner_esa_steeling_keiko"),
    ("corp_act8d", "Burn Notice",         "Phoenix Rising Cell Alpha, Heinlein Sublevel 15",   "runner_ryo_classy_fire"),
    ("corp_act8e", "Deep Cartography",    "Syndicate Expedition Server, Heinlein Fringe",       "runner_padma_dr_nuka"),
    ("corp_act8f", "Living Archive",      "Syndicate Knowledge Vault, Heinlein Academic Ring",  "runner_dewi_self_modifying_pinhole"),
]
for i, (mid, title, subtitle, opp_id) in enumerate(act8_data):
    next_m = [f"corp_act8{chr(ord('a')+i+1)}"] if i < 5 else ["corp_act9a"]
    if i == 0:
        prereqs = ["corp_act7f"]
    else:
        prereqs = [f"corp_act8{chr(ord('a')+i-1)}"]
    new_missions.append(make_mission(mid, title, subtitle, 8, 3,
        f"{mid}_pre", f"{mid}_post", opp_id, next_m, act8_unlocks[i], prereqs))

# Act 9 (6 missions, ai_level 3)
act9_data = [
    ("corp_act9a", "Machine Politics",    "Syndicate Governance Node, Heinlein Admin Ring",    "runner_ryo_takas_cookbook"),
    ("corp_act9b", "Iron Harvest",        "Syndicate Resource Extraction Hub, Heinlein Belt",  "runner_esa_tungsten_carnivore"),
    ("corp_act9c", "Sangue e Moeda",      "Syndicate Finance Server, Heinlein Commercial",     "runner_barry_sang_curu"),
    ("corp_act9d", "The Libertador",      "Syndicate Comms Relay, Heinlein Free Market Zone",  "runner_mercury_mystic_shibboleth"),
    ("corp_act9e", "Future Contract",     "Syndicate Futures Division, Heinlein High Orbit",   "runner_magdalene_future_freedom_flow"),
    ("corp_act9f", "Street Gallery",      "Syndicate Public Interface, Heinlein Open Level",   "runner_arissana_lilypad_gamble"),
]
for i, (mid, title, subtitle, opp_id) in enumerate(act9_data):
    next_m = [f"corp_act9{chr(ord('a')+i+1)}"] if i < 5 else ["corp_act10a"]
    if i == 0:
        prereqs = ["corp_act8f"]
    else:
        prereqs = [f"corp_act9{chr(ord('a')+i-1)}"]
    new_missions.append(make_mission(mid, title, subtitle, 9, 3,
        f"{mid}_pre", f"{mid}_post", opp_id, next_m, act9_unlocks[i], prereqs))

# Act 10 (6 missions, ai_level 3)
act10_data = [
    ("corp_act10a", "Shadow Protocol",   "Syndicate Black Archive Omega, Heinlein Core",      "runner_hiram_nosferatu"),
    ("corp_act10b", "Howling",           "Syndicate Perimeter Array, Heinlein Night Sector",   "runner_loup_midnight_wolf"),
    ("corp_act10c", "Reckoning",         "Syndicate Legal Ledger Server, Heinlein Tower 2",    "runner_vic_courage"),
    ("corp_act10d", "Wearable Tech",     "Syndicate Consumer Interface, Heinlein Mall Level",  "runner_loup_devil_wears_chisel"),
    ("corp_act10e", "Open Revolt",       "Syndicate Public Records Server, Heinlein Civic",    "runner_esa_face"),
    ("corp_act10f", "Profit Over Principle: Finale",
                                         "Syndicate Central Executive Suite, Lunacent Tower 1","runner_arissana_trojan_exe"),
]
for i, (mid, title, subtitle, opp_id) in enumerate(act10_data):
    next_m = [f"corp_act10{chr(ord('a')+i+1)}"] if i < 5 else []
    if i == 0:
        prereqs = ["corp_act9f"]
    else:
        prereqs = [f"corp_act10{chr(ord('a')+i-1)}"]
    new_missions.append(make_mission(mid, title, subtitle, 10, 3,
        f"{mid}_pre", f"{mid}_post", opp_id, next_m, act10_unlocks[i], prereqs))

# ── Load, extend, and save corp_campaign.json ─────────────────────────────────
path = "C:/Users/jws780/Documents/GitHub/netrunner/Campaign/corp_campaign.json"
with open(path, encoding="utf-8") as f:
    campaign = json.load(f)

campaign["missions"].extend(new_missions)
campaign["opponents"].update(opponents)

with open(path, "w", encoding="utf-8") as f:
    json.dump(campaign, f, indent=2, ensure_ascii=False)

print(f"Updated {path}")
print(f"  Total missions: {len(campaign['missions'])}")
print(f"  Total opponents: {len(campaign['opponents'])}")
for k, v in opponents.items():
    n = len(v["deck"])
    flag = " ** SMALL" if n < 30 else (" ** LARGE" if n > 55 else "")
    print(f"  {k}: {n} cards{flag}")
