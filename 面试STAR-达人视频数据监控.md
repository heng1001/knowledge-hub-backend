# 面试 STAR：达人视频数据监控（第 7 个亮点）

> 定位：这是你 **米播 ERP「达人投放/接单」** 里最能体现「**对时序数据的建模 + 商业闭环理解 + 行业反爬/口径认知**」的一个点——**交付后、单条作品粒度的自动数据回收**。
> 与既有亮点**不重复**：第 6 个亮点（多平台异构）是**选号前**把 4/5 平台达人数据静态归一；ClickHouse 大屏（后端亮点三）是**管理层**看宏观漏斗/收入；本亮点是**媒介/运营在「数据监控→结算」阶段盯单条视频**（播放/互动/投流消耗）的表现，决定**是否达标、是否追投、能否完结**。
> ⚠️ 纪律同全库：以下真实事实来自 mibo（`/Users/mixianyun/dev/BE/mibo`）+ new-oa（`/Users/mixianyun/Desktop/FE/new-oa`）代码勘察，标 **数据量未核实** 处为推断，别在面试里编数字。**每句能溯源到类名/表名/常量/行号**；行号以你面试前重读的最新代码为准。

---

## 〇、一句话版（背这句）

> 「达人拍完商单视频、客户确认发布后，系统要**自动盯这条视频的数据表现**：播放、点赞、收藏、评论、分享，还有投流的消耗和转化成本。难点是——**平台官方数据是闭环的、不给你随便拉**，而且单条视频的数据是『活的』，会涨会修正、还可能被达人删掉。我们的做法是把一条视频建模成**按天/按周的时间序列快照**：发布后 T+1~T+7 每天采一次，之后每周采一次采到第 4 周就**封存**——用封存时的数据当作结算口径，不再动它。这套快照既支撑媒介在页面上逐日回看趋势、判断这条视频值不值得追投，也在后端驱动了一条业务闭环：抓到平台发布时间 → 财务把这条视频置为『可付款』→ 数据齐全 + 财务到账 → 达人才能完结进结算。数据源全部来自**官方/商业口径的采集网关，不是第三方估算**。」

---

## 一、先说清楚它长在哪（别讲错层）

它在达人投放漏斗里的位置（前后端一致，可溯源）：
- 状态机 `ErpTalentProgressEnum`：`… 190 客户确认脚本(CUSTOMER_CONFIRM_SCRIPT) → 200 数据监控(DATA_MONITORING) → 210 已完成(COMPLETED)`。190→200 收量项目下单审批通过直接跳 200，普通项目须先 190。
- 前端漏斗第 6 段「数据」：`talentform/index.tsx` 步骤定义 `{key:'data', label:'数据', apiKey:'数据监控', progressList:[190,200]}`；`StageSteps` 里 index 6，介于「内容(5)」与「结算(7)」之间；已完成(210)支持 `completed-to-data-monitoring` 退回数据监控「再次投流/加热」。
- 进入方式：`DataStageTable/index.tsx:1` 注释「数据阶段 Table(progress=190/200, 数据监控)」；菜单「项目执行管理 → 选号达人表单」。

**一句话分层**：有人拿大屏问你——答「那是管理层看**整条漏斗**的宏观聚合（ClickHouse 那套 CDC 链路），这是**单条作品**的微观监控，数据源是作品快照明细不是阶段漏斗，产出的是『追不追投 / 结不结算』的**动作**」。

---

## 二、难点到底是什么（真实痛点 + 行业约束）

| # | 难点 | 为什么难（行业/真实） | 代码/来源证据 |
|---|---|---|---|
| 1 | **官方数据是闭环的** | 星图/聚星/蒲公英/花火/互选数据在**官方后台闭环**；抖音开放平台只能查「自己或已授权账号」的作品；B 站稿件数据需 `ARC_DATA` 权限+UP 授权；小红书蒲公英 API 有年耗门槛。**想合规拿"任意达人单条商单视频"的数据，官方不给路** | 官方文档勘察：星图仅后台看；抖音 `item_bc/get_base|get_play` 仅授权账号；B 站 `arc/stat` 需作者授权 |
| 2 | **单条视频数据是「活的」** | 前 24~48h 平台审核计数未稳定、会冻结/修正；发布期达人删视频或设私密**直接取消收益、影响结算**（星图：任务期前删除不可恢复；视频号互选：发布后 7 天合作保护期）→ 需要一个**固化口径的时点** | 行业(YouTube 官方计数口径 + 星图/互选规则)；对应我们的 **archive_time 封存**
| 3 | **跨平台全异构** | 5 个发布平台字段名、单位、口径不同：有效播放抖音看 ≥3s/商单 ≥10s、小红书图文=进详情、视频号自然播放剔除加热流量；互动率抖音**不含**收藏、小红书**含**收藏；`actual_cost/cpm` 抖音除 100、快手除 1000 | 后端表单分页做单位换算；前端 23 项指标注册表按平台过滤
| 4 | **采集要花钱 + 有频控** | 商业数据走**付费第三方网关按次计费**（token 硬编码），爬公开页有反爬/封号风险 → 不能无脑高频重拉，要有节奏和降级 | `PlatformStatsStrategy` 各平台实现；BI 自研旁路兜底
| 5 | **是"时序"不是"现值"** | 只看"最新一条"会丢趋势、没法复盘"第 3 天冲高、第 10 天回落"；重复采集要幂等、晚到要可修正，才能拿去做结算凭证 | 快照表建模（详见四）
| 6 | **数据要驱动钱的动作** | 采集结果不只展示：抓到发布时间→财务可付款；数据齐+到账→完结进结算。**采数和财务/客户通知是联动的** | `changeToPayable`、完结门禁（详见四.5）

---

## 三、行业基准线（答"你们比行业差/好在哪"用）

- **官方口径 vs 第三方估算**：行业铁律——**凡是结算/验收/播放达标判定，只认星图/聚星/蒲公英/花火/互选官方后台口径**；蝉妈妈/飞瓜这类第三方是"估算/区间"，官方自己都声明"价值在趋势准，不在绝对值精确"，**不能当结算依据**。→ 我们的卖点：数据走商业数据采集网关 + 官方星图同步 job，**天然贴近结算口径**；而不是像多数内部系统拿第三方估算值打标。
- **采集频率分层**：榜单/大盘近实时(60s 级)、单作品监测多为**分钟级**(卡思 5 分钟/飞瓜 10 分钟/千瓜笔记监控最长 90 天)，不是每秒级。→ 我们商用场景按 **T+1~T+7 日 + 周** 采样即可覆盖"涨跌曲线 + 结算判定"，频率选择**贴合结算周期而非炫技**。
- **单作品监控的成熟产品形态**（飞瓜"视频监控"/千瓜"笔记监控"）：提交链接→选监控时长→固定间隔自动记录→趋势/增量图→**阈值/异动提醒**。→ 我们的时间线抽屉/导出 = 同形态；**差在：我们没有阈值异动提醒**（见六）。
- **工程基准**（时序采集业界共识）：**实体×日期一行**的快照表 + 唯一键 upsert 幂等 + `collected_at/version` 条件更新防旧覆盖 + 下架素材**冻结终态保留最后快照不回填 0**。→ 我们实现了 upsert + 封存冻结；**差在无 DB 唯一键、无新鲜度/对账告警**（见六）。

---

## 四、我们怎么做：后端（STAR 完整版）

### 4.0 一句话架构
「一条发布视频 = **star_graph_video_report** 里的一组**按日/周的时间序列快照行**（页面时间线/详情都读它）；另有一张 **erp_talent_work_stats** 存"当前监控对象 + 最新值"（达人端自助监控读它）。两表分工：**时序靠 star 表，现值靠 work_stats 表**，应用层做幂等。别再臆想一张大宽表。」

### 4.1 核心难点 1：一条视频的「采集节奏」算法（背这一段，数字最硬）

`StarGraphVideoReportServiceImpl.calculateTimePeriod(videoUrl)`（L233-283）+ `TimeCalcResult`（L355-373）：
- 从分享/作品 URL **解析出视频 ID**（视频号取 `?id=`、抖音取 `modal_id=`、其余去追踪参数取最后路径段）；
- 按 `countByVideoUrlLike("%videoId%")` 统计已采条数：**0 条→T+1，1 条→T+2 … 6 条→T+7**（= 发布后 7 天内每天 1 条日采快照，`count < 7` 走 daily，L262-263，注释 L229-231）；
- **≥7 条切周采**：`weekNum = (发布首条快照 ~ 今天)/7 + 1`（L274），算出该周的日历范围写 `report_date`（第 N 周 = 周一到周日，L275-280）；
- `TimeCalcResult.weekly`（L366-371）：`skip = weekNum==1 || weekNum>=5`；**`archive = weekNum==4` → 打 `archive_time` 封存**。即**只落第 2/3/4 周各 1 条，第 4 周那条写入即封存，第 5 周起 skip 停止采集**。

（BI 自研旁路 `calcTimePeriodForBi`，`ErpTalentWorkStatsServiceImpl` L1006-1072，同一套语义，只是 `earlyWeek` 表达方式不同。）

**封装出来的业务语言（讲给面试官）**：「发布后前 7 天是**快变量**，每天采；之后是**慢变量**，每周采；约一个月后数据基本定型，**封存不动，作为结算口径**。」

### 4.2 核心难点 2：快照幂等落库（同一视频同一天只留一行）

- 落库前按 `videoUrl LIKE %id% + reportDate` **查旧记录 → updateById 覆盖**，否则 insert（`ErpTalentWorkStatsServiceImpl` L759-778，注释「同一天同一视频已存在则更新，避免重复插入」）。
- `star_graph_video_report` **只有主键、无业务唯一键**（DDL `sql/mysql/star_graph_video_report.sql`），幂等靠应用层 `selectOne + update` 而非 DB 约束——**这是真实短板**，被追问就这么认 + 说改进（加 `uk(video_url, report_date, time_type)` + `ON DUPLICATE KEY`）。
- 指标列**全 varchar**（like_count/play_count/actual_cost/cpm…都是 `varchar(20)`）：平台原始口径字符串原样落库、展示侧换算——好处是贴近上游、坏处是**数值解析 bug 家族**（见六🚫）。

### 4.3 核心难点 3：5 平台数据源「统一接口 + 自研降级」

- **策略模式**：`talentworkstats/strategy/PlatformStatsStrategy`（方法：`getPlatformType / extractContentId(分享链接→平台内容ID) / fetchStats / applyStats`）+ `PlatformStatsStrategyFactory` 按平台路由；5 个实现：抖音/快手/B站/小红书/视频号（`PublishPlatformEnum` 1-5）。
- **商业口径主链路**：走第三方商业化数据网关（JustOneAPI，按次计费，token 硬编码）；**视频号**口径最封闭，接另一家供应商；抖音单条播放需另调星图接口且做 `Thread.sleep` 限速。失败写 `import_error_reason` 留痕、靠定时任务/手动重拉清除。
- **自研 BI 旁路降级**（`fetchMultiPlatformWorkStatsByBi`，`ErpTalentWorkStatsServiceImpl` L813+）：自研抓取覆盖 **抖音/B站/小红书** 3 平台（这三个公开页相对可抓），抓不到发布时间或失败再回第三方网关兜底——**能讲成"降级链 + 不只依赖单一付费源"**，但别吹 5 平台都自研。

### 4.4 触发链路（数据从哪进来，答"谁触发采集"）

| 入口 | 触发方 | 路径 |
|---|---|---|
| 达人自助登记 | 达人小程序/后台上传分享链接 | `POST /fluencer/data-monitor/work-stats/config-link`（`DataMonitorController` L44-50）→ upsert `erp_talent_work_stats` + 同步首采 |
| 达人发布信息保存 | 达人端内容生产 | `savePublishInfo` → `changeToPayable` + `fetchMultiPlatformWorkStatsByBi` |
| 媒介人工确认发布 | ERP「确认视频发布时间」批量 | `POST /erp/finance-payment-item/change-to-payable`（5 参带 publishUrls）→ 写 `videoActualPublishDate/publishUrl` |
| 定时全量同步 | Quartz `StarGraphVideoReportSyncJob` **每天 00:00** | 星图/磁力聚星订单 + 线下视频 BI → 逐条按 4.1 节奏算 T+N/第N周 |
| 手动重抓 | `SyncAllPlatfromVedioDataJob` | 遍历 `erp_talent_work_stats` 全表 `reFetch`（单条失败不断链） |

> 讲法提醒：**别把五条路说成一张图**，先说主链路「确认发布(change-to-payable) + 每日 00:00 全量同步 job + 手动重抓」，达人端自助登记作为「达人自己也能量身登记」的补充入口提一句即可。

### 4.5 数据怎么驱动业务闭环（这才是"亮点"里的"亮"）

1. **采到"视频已在平台发布"(videoPublishTime 非空) → 自动触发财务 `changeToPayable`**：把该视频的收/付款子单置 `isPayable`（付款单首次以"实际发布日"建账、`paymentTimeForSettle=发布日+结算天数`）、回写 `erp_talent.videoActualPublishDate / videoPublishUrl`、`erp_sale_order_items` 置"已发布"（`ErpFinancePaymentItemServiceImpl` L2457-2600）。
2. **首次成功入库 → 给客户发短信**"达人已发布视频"（Redis `SETNX` 24h 防重，模板 `sms-talent-publish-video`）+ 同步飞书多维表格（`updateFeishuBitableRecord`）。
3. **完结门禁**：`complete-from-data-monitoring`（`ErpTalentServiceImpl` L3942-4000，仅 `{190,200}`→210）两道校验——
   - `validateVideoInfo`（L4361）：`videoPublishUrl` 非空 **且** 星图报表存在含 `videoPublishTime` 的记录（**数据确实在采了**）；
   - `validateFinanceStatus`（L4402）：付款场景付款子单 `processStatus==3`（已付）/ 收款场景收款子单 `processStatus==6`（已到账）。
   - 通过才 `progress 200→210` 进「已完成」，反向支持"再次投流退回数据监控"。

**把它讲成一个因果链**：「采数 → 判定发布 → 财务可付款 → 客户被通知 → 数据+到账双齐 → 完结结算」。财务不是因为人工，而是被**数据采集结果驱动**的——这是这套系统和"人工在 Excel 里数数"的本质区别。

---

## 五、前端怎么呈现（DataStageTable 里做了什么）

媒介看到的是一个"**数据监控工作台**"（`views/erp/accountpick/talentform/components/table/stages/DataStageTable/`）：

- **23 项指标注册表、按平台配置列**：`videoMetricsConfig.ts` 把指标分 6 类（基础互动/曝光/平台特色/深度转化/投流消耗/流量沉淀），`ALL_METRICS` L15-53；按当前平台过滤、勾选列配置（`VideoMetricsConfigDialog`）。**注意如实讲**：配置只写 React state（会话级），不落库跨会话（见六）。
- **采集相位前端推导**：`getCollectionPhase`（`DataStageTable/index.tsx` L44-56）只看已返回快照——有 `archiveTime` → **已封存**；日采+周采并存 → **周采期**；否则日采期。配 `PHASE_CONFIG` 标签。
- **展开行 = 各平台最新快照**（`VideoDataSubTable`：按 `platformType` 分组、取最新一条）；数值 ≥10000 显示成 `x.xw`。
- **时间线抽屉**（`VideoTimelineDrawer.tsx`）：按 `videoUrl||workUrl` 分组同一视频的全部历史快照，渲染"**每日采集**（T+1~T+7）"与"**每周采集**"两段表，可逐行对比指标、导出 `exportByType(excelType=3)` CSV；多视频分组用 **IntersectionObserver 懒渲染**（`LazyGroup`，rootMargin 400px）只挂可见组；顶部"已完成"标记 = daily 满 7 条 / weekly ≥3 条。
- **业务动作**：确认视频发布时间（调 change-to-payable 批量、`Promise.allSettled` 汇总）、投流/加热数据手工补录（`TrafficDataDialog`，聚星/花火/星图）、分析作品（批量 BI 抓取）、发起付款/发票、完结/批量完结（`canComplete`+`completeReason` 控制）。

前端口径文案（可引用）：「T+1 ~ T+7 · 发布后 7 天内每日自动采集 1 次」「T+8 ~ T+30 · 日采结束后切换为每周采集 1 次」「T+30 已过，数据于 xx 封存，不再自动采集」（`VideoTimelineDrawer.tsx` L386/428/470）。

---

## 六、真实 vs 理想差异（诚实，面试主动说 = 加分）

| 真实（代码现状） | 理想（改进方向） |
|---|---|
| 幂等靠**应用层 selectOne+update**，`star_graph_video_report` 无唯一键；批量导入 `@Async`，并发下有重复行风险 | DB 唯一键 `uk(video_url, report_date, time_type)` + `INSERT…ON DUPLICATE KEY UPDATE` 兜底并发 |
| **无任务状态机/失败重试/告警**（对比 STAR1 采集体系）：失败只写 `import_error_reason`，靠全表重抓兜底 | 按视频维护"应采未采"新鲜度检查 + 失败队列指数退避 + 告警 |
| 无 **DB 层 archive/冻结状态**，封存只是打 `archive_time` 时间戳；"已封存/已完成"标签是**前端纯推导** | 封存写为终态字段，完结门禁校验"快照已齐"，前后端口径后端化 |
| 指标**全 varchar** 存，展示侧换算（actualCost/cpm 抖音除 100、快手除 1000），解析 bug 家族（`'10.5万'` 剥小数点丢精度） | 统一数值口径层 + Decimal 解析（复用第 6 亮点 `parseNumberWithW` 教训） |
| 前端文案「T+30 封存」与代码**第 4 周(~T+22~28)封存**略不一致；数据阶段 190/200 同 tab、结算阶段 190/200/210 与客户侧口径不一致 | 对齐产品文案与代码节奏，口径表后端收敛 |
| 第三方网关 **token/URL 硬编码**，无配额/扣费告警；每日 00:00 全量同步 job 是否加分布式锁未核实 | 配置化 + 配额告警 + 分布式锁/分片 |
| 达人端 `config-link` 与 BI `savePublishInfo` 两条登记入口并存（现值表 vs 时序表），同作品可能两线都记 | 明确单一登记真源，或做双表一致对账 |

---

## 七、能讲 vs 不能讲（✅🚫 追问红线）

**✅ 能放心讲（有真代码支撑）**：
- 快照时序建模：`star_graph_video_report`（video × 日/周）+ `erp_talent_work_stats`（最新值），两表分工；
- 采集节奏算法 & 精确数字：7 条日采 T+1~T+7 → 周采第 2/3/4 周 → 第 4 周封存 → 第 5 周 skip（`calculateTimePeriod` 可背到行号）；
- "同日同视频"应用层幂等 upsert；
- 5 平台策略模式（`PlatformStatsStrategy`）+ 分享链接提取 contentId + BI 自研旁路(抖音/B站/小红书)降级第三方网关；
- 采集→财务→通知→完结的**因果链**（changeToPayable / 短信 / 完结门禁两道校验）；
- 前端工作台呈现（23 项注册表 / 相位推导 / 时间线懒渲染 / 导出）。

**🚫 不能主动讲的（被追问先承认 + 说改进）**：
- **没有阈值/异动提醒**（对比飞瓜"达到 xx 万点赞公众号推送"）——改进：`change`/anomaly 告警而非固定阈值（低基数用绝对值防失真）；
- **没有对账**（star 报表 vs 官方后台）与**数据新鲜度告警**；
- 幂等**无 DB 唯一键**（并发重复风险）；
- 指标 varchar + 解析 bug 家族、单位换算散落各层（无统一口径层）；
- 前端**指标列配置不落库**（刷新/换人即丢默认）；`VideoTimelineDrawer` 顶部写死 `currentPhase='daily'` 的死代码、展开行只显示各平台最新一条；
- 达人端与 ERP 两条登记入口并存（别吹"单一数据真源"）。

**🚫 平台口径红线**：
- 别吹"官方 API 直连"——实际是**第三方商业化网关 + 星图同步**，官方几乎不给第三方批量拉；
- 别把采集数据说成"实时"——**日/周采样**，是结算口径不是实时大盘；
- 被问数据规模——**数据量未核实**，如实答中小量级，别编视频数/行数。

---

## 八、2 分钟讲法（背这段即可）

> 「达人把商单视频发布后，客户要按这条视频的表现来验收和付款。我们做了一个**数据监控阶段**，把每条发布视频建模成时间序列快照。
> 后端核心是**采集节奏**：一条视频从发布起，T+1 到 T+7 **每天采一次**，之后**每周采一次**，采到第 4 周，数据基本定型，就**封存**——封存时刻的数据就是结算口径，不再动。落库是**同一视频同一天只留一行**的幂等 upsert，指标存进 `star_graph_video_report`，按日/周排序就是页面上那条可回看的时间线。
> 数据源我们做了**策略模式接 5 个发布平台**，商业口径走采集网关，另外**自研了一套 BI 旁路抓抖音/B站/小红书兜底降级**——不把命脉押在单一付费源上。
> 最关键是它驱动了**钱的闭环**：一采到'视频已发布'的时间，系统就自动把财务的单子置成可付款、通知客户；等数据采齐 + 财务到账，两道校验过了，达人才**完结**进结算。采数不只是展示，是驱动付款和结算的**触发点**。
> 前端给媒介的是个工作台：23 项指标按平台可配列，展开行看各平台最新值，时间线抽屉逐日回看、可导出。跟蝉妈妈这类行业工具比，我们缺的是**异动预警**——那是我明确知道的下一步。」

---

## 九、为什么面试官会"哇" + 串讲

1. **它有一个专业内核**：把"一条会变、会被删、官方不给数据的视频"做成**带封存时点的时序快照**——做过监控/数仓的人都知道封存口径多重要；
2. **数字能背**：7 天日采 / 第 4 周封存 / 同视频同日幂等——精确到行号，极有说服力；
3. **懂行业边界**：能说出"官方数据闭环、第三方是估算、结算只认商业口径"，说明不是闷头写 CRUD 的人；
4. **钱是被数据驱动的**：采数→可付款→通知→完结是因果链，体现业务建模能力；
5. **和已有亮点能串**：这个"单作品微观监控"补齐了 ClickHouse"宏观大屏"看不到的粒度；跨平台异构(第 6)是**选号前**的统一，这里是**投后**的统一——把"达人投放全生命周期"讲完整了（选号→内容→监控→结算）。

---

## 十、面试前 checklist

- [ ] 通读 `StarGraphVideoReportServiceImpl.calculateTimePeriod`（L233-283）+ `TimeCalcResult`（L355-373）——**背熟 0→T+1…6→T+7 / weekNum 公式 / 第 4 周封存 / 第 5 周 skip**；
- [ ] 通读 `ErpTalentWorkStatsServiceImpl` 快照落库 L759-778 + `calcTimePeriodForBi` L1006-1072 + BI 处理 L813+；
- [ ] 通读 `ErpFinancePaymentItemServiceImpl.changeToPayable` L2457-2600（写了哪些表/字段）；
- [ ] 通读 `ErpTalentServiceImpl` 完结门禁：`completeTalentFromDataMonitoring` L3942 + `validateVideoInfo` L4361 + `validateFinanceStatus` L4402；
- [ ] 看 `star_graph_video_report.sql` DDL（确认列、全 varchar、无唯一键）+ `PlatformStatsStrategy` 5 实现；
- [ ] 前端：`DataStageTable`、`videoMetricsConfig.ts`、`VideoTimelineDrawer.tsx` 各过一遍，能说出交互；
- [ ] **确认参与边界**：本模块哪些是你"负责/参与/对接"（尤其 BI 自研旁路、采集网关接入、达人端 fluencerform 是否你写的），面试措辞分别用"负责/参与/对接"；数字/行号以最新代码为准；
- [ ] **被问"和蝉妈妈/飞瓜差距"**：先答"结算口径=官方商业数据、非估算"，再答"缺异动预警/对账/告警"（第六节），别吹数据规模。
