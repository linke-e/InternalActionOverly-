# InternalReactionOverlay+

English | [中文](README.md)

A 256×256 animated desktop-pet overlay in the **bottom-left corner** of the game.
When a game event triggers, the pet plays a matching reaction animation, then
returns to its main state (static sprite + random blinking). While idle in the
main state, it occasionally plays a random idle animation.

> Requires: The Binding of Isaac: Repentance+
> API reference: [IsaacDocs (wofsauge)](https://wofsauge.github.io/IsaacDocs/rep/)
>
> **v3.1**: every desktop-pet character now keeps its own independent settings
> profile (all animation/appearance options are saved per character and
> auto-applied on switch; old saves migrate automatically).

---

## Installation

1. Subscribe on the Steam Workshop
```
https://steamcommunity.com/sharedfiles/filedetails/?id=3786174946
```
2. For the "room item quality" animations (item0~item4), also install the dependency:
   [ReactionAPI](https://steamcommunity.com/sharedfiles/filedetails/?id=3096181411)
3. Launch the game; the mod loads automatically. It works without MCM — install
   [Mod Config Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=2686875783)
   (or its Chinese localization) to configure in-game.

---

## Desktop-Pet Character Pool

All characters live under `resources/gfx/pets/` — **one folder per character** (up to 5):

```
resources/gfx/pets/
├── Angle/                       # character 1 (folder name = character name)
│   ├── main.png  main_sad.png   # static single-frame sprites (normal / half health)
│   ├── Medicine/  activity/  boss/  half/  hurt/
│   ├── idle1/ ~ idle4/          # idle animations
│   ├── item0/ ~ item4/          # item-quality animations
│   └── wink/  wink1/            # blink animations (full health / half health)
└── TangTang/                    # character 2 (has an extra idle5/)
```

Characters are bundled: DeepseekWhite,DeepseekSchool,Genimi,Angle and Rain, all 256×256 transparent PNGs.

**Switching characters** (all of these persist into the save):
- In-game: MCM → "桌宠角色" (Character) page, cycle left/right;
- Or set `activePet = "CharacterName"` in `internalreactionoverlay_config.lua`;
- Takes effect immediately, no game restart needed.

### Per-character settings 

**Every desktop-pet character owns an independent settings profile**, fully isolated:

- Scale/position, animation speed, blink intervals, idle triggering, event
  durations, state switches, `animHold` — all animation/appearance settings are
  **saved per character**;
- MCM edits always target the **current character** (each settings page shows
  the active character in its title); **switching characters automatically
  applies that character's own profile**;
- A newly added character starts from the factory defaults in
  `internalreactionoverlay_config.lua`, then diverges independently;
- Global options shared by all characters: master toggle, hotkey, `petFallback`
  borrow toggle, top-left debug line;
- Persistence: Isaac only offers a single save slot, so independent profiles are
  stored name-sectioned inside that save
  (`internalreactionoverlay_profiles.lua` handles capture/apply/sanitize);
- **Old saves migrate automatically**: after upgrading, the previous shared
  settings are cloned to every character (behavior identical to pre-upgrade),
  then characters diverge as you edit each one.

**Adding a character**:
1. Create a new folder under `resources/gfx/pets/` (use ASCII letters/digits/underscores
   for the name — Isaac's resource loader handles non-ASCII paths poorly);
2. Add `main.png`, `main_sad.png` and the animation sub-folders (256×256 PNG frames;
   off-size frames are auto-resized by the script);
3. Run `python gen_anim.py` in the mod root to rebuild the frame manifest;
4. The new character appears in the MCM "桌宠角色" page (initial profile = factory
   defaults, saved independently from then on).

> Incomplete character assets still work: by default (`petFallback = false`) events
> referencing a missing animation simply do not trigger — the pet stays in its
> idle/normal animation and never borrows other characters' assets. To borrow
> across characters, enable "缺素材时借用其它角色" in the MCM character page
> (or set `petFallback = true`).

---

## Event → Animation Mapping

| Game event | Animation key | Character folder | Playback |
|---|---|---|---|
| Normal (full health) | main_static | main.png | static, persistent |
| Normal (half health) | main_sad | main_sad.png | static, persistent |
| Hurt (environment damage / monster attacks) | hurt | hurt/ | once |
| Card / pill used | Medicine | Medicine/ | once |
| Active item / pocket active used | activity | activity/ | once |
| Boss fight (uncleared boss room) | boss | boss/ | once |
| Half health (≤ half red heart) | half | half/ | once |
| Unpicked item in room | item0~item4 | item0/ ~ item4/ | once or loop |
| Random idle | idle1~idle4* | idle1/ ~ idle4/ | once |
| Blink (full health) | wink | wink/ | loop |
| Blink (half health) | wink1 | wink1/ | loop |

> \* Frame counts vary per character (e.g. Angle's hurt has 3 frames, TangTang's has 8;
> see `internalreactionoverlay_frames.lua`). TangTang ships an extra idle5, but the
> default idle pool only enables idle1~idle4 — to enable it, add
> `{ key = "idle5", weight = 2 }` to `config.idle.entries`.

### Hurt animation

The `hurt` animation plays once when the player takes the following damage:

**Environmental damage** (matched by damage type, `config.hurt.damageFlags`):

Fire (DAMAGE_FIRE), explosion (DAMAGE_EXPLOSION), laser (DAMAGE_LASER),
acid (DAMAGE_ACID), spikes (DAMAGE_SPIKES), red poop (DAMAGE_POOP),
TNT (DAMAGE_TNT), poison/burn (DAMAGE_POISON_BURN), pitfall (DAMAGE_PITFALL).

**Monster attacks** (matched by damage source; toggle `config.hurt.monsterDamage`, on by default):

Monster body contact / claw / self-destruction, enemy tears, enemy lasers/projectiles, monster bomb explosions.

Decision tree (`mod:IsMonsterDamage`):
1. **Flag override**: damage carrying any of these flags is forcibly classified as
   "not monster damage": FIRE / SPIKES / ACID / POISON_BURN / DEVIL / IV_BAG /
   PITFALL / CHEST / CURSED_DOOR / TIMER / TNT / POOP / RED_HEARTS / COUNTDOWN /
   CLONES / ISSAC_HEART
   (note: EXPLOSION / LASER are **not** sufficient evidence of a monster — the
   player's own bombs / tech lasers carry them too, hence step 2);
2. **Source classification**:
   - `source.Entity == nil` (spikes/fire/curses…) → not monster
   - `source.Entity:IsEnemy()` (monster body contact/claw/self-destruct) → monster
   - `source.Type ∈ {ENTITY_TEAR, ENTITY_LASER, ENTITY_PROJECTILE}` and not friendly → monster
   - `source.Type == ENTITY_BOMB` → check `SpawnerType`: player-placed → not monster, otherwise monster
   - Player / friendly sources (blood donation machine, razor, blood bag) → not monster
   - `ENTITY_EFFECT` (creep/fire/red poop) → not monster

> Monster contact/claw damage usually has `damageFlags == 0` — that is normal;
> classification falls through to the source-based path above.

- Damage types are listed in `config.hurt.damageFlags` (see
  [DamageFlag enum](https://cuerzor.github.io/IsaacDocs/rep/enums/DamageFlag.html)).
- **Non-penalty damage** carrying `DAMAGE_NO_PENALTIES` (no devil-deal penalty)
  does not trigger hurt (`config.hurt.ignoreNoPenalties`, on by default).
- Hurt animations **play their full sequence** (hurt frames × animHold.hurt), no fixed cutoff;
  repeated damage re-triggers after the previous play finishes.
- Hurt and boss share the **same priority level** — they never interrupt each other
  (the playing one finishes, the other is deferred).
- Detection uses `MC_ENTITY_TAKE_DMG` (player only) + `CallbackPriority.EARLY`,
  so errors thrown by other mods' callbacks cannot skip it.

### Active item usage

Using an **active item** (primary or pocket slot) plays the `activity` animation once.

- Detected via `MC_USE_ITEM`, which only fires when an active item is **actually used**;
  covers all slots (`SLOT_PRIMARY`, `SLOT_POCKET`, …).
- Pills use `MC_USE_PILL` and cards use `MC_USE_CARD`, so they never false-trigger this.
- The activity animation **plays its full sequence** (frames × animHold.activity), no fixed cutoff.
- Toggle: `config.states.active` (on by default).

### Room item quality (requires ReactionAPI)

When unpicked items exist in the current room, the animation matching the **highest
quality** present plays: Quality 0→item0, 1→item1, 2→item2, 3→item3, 4→item4.

**Highest wins**: a room containing both quality-2 and quality-4 items only plays item4.
Re-detected when items are picked up or the room changes; reset on new room.

**Playback mode** (`config.itemQuality.mode`):
- `once`: plays once per detected quality change, then returns to main (default);
- `loop`: loops for as long as unpicked items exist, switching animation on quality change.

**Playback priority**: item0~item4 sit above card/pill, active item, hurt and boss
in the animation priority (only half health — and a quality change itself — outrank
them below item4), so those events are deferred until the item animation finishes;
picking up a higher-quality item switches to the new animation immediately.

> Without ReactionAPI this feature silently disables itself; everything else keeps working.

---

## Playback Rules

- **Event animations** (hurt, card/pill, active item, boss, half health, item quality):
  **play to the end of the full sequence** (duration = frames × animHold ÷ animSpeed,
  no fixed-duration cutoff), then return to main.
- **Animation priority** (only a higher priority interrupts a playing animation;
  interrupted events are deferred and replayed in full afterwards):
```
item4 > half > item3 > item2 > item1 > item0 > Medicine(card/pill) > Activity(active item) > hurt = boss > idle1~4 > wink = wink1
```
  - the item state's priority follows the room's current **highest quality**
    (item4 outranks half health; item0 is below it);
  - **hurt and boss are equal**: they never interrupt each other — the playing
    one finishes first, the other is deferred;
  - repeated events at the same level (e.g. taking damage again) naturally
    re-trigger after the previous play finishes.
- **Sustained conditions** (boss fight, half health, item quality): after one play,
  the state is "suppressed" until the condition clears (leave boss room / heal /
  items picked up) to avoid endless re-triggering.
- **Blinking**: loops while in main state; after each blink it waits a random
  interval. Lowest priority.
- **Item animation mode** (`itemQuality.mode`): once = play once, return to main;
  loop = persist while unpicked items exist (while looping, lower-priority events
  stay deferred until items are picked up / the room changes).

---

## Configuration (internalreactionoverlay_config.lua)

All tunables live in `internalreactionoverlay_config.lua`; no need to touch main.lua.

> **Scope**: except the 4 options marked **[GLOBAL]** below, every MCM-adjustable
> option is **per character** (factory defaults live in this file; in-game edits
> are saved per character and auto-applied on switch — see "Per-character
> settings"). Structural tables (`animHold`/`events`/`main`, …) are shared
> factory declarations; per-character profiles override individual values.

| Option | Default | Scope | Description |
|---|---|---|---|
| `activePet` | "Angle" | **[GLOBAL]** | Active desktop-pet character (pool folder name; MCM-switchable, persisted) |
| `petFallback` | false | **[GLOBAL]** | Borrow other characters' same-key animation when missing; off by default (missing events don't trigger, pet stays idle) |
| `animFps` | 15 | global | Default animation frame rate (render fps, 60 fps basis) |
| `animHold` | see file | global (factory-shared) | Per-animation frame hold (render frames per animation frame; 60 ≈ 1 s); not saved per character since v1.5 — edits apply on restart |
| `animSpeed` | 1.0 | per character | Animation speed multiplier (>1 faster / <1 slower) |
| `scale` | 0.5 | per character | Sprite scale (1.0 = original 256 px) |
| `margin` | -50 | per character | Horizontal offset (positive = right) |
| `offsetY` | -30 | per character | Vertical offset (positive = up, 0 = flush bottom) |
| `maskStrength` | 0.0 | per character | Mask strength: multiplies the pet darker (0–1; 0 = original brightness, 1 = black) — raise it when a game filter overexposes the animation |
| `highlightStrength` | 0.0 | per character | Highlight strength: subtracts brightness linearly (0–1, higher = stronger); hits overexposed highlights hardest, stacks with mask strength |
| `opacity` | 1.0 | per character | Opacity of the pet (0–1; 1 = fully opaque); lower it to see the game behind |
| `main.entries` | main_static | shared factory | Full-health idle sprite pool (weighted random) |
| `main.sadStatic` | main_sad | shared factory | Half-health idle sprite |
| `wink.*` | — | per character | Blink toggle/animation/intervals (full: wink 3–5 s, half: wink1 3–7 s; each supports random / fixed mode) |
| `idle.*` | minMainTime=600 / 30% | per character (pool structure shared) | Idle pool and trigger chance (30% per second after 10 s in main) |
| `hurt.ignoreNoPenalties` | true | per character | Non-penalty damage (DAMAGE_NO_PENALTIES) does not trigger hurt |
| `hurt.monsterDamage` | true | per character | Monster attacks (body/tears/laser/bombs) also trigger hurt |
| `hurt.damageFlags` | 9 types | shared factory | Damage types that trigger hurt (DamageFlag bit flags) |
| `halfHealth` | — | per character | Half-health rule: threshold (≤1 half heart) / count soul hearts / special characters (Lost immune, Keeper at 1 full heart) |
| `itemQuality` | — | per character (animKeys shared) | Item-quality animation: enabled / mode (once/loop) / graceFrames / animKeys mapping |
| `events` | — | shared factory | Event → animation key mapping (fixed key or weighted variants) |
| `playback` | once | shared factory | Playback mode per state (once / loop) |
| `bossRoomTypes` | ROOM_BOSS/BOSSRUSH | shared factory | Room types counted as boss fights |
| `states` | — | per character | Per-state on/off switches |
| `toggleKey` | F3 | **[GLOBAL]** | Hotkey to toggle the whole overlay |

> Removed since v1.5: `hurt.duration` / `cardpillDuration` / `activeItemDuration`
> (event animations now play their full sequence with no fixed duration),
> `itemQuality.lock` (replaced by the animation priority), and `priority`
> (now a numeric in-code animation priority). Stale keys in old saves are
> dropped automatically.
| `topData` | false | **[GLOBAL]** | Debug text line in the top-left corner (room/coords/FPS) |

---

## In-Game Configuration (Mod Config Menu)

With [Mod Config Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=2686875783)
(or its Chinese localization) installed, open it in-game → "InternalReactionOverlay".
Every change is persisted into the save. Without MCM, edit
`internalreactionoverlay_config.lua` directly — same effect.

> Except "总开关 (Master)", the fallback toggle on "桌宠角色 (Character)" and
> "其它 (Other)", every page edits the **current character's own profile** (the
> active character is shown in the page title). After a switch, the pages show —
> and edit — the new character's values.

| MCM page | Settings | Scope |
|---|---|---|
| **总开关 (Master)** | Enable the whole overlay; toggle hotkey (F3 by default) | global |
| **桌宠角色 (Character)** | Active character (cycle through the pool, effective immediately, applies its own profile); fallback-to-other-characters toggle | switch = global; fallback = global |
| **状态开关 (State switches)** | Individual toggles: hurt / card & pill / active item / boss / item quality / half health / idle / blink | per character |
| **动画速度 (Speed)** | Speed multiplier (0.25–4); default animation fps | per character |
| **眨眼间隔 (Blink intervals)** | Full-health & half-health: mode (random/fixed), random min/max, fixed interval | per character |
| **待机 (Idle)** | Idle delay (1–120 s); trigger chance per second (0–100%) | per character |
| **受击 (Hurt)** | Monster attacks also trigger; ignore non-penalty damage | per character |
| **道具质量 (Item quality)** | Toggle; playback mode (once/loop); new-room detection grace | per character |
| **半血判定 (Half health)** | Threshold (half hearts); count soul/black hearts; Keeper threshold | per character |
| **外观位置 (Appearance)** | Scale / horizontal offset / vertical offset / mask strength / highlight strength / opacity (darkening & translucency, for overexposing filters) | per character |
| **其它 (Other)** | Top-left debug data toggle | global |

---

## Replacing Assets (gen_anim.py deployment script guide)

Animation frames live in `resources/gfx/pets/<Character>/` — one folder per animation
(one 256×256 PNG per frame), plus root single-frame PNGs (mapping table below).

### How to run

- **Requirements**: Python 3 (Pillow needed for auto-resize: `pip install pillow`;
  without it the script skips resizing with a warning and still rebuilds the manifest).
- Keep the script in the mod root (next to main.lua) and run from a terminal/PowerShell:
```
python gen_anim.py
```
  (quote the full path if it contains spaces, or PowerShell splits it and fails with
  "can't open file")
- **Run it from a terminal**, not by double-clicking — a double-clicked window closes
  instantly and you lose all output and errors.

### When to re-run

- After adding / deleting / renaming animation frames inside a character folder;
- After adding / deleting character folders;
- After replacing a whole set of assets.

### Animation folder → animation key mapping

| Character folder content | Animation key | Referenced from |
|---|---|---|
| `main.png` | main_static | `config.main.entries` (full-health idle sprite) |
| `main_sad.png` | main_sad | `config.main.sadStatic` (half-health idle sprite) |
| `death.png` | death_static | death sprite (optional; wire it up in events yourself) |
| `voice_training/` | activity | legacy folder-name alias for `activity/` |
| `activity/` `boss/` `hurt/` `half/` `Medicine/` `wink/` `wink1/` | same name | `config.events` |
| `idle1/` ~ `idle5/` | same name | `config.idle.entries` |
| `item0/` ~ `item4/` | same name | `config.itemQuality.animKeys` |

> A sub-folder's name is its animation key (ASCII letters/digits/underscores only;
> folders with unsafe names are skipped with a warning). Other root PNGs map as
> `<name>.png` → `<name>`.

### What the script does

- **Asset integrity check**: every character must have `main.png` (generates the
  `main_static` idle sprite). A missing one is a hard error (`[X]`, non-zero exit)
  with typo-suspect hints — e.g. `mian.png` is only 2 edits from the reserved name
  `main.png` (a misspelled filename yields an orphan key nobody references, leaving
  the pet's main state with nothing to draw). Also checks: root PNGs whose names are
  near a reserved name yet never referenced by the config, empty animation folders
  (`[!]`), and animation keys referenced by `internalreactionoverlay_config.lua`
  but missing for the character (`[i]`, lists which events won't trigger for that
  character; enable `petFallback` to borrow from others);
- Scans every character under `resources/gfx/pets/` (up to 5; folder names limited to
  ASCII letters/digits/underscores);
- **Auto-resizes** off-size frames to 256×256, overwriting in place (asks for
  confirmation interactively; auto-confirms in non-interactive runs; skipped with a
  warning if Pillow is not installed);
- Filters Discord duplicate downloads (filenames with a ` #number` suffix);
- Checks frame-number continuity (prints a `[!]` warning on gaps — the animation
  would skip a beat there);
- Rebuilds the multi-character manifest `internalreactionoverlay_frames.lua`.

### Reading the output

The script prints character discovery, resize/verification results and per-animation
frame counts, e.g.:
```
发现 2 个角色（上限 5）：Angle, TangTang
校验通过：全部 231 个动画帧均为 256×256，可直接进游戏使用。
internalreactionoverlay_frames.lua 已重建(角色池格式, 2 个角色):
  [Angle] 18 个动画 / 89 帧:
      Medicine      5 帧
      activity      5 帧
      ...
生成位置: <mod root>\internalreactionoverlay_frames.lua
```

### Parameters

> Default resize mode is `contain` (fit + transparent padding, no distortion/crop);
> use `--mode cover|stretch` to change, `--size 512` for another edge length,
> `--yes` to skip confirmation.
> To keep originals untouched, batch-resize with `resize_256.py` first
> (writes to `resized_256/`), then copy into the character folder.
>
> The legacy single-directory `overlay_anim/` has been migrated to the first pool
> character `pets/Angle/`; installs that still only have the legacy directory are
> handled by a fallback that emits the old single-character manifest.

---

## Missing Assets / Incomplete Characters → Graceful Degradation

- The active character lacks an animation key (e.g. `idle3/` deleted) → by default
  the event referencing it does **not trigger** (auto-disabled, error-free) and the
  pet keeps its idle/normal animation — no borrowing. With `petFallback` enabled,
  the same animation is borrowed from other characters in the pool instead:
  - a missing idle animation → removed from the idle pool
  - a missing half-health sprite → falls back to `main_static`
  - a missing item-quality animation → that quality tier stays silent, the rest work
- An invalid `activePet` (folder deleted/renamed) → falls back to the first pool character.
- More than 5 characters → `gen_anim.py` skips the extras with a warning.
- Asset-missing auto-disables are **temporary degradation**: they are never written
  into the character's profile, and automatically re-enable once the assets are
  back (or you switch to a character that has them).

---

## File Layout

```
internalreactionoverlay+/
├── main.lua                          # main logic (state machine + rendering + character pool + MCM + save)
├── internalreactionoverlay_config.lua# configuration file: factory defaults + global options (edit this)
├── internalreactionoverlay_profiles.lua # per-character settings (profile) module: capture/apply/sanitize
├── internalreactionoverlay_frames.lua# multi-character frame manifest (generated by gen_anim.py, do not hand-edit)
├── gen_anim.py                       # manifest rebuilder (multi-character + 256×256 auto-resize)
├── resize_256.py                     # batch-resize any assets to 256×256 (outputs to resized_256/, originals untouched)
├── metadata.xml                      # mod metadata
├── icon.png
├── README.md / README_en.md          # bilingual docs (incl. gen_anim.py deployment guide)
├── Angle.zip / TangTang.zip          # character asset archives (backup)
└── resources/gfx/
    ├── overlay_frame_template.anm2   # frame template (single 256×256 frame)
    └── pets/                         # ★ character asset pool (one folder per character, max 5)
        ├── Angle/                    #   character: Angle
        └── TangTang/                 #   character: TangTang
```

---

## FAQ

**Q: How do I switch the desktop-pet character?**
A: In-game MCM → "桌宠角色" page, cycle the selection (instant, persisted); or set
`activePet` in the config. The available characters are listed on the same page
(scanned from `resources/gfx/pets/` by `gen_anim.py`).

**Q: How do I add a new character?**
A: Create a folder under `resources/gfx/pets/` (ASCII name), add main.png /
main_sad.png and animation sub-folders (256×256 PNGs), run `python gen_anim.py`,
then pick the character in-game. Up to 5 characters.

**Q: Item-quality animations never play?**
A: Install [ReactionAPI](https://steamcommunity.com/sharedfiles/filedetails/?id=3096181411).
Without it the feature silently disables itself.

**Q: Animations play too fast/slow?**
A: Adjust the speed multiplier in MCM "动画速度" (>1 = faster); or edit
`config.animFps` (global) / `config.animHold` (per animation). Render frames per
animation frame = 60 / fps — larger is slower.

**Q: The pet is in the wrong spot?**
A: Adjust `config.margin` (horizontal) and `config.offsetY` (vertical); scale via
`config.scale` (all in the MCM "外观位置" page).

**Q: Want to hide the pet temporarily?**
A: Press `F3` in-game (`config.toggleKey`).

**Q: Hurt animation never plays?**
A: Make sure damage actually lands (invulnerability like flight/holy cloak doesn't
trigger); check MCM's hurt state switch. Environmental damage must match a type in
`config.hurt.damageFlags`; monster damage requires `config.hurt.monsterDamage` on
(monster contact damage carrying flags == 0 is normal, it goes through source
classification). Errors from other mods' `PreEntityTakeDamage` callbacks cannot
skip this mod thanks to the EARLY priority.

**Q: After switching characters some animation doesn't play?**
A: The active character is missing that asset. By default it is not borrowed — the
event doesn't trigger and the pet stays idle. To borrow it across characters,
enable "缺素材时借用其它角色" (`petFallback`) in MCM.

**Q: Do the characters' settings interfere with each other?**
A: No. Every character's animation/appearance settings are saved independently —
MCM edits only affect the current character, and switching applies that
character's own profile. Only the master toggle, hotkey and the borrow toggle
are global. Upgrading from an older version clones your previous settings to
every character, so behavior stays the same.

**Q: After replacing assets the pet doesn't show at all?**
A: Most likely the new assets are **not 256×256** (and inconsistent across frames) —
the Isaac engine can't render them. Run from the mod root (Pillow required):
```
pip install pillow
python gen_anim.py --yes --mode cover
```
`--yes` auto-resizes every frame to 256×256, overwriting in place (`cover` on
already-square art is a pure upscale, no crop). Then relaunch the game. If some
frames have opaque white backgrounds, that is an asset problem — replace them with
transparent-background PNGs.

---

## License

All artwork belongs to its original authors; for study and personal use only.
