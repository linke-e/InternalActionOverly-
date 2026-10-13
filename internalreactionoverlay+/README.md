# InternalReactionOverlay+ 内置反应桌宠+

在游戏**左下角**叠加一张 256×256 动画桌宠。触发游戏事件时播放对应的反应动画，
播放完毕回到主状态（常态贴图 + 随机眨眼）；main 状态静置时偶尔随机播放待机动画。

> 适用版本：以撒的结合：忏悔+ (The Binding of Isaac: Repentance+)
> 文档参考：[IsaacDocs (wofsauge)](https://wofsauge.github.io/IsaacDocs/rep/)

---

## 安装

1. 在创意工坊订阅
```
<以撒安装目录>/mods/
```
2. 若需「房间道具质量」动画（item0~item4），需**同时安装依赖**：
   [ReactionAPI](https://steamcommunity.com/sharedfiles/filedetails/?id=3096181411)
3. 启动游戏，Mod 自动加载；无 MCM 也能用，装 [Mod Config Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=2686875783) 可游戏内配置。

---

## 事件 → 动画对照

| 游戏事件 | 动画 | 目录 | 帧数 | 播放模式 |
|---|---|---|---|---|
| 常态（满血） | main_static | main.png | 1 | 常驻静态 |
| 常态（半血 ≤半颗心） | mian_sad¹ | mian_sad.png | 1 | 常驻静态 |
| 受击（环境伤害/怪物攻击） | hurt | hurt/ | 8 | 一次 |
| 使用卡牌 / 药丸 | Medicine | Medicine/ | 13 | 一次 |
| 使用主动/副主动道具 | activity | activity/ | 4 | 一次 |
| Boss 战（Boss 房未清空） | boss | boss/ | 3 | 一次 |
| 半血（总血量 ≤ 半颗心） | half | half/ | 14 | 一次 |
| 房间存在未拾取道具 | item0~item4 | item0/ ~ item4/ | 各 5~14 | 一次 |
| 待机随机 | idle1~idle5 | idle1/ ~ idle5/ | 各 2~12 | 一次 |
| 眨眼（满血） | wink | wink/ | 2 | 循环 |
| 眨眼（半血） | wink1 | wink1/ | 2 | 循环 |

> ¹ 半血常态贴图素材键为 `mian_sad`（文件名即如此拼写）；但 `config.main.sadStatic`
> 默认填的是 `main_sad`，两者不一致导致当前**不生效**，把配置改成 `mian_sad` 即可启用
> （详见「配置」）。
> `idle5` 素材（2 帧）已收录，但默认待机池只启用 idle1~idle4；想启用请在
> `config.idle.entries` 里加 `{ key = "idle5", weight = 2 }`。`hurt` 帧数为
> `internalreactionoverlay_frames.lua` 实际收录值（Discord 重复帧已过滤）。

### 受击动画

角色受到以下伤害时播放一次 `hurt` 动画（`hurt/` 目录，8 帧）：

**环境伤害**（按伤害类型匹配）：

火焰（DAMAGE_FIRE）、爆炸（DAMAGE_EXPLOSION）、激光（DAMAGE_LASER）、
酸液（DAMAGE_ACID）、尖刺（DAMAGE_SPIKES）、红屎（DAMAGE_POOP）、
TNT（DAMAGE_TNT）、中毒/燃烧（DAMAGE_POISON_BURN）、塌陷坑洞（DAMAGE_PITFALL）。

**怪物攻击**（按伤害来源匹配，开关 `config.hurt.monsterDamage`，默认开启）：

怪物本体接触/爪击/自爆、敌方弹幕（泪弹）、敌方激光/子弹、怪物炸弹爆炸。

判定决策树（`mod:IsMonsterDamage`）：
1. **flags 兜底**：伤害带以下任一标志 → 强制判定"非怪物伤害"：
   FIRE / SPIKES / ACID / POISON_BURN / DEVIL / IV_BAG / PITFALL / CHEST /
   CURSED_DOOR / TIMER / TNT / POOP / RED_HEARTS / COUNTDOWN / CLONES / ISSAC_HEART
   （注意：EXPLOSION / LASER **不是**怪物的充分条件——玩家自己的炸弹/科技激光
   也带这些标志，必须回到第 2 步看来源）
2. **按来源（source）分类**：
   - `source.Entity == nil`（尖刺/火/诅咒等环境）→ 非怪物
   - `source.Entity:IsEnemy()`（怪物本体接触/爪击/自爆）→ 怪物
   - `source.Type ∈ {ENTITY_TEAR, ENTITY_LASER, ENTITY_PROJECTILE}` 且非友方 → 怪物
   - `source.Type == ENTITY_BOMB` → 查 `SpawnerType`：玩家放的 → 非怪物，否则怪物
   - 玩家 / 友方单位（献血机/剃刀/血袋）→ 非怪物
   - `ENTITY_EFFECT`（creep/火/红便便）→ 非怪物

> 怪物本体接触/爪击伤害的 `damageFlags` 通常为 0（无特殊标志），这是正常的——
> 判定会走上面的来源分类路径，不会被提前过滤。

- 伤害类型列表在 `config.hurt.damageFlags`，可自行增删（参考
  [DamageFlag 枚举](https://cuerzor.github.io/IsaacDocs/rep/enums/DamageFlag.html)）。
- 带 `DAMAGE_NO_PENALTIES` 的**非惩罚性伤害**（不扣恶魔房概率等惩罚）不触发受击
  （开关：`config.hurt.ignoreNoPenalties`，默认开启）。
- 状态持续时长由 `config.hurt.duration`（默认 90 渲染帧 ≈1.5 秒）控制。
- 受击优先级**最高**，任何事件动画都会被受击打断；每次受伤都会重新触发。
- 受击判定使用 `MC_ENTITY_TAKE_DMG`（仅玩家）+ `CallbackPriority.EARLY`，
  保证即使其它 mod 的伤害回调报错也不会被跳过。

### 主动/副主动道具使用

角色**使用主动道具**（主槽或副槽）时播放一次 `activity` 动画（`activity/` 目录，4 帧）。

- 通过 `MC_USE_ITEM` 回调检测，仅在主动道具**真正使用**时触发，覆盖所有槽位
  （主槽 `SLOT_PRIMARY` / 副槽 `SLOT_POCKET` 等）。
- 药丸走 `MC_USE_PILL`、卡牌走 `MC_USE_CARD`，**不会**误触发本动画。
- 状态持续时长由 `config.activeItemDuration`（默认 90 渲染帧 ≈1.5 秒）控制。
- 开关：`config.states.active`（默认开启）。

### 房间道具质量（依赖 ReactionAPI）

当前房间存在未拾取道具时，按其**最高质量**播放对应动画：
Quality 0→item0、1→item1、2→item2、3→item3、4→item4。

**高等级优先**：房间同时出现 2 级与 4 级道具时只播放 item4。
道具被拾取 / 房间变化后自动重新检测；进新房重置。

**播放不打断**：item 动画一旦开始播放会一直播完为止，不会被受击/卡牌等
更高优先级事件打断（这些事件顺延到动画结束后再响应）。开关：`itemQuality.lock`。

> 未安装 ReactionAPI 时该功能自动失效，不影响其它功能。

---

## 播放规则

- **事件动画**（受击、卡牌/药丸、主动/副主动道具、Boss 战、半血、道具质量）：播放一次后回到 main。
- **道具动画不打断**：item 动画播放期间锁定直到播完（`itemQuality.lock = true`），
  受击/卡牌等更高优先级事件顺延到动画结束后再响应。
- **持续条件**（Boss 战、半血、道具质量）：动画播完一次后会被"抑制"，直到条件消失
  （离开 Boss 房 / 回血 / 道具被拾取）才允许再次触发，避免反复重播。
- **眨眼**：main 状态下循环，眨眼播完随机等待后眨下一次。
  - 满血：wink，间隔 **3~5 秒**
  - 半血：wink1，间隔 **3~7 秒**
  - 眨眼优先级最低，任何事件动画都会打断它。
- **优先级**（高→低）：
```
hurt > cardpill > active > boss > item > half > idle > wink > main
```

---

## 配置（internalreactionoverlay_config.lua）

所有可调参数集中在 `internalreactionoverlay_config.lua`，无需改动 main.lua。

| 配置项 | 默认 | 说明 |
|---|---|---|
| `animFps` | 15 | 全局动画帧率（渲染帧/秒，60fps 基准） |
| `animHold` | 见文件 | 按动画键单独设置每帧停留帧数（60 帧≈1s） |
| `scale` | 0.5 | 图片缩放倍数（1.0=原始 256px） |
| `margin` | -50 | 水平偏移（正=右移，负=左移） |
| `offsetY` | -15 | 垂直偏移（正=上移，负=下移，0=贴底） |
| `main.entries` | main_static | 满血常态贴图（可加权重随机） |
| `main.sadStatic` | main_sad | 半血常态贴图（⚠️ 素材键实为 `mian_sad`，需改成 `mian_sad` 才生效） |
| `wink.*` | — | 眨眼动画与间隔（满血 wink/3~5s，半血 wink1/3~7s；每档可选 random / fixed 模式） |
| `idle.*` | minMainTime=600 / 30% | 待机动画池与触发概率（连续 main 满 10 秒后，每秒 30% 概率触发） |
| `hurt.duration` | 90 | 受击动画状态持续时长（渲染帧） |
| `hurt.ignoreNoPenalties` | true | 非惩罚性伤害（DAMAGE_NO_PENALTIES）不触发受击 |
| `hurt.monsterDamage` | true | 怪物攻击伤害（本体/弹幕/激光/怪物炸弹）也触发受击 |
| `hurt.damageFlags` | 9 种 | 触发受击动画的伤害类型列表（DamageFlag 位标志） |
| `cardpillDuration` | 90 | 卡牌/药丸动画状态持续时长（渲染帧） |
| `activeItemDuration` | 90 | 主动/副主动道具使用状态持续时长（渲染帧） |
| `halfHealth` | — | 半血判定：阈值（≤1 半心）/ 是否计灵魂心 / 特殊角色（游魂不触发、店主 1 整心） |
| `events` | — | 事件 → 动画键映射（可改动画或加变体权重） |
| `playback` | once | 各状态播放模式（once / loop） |
| `bossRoomTypes` | ROOM_BOSS/BOSSRUSH | Boss 战判定房间类型 |
| `itemQuality` | — | 道具质量动画：enabled / mode / lock 播放期间不打断 / graceFrames 进新房检测冷却 / animKeys Quality→动画键映射 |
| `states` | — | 每个状态的独立开关 |
| `priority` | — | 状态优先级顺序 |
| `toggleKey` | F3 | 游戏内一键启停叠加层 |
| `topData` | false | 左上角调试数据行（房间/坐标/FPS） |

---

## 游戏内配置（Mod Config Menu）

安装 [Mod Config Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=2686875783) 后，
游戏内菜单中可直接调整（修改会自动存入存档，下次启动沿用；不装 MCM 时直接改
`internalreactionoverlay_config.lua` 同样生效）：

- **总开关**：启用整个叠加层；切换快捷键（默认 F3）
- **状态开关**：受击 / 卡牌药丸 / 主动道具 / Boss / 道具质量 / 半血 / 待机 的独立开关
- **受击**：怪物攻击是否也触发受击
- **道具质量**：房间道具质量动画开关；「播放期间不被打断」开关
- **外观位置**：缩放倍数 / 水平偏移 / 上下偏移
- **其它**：全局动画帧率 / 左上角调试数据

---

## 素材替换

动画帧在 `resources/gfx/overlay_anim/` 下，每个动画一个文件夹（每帧一张 256×256 PNG），
或根目录单张 PNG（`main.png`、`mian_sad.png`）。

**新增 / 替换 / 删除素材后**，在 mod 根目录运行（目录名含空格，路径必须加引号）：

```
python "~\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\InternalReactionOverlay+\gen_anim.py"
```

脚本会：
- **自动缩放**：检测到非 256×256 的动画帧时，提示确认后缩放为 256×256 并【覆盖原文件】
  （回答 `y` 才转换，`n`/回车则跳过不动；Pillow 未安装时自动跳过缩放并警告）。
- 自动过滤 Discord 下载产生的重复帧（文件名带 ` #数字` 后缀，如 `xxx_000 #50548.png`）。
- 重新生成 `internalreactionoverlay_frames.lua` 帧清单（自动收录目录与单帧 PNG）。

> 缩放方式默认 `contain`（等比缩放 + 透明边，不变形不裁切）；可用
> `--mode cover|stretch` 切换，如 `python gen_anim.py --mode cover`；
> `--size 512` 可改目标边长，`--yes` 可跳过确认直接转换。
> 不想覆盖原图时，先用 `resize_256.py` 批量把素材统一缩放成 256×256
> （输出到 `resized_256/` 子目录，原图不动），再拷进 `overlay_anim/` 使用。

> 文件夹名即动画键（`activity`→activity、`boss`→boss…）；
> 根 PNG 映射：`main.png`→main_static、`death.png`→death_static，其余 `<name>.png`→<name>
> （如当前半血贴图 `mian_sad.png`→`mian_sad`）。
> `voice_training` 目录会映射为 activity 键（保留兼容）。

---

## 素材变少 → 缺失键自动禁用

替换素材后若某动画键不存在（例如删掉了 `idle3/`、没有 `mian_sad.png`），
`main.lua` 会**自动禁用**引用它的功能，不报错、不影响其它功能：

- 没有某待机动画 → 待机池自动去掉该键
- 没有半血常态贴图（默认键 `main_sad`，素材实为 `mian_sad`）→ 回退成 `main_static`
- 某道具质量等级没有素材 → 该等级不播动画，其余照常

所以替换成「比配置里少的动画」也完全能正常跑。

---

## 文件结构

```
internalreactionoverlay+ 内置反应桌宠+/
├── main.lua                          # 主逻辑（状态机 + 渲染 + MCM + 存档）
├── internalreactionoverlay_config.lua# 配置文件（改这里）
├── internalreactionoverlay_frames.lua# 帧清单（gen_anim.py 生成，勿手改）
├── gen_anim.py                       # 素材清单重建脚本（含 256×256 自动缩放）
├── resize_256.py                     # 批量把任意素材缩放为 256×256（输出到 resized_256/，原图不动）
├── metadata.xml                      # 模组元数据
├── icon.png
├── Angle.zip / TangTang.zip          # 备用动画素材压缩包
├── 一键部署工具使用.txt               # 素材脚本使用说明
└── resources/gfx/
    ├── overlay_frame_template.anm2   # 帧模板（256×256 单帧）
    └── overlay_anim/                 # 动画素材（每动画一文件夹 / 根单帧 PNG）
        ├── main.png  mian_sad.png    # 根单帧静态（满血 / 半血）
        ├── idle1/ ~ idle5/
        ├── item0/ ~ item4/
        ├── wink/  wink1/
        ├── hurt/
        └── Medicine/
```

---

## 常见问题

**Q：道具质量动画不生效？**
A：需要安装 [ReactionAPI](https://steamcommunity.com/sharedfiles/filedetails/?id=3096181411) 依赖。
未安装时该功能自动跳过（控制台无报错）。

**Q：动画播放太快/太慢？**
A：改 `config.animFps`（全局）或 `config.animHold`（按动画），
每帧停留帧数 = 60 / fps，数字越大越慢。

**Q：桌宠位置不对？**
A：调 `config.margin`（左右）与 `config.offsetY`（上下）；缩放用 `config.scale`。

**Q：想临时隐藏桌宠？**
A：游戏中按 `F3`（`config.toggleKey`）一键启停。

**Q：受击动画不播放？**
A：确认受伤时真的掉血（飞行、圣斗篷等免疫状态下不会触发）；检查 MCM「状态开关-受击动画」
是否开启。环境伤害需 `config.hurt.damageFlags` 包含对应类型；怪物伤害需
`config.hurt.monsterDamage` 开启（怪物接触伤害 flags 为 0 属正常，走来源判定）。
若日志中有其它 mod 的 `PreEntityTakeDamage` 报错，本 mod 已通过 EARLY 优先级保证不受影响。

**Q：idle5 待机动画怎么不播放？**
A：idle5 素材（2 帧）已收录，但默认待机池只启用 idle1~idle4。想启用就在
`config.idle.entries` 里添加 `{ key = "idle5", weight = 2 }`。

**Q：替换素材后游戏里完全不显示桌宠？**
A：最常见原因是新素材**不是 256×256**（且各帧尺寸不一致），Isaac 引擎无法正常渲染，
左下方什么都看不到。先在 mod 根目录执行（需要 Pillow）：
```
pip install pillow
python gen_anim.py --yes --mode cover
```
`--yes` 会自动把所有帧统一缩放为 256×256 并覆盖原文件（正方形素材用 `cover` 是纯放大不裁切），
完成后重新进游戏即可。若个别帧是白底不透明，属于素材本身问题，换成透明背景的图再替换。

---

## 许可证

素材版权归原作者所有，仅作学习交流使用。
