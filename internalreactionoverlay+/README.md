# InternalReactionOverlay+ 内置反应桌宠+

[English](README_en.md) | 中文

在游戏**左下角**叠加一张 256×256 动画桌宠。触发游戏事件时播放对应的反应动画，
播放完毕回到主状态（常态贴图 + 随机眨眼）；main 状态静置时偶尔随机播放待机动画。

> 适用版本：以撒的结合：忏悔+ (The Binding of Isaac: Repentance+)
> 文档参考：[IsaacDocs (wofsauge)](https://wofsauge.github.io/IsaacDocs/rep/)

---

## 安装

1. 在创意工坊订阅
```
https://steamcommunity.com/sharedfiles/filedetails/?id=3786174946
```
2. 若需「房间道具质量」动画（item0~item4），需**同时安装依赖**：
   [ReactionAPI](https://steamcommunity.com/sharedfiles/filedetails/?id=3096181411)
3. 启动游戏，Mod 自动加载；无 MCM 也能用，装 [Mod Config Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=2686875783)（或中文版）可游戏内配置。

---

## 桌宠角色素材池

所有角色放在 `resources/gfx/pets/` 下，**一个角色一个文件夹**（最多 5 个）：

```
resources/gfx/pets/
├── Angle/                       # 角色一（文件夹名即角色名）
│   ├── main.png  main_sad.png   # 常态/半血静态单帧
│   ├── Medicine/  activity/  boss/  half/  hurt/
│   ├── idle1/ ~ idle4/          # 待机动画
│   ├── item0/ ~ item4/          # 道具质量动画
│   └── wink/  wink1/            # 眨眼动画（满血/半血）
└── TangTang/                    # 角色二（多一个 idle5/）
```

内置两个角色：**Angle**（超天酱）与 **TangTang**（糖糖），均为 256×256 透明底 PNG。

**切换角色**（三选一，修改都会存入存档）：
- 游戏内 MCM →「桌宠角色」页左右切换；
- 改 `internalreactionoverlay_config.lua` 的 `activePet = "角色名"`；
- 切换立即生效，无需重启游戏。

**新增角色**：
1. 在 `resources/gfx/pets/` 下新建文件夹（角色名建议只用英文字母/数字/下划线——以撒资源路径对中文/空格支持差）；
2. 放入 `main.png`、`main_sad.png` 与各动画子文件夹（帧为 256×256 PNG，非 256 的帧脚本会自动缩放）；
3. 在 mod 根目录运行 `python gen_anim.py` 重建帧清单；
4. 游戏内 MCM「桌宠角色」页即可选到新角色。

> 角色素材不全也能跑：默认情况下（`petFallback = false`）当前角色缺少的动画对应
> 的**事件不触发，桌宠保持待机/常态动画**，不借用其它角色的素材；想跨角色借用，
> 在 MCM「桌宠角色」页打开「缺素材时借用其它角色」（或改 `petFallback = true`）。

---

## 事件 → 动画对照

| 游戏事件 | 动画键 | 角色文件夹 | 播放模式 |
|---|---|---|---|
| 常态（满血） | main_static | main.png | 常驻静态 |
| 常态（半血 ≤半颗心） | main_sad | main_sad.png | 常驻静态 |
| 受击（环境伤害/怪物攻击） | hurt | hurt/ | 一次 |
| 使用卡牌 / 药丸 | Medicine | Medicine/ | 一次 |
| 使用主动/副主动道具 | activity | activity/ | 一次 |
| Boss 战（Boss 房未清空） | boss | boss/ | 一次 |
| 半血（总血量 ≤ 半颗心） | half | half/ | 一次 |
| 房间存在未拾取道具 | item0~item4 | item0/ ~ item4/ | 一次或循环 |
| 待机随机 | idle1~idle4* | idle1/ ~ idle4/ | 一次 |
| 眨眼（满血） | wink | wink/ | 循环 |
| 眨眼（半血） | wink1 | wink1/ | 循环 |

> \* 帧数因角色而异（如 Angle 的 hurt 3 帧、TangTang 的 hurt 8 帧；详见
> `internalreactionoverlay_frames.lua`）。TangTang 收录了 idle5 素材，默认待机池只启用
> idle1~idle4；想启用请在 `config.idle.entries` 里加 `{ key = "idle5", weight = 2 }`。

### 受击动画

角色受到以下伤害时播放一次 `hurt` 动画：

**环境伤害**（按伤害类型匹配，`config.hurt.damageFlags`）：

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

- 带 `DAMAGE_NO_PENALTIES` 的**非惩罚性伤害**（不扣恶魔房概率等惩罚）不触发受击
  （开关：`config.hurt.ignoreNoPenalties`，默认开启）。
- 状态持续时长由 `config.hurt.duration`（默认 90 渲染帧 ≈1.5 秒）控制。
- 受击优先级**最高**，任何事件动画都会被受击打断；每次受伤都会重新触发。
- 受击判定使用 `MC_ENTITY_TAKE_DMG`（仅玩家）+ `CallbackPriority.EARLY`，
  保证即使其它 mod 的伤害回调报错也不会被跳过。

### 主动/副主动道具使用

角色**使用主动道具**（主槽或副槽）时播放一次 `activity` 动画。

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

**播放模式**（`config.itemQuality.mode`）：
- `once`：检测到质量变化时播一遍回 main（默认）；
- `loop`：房间存在道具期间持续循环展示，质量变化时切换到新质量的动画。

**播放不打断**（仅 once 模式，`itemQuality.lock`）：item 动画一旦开始播放会一直
播完为止，不会被受击/卡牌等更高优先级事件打断（这些事件顺延到动画结束后再响应）。

> 未安装 ReactionAPI 时该功能自动失效，不影响其它功能。

---

## 播放规则

- **事件动画**（受击、卡牌/药丸、主动/副主动道具、Boss 战、半血、道具质量）：播放一次后回到 main。
- **道具动画不打断**：once 模式下 item 动画播放期间锁定直到播完（`itemQuality.lock = true`），
  受击/卡牌等更高优先级事件顺延到动画结束后再响应。
- **持续条件**（Boss 战、半血、道具质量）：动画播完一次后会被"抑制"，直到条件消失
  （离开 Boss 房 / 回血 / 道具被拾取）才允许再次触发，避免反复重播。
- **眨眼**：main 状态下循环，眨眼播完随机等待后眨下一次。
  - 满血：wink，间隔 **3~5 秒**；半血：wink1，间隔 **3~7 秒**（均可在 MCM 调整）。
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
| `activePet` | "Angle" | 当前桌宠角色（素材池文件夹名；MCM 可切换并存档） |
| `petFallback` | false | 是否借用其它角色的同名动画补缺；默认关闭（缺动画的事件不触发，保持待机） |
| `animFps` | 15 | 默认动画帧率（渲染帧/秒，60fps 基准） |
| `animHold` | 见文件 | 按动画键单独设置每帧停留帧数（60 帧≈1s） |
| `animSpeed` | 1.0 | 全局动画速度倍率（>1 加速 / <1 减速） |
| `scale` | 0.5 | 图片缩放倍数（1.0=原始 256px） |
| `margin` | -50 | 水平偏移（正=右移，负=左移） |
| `offsetY` | -30 | 垂直偏移（正=上移，负=下移，0=贴底） |
| `main.entries` | main_static | 满血常态贴图（可加权重随机） |
| `main.sadStatic` | main_sad | 半血常态贴图 |
| `wink.*` | — | 眨眼开关/动画/间隔（满血 wink/3~5s，半血 wink1/3~7s；每档可选 random / fixed 模式） |
| `idle.*` | minMainTime=600 / 30% | 待机动画池与触发概率（连续 main 满 10 秒后，每秒 30% 概率触发） |
| `hurt.duration` | 90 | 受击动画状态持续时长（渲染帧） |
| `hurt.ignoreNoPenalties` | true | 非惩罚性伤害（DAMAGE_NO_PENALTIES）不触发受击 |
| `hurt.monsterDamage` | true | 怪物攻击伤害（本体/弹幕/激光/怪物炸弹）也触发受击 |
| `hurt.damageFlags` | 9 种 | 触发受击动画的伤害类型列表（DamageFlag 位标志） |
| `cardpillDuration` | 90 | 卡牌/药丸动画状态持续时长（渲染帧） |
| `activeItemDuration` | 90 | 主动/副主动道具使用状态持续时长（渲染帧） |
| `halfHealth` | — | 半血判定：阈值（≤1 半心）/ 是否计灵魂心 / 特殊角色（游魂不触发、店主 1 整心） |
| `itemQuality` | — | 道具质量动画：enabled / mode(once/loop) / lock 播放期间不打断 / graceFrames 进新房检测冷却 / animKeys 映射 |
| `events` | — | 事件 → 动画键映射（可改动画或加变体权重） |
| `playback` | once | 各状态播放模式（once / loop） |
| `bossRoomTypes` | ROOM_BOSS/BOSSRUSH | Boss 战判定房间类型 |
| `states` | — | 每个状态的独立开关 |
| `priority` | — | 状态优先级顺序 |
| `toggleKey` | F3 | 游戏内一键启停叠加层 |
| `topData` | false | 左上角调试数据行（房间/坐标/FPS） |

---

## 游戏内配置（Mod Config Menu）

安装 [Mod Config Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=2686875783)
（或其汉化版）后，游戏内「Mod Config Menu」→「InternalReactionOverlay」可直接调整
（修改自动存入存档，下次启动沿用；不装 MCM 时直接改
`internalreactionoverlay_config.lua` 同样生效）：

| MCM 子页面 | 可调项 |
|---|---|
| **总开关** | 启用整个叠加层；切换快捷键（默认 F3） |
| **桌宠角色** | 当前角色（左右循环切换素材池，立即生效）；缺素材时是否借用其它角色 |
| **状态开关** | 受击 / 卡牌药丸 / 主动道具 / Boss / 道具质量 / 半血 / 待机 / 眨眼 的独立开关 |
| **动画速度** | 全局速度倍率（0.25~4）；默认动画帧率 |
| **眨眼间隔** | 满血/半血两档：间隔模式（随机/固定）、随机间隔上下限、固定间隔 |
| **待机** | 静置多久后开始待机（1~120 秒）；每秒触发概率（0~100%） |
| **事件时长** | 受击 / 卡牌药丸 / 主动道具 动画持续时长（0.5~10 秒） |
| **受击** | 怪物攻击也触发；忽略非惩罚性伤害 |
| **道具质量** | 开关；播放模式（播一遍/持续循环）；播放期间不被打断；进新房检测冷却 |
| **半血判定** | 普通角色阈值（半心数）；灵魂心/黑心是否计入；店主类角色阈值 |
| **外观位置** | 缩放倍数 / 水平偏移 / 上下偏移 |
| **其它** | 左上角调试数据开关 |

---

## 素材替换（gen_anim.py 部署脚本使用说明）

动画帧在 `resources/gfx/pets/<角色名>/` 下，每个动画一个文件夹（每帧一张 256×256 PNG），
或根目录单张 PNG（根 PNG 映射见下方对照表）。

### 运行方式

- **运行环境**：Python 3（缩放功能需 Pillow：`pip install pillow`；未安装时自动跳过
  缩放并警告，帧清单照常生成）。
- 脚本放在 mod 根目录（与 main.lua 同级），在该目录开终端/PowerShell 执行：
```
python gen_anim.py
```
  （路径含空格时完整路径必须加引号，否则 PowerShell 会把路径拆开报 can't open file）
- **推荐在终端里运行**，能看到输出与报错；直接双击脚本会一闪而过，看不到结果。

### 何时需要重新运行

- 往角色文件夹里新增 / 删除 / 改名动画帧后；
- 新增 / 删除角色文件夹后；
- 更换整套动画素材后。

### 动画文件夹 → 动画键对照

| 角色文件夹内容 | 动画键 | 在 config 中的引用处 |
|---|---|---|
| `main.png` | main_static | `config.main.entries`（满血常态贴图） |
| `main_sad.png` | main_sad | `config.main.sadStatic`（半血常态贴图） |
| `death.png` | death_static | 死亡静态（可选，需自行在 events 引用） |
| `voice_training/` | activity | 旧目录名兼容，等价 `activity/` |
| `activity/` `boss/` `hurt/` `half/` `Medicine/` `wink/` `wink1/` | 同名键 | `config.events` |
| `idle1/` ~ `idle5/` | 同名键 | `config.idle.entries` |
| `item0/` ~ `item4/` | 同名键 | `config.itemQuality.animKeys` |

> 子文件夹名即动画键（限英文字母/数字/下划线，含非法字符的文件夹会被跳过并警告）；
> 其余根 PNG 按 `<name>.png` → `<name>` 映射。

### 脚本行为

- 扫描 `resources/gfx/pets/` 下全部角色（最多 5 个，角色文件夹名限英文字母/数字/下划线）；
- **自动缩放**：检测到非 256×256 的动画帧时，提示确认后缩放为 256×256 并【覆盖原文件】
  （回答 `y` 才转换，`n`/回车则跳过不动；Pillow 未安装时自动跳过缩放并警告）；
- 自动过滤 Discord 下载产生的重复帧（文件名带 ` #数字` 后缀，如 `xxx_000 #50548.png`）；
- 检查帧序号连续性（缺号时打印 `[!]` 警告，动画在该处会跳帧）；
- 重新生成 `internalreactionoverlay_frames.lua` 多角色帧清单。

### 输出怎么看

脚本会打印角色发现、缩放/校验结果与每个动画的帧数，例如：
```
发现 2 个角色（上限 5）：Angle, TangTang
校验通过：全部 231 个动画帧均为 256×256，可直接进游戏使用。
internalreactionoverlay_frames.lua 已重建(角色池格式, 2 个角色):
  [Angle] 18 个动画 / 89 帧:
      Medicine      5 帧
      activity      5 帧
      ...
生成位置: <mod根目录>\internalreactionoverlay_frames.lua
```

### 参数

> 缩放方式默认 `contain`（等比缩放 + 透明边，不变形不裁切）；可用
> `--mode cover|stretch` 切换，如 `python gen_anim.py --mode cover`；
> `--size 512` 可改目标边长，`--yes` 可跳过确认直接转换。
> 不想覆盖原图时，先用 `resize_256.py` 批量把素材统一缩放成 256×256
> （输出到 `resized_256/` 子目录，原图不动），再拷进角色文件夹使用。
>
> 旧版单目录 `overlay_anim/` 已迁移为素材池的第一个角色 `pets/Angle/`；
> 若你的安装里只有旧目录，脚本会按旧格式自动回退生成单角色清单。

---

## 素材变少 / 角色素材不全 → 自动降级

- **素材缺失自动降级**（不借用）：缺失动画对应的事件不触发，桌宠保持待机/常态动画：
  - 没有某事件动画 → 该事件不再触发（自动禁用并记录，换到素材齐全的角色时自动恢复开启）
  - 没有某待机动画 → 待机池自动去掉该键
  - 没有半血常态贴图 → 回退成 `main_static`
  - 某道具质量等级没有素材 → 该等级不播动画，其余照常
- 开启 `petFallback`（MCM「缺素材时借用其它角色」）后：缺失动画自动借用素材池中
  其它角色的同名动画，行为同上但以借用素材播放。
- 当前角色名失效（文件夹被删/改名）→ 自动回退素材池第一个角色。
- 角色数量超过 5 个 → `gen_anim.py` 跳过多余角色并警告。

---

## 文件结构

```
internalreactionoverlay+/
├── main.lua                          # 主逻辑（状态机 + 渲染 + 角色池 + MCM + 存档）
├── internalreactionoverlay_config.lua# 配置文件（改这里）
├── internalreactionoverlay_frames.lua# 多角色帧清单（gen_anim.py 生成，勿手改）
├── gen_anim.py                       # 素材清单重建脚本（多角色 + 256×256 自动缩放）
├── resize_256.py                     # 批量把任意素材缩放为 256×256（输出到 resized_256/，原图不动）
├── metadata.xml                      # 模组元数据
├── icon.png
├── README.md / README_en.md          # 双语文档（含 gen_anim.py 部署脚本使用说明）
├── Angle.zip / TangTang.zip          # 角色素材压缩包备份
└── resources/gfx/
    ├── overlay_frame_template.anm2   # 帧模板（256×256 单帧）
    └── pets/                         # ★ 桌宠角色素材池（一角色一文件夹，最多 5 个）
        ├── Angle/                    #   角色：超天酱
        └── TangTang/                 #   角色：糖糖
```

---

## 常见问题

**Q：怎么切换桌宠角色？**
A：游戏内 MCM「桌宠角色」页左右切换（立即生效并存档）；或改配置 `activePet`。
可用角色列表显示在同一页（由 `gen_anim.py` 扫描 `resources/gfx/pets/` 生成）。

**Q：怎么添加新角色？**
A：在 `resources/gfx/pets/` 新建角色文件夹（英文名），放入 main.png / main_sad.png
与动画子文件夹（256×256 PNG），运行 `python gen_anim.py`，游戏内即可切换。最多 5 个。

**Q：道具质量动画不生效？**
A：需要安装 [ReactionAPI](https://steamcommunity.com/sharedfiles/filedetails/?id=3096181411) 依赖。
未安装时该功能自动跳过（控制台无报错）。

**Q：动画播放太快/太慢？**
A：MCM「动画速度」页调速度倍率（>1 加速）；或改 `config.animFps`（全局）、
`config.animHold`（按动画），每帧停留帧数 = 60 / fps，数字越大越慢。

**Q：桌宠位置不对？**
A：调 `config.margin`（左右）与 `config.offsetY`（上下）；缩放用 `config.scale`（均在 MCM「外观位置」页）。

**Q：想临时隐藏桌宠？**
A：游戏中按 `F3`（`config.toggleKey`）一键启停。

**Q：受击动画不播放？**
A：确认受伤时真的掉血（飞行、圣斗篷等免疫状态下不会触发）；检查 MCM「状态开关-受击动画」
是否开启。环境伤害需 `config.hurt.damageFlags` 包含对应类型；怪物伤害需
`config.hurt.monsterDamage` 开启（怪物接触伤害 flags 为 0 属正常，走来源判定）。
若日志中有其它 mod 的 `PreEntityTakeDamage` 报错，本 mod 已通过 EARLY 优先级保证不受影响。

**Q：切角色后某个动画不播放？**
A：当前角色缺该素材，默认不借用他人素材——对应事件不触发，桌宠保持待机动画。
想让该动画跨角色借用，打开 MCM「桌宠角色-缺素材时借用其它角色」（`petFallback`）即可。

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
