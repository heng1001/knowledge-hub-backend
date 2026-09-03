# 面试STAR-ES达人检索与推荐评分

> 代码讲稿：ES/OpenSearch 达人检索的 query 拼装 + 推荐打分体系。
> 全文可分两条主线理解：**Part 2 离线给每个达人算出 `evaluation_scopes`，Part 1 在线列表/推荐补足都拿它排序**——评分与检索靠一个字段打通。

---

## Part 1：ES 达人检索的 query 拼装

### 1.1 整体架构：一次请求，广播给多个平台，各自返回再合并

入口 `ResourceOverviewServiceImpl.talentListPageEs`（`ResourceOverviewServiceImpl.java:266-309`）：请求体里带 `platformList`，主服务不碰任何 ES 细节，只做三件事——

```java
for (Integer platformType : platformList) {
    EsPlatformTalentListStrategy strategy = esPlatformTalentListStrategyFactory.getStrategy(platformType);
    PageResult<ResourceOverviewRespVO> result = strategy.talentListPage(req);  // ← 同一份 req 广播
    allResults.addAll(result.getList());
    totalCount += result.getTotal();
}
```

返回前再做三段富化（`enrichCooperationCount` / `enrichWorkWechatInfo` / `enrichOngoingCooperationInfo`），这些要查 MySQL 里的合作/企微上下文，属于 ES 检索完成后叠加。

**平台策略怎么挂进来的？** `EsPlatformTalentListStrategyFactory`（57 行）：Spring 注入 `List<EsPlatformTalentListStrategy>`，`@PostConstruct` 时读每个策略的 `getPlatformType()` 自动注册进 `ConcurrentHashMap`。

> ▎ 结论：新增一个平台 = 只新增一个 `@Service` 子类，主服务、工厂、分发逻辑一行都不用改。

### 1.2 模板方法：doTalentListPage 双路分页

`AbstractEsTalentListStrategy.doTalentListPage`（:97-149）把"核心查询模板"固化下来，抽象类只留 11 个抽象方法给平台子类实现（索引名 x3、kolId 排序字段、按条件查 kolId、有无筛选、联系方式补充、推荐来源……）。核心逻辑是按"有没有筛选条件"分两条路径：

```java
hasAnyCondition = hasTalentListFilterCondition(req);
matchedKolIds   = queryKolIdsByConditions(req);      // 路径A：筛选 → 内存候选集合
matchedKolIds   = sortKolIdsByEvaluationScopes(...); //   再按评分重排

if (筛选有结果)   { total = matchedKolIds.size(); pageKolIds = matchedKolIds.subList(from, to); }  // 内存分页
else if (无筛选)  { // 路径B：search_after 深分页
    先 size(0)+trackTotalHits 拿 total
    pageKolIds = queryKolsPageKolIdsBySearchAfter(from, pageSize);
}
```

设计意图很清晰：有筛选时结果集合天然受限，直接在内存里 `subList` 分页最便宜；只有无筛选这种"全量翻页"场景才值得走 ES 深分页，避免内存里攒几十万 id。

外层每个环节都套了 try/catch：ES 客户端没配、单维度查询挂了、排序挂了，各自返回空页或回退原集合，整页绝不让某个平台/某个维度拖垮。

### 1.3 深分页：search_after 突破 from 1w 上限

`queryKolsPageKolIdsBySearchAfter`（:353-411）。ES 的 `from+size` 默认不能超过 `max_result_window=10000`，达人库这种翻到 100 页就要炸，所以它不用 from，改游标快进：

```java
while (skipped < from) {              // 阶段1：快速跳过 from 条，每次 1000
    size = min(1000, from - skipped);
    ... builder.searchAfter(cursor);   // 用上一页最后一行的 sort() 值当游标
    cursor = hits.get(hits.size()-1).sort();
}
// 阶段2：此时游标停在 from 处，再 size=pageSize 取当前页
```

关键是排序必须**全局唯一、稳定可续**，否则游标会跳/重：

```java
.sort(has_detail DESC, missing(0))        // 精选靠前，无此字段的排最后
.sort(evaluation_scopes DESC, missing(0)) // 评分高靠前
.sort(kol_id ASC)                          // 最后用唯一键兜底，保证游标严格前进
```

`missing(0)` 让没有该字段的文档当成 0 参与排序，游标不会因为字段缺失错位。且每次翻页 `_source.filter(includes("kol_id"))` 只取 id，省带宽。同文件 `collectKolIdsBySearchAfter`（:416-463）把这个游标工具抽出来复用——它就是所有"全量拉 id"逻辑的地基。

### 1.4 多条件筛选 = 多个"kolId 有序集合"取保序交集

这是最有味道的地方。子类 `queryKolIdsByConditions`（抖音实例 `EsDouyinTalentListStrategy.java:150-236`）不是拼一个大 bool query，而是把每个筛选维度各自查成一个 kolId 集合，塞进 `List<LinkedHashSet>`，最后统一取交集：

```java
// 每个条件 -> 一个有序 kolId 集合
if (fansMin!=null||fansMax!=null) kolIdSets.add(queryByRange(getDataIndex(),"follower",fansMin,fansMax));
if (cpmMin!=null||cpmMax!=null)   kolIdSets.add(queryCpmKolIds(filter));          // CPM 内部可能是6字段并集
...
LinkedHashSet<String> result = intersectKolIdSetsOrdered(kolIdSets);   // 保序交集
```

而 `intersectKolIdSetsOrdered`（基类 :581-594）实现得极轻：

```java
LinkedHashSet<String> result = new LinkedHashSet<>(kolIdSets.get(0));   // 以第一个为基准
for (i=1..) result.removeIf(kolId -> !nextSet.contains(kolId));          // 逐个删不在后面的
```

保留 `LinkedHashSet` 的插入序 = 天然继承第一个维度的返回顺序（这个顺序来自 ES 按 `has_detail`/评分排好的序）。

**为什么"每维度一个查询"，而不是一个 bool 复合查询？** 因为各维度的数据源根本不同——

| 条件 | 打的索引/字段 |
|---|---|
| 名称 | kols 主索引 `nick_name`(抖音)/`name`(其它) |
| 合作状态 / 有联系方式 / 省市 | kols 主索引 `terms`(`province.keyword` / `city.keyword`) |
| 粉丝数 / 预期播放 / 互动率 / 完播率 | data 明细索引 `range` |
| CPM / 报价 | price 报价索引 `range` |

一个 bool query 无法横跨三个索引。这套设计相当于在应用层做了一次**"索引裁剪 → 各取所需 → 内存求交"**，代价是 N 次小查询，换来的是每维度独立、可单点降级（`queryByTerms`/`queryByRange` 失败都只返回空集并记日志）、且字段映射天然解耦。

**维度的映射细节也做得细，体现平台差异收敛在子类：**

- CPM 字段映射用 Java switch 表达式把业务词映射到 6 个字段（`getCpmFieldByType:278-288`）；用户没选 `cpmType` 时，把 6 个 CPM 字段各查一遍取并集（`queryCpmKolIds:244-270`）——因为一个达人只要任一 CPM 达标就该命中。
- 报价同理：`quoteType` → `price_1_20` / `price_20_60` / `price_60` / `price`（`queryQuoteKolIds:296-323`）。
- 名称两级检索在基类复用（`queryKolIdsByTalentName:638-654`）：先 `term(name.keyword)` 精准命中即返回；没精准命中再 `match(name)` 模糊召回——精准优先保住精确匹配用户的体验，模糊兜底保证召回。
- B 站报价筛选用 `queryByRangeWithTermFilter`（bool: `filter term` + `must range`）；小红书地区用 `match` 多值 `should`（省市清洗）。

> ⚠️ 一个值得留意的取舍：`addKolIdSetOrdered`（:571-576）只把非空集合加入待求交列表。好处是单维度异常/空查询不炸整页；副作用是——当有 ≥2 个筛选条件、其中某个条件"真实命中 0 条"时，它会被静默丢弃，交集结果变成其它条件的超集，而不是空集。单条件场景没问题（集合列表为空 → 直接返回空）。如果产品语义是"某维度命中 0 就该整体返回空"，这里是个隐藏 bug。

### 1.5 页内组装：并发打三个索引，按请求序归位

拿到一页 kolId 后，`queryAndAssembleVOs`（:210-266）并发发三个 `terms(kol_id)` 请求拿全字段：

```java
SearchResponse kolsResp  = esClient.search(kolsReq,  Map.class);   // 主表
SearchResponse dataResp  = esClient.search(dataReq,  Map.class);   // 明细
SearchResponse priceResp = esClient.search(priceReq, Map.class);   // 报价
```

然后 `groupingBy(kol_id)` 本地归组，但回源遍历的是入参 `kolIds` 的顺序（`for (String kolId : kolIds)`），而不是 ES 返回顺序——因为三个请求返回顺序不可靠，以入参顺序为基准才能保住上一页拼好的分页顺序。VO 组装时顺手 `sanitizeAuditFields` 剥掉 `creator/deleted/tenant_id/updater`，内部字段不外泄。

### 1.6 联系方式：ES 里不落明文，页内回查 MySQL 再脱敏

抖音子类 `enrichContactInfo`（`EsDouyinTalentListStrategy.java:331-353`）：只对当前页的 kolIds 查 `douyin_pool_base_info.contact_info`，塞进 VO。这条链路把"ES 索引（公开画像数据）"和"MySQL 明文联系方式（敏感）"**物理隔离**，敏感数据只在 VO 层走统一脱敏（Jackson SpEL 脱敏）。这样 ES 索引即使被拉全量也拿不到联系方式，明文只按页按需出 MySQL。

### 1.7 置顶推荐

`prependProjectRecommendation`（:154-188）：仅当 `pageNo==1 && 无筛选 && 请求带了 projectId` 时，从 `brief_recommend` 的 stage1 推荐表按项目取已推荐的 kolId，`assembleVOsByKolIds` 现组 VO 拼到最前面，并同步加 total。失败只记日志、返回原结果。

---

## Part 2：推荐打分体系

### 2.1 ScoringUtil：一份"打分手册"被实现成纯函数库

8 个维度权重集中声明在类顶部（`ScoringUtil.java:19-26`），权重和 `aggregate`（:131-142）加权求和，所有方法只做纯计算、无状态、无 I/O——可单测、可被四个平台策略共享：

| 维度 | 权重 | 说明 |
|---|---|---|
| A 粉丝规模 | 20% | 粉丝数 + 预期播放量 |
| B 内容质量 | 20% | 互动率 + 完播率 + 爆文率 |
| C 性价比 | 15% | 预期 CPM + 21-60s 报价 + 播放 CPM |
| D 触达效率 | 10% | 播放/粉丝比 + 月连用户/粉丝比 |
| E 内容稳定性 | 10% | 暂无数据，固定 0 |
| F 成长潜力 | 10% | 15 日涨粉率 |
| G 信息完整度 | 10% | 有详情页 + 有联系方式 |
| H 历史合作 | 5% | 每合作 1 次 +5，20 次封顶 |

最有设计感的是四个私有子算法（:146-195），每个都针对"指标的量纲/分布"选了不同的归一化：

```java
// 1) logScale：粉丝/播放这种数量级差异巨大的指标 —— 对数刻度压量级
//    <=100 → 0；每乘 10 → 涨 10 分。粉丝 1k=10分, 1w=20, 10w=30, 100w=40...
score = log10(v/100) * 10

// 2) ratioToScore：达成率类（互动率/完播率）—— 线性比值，达到阈值即封顶 100
ratio/threshold * 100   // 互动率 30% 满分、完播率 90% 满分、爆文率 50% 满分

// 3) costToScore：成本类 —— 反向打分，null 按满分（没报价视作"便宜"）
max(0, 100 - cost/zeroThreshold*100)   // CPM 0分线 200元；报价 0分线 5万元

// 4) connectToFans：月连用户/粉丝比 —— sigmoid 平滑，不硬截断
sigmoid = 100 / (1 + e^(-0.5*(r-1)))
```

`sigmoid` 那处尤其值得注意：比值 r 在 1 附近（连接用户≈粉丝数）时斜率最陡，越往两端越饱和——比 `min(100, r/阈值*100)` 这种线性硬截断更像"边际收益递减"的真实规律，且不会在阈值处跳变。

每个方法都处理 null（记 0 或按策略记满分），返回值统一 clamp 到 [0,100]。

### 2.2 平台策略只喂字段，"数学口径"不重复

拿抖音 `DouyinRecommendStrategy.computeScore`（`DouyinRecommendStrategy.java:78-122`）看，它一行计算逻辑都没有，只做字段搬运：

```java
// 维度A：粉丝规模（data 表 follower + snExpectedPlayNum）
BigDecimal a = ScoringUtil.scoreDimensionA(data.getFollower(), data.getSnExpectedPlayNum());
// 维度C：性价比（price 表 snProspective2060Cpm + price2060）
BigDecimal c = ScoringUtil.scoreDimensionC(expectedCpm, price2060, BigDecimal.ZERO);
// 维度F：成长潜力（15日涨粉率）
BigDecimal f = ScoringUtil.scoreDimensionF(data.getFansIncrementRateWithin15d());
// 维度H：历史合作（progress=210 已合作项目数）
BigDecimal h = ScoringUtil.scoreDimensionH(countCooperation(kolId));
return ScoringUtil.aggregate(a, b, c, d, e, f, g, h);
```

B站/快手/小红书的 `RecommendStrategy` 结构与它同构，只是把各自的 `averagePlayCnt` / `platformPrice` / 爆文率 等平台字段喂进对应维度。

> ▎ 一句话：业务口径（怎么算分）收敛在 ScoringUtil，平台差异（字段在哪）收敛在各 platform strategy——这是很标准的"策略 + 纯函数"拆法。

算出的综合分写回 `douyin_kols_os.evaluation_scopes`（:66-68）——这个字段就是 Part 1 检索排序里用的那个 `evaluation_scopes DESC` 排序键。**评分系统和检索系统靠这一个字段打通：离线算好分 → 实时列表/推荐按分排序。**

### 2.3 LLM 只做"自然语言 → 结构化条件"，召回仍是确定性检索

`convertBriefStandardJsonToTalentListReq`（`BriefRecommendServiceImpl.java:812-838`）：用豆包把客户的 Brief 标准化 JSON 翻译成 `ResourceTalentListPageReqDTO`（也就是 Part 1 那套筛选 DTO）：

```java
aiResp = douBaoArkService.chatCompletionDirect(SYSTEM_PROMPT, userPrompt, 0.1, true);  // temperature 0.1
String json = sanitizeAiJson(aiResp);   // 剥 markdown fence/首尾噪声，只留 {...}
return objectMapper.readValue(json, ResourceTalentListPageReqDTO.class);
```

- `temperature 0.1` + 强约束 system prompt：让模型输出尽量稳定、可解析的 JSON；
- `sanitizeAiJson`（:841-852）用 `indexOf('{')` ~ `lastIndexOf('}')` 兜底截取，扛住模型输出带前后缀；
- 任一环节失败（LLM 挂了 / JSON 解析失败）一律返回 null，上层静默降级，绝不把"推荐"做成硬依赖。

设计意图是把 AI 的"不可控"关在**翻译层**——AI 的职责只是理解客户需求并翻译成结构化筛选条件，真正召回走的是 Part 1 那套确定性的 ES/OpenSearch 检索。推荐结果的可靠性因此只取决于筛选条件翻译得准不准，而非模型当场幻觉出 KOL。

### 2.4 恒补足 10 条：召回保底 + 评分定序的组合

`recommendTalentsByBrief`（:577-624）对每个平台调对应 `SearchStrategy.queryKolIdsByConditions(req)`，单平台异常 `continue` 不拖累其它平台。真正的精髓在 `postProcessKolIds`（:626-669），它保证每个平台永远凑满 `RECOMMEND_LIMIT_PER_PLATFORM(10)` 条，分三种情况：

```java
if (命中 == 0)      → 全量按 evaluation_scopes 降序取 top10          // 条件过严也不空推荐位
if (命中 >= 10)     → 用 kolIds terms 回源，按 evaluation_scopes 重排取前 10
else (命中 < 10)    → 评分全量 top(10-n) 补足，与已有按 kolId 去重合并
```

其中排序/补足都用 `_source.filter(includes("kol_id"))` + `trackTotalHits(false)` 只取 id 省开销（:688-736、:742-787），OpenSearch 调用失败则降级为原顺序截断（:784-785）。

> ▎ 一句话闭环：结构化条件负责"筛准"，`evaluation_scopes` 评分负责"排序和兜底"。就算客户的 Brief 拆出来的条件一个都召不回，评分最高的达人也会填满 10 个推荐位——推荐永远有结果，只是可能不那么精准。

### 2.5 两处如实备注

- `generateEvaluationScopes`（`DouyinRecommendStrategy.java:50-76`）是离线圈选：全表 `select` + 每行 `selectByKolId(data)` + `selectByKolId(price)` + `selectCount(erp_talent)` + 逐行 `UPDATE` 的 N+1，数据量大时耗时明显；且该 Controller `@PermitAll`，理论上匿名可触发全量重算。**打分"口径设计"是亮点，但回填执行器的效率不算。**
- 报价只取 `priceList.get(0)` 首个报价行（:89），多档位报价达人只算第一档，性价比口径略糙。

---

> 两块其实是一条主线上的前后端：**Part 2 离线给每个达人算出 `evaluation_scopes`，Part 1 在线列表/推荐补足都拿它排序。**
