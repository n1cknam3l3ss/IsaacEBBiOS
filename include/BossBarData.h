#pragma once
#include <cstdint>
#include <unordered_map>
#include <string>
#include <vector>

struct BossBarStyleInfo {
    const char *barRelPath;      // e.g. "bosshp_bars/bosses/bossbar_mother.png"
    const char *overlayRelPath;  // e.g. "bosshp_bars/bosses/bossbar_overlay_mother.png" or nullptr
    bool isDefaultTint;          // true if white fill needs red tint
};

inline BossBarStyleInfo GetBarStyleInfo(const char *styleName) {
    if (!styleName || !*styleName) {
        return { "bosshp_bars/custom_bosshp_default.png", nullptr, true };
    }
    std::string s = styleName;
    for (char &c : s) c = (char)tolower((unsigned char)c);

    if (s == "mother") {
        return { "bosshp_bars/bosses/bossbar_mother.png", "bosshp_bars/bosses/bossbar_overlay_mother.png", false };
    }
    if (s == "delirium") {
        return { "bosshp_bars/bosses/bossbar_delirium.png", nullptr, false };
    }
    if (s == "dogma") {
        return { "bosshp_bars/bosses/dogma_bar.png", nullptr, false };
    }
    if (s == "beast") {
        return { "bosshp_bars/bosses/bossbar_beast.png", "bosshp_bars/bosses/bossbar_overlay_beast.png", false };
    }
    if (s == "hush") {
        return { "bosshp_bars/bosses/bossbar_hush.png", nullptr, false };
    }
    if (s == "mega satan" || s == "mega_satan") {
        return { "bosshp_bars/bosses/bossbar_mega_satan.png", nullptr, false };
    }
    if (s == "mega satan phase 2" || s == "mega_satan_phase2" || s == "mega satan 2") {
        return { "bosshp_bars/bosses/bossbar_mega_satan_phase2.png", nullptr, false };
    }
    if (s == "colostomia") {
        return { "bosshp_bars/bosses/bossbar_colostomia.png", nullptr, false };
    }
    if (s == "dark esau" || s == "darkesau") {
        return { "bosshp_bars/bosses/bossbar_darkesau.png", nullptr, false };
    }
    if (s == "steven") {
        return { "bosshp_bars/bosses/bossbar_steven.png", nullptr, false };
    }
    if (s == "ultra greed" || s == "ultra_greed") {
        return { "bosshp_bars/bosses/bossbar_ultra_greed.png", nullptr, false };
    }
    if (s == "ultra greedier" || s == "ultra_greedier") {
        return { "bosshp_bars/bosses/bossbar_ultra_greedier.png", nullptr, false };
    }
    return { "bosshp_bars/custom_bosshp_default.png", nullptr, true };
}

struct BossBarInfo {
    int32_t type;
    int32_t variant;
    const char *name;
    const char *iconRelPath;
    const char *barStyle;
    std::vector<std::string> championColorSuffixes;
};

inline const std::unordered_map<int64_t, BossBarInfo>& GetBossDefinitions() {
    static const std::unordered_map<int64_t, BossBarInfo> kBossDefs = {
        { ((int64_t)19 << 16) | 0, { 19, 0, "Larry Jr", "chapter1/larry jr.png", nullptr, {} } },
        { ((int64_t)19 << 16) | 1, { 19, 1, "The Hollow", "chapter2/the_hollow.png", nullptr, {} } },
        { ((int64_t)19 << 16) | 2, { 19, 2, "Tuff Twin", "altpath/tuff_twin.png", nullptr, {} } },
        { ((int64_t)19 << 16) | 3, { 19, 3, "The Shell", "altpath/the_shell.png", nullptr, {} } },
        { ((int64_t)20 << 16) | 0, { 20, 0, "Monstro", "chapter1/monstro.png", nullptr, {} } },
        { ((int64_t)28 << 16) | 0, { 28, 0, "Chub", "chapter2/chub.png", nullptr, {} } },
        { ((int64_t)28 << 16) | 1, { 28, 1, "Chad", "chapter2/chad.png", nullptr, {} } },
        { ((int64_t)28 << 16) | 2, { 28, 2, "Carrion Queen", "chapter2/carrion_queen.png", nullptr, {} } },
        { ((int64_t)36 << 16) | 0, { 36, 0, "Gurdy", "chapter2/gurdy.png", nullptr, {} } },
        { ((int64_t)38 << 16) | 2, { 38, 2, "Ultra Pride Florian", "minibosses/ultra_pride_florian.png", nullptr, {} } },
        { ((int64_t)43 << 16) | 0, { 43, 0, "Monstro Two", "chapter3/monstro_two.png", nullptr, {} } },
        { ((int64_t)43 << 16) | 1, { 43, 1, "Gish", "chapter3/gish.png", nullptr, {} } },
        { ((int64_t)45 << 16) | 0, { 45, 0, "Mom", "final/mom.png", nullptr, {"_blue", "_red"} } },
        { ((int64_t)45 << 16) | 10, { 45, 10, "Mom", "final/mom.png", nullptr, {} } },
        { ((int64_t)46 << 16) | 0, { 46, 0, "Sloth", "minibosses/sloth.png", nullptr, {} } },
        { ((int64_t)46 << 16) | 1, { 46, 1, "Super Sloth", "minibosses/super_sloth.png", nullptr, {} } },
        { ((int64_t)46 << 16) | 2, { 46, 2, "Ultra Pride Ed", "minibosses/ultra_pride_ed.png", nullptr, {} } },
        { ((int64_t)47 << 16) | 0, { 47, 0, "Lust", "minibosses/lust.png", nullptr, {} } },
        { ((int64_t)47 << 16) | 1, { 47, 1, "Super Lust", "minibosses/super_lust.png", nullptr, {} } },
        { ((int64_t)48 << 16) | 0, { 48, 0, "Wrath", "minibosses/wrath.png", nullptr, {} } },
        { ((int64_t)48 << 16) | 1, { 48, 1, "Super Wrath", "minibosses/super_wrath.png", nullptr, {} } },
        { ((int64_t)49 << 16) | 0, { 49, 0, "Gluttony", "minibosses/gluttony.png", nullptr, {} } },
        { ((int64_t)49 << 16) | 1, { 49, 1, "Super Gluttony", "minibosses/super_gluttony.png", nullptr, {} } },
        { ((int64_t)50 << 16) | 0, { 50, 0, "Greed", "minibosses/greed.png", nullptr, {} } },
        { ((int64_t)50 << 16) | 1, { 50, 1, "Super Greed", "minibosses/super_greed.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 0, { 51, 0, "Envy Large", "minibosses/envy_large.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 1, { 51, 1, "Super Envy Large", "minibosses/super_envy_large.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 10, { 51, 10, "Envy Large", "minibosses/envy_large.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 11, { 51, 11, "Super Envy Medium", "minibosses/super_envy_medium.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 20, { 51, 20, "Envy Medium", "minibosses/envy_medium.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 21, { 51, 21, "Super Envy Small", "minibosses/super_envy_small.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 30, { 51, 30, "Envy Small", "minibosses/envy_small.png", nullptr, {} } },
        { ((int64_t)51 << 16) | 31, { 51, 31, "Super Envy Tiny", "minibosses/super_envy_tiny.png", nullptr, {} } },
        { ((int64_t)52 << 16) | 0, { 52, 0, "Pride", "minibosses/pride.png", nullptr, {} } },
        { ((int64_t)52 << 16) | 1, { 52, 1, "Super Pride", "minibosses/super_pride.png", nullptr, {} } },
        { ((int64_t)62 << 16) | 0, { 62, 0, "Pin", "chapter1/pin.png", nullptr, {} } },
        { ((int64_t)62 << 16) | 1, { 62, 1, "Scolex", "chapter4/scolex.png", nullptr, {} } },
        { ((int64_t)62 << 16) | 2, { 62, 2, "The Frail", "chapter2/the_frail.png", nullptr, {} } },
        { ((int64_t)62 << 16) | 3, { 62, 3, "Wormwood", "altpath/wormwood.png", nullptr, {} } },
        { ((int64_t)63 << 16) | 0, { 63, 0, "Famine", "horsemen/famine.png", nullptr, {} } },
        { ((int64_t)64 << 16) | 0, { 64, 0, "Pestilence", "horsemen/pestilence.png", nullptr, {} } },
        { ((int64_t)65 << 16) | 0, { 65, 0, "War", "horsemen/war.png", nullptr, {} } },
        { ((int64_t)65 << 16) | 1, { 65, 1, "Conquest", "horsemen/conquest.png", nullptr, {} } },
        { ((int64_t)65 << 16) | 10, { 65, 10, "War Phase2", "horsemen/war_phase2.png", nullptr, {} } },
        { ((int64_t)66 << 16) | 0, { 66, 0, "Death", "horsemen/death.png", nullptr, {} } },
        { ((int64_t)66 << 16) | 20, { 66, 20, "Death Horse", "horsemen/death_horse.png", nullptr, {} } },
        { ((int64_t)66 << 16) | 30, { 66, 30, "Death", "horsemen/death.png", nullptr, {} } },
        { ((int64_t)67 << 16) | 0, { 67, 0, "Duke Of Flies", "chapter1/duke_of_flies.png", nullptr, {} } },
        { ((int64_t)67 << 16) | 1, { 67, 1, "The Husk", "chapter2/the_husk.png", nullptr, {} } },
        { ((int64_t)68 << 16) | 0, { 68, 0, "Peep", "chapter2/peep.png", nullptr, {} } },
        { ((int64_t)68 << 16) | 1, { 68, 1, "The Bloat", "chapter3/the_bloat.png", nullptr, {} } },
        { ((int64_t)69 << 16) | 0, { 69, 0, "Loki", "chapter3/loki.png", nullptr, {} } },
        { ((int64_t)69 << 16) | 1, { 69, 1, "Lokii", "chapter4/lokii.png", nullptr, {} } },
        { ((int64_t)71 << 16) | 0, { 71, 0, "Fistula Large", "chapter2/fistula_large.png", nullptr, {} } },
        { ((int64_t)71 << 16) | 1, { 71, 1, "Teratoma Large", "chapter4/teratoma_large.png", nullptr, {} } },
        { ((int64_t)72 << 16) | 0, { 72, 0, "Fistula Medium", "chapter2/fistula_medium.png", nullptr, {} } },
        { ((int64_t)72 << 16) | 1, { 72, 1, "Teratoma Medium", "chapter4/teratoma_medium.png", nullptr, {} } },
        { ((int64_t)73 << 16) | 0, { 73, 0, "Fistula Small", "chapter2/fistula_small.png", nullptr, {} } },
        { ((int64_t)73 << 16) | 1, { 73, 1, "Teratoma Small", "chapter4/teratoma_small.png", nullptr, {} } },
        { ((int64_t)74 << 16) | 0, { 74, 0, "Blastocyst Large", "chapter4/blastocyst_large.png", nullptr, {} } },
        { ((int64_t)75 << 16) | 0, { 75, 0, "Blastocyst Medium", "chapter4/blastocyst_medium.png", nullptr, {} } },
        { ((int64_t)76 << 16) | 0, { 76, 0, "Blastocyst Small", "chapter4/blastocyst_small.png", nullptr, {} } },
        { ((int64_t)78 << 16) | 0, { 78, 0, "Moms Heart", "final/moms_heart.png", nullptr, {} } },
        { ((int64_t)78 << 16) | 1, { 78, 1, "It Lives", "final/it_lives.png", nullptr, {} } },
        { ((int64_t)79 << 16) | 0, { 79, 0, "Gemini Contusion", "chapter1/gemini_contusion.png", nullptr, {} } },
        { ((int64_t)79 << 16) | 1, { 79, 1, "Steven Big", "chapter1/steven_big.png", "Steven", {} } },
        { ((int64_t)79 << 16) | 2, { 79, 2, "Blighted Ovum", "chapter1/blighted_ovum.png", nullptr, {} } },
        { ((int64_t)79 << 16) | 10, { 79, 10, "Gemini Suture", "chapter1/gemini_suture.png", nullptr, {} } },
        { ((int64_t)79 << 16) | 11, { 79, 11, "Steven Small", "chapter1/steven_small.png", "Steven", {} } },
        { ((int64_t)81 << 16) | 0, { 81, 0, "The Fallen", "chapter1/the_fallen.png", nullptr, {} } },
        { ((int64_t)81 << 16) | 1, { 81, 1, "Krampus", "minibosses/krampus.png", nullptr, {} } },
        { ((int64_t)82 << 16) | 0, { 82, 0, "Headless Horsemen Body", "horsemen/headless_horsemen_body.png", nullptr, {} } },
        { ((int64_t)83 << 16) | 0, { 83, 0, "Headless Horsemen Head", "horsemen/headless_horsemen_head.png", nullptr, {} } },
        { ((int64_t)84 << 16) | 0, { 84, 0, "Satan", "final/satan.png", nullptr, {} } },
        { ((int64_t)84 << 16) | 10, { 84, 10, "Satan Phase2", "final/satan_phase2.png", nullptr, {} } },
        { ((int64_t)97 << 16) | 0, { 97, 0, "Mask Of Infamy", "chapter3/mask_of_infamy.png", nullptr, {} } },
        { ((int64_t)98 << 16) | 0, { 98, 0, "Heart Of Infamy", "chapter3/heart_of_infamy.png", nullptr, {} } },
        { ((int64_t)99 << 16) | 0, { 99, 0, "Gurdy Jr", "chapter2/gurdy_jr.png", nullptr, {} } },
        { ((int64_t)100 << 16) | 0, { 100, 0, "Widow", "chapter1/widow.png", nullptr, {} } },
        { ((int64_t)100 << 16) | 1, { 100, 1, "The Wretched", "chapter2/the_wretched.png", nullptr, {} } },
        { ((int64_t)101 << 16) | 0, { 101, 0, "Daddy Long Legs", "chapter4/daddy_long_legs.png", nullptr, {} } },
        { ((int64_t)101 << 16) | 1, { 101, 1, "Triachnid", "chapter4/triachnid.png", nullptr, {} } },
        { ((int64_t)102 << 16) | 0, { 102, 0, "Isaac", "final/isaac.png", nullptr, {} } },
        { ((int64_t)102 << 16) | 1, { 102, 1, "Blue Baby", "final/blue_baby.png", nullptr, {} } },
        { ((int64_t)102 << 16) | 2, { 102, 2, "Hush Baby", "final/hush_baby.png", nullptr, {} } },
        { ((int64_t)237 << 16) | 1, { 237, 1, "Gurgling", "chapter1/gurgling.png", nullptr, {} } },
        { ((int64_t)237 << 16) | 2, { 237, 2, "Turdling", "chapter1/turdling.png", nullptr, {} } },
        { ((int64_t)260 << 16) | 0, { 260, 0, "The Haunt", "chapter1/the_haunt.png", nullptr, {} } },
        { ((int64_t)261 << 16) | 0, { 261, 0, "Dingle", "chapter1/dingle.png", nullptr, {} } },
        { ((int64_t)261 << 16) | 1, { 261, 1, "Dangle", "chapter1/dangle.png", nullptr, {} } },
        { ((int64_t)262 << 16) | 0, { 262, 0, "Mega Maw", "chapter2/mega_maw.png", nullptr, {} } },
        { ((int64_t)263 << 16) | 0, { 263, 0, "The Gate", "chapter3/the_gate.png", nullptr, {} } },
        { ((int64_t)264 << 16) | 0, { 264, 0, "Mega Fatty", "chapter2/mega_fatty.png", nullptr, {} } },
        { ((int64_t)265 << 16) | 0, { 265, 0, "The Cage", "chapter3/the_cage.png", nullptr, {} } },
        { ((int64_t)266 << 16) | 0, { 266, 0, "Mama Gurdy", "chapter4/mama_gurdy.png", nullptr, {} } },
        { ((int64_t)267 << 16) | 0, { 267, 0, "Dark One", "chapter2/dark_one.png", nullptr, {} } },
        { ((int64_t)268 << 16) | 0, { 268, 0, "The Adversary", "chapter3/the_adversary.png", nullptr, {} } },
        { ((int64_t)269 << 16) | 0, { 269, 0, "Polycephalus", "chapter2/polycephalus.png", nullptr, {} } },
        { ((int64_t)269 << 16) | 1, { 269, 1, "The Pile", "chapter3/the_pile.png", nullptr, {} } },
        { ((int64_t)270 << 16) | 0, { 270, 0, "Mr Fred", "chapter4/mr_fred.png", nullptr, {} } },
        { ((int64_t)271 << 16) | 0, { 271, 0, "Uriel", "minibosses/uriel.png", nullptr, {} } },
        { ((int64_t)271 << 16) | 1, { 271, 1, "Fallen Uriel", "minibosses/fallen_uriel.png", nullptr, {} } },
        { ((int64_t)272 << 16) | 0, { 272, 0, "Gabriel", "minibosses/gabriel.png", nullptr, {} } },
        { ((int64_t)272 << 16) | 1, { 272, 1, "Fallen Gabriel", "minibosses/fallen_gabriel.png", nullptr, {} } },
        { ((int64_t)273 << 16) | 0, { 273, 0, "The Lamb", "final/the_lamb.png", nullptr, {} } },
        { ((int64_t)273 << 16) | 10, { 273, 10, "The Lamb Body", "final/the_lamb_body.png", nullptr, {} } },
        { ((int64_t)274 << 16) | 0, { 274, 0, "Mega Satan", "final/mega_satan.png", "Mega Satan", {} } },
        { ((int64_t)274 << 16) | 1, { 274, 1, "Mega Satan Righthand", "final/mega_satan_righthand.png", "Mega Satan", {} } },
        { ((int64_t)274 << 16) | 2, { 274, 2, "Mega Satan Lefthand", "final/mega_satan_lefthand.png", "Mega Satan", {} } },
        { ((int64_t)275 << 16) | 0, { 275, 0, "Mega Satan Phase2", "final/mega_satan_phase2.png", "Mega Satan Phase 2", {} } },
        { ((int64_t)401 << 16) | 0, { 401, 0, "The Stain", "chapter2/the_stain.png", nullptr, {} } },
        { ((int64_t)402 << 16) | 0, { 402, 0, "Brownie", "chapter3/brownie.png", nullptr, {} } },
        { ((int64_t)403 << 16) | 0, { 403, 0, "The Forsaken", "chapter2/the_forsaken.png", nullptr, {} } },
        { ((int64_t)404 << 16) | 0, { 404, 0, "Little Horn", "chapter1/little_horn.png", nullptr, {} } },
        { ((int64_t)405 << 16) | 0, { 405, 0, "Ragman", "chapter1/ragman.png", nullptr, {} } },
        { ((int64_t)406 << 16) | 0, { 406, 0, "Ultra Greed", "final/ultra_greed.png", "Ultra Greed", {} } },
        { ((int64_t)406 << 16) | 1, { 406, 1, "Ultra Greedier", "final/ultra_greedier.png", "Ultra Greedier", {} } },
        { ((int64_t)407 << 16) | 0, { 407, 0, "Hush", "final/hush.png", "Hush", {} } },
        { ((int64_t)408 << 16) | 0, { 408, 0, "Skinless Hush", "unused/skinless_hush.png", nullptr, {} } },
        { ((int64_t)409 << 16) | 0, { 409, 0, "Rag Mega", "chapter2/rag_mega.png", nullptr, {} } },
        { ((int64_t)410 << 16) | 0, { 410, 0, "Sisters Vis", "chapter3/sisters_vis.png", nullptr, {} } },
        { ((int64_t)411 << 16) | 0, { 411, 0, "Big Horn", "chapter2/big_horn.png", nullptr, {} } },
        { ((int64_t)412 << 16) | 0, { 412, 0, "Delirium", "final/delirium.png", "Delirium", {} } },
        { ((int64_t)413 << 16) | 0, { 413, 0, "The Matriarch", "chapter4/the_matriarch.png", nullptr, {} } },
        { ((int64_t)866 << 16) | 0, { 866, 0, "Dark Esau", "minibosses/dark_esau.png", "Dark Esau", {} } },
        { ((int64_t)900 << 16) | 0, { 900, 0, "Reap Creep", "chapter3/reap_creep.png", nullptr, {} } },
        { ((int64_t)901 << 16) | 0, { 901, 0, "Lil Blub", "altpath/lil_blub.png", nullptr, {} } },
        { ((int64_t)902 << 16) | 0, { 902, 0, "Rainmaker", "altpath/rainmaker.png", nullptr, {} } },
        { ((int64_t)903 << 16) | 0, { 903, 0, "The Visage Heart", "altpath/the_visage_heart.png", nullptr, {} } },
        { ((int64_t)903 << 16) | 1, { 903, 1, "The Visage Mask", "altpath/the_visage_mask.png", nullptr, {} } },
        { ((int64_t)904 << 16) | 0, { 904, 0, "Siren", "altpath/siren.png", nullptr, {} } },
        { ((int64_t)905 << 16) | 0, { 905, 0, "The Heretic", "altpath/the_heretic.png", nullptr, {} } },
        { ((int64_t)906 << 16) | 0, { 906, 0, "Hornfel", "altpath/hornfel.png", nullptr, {} } },
        { ((int64_t)907 << 16) | 0, { 907, 0, "Great Gideon", "altpath/great_gideon.png", nullptr, {} } },
        { ((int64_t)908 << 16) | 0, { 908, 0, "Baby Plum", "chapter1/baby_plum.png", nullptr, {} } },
        { ((int64_t)909 << 16) | 0, { 909, 0, "The Scourge", "altpath/the_scourge.png", nullptr, {} } },
        { ((int64_t)910 << 16) | 0, { 910, 0, "Chimera Head", "altpath/chimera_head.png", nullptr, {} } },
        { ((int64_t)910 << 16) | 1, { 910, 1, "Chimera Body", "altpath/chimera_body.png", nullptr, {} } },
        { ((int64_t)910 << 16) | 2, { 910, 2, "Chimera Head", "altpath/chimera_head.png", nullptr, {} } },
        { ((int64_t)911 << 16) | 0, { 911, 0, "Rotgut Mouth", "altpath/rotgut_mouth.png", nullptr, {} } },
        { ((int64_t)911 << 16) | 1, { 911, 1, "Rotgut Maggot", "altpath/rotgut_maggot.png", nullptr, {} } },
        { ((int64_t)911 << 16) | 2, { 911, 2, "Rotgut Balls", "altpath/rotgut_balls.png", nullptr, {} } },
        { ((int64_t)912 << 16) | 0, { 912, 0, "Mother", "final/mother.png", "Mother", {} } },
        { ((int64_t)912 << 16) | 10, { 912, 10, "Mother Phase2", "final/mother_phase2.png", "Mother", {} } },
        { ((int64_t)913 << 16) | 0, { 913, 0, "Min Min", "altpath/min_min.png", nullptr, {} } },
        { ((int64_t)914 << 16) | 0, { 914, 0, "Clog", "altpath/clog.png", nullptr, {} } },
        { ((int64_t)915 << 16) | 0, { 915, 0, "Singe", "altpath/singe.png", nullptr, {} } },
        { ((int64_t)916 << 16) | 0, { 916, 0, "Bumbino", "chapter2/bumbino.png", nullptr, {} } },
        { ((int64_t)917 << 16) | 0, { 917, 0, "Colostomia", "altpath/colostomia.png", "Colostomia", {} } },
        { ((int64_t)918 << 16) | 0, { 918, 0, "Turdlet", "altpath/turdlet.png", nullptr, {} } },
        { ((int64_t)919 << 16) | 0, { 919, 0, "Raglich", "unused/raglich.png", nullptr, {} } },
        { ((int64_t)920 << 16) | 0, { 920, 0, "Horny Boys", "altpath/horny_boys.png", nullptr, {} } },
        { ((int64_t)921 << 16) | 0, { 921, 0, "Clutch", "altpath/clutch.png", nullptr, {} } },
        { ((int64_t)922 << 16) | 0, { 922, 0, "Cadavra", "unused/cadavra.png", nullptr, {} } },
        { ((int64_t)950 << 16) | 0, { 950, 0, "Dogma", "final/dogma_tv.png", "Dogma", {} } },
        { ((int64_t)950 << 16) | 1, { 950, 1, "Dogma Tv", "final/dogma_tv.png", "Dogma", {} } },
        { ((int64_t)950 << 16) | 2, { 950, 2, "Dogma Angel", "final/dogma_phase2.png", "Dogma", {} } },
        { ((int64_t)951 << 16) | 0, { 951, 0, "The Beast", "final/beast.png", "Beast", {} } },
        { ((int64_t)951 << 16) | 10, { 951, 10, "Ultra Famine", "final/ultra_famine.png", nullptr, {} } },
        { ((int64_t)951 << 16) | 20, { 951, 20, "Ultra Pestilence", "final/ultra_pestilence.png", nullptr, {} } },
        { ((int64_t)951 << 16) | 30, { 951, 30, "Ultra War", "final/ultra_war.png", nullptr, {} } },
        { ((int64_t)951 << 16) | 40, { 951, 40, "Ultra Death", "final/ultra_death.png", nullptr, {} } },
    };
    return kBossDefs;
}

inline const BossBarInfo* FindBossInfo(int32_t type, int32_t variant) {
    const auto& map = GetBossDefinitions();
    // 1. Exact match (type, variant)
    int64_t key = ((int64_t)type << 16) | variant;
    auto it = map.find(key);
    if (it != map.end()) return &it->second;

    // 2. Check variant 0 fallback
    key = ((int64_t)type << 16) | 0;
    it = map.find(key);
    if (it != map.end()) return &it->second;

    // 3. Check variant 10 fallback (common in Isaac)
    key = ((int64_t)type << 16) | 10;
    it = map.find(key);
    if (it != map.end()) return &it->second;

    // 4. Fallback search by type
    for (const auto& pair : map) {
        if (pair.second.type == type) {
            return &pair.second;
        }
    }
    return nullptr;
}
