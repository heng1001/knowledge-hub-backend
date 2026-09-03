# 权限/认证模块 · 面试 STAR 稿（mibo + new-oa）

> 用途：面试前熟读，讲到能自然转述。每条 = 一句话亮点 + STAR 话术(可直接背) + 追问 Q&A + 诚实口径。
> ⚠️ 引用的类/方法/行号以你本地仓库为准，讲前按 checklist 各 grep 一次确认（个别行号会因分支漂移）。
> ⚠️ 本模块是 **芋道 yudao(ruoyi-vue-pro) 开源 fork** 的地基 + 大量二次开发：开讲前先看文末「诚实边界」，别把框架自带能力说成纯自研。

---

## 权限体系一句话总览（30 秒版）

技术栈：Spring Boot + Spring Security + **自研轻量 OAuth2**(非 Spring Authorization Server) + Redis + MyBatis-Plus；前端是 React 18 的 new-oa。
权限分三层：
1. **RBAC 功能权限** —— 用户/角色/菜单 + `permission` 码("system:user:list")即接口+按钮授权点；
2. **行级数据权限** —— MyBatis-Plus 在 SQL 执行期改写 WHERE，部门 data_scope 5 档 + 我们自研的"角色/成员归属"规则；
3. **多租户** —— tenant_id 全链路注入，但现网活跃租户基本=1(框架预留 SaaS、实际单主体)。

认证上最大的二次开发：在 yudao 双 token(access/refresh) 之上叠了**多身份 currentIdentity**，一个账号可同时是 服务商/客户/达人/充值客户。**讲权限先讲这一句，面试官会立刻知道你真懂这套系统。**

---

## 亮点一：多身份认证体系 currentIdentity（后端，最值得深讲）

**一句话**：一个账号同时拥有服务商/客户/达人/充值客户多套角色，登录时把"当前身份"写进 OAuth2 token，鉴权和菜单下发都只在当前身份的角色范围内生效。

### STAR 话术

> **S(背景)**：公司人货场是通的——同一个手机号可能是米播员工、也可能是客户公司账号、甚至是达人/充值客户。开源框架(芋道)只有"单身份 RBAC"，登录进去是什么角色就看什么菜单，支撑不了"一个人有多重业务身份、想以哪种身份进系统"的场景。
>
> **T(任务)**：把单身份扩展成"一人多身份矩阵"，登录时选择身份、鉴权只认当前身份，且不推翻现有 RBAC。
>
> **A(行动)**：
> - 定义身份枚举 `IdentityEnum`：PROVIDER/CUSTOMER/TALENT/RECHARGE_PLATFORM_CUSTOMER(服务商/客户/达人/充值客户)；
> - **身份写进 token**：`OAuth2AccessTokenDO` 新增 `currentIdentity` 字段，登录出口 `createTokenAfterLoginSuccess` 里先 `resolveIdentity` 解析身份，再 `createAccessToken(userId, userType, clientId, null, currentIdentity)` 一起落库；
> - **消歧逻辑** `resolveIdentity`：登录时根据用户角色 code 推导"可用身份集合"，只有一个身份就直接带；有多个身份而前端没传 → 抛 `AUTH_LOGIN_IDENTITY_REQUIRED` 让前端弹选择；传了非法身份 → 抛 `AUTH_LOGIN_IDENTITY_INVALID`；**超管例外**——`RoleCodeEnum.isSuperAdmin`(按角色 code 判、不按 userId==1)任意身份都放行；
> - **下发侧过滤**：`get-permission-info` 取菜单时，若当前身份非超管，则按 `isRoleBelongToIdentity(roleCode, identity)` 把不属于该身份的角色 `removeIf` 掉，再取角色-菜单；
> - **刷新保身份**：refresh token 重建 access token 时把旧 token 的 currentIdentity 原样带出，保证"刷新不变身份"；
> - 前端配套：登录后可用 `available-identities` 拉身份列表；`currentIdentity` 通过 `/system/auth/get-permission-info` 随权限信息一起回传存进 authStore，前端路由守卫据此取菜单。
>
> **R(结果)**：一张 user 表 + 一套 OAuth2 支撑起多业务身份矩阵；登录/刷新/鉴权/菜单四处身份口径一致；超管、单身份用户零感知。

### 追问 Q&A

- **Q：同一手机号命中多个账号怎么办？** A：手机号+密码登录先按 mobile 查出多账号，再按前端传入的 identity 匹配各账号角色；身份唯一自动进，多个身份无匹配就提示"未找到匹配账号"，把歧义显式抛给前端而不是静默选错。
- **Q：身份存哪、会不会丢？** A：存 OAuth2 access token 记录(currentIdentity 字段，MySQL+Redis 双写)；每次请求由 TokenAuthenticationFilter 把 token 还原成 LoginUser 时一并带回，所以鉴权 Filter 里也能拿到身份。
- **Q：超管为什么豁免？** A：超管按角色 code(super_admin)判定而非 userId==1，避免硬编码 userId；超管身份下不看角色归属过滤，全量菜单。
- **Q：刷新 token 会换身份吗？** A：不会。refreshAccessToken 是"删旧 access token、重建新 access token"，并刻意把旧 token 的 currentIdentity 带出——刷新只是续期，身份语义不变。

### 诚实口径

- 核心类是真实存在且能背的：`IdentityEnum`、`resolveIdentity`(AdminAuthServiceImpl)、`OAuth2AccessTokenDO.currentIdentity`、`PermissionServiceImpl` 里按身份 removeIf 角色。
- 菜单"按身份过滤角色"那步在 `AuthController.getPermissionInfo` 里是逐条写清的，讲前读一遍。
- ⚠️ **确认参与边界**：如果多身份是多人一起做的，就说清你负责的段(如 resolveIdentity 消歧 / token 字段落库 / 前端身份选择)。
- 被问"为什么不用 Spring Security 自带的身份体系"——答：底层鉴权(Spring Security Filter)没动，身份是加在**业务 RBAC 层 + token 载荷**上的扩展，成本低、不动框架。

---

## 亮点二：一张 user 表装下"员工+达人+客户"，首登自动建档（后端）

**一句话**：达人"短信验证码即注册即登录"、客户由 ERP 反填建号，全部收编进同一张 system_users、复用同一套 OAuth2 token，砍掉了双表双 token 双轨。

### STAR 话术

> **S(背景)**：开源框架通常分"管理端用户表"和"会员端用户表"两套认证；但我们业务里达人和客户也要登 OA/小程序看数据、走流程，开第二套认证链路意味着重复实现一遍登录/令牌/角色体系。
>
> **T(任务)**：让员工、达人、客户三端登录都复用同一套 system_users + OAuth2，靠"角色 code + 身份 + 派生业务ID"隔离，而不是靠多张用户表。
>
> **A(行动)**：
> - **达人**：`talent-sms/login` 短信验证即"注册+登录"一体——事务保证 `talent_account / system_users / talent_platform_binding` 三表原子；存量达人(erp_talent 有记录但没 OA 账号)按手机号匹配 `erp_talent.tel` 补建；平台绑定用 `platform + kol_id` 全局唯一索引防重复；新号 `isModified=false`，前端强制跳改密页(设计要点注释原话在 `TalentAuthServiceImpl` 类注释)；
> - **客户**：客户建档时由 ERP 侧按 customerNo 创建 system_users 并分配客户角色 code，反填关联；
> - 所有登录方式收敛到**同一个出口** `createTokenAfterLoginSuccess`：写登录日志 → resolveIdentity → createAccessToken → 回填 isModified(是否初始密码、要不要强制改密)。
> - **安全钩子**：改密/封停后调 `removeAccessTokenByUserId` 批量删该用户 MySQL+Redis 的全部 access token(连带删 refresh token)，"全端立即踢下线"；刻意区分 `updateUserPassword`(改密=踢)与 `updateUserPasswordDirect`(直换号=不踢，避免短信登录刚发的 token 被误踢)。
>
> **R(结果)**：一套认证基础设施承载三类用户；达人首次进来 30 秒内能登录且被强制完善密码；改密/封号后旧 localStorage token 立即失效，多端无残留登录态。

### 追问 Q&A

- **Q：外部用户(达人/客户)拿的是"管理端令牌"，会不会太危险？** A：会，这是设计取舍，所以有两点兜底——① 角色只配 `talent_common/customer_common/customer_account` 这类最小角色集，菜单/权限码天然收敛；② 行级数据权限靠"从登录用户派生业务主键"下钻(达人→erp_talent_ids、客户→crmCustomerId)，他不会拿到全量数据。被追问时可主动承认"如果角色漏配，外部用户权限面会扩大"，再讲你上线时的角色巡检。
- **Q：改密后为什么能踢掉所有端？** A：access token 不只存 Redis，MySQL 也落了主键索引的记录，`removeAccessTokenByUserId` 两条都删，所以按 userId 就能精确踢全端。
- **Q：isModified 怎么驱动前端？** A：登录响应和 `get-permission-info` 都返回 isModified；前端路由守卫拿不到 true 就强制进改密页，改密成功才放行。

### 诚实口径

- 类注释就是讲稿：`TalentAuthServiceImpl` 顶部"设计要点 1~5"基本是现成 STAR 骨架。
- 客户自动建号那段在 ERP 侧(ErpCustomerFormServiceImpl 附近)，讲前确认是团队谁写的、你在不在里面——**如果客户建档是 ERP 同事做的，措辞改成"达人侧我做的，客户侧我复用了同一套注册函数"**。
- "踢号"钩子是 yudao 没有的二次开发点，能讲出 `removeAccessTokenByUserId` 里"MySQL+Redis 双删 + 区分改密/直换"就够深。

---

## 亮点三：行级数据权限——框架 SQL 改写 + 自研"成员归属"规则（后端，架构味最重）

**一句话**：功能权限之外还有"行级"权限：部门 data_scope 5 档走框架 SQL 改写引擎；投放项目这类"owner+媒介+执行数组+客户"的多成员语义，我们自研了基于冗余列的成员规则接入同一引擎，业务 Mapper 几乎零侵入。

### STAR 话术

> **S(背景)**：光有"能不能点这个菜单/按钮"(功能权限)不够，还得控"能看哪些行"——比如销售只能看自己部门的客户，项目执行只能看自己参与的项目。手写进每个 Service 会又臭又容易漏。
>
> **T(任务)**：让"行级可见性"在 SQL 层统一生效，业务代码不加过滤条件；同时支持复杂的"成员归属"而不是只支持部门树。
>
> **A(行动)**：
> - **框架层(部门行权)**：MyBatis-Plus 拦截器在 SQL 执行期改 WHERE——对命中表取每条 DataPermissionRule 的表达式用 And 叠加；数据范围 5 档(全部/自定义部门/本部门/本部门及以下/仅本人)逐角色求并；登录时算一次结果塞进 LoginUser 上下文避免每 SQL 重算；"空权限"用 `WHERE null=null` 哨兵让结果恒空；需要豁免的方法用 `@DataPermission(enable=false)` 栈式 AOP 精细控制。
> - **自研成员规则(RoleDataPermissionRule)**：erp_project(达人投放项目)的成员语义是"owner + 媒介数组 + 执行数组 + 关联客户"，部门模型表达不了。我们在表上冗余 `role_codes`(varchar) 和 `user_ids`(json) 两列，规则生成条件：
>   - 命中我角色 → `role_codes LIKE '%my_role%'`；
>   - 命中我本人 → `JSON_CONTAINS(user_ids, 'userId') = 1`；
>   - 超管直接短路 `1=1`。
>   条件注册到 `erp_project` 后，所有查该表的 Mapper 自动带上，业务代码零改动。
>
> **R(结果)**：三端(员工/达人/客户)看同一张投放项目表，各自只见自己参与的行；新表想加行权只注册一条规则，不用碰业务查询。

### 追问 Q&A

- **Q：为什么不用部门数据权限来表达"我参与的项目"？** A：成员是"数组归属"语义(一个项目同时挂媒介组、执行组、客户)，不是组织树；部门规则只能按部门 or 本人，表达不了"组内多个角色 + 本人"的并集。
- **Q：LIKE/JSON_CONTAINS 走不了索引，性能怎么办？** A：承认这是冗余列架构债(列只为 SQL 过滤器服务，写入要同步维护)。演进方向：倒排子表 + EXISTS、或 Service 层先算"我可见的 id 集合"再 `IN`，缩小参与行集也能缓解。属于"已知代价，量级上来前够用"。
- **Q：和数据权限框架什么关系？** A：RoleDataPermissionRule 是框架 DataPermissionRule 接口的一个实现，注册进规则工厂后走同一个 SQL 改写引擎；豁免语义也和部门规则一致，方法级 `@DataPermission(enable=false)` 可逐方法退出。
- **Q：会不会有的查询没被改写，越权？** A：会，这正是难点——同一张 erp_project 的"成员可见"在我们系统里有三份实现(框架 Rule + 几个 Mapper 手写"我参与"4 段 OR + ErpRoleAccessChecker 的 SEE_ALL_ROLES 预判)，而且 ERP 主列表为了复杂查询普遍 `enable=false` 退出了框架再自己过滤。**口径三处并存，改一处漏两处就会越权/误拦，这是我们已知的待收敛项。** 主动讲出来比被追问强。

### 诚实口径

- 框架的部门行权引擎(dept 5 档 + SQL 改写 + null=null)是 **yudao 自带**，讲时归为"框架既有能力，我在业务上落地"。
- 自研点是：`RoleDataPermissionRule`(role_codes LIKE + user_ids JSON_CONTAINS)、冗余列设计、`erp_project` 业务角色族。类路径在 mibo-framework 的 biz-data-permission starter。
- ⚠️ **确认参与边界**：如果你主要做 ERP 调用侧而不是写框架规则，讲成"在框架扩展点上给 erp_project 接了成员行权 + 定义业务角色"，别揽"我写了 SQL 改写引擎"。

---

## 亮点四：敏感数据治理——默认脱敏 + "明文网关"集中出口 + 全审计（后端/全栈）

**一句话**：达人/客户联系方式这类敏感字段，普通读接口统一返回脱敏值；要拿明文必须走一个"集中明文出口"，loader 声明类型/权限/字段白名单，每次取数强制带 operation+reason、无论成败都写审计。

### STAR 话术

> **S(背景)**：达人手机号/微信、客户联系方式是敏感数据。第一版做法是到处脱敏注解、明文散落在各接口，结果"谁该看明文、看没看、看了哪几个字段"完全不可控，权限审计无从谈起。
>
> **T(任务)**：把"看明文"从每个接口里收口成一条受控通道：默认都看不到，只有过网关才看得到，且每次查看留痕。
>
> **A(行动)**：
> - **读接口默认脱敏**：普通列表/详情接口统一返回脱敏值(保留规则：手机号中间四位打码等)；
> - **明文网关 `SensitivePlaintextService`**：想看明文只调它。校验链条 = ① 校验 objectType 是否有 loader → ② 校验登录 → ③ 用 loader 声明的功能权限补校验(`loader.getPermission()`，即"越权了功能权限也拦得住")→ ④ 校验字段 ∈ loader 字段白名单，非白名单字段静默跳过不返回 → ⑤ 取数成功/失败都调 `SensitiveAuditService.log` 写审计(operation=VIEW/COPY/EDIT + reason + 实际放行的 field_scope)。
> - **设计哲学写死在类注释里："不挡人只留痕"**——网关不新增权限，只复用已有"功能权限 + 行级数据权限"，但把每次明文访问变成可追溯事件。
> - 前端填"查看原因"，操作审计与业务日志打通。
>
> **R(结果)**：明文读取从"到处散着"变成"一个出口 + 一张审计表"；运营批量查看时系统能回答"谁、何时、以什么理由、看了哪个达人的哪些字段"。

### 追问 Q&A

- **Q：明文权限在哪里兜底？** A：两层——脱敏注解在 per-field 防呆，明文网关在出口层用 loader.getPermission() 补一次功能权限 + 字段白名单，双保险。
- **Q：会不会有接口忘了接网关，明文漏出来？** A：会，而且我们就有——复盘时发现 star 模块某 loader `getPermission()` 返回 null(=只验登录不验权限)、resource-overview/page 还标了 @PermitAll 且默认返回明文。**这是已知待收口的风险点**，我把它当成复盘素材，而不是回避。
- **Q：审计会不会变成日志轰炸？** A：审计写的是"成功取到哪些字段"的 field_scope 而不是整行数据，能回答溯源问题又不落全量明文到审计表。

### 诚实口径

- 类路径：mibo-framework 的 biz-sensitive starter 下 `SensitivePlaintextController` / `SensitivePlaintextService` / `SensitiveAuditService` / loader 注册表。类注释"不挡人只留痕"是原话，能背很加分。
- yudao 只有 per-field 的 Desensitize 注解，"集中明文出口 + loader + 全审计"是自研。
- ⚠️ 大概率是多人一起做的治理专项，讲前确认自己写了哪块(网关服务 / 某个 loader / 审计表 / 前端查看原因)，以及上文那个 loader 漏配是谁发现的。

---

## 亮点五：new-oa 前端权限架构——后端菜单驱动动态路由 + 401 并发刷新（前端）

**一句话**：登录后把后端下发的菜单转成 React 路由树(约定式加载，新增页面零配置)；token 过期做"单次刷新 + 并发请求挂起重放"，不丢请求不弹窗轰炸。

### STAR 话术

> **S(背景)**：老系统是 Vue(芋道官方后台)，菜单/路由由后端菜单表驱动。我们用 React 18 重写 OA，最大的坑是 **React Router v6 不支持运行时增量 addRoute**——权限菜单是登录后才拿到的，路由只能"后补"；另外 access token 有效期短，401 一多，并发请求各自去刷新就会互相覆盖 token。
>
> **T(任务)**：做出"后端配置菜单、前端自动出路由+按钮权限"的 React 权限骨架，并解决 401 竞态。
>
> **A(行动)**：
> - **约定式路由映射**：`import.meta.glob('/src/views/**/*.tsx')` 预扫描全部页面文件；后端菜单的 component 字段("influencer/list/index")直接当 key 查表懒加载 → 新增页面 = 放个文件，**零路由注册表**。顺带做了三类兼容：抹 `.vue` 后缀(后端菜单还留着 Vue 老配置)、抹前导 `/`、自动补全 `/index`；
> - **登录后重建整棵路由树**：路由守卫里 `get-permission-info` 拉到 menus → `buildDynamicRoutes(menus)` → `createBrowserRouter(...)` 整树重建 → 存 store → key 重挂载。刷新页面后内存 store 清空，守卫重拉权限信息自动恢复；
> - **404 的坑**：通配符 `*` 路由必须放 layout children 内而不是顶层，否则动态路由加载前 `*` 先命中，**刷新非根路径永远 404**——这是踩出来的，注释里写明了；
> - **按钮级权限**：页面里 `permissions.includes('infra:job:create')` 决定按钮显隐，权限码和按钮一一对应，不是只控菜单；
> - **401 单刷新 + 重放**：第一个 401 置 `isRefreshToken` 标志并用**裸 axios**(不走本实例，防递归)调 refresh-token；期间的其它 401 把原 config 压进 requestQueue，刷新成功后逐个用新 token 重放；`isRelogin.show` + 已处于 /login 双重短路，防重复弹"登录超时"弹窗。
>
> **R(结果)**：菜单加按钮都在后端配，前端零路由表维护；401 风暴下只刷一次 token、所有请求不丢；刷新任意深链路不 404。

### 追问 Q&A

- **Q：为什么不把路由一次性全注册，而是登录后重建？** A：菜单本身就是权限边界——不该看的页面连路由都不存在，直接访问 URL 由后端 401/403 兜底；一次性全注册意味着未授权页面也能进，只剩按钮层拦截。
- **Q：React Router 怎么"后补"路由？** A：不做增量，直接"重建整树 + 用 router key 强刷新"，v6 的 createBrowserRouter 替换实例即可，页面级 state 用 key 重置避免沿用旧菜单的路由缓存。
- **Q：401 重放会不会重复发请求？** A：重放的是"挂起时还没成功的请求"，刷新成功的那个 401 请求由服务端重放一次；用模块级标志位保证同一时刻只有一个刷新在飞。
- **Q：这个 401 设计是你原创吗？** A：Vue 版(yudao 官方 admin)也是"单刷新+队列重放"思路，我在 React/TS 侧是同构复刻，但动态路由、约定式组件映射、404 布局、remember-me 的 RSA 加解密是 React 侧重新设计的——**主动说明"后端契约沿用、前端实现是重写的"，比被问到更稳**。

### 诚实口径

- 核心代码都能指给你：`new-oa/src/router/modules.ts`(import.meta.glob)、`guard.tsx`(守卫+重建)、`staticRoutes.tsx`(404 放 layout children，注释写着"否则…永远看到 404")、`utils/request.ts`(刷新队列)。这些基本是**你亲手写的概率最高**，也最该当主打故事。
- 前端 401 单刷新与 Vue 版 service.ts 逐行同构，别吹原创；动态路由/约定式映射是前端自研亮点。
- ⚠️ 一个可以留作"主动暴露"的点：request 拦截器里租户头 `tenant-id: 1` 目前是写死的(OA 固定打米播自己租户)，多租户头没有真正从登录选择的租户取——说明多租户在 OA 端只是"预留"。

---

## 安全视角：如果被问"这套权限有什么隐患/风险"（主动答，不要等被戳穿）

这几条都是仓库内核实过的真实点，用"我在自查中发现、正在推动整改"的口吻讲，展示安全意识：

1. `/system/auth/sso/direct-login` 是 @PermitAll 的 GET，**只传 userId 就能免登录拿 accessToken**(AuthController 原样存在)——必须加来源校验/签名/token。
2. prod 配置 `application-prod.yaml` 里 `mock-enable: true`——mock token 前缀可伪造任意用户；线上是否被环境变量/网关覆盖待确认，但仓库里开着就是隐患。
3. 主登录口 `login()` 里验证码校验被注释掉了(validateCaptcha/validateCaptchaV2)，且没有登录失败锁定/限流(框架有 @RateLimiter 组件但没启用)。
4. 快手 OAuth2 的 client_id/client_secret 用 @Value 明文写死在代码里、日志还打印含 token 的完整响应，且只有"测试"Controller 没接完整绑定链路——属半成品接入，凭据需外置+轮换。
5. 充值客户模块存在按入参 id 直接读改任意记录的 IDOR 风险 + 密码明文入库，而同库另一个模块同字段却走了加密——两处口径不一致，可佐证是疏漏。

> 讲法建议：挑 1-2 条讲成"我在安全自查里发现并推动的整改"，尤其 mock-enable 和验证码这两条最有共鸣；**别把全部 5 条倒给面试官**，那是给自己挖坑。

---

## 诚实边界（讲前必读，30 秒）

**框架自带、要归为"开源 yudao 上二次开发"的**：
OAuth2 五角色(client/code/token/refresh)、access/refresh 双 token(MySQL+Redis 双写与过期)、TokenAuthenticationFilter 鉴权骨架、RBAC 五表模型、permission 码注解求值、**部门行级数据权限 SQL 改写引擎(dept 5 档 + null=null 哨兵)**、多租户 tenant_id 注入、@PermitAll/401/403、登录日志、脱敏注解、前端 401"单刷新+重放"(复刻 Vue 版)。

**确实是米播二次开发/新增、能放心当"自己做的"讲的**：
多身份 currentIdentity 体系、达人/客户首登自动建档、removeAccessTokenByUserId 全端踢号、SSO direct-login 桥接与 10+ 登录方式收敛、敏感明文网关+loader+审计(以及它的漏网瑕疵)、RoleDataPermissionRule/erp_project 成员行权、new-oa 的约定式动态路由与路由树重建。

**归属有争议/建议先问清同事再讲**：客户建档(ERP 侧)、明文网关各 loader、CDC/数仓(那是另一个亮点)、快手/巨量接入的完整度。

---

## 面试前 checklist

- [ ] `IdentityEnum` / `AdminAuthServiceImpl.resolveIdentity` / `AuthController.getPermissionInfo` 各读一遍，能说出身份消歧 + 超管豁免路径
- [ ] `TalentAuthServiceImpl` 类注释(设计要点 1-5)背熟——那就是达人建档的现成讲稿
- [ ] `OAuth2TokenServiceImpl.removeAccessTokenByUserId` + `AdminUserServiceImpl` 里"改密=踢 / 直换=不踢"的两个方法名记准
- [ ] `RoleDataPermissionRule`：能说出 role_codes LIKE + JSON_CONTAINS(user_ids) 拼 WHERE、超管 1=1、如何注册到 erp_project
- [ ] `SensitivePlaintextService`：背出"不挡人只留痕" + 校验链条(类型→登录→功能权限→字段白名单→全审计)
- [ ] new-oa `guard.tsx` / `dynamicRoutes.tsx` / `modules.ts` / `utils/request.ts` 至少能指出关键行
- [ ] 确认自己在这 5 个亮点里的参与边界(亲自写 vs 参与 vs 复刻)，措辞分别用"负责/参与/复刻"
- [ ] 挑 1-2 条安全风险用"自查发现、推动整改"口吻准备，别全倒
- [ ] 行号以本地仓库为准，讲前一天再 grep 一遍，别背错行

---

# 附录 A：浓缩口播版（60~90 秒，面试前背熟）

> 用途：不按 5 个亮点全讲，按面试方向和剩余时间抽 1~3 个。
> 每个版本 = 一段可整段背的话。**数字/类名是记忆锚点，背错比背不出来更伤。**

## 后端主打版（90 秒，最稳的"权限深度"组合）

> 我们公司的权限系统是在芋道 yudao 这套开源框架上二次开发的。整体分三层：菜单按钮级的功能权限、SQL 执行期改写的行级数据权限、租户隔离。功能权限这层我们做了个很大的扩展，叫**多身份**——一个账号可以同时是服务商、客户、达人、充值客户，登录时把"当前身份"写进 OAuth2 token 里，鉴权和菜单下发只认当前身份。实现上有几个关键点：身份由用户角色推导，身份有多个就必须让前端选；超管按角色 code 判、不受身份限制；刷新 token 时把旧身份原样带出，刷新不会换身份。在数据层，投放项目这种"一个项目挂 owner、媒介组、执行组、客户"的多成员语义，部门模型表达不了，我复用框架的数据权限规则机制，在表上冗余了角色和用户两列，用 LIKE 和 JSON_CONTAINS 让 SQL 引擎自动拼过滤条件，业务 Mapper 零改动。另外敏感数据这块，我们做了一个"默认脱敏 + 明文网关"的设计：平时接口都返回打码值，想看明文必须走一个集中出口，每次查看都要带理由并且全量写审计——类注释里写的是"不挡人只留痕"。

## 前端/全栈主打版（60 秒，new-oa 是你自己写的就讲这个）

> 前端这套是我用 React 重新写的。权限是"后端菜单驱动"——登录后拉一次权限信息，后端下发的菜单直接转成 React 路由树。这里有个 React Router v6 的坑：它不支持运行时加路由，所以我们是登录后**整棵树重建**，刷新页面再从内存状态恢复。页面文件用 import.meta.glob 约定式扫描，后端菜单的 component 字段直接映射到对应 tsx，**新增页面只要放个文件，不用改任何路由表**。按钮级的权限就判断权限码在不在列表里。token 过期这块做了并发保护：第一个 401 触发一次刷新，期间的其它 401 排队挂起，刷新成功用新 token 逐个重放，不会出现一堆请求各自刷新把 token 互相覆盖的情况。

## 如果只够讲 1 个（半分钟版）

> 后端就讲**多身份**，前端就讲**动态路由**；这是两个"框架给不了、只能自己写"的点，最容易让面试官觉得你有原创深度。

## 记忆锚点小抄（背数字不如背这几个名字）

| 锚点 | 对应故事 | 一句提示 |
|------|---------|---------|
| `IdentityEnum` + `resolveIdentity` | 多身份 | 角色→身份集合→歧义抛错/唯一自动/超管豁免 |
| `OAuth2AccessTokenDO.currentIdentity` | 多身份落库 | 刷新保身份，删除重建时带出旧身份 |
| `removeAccessTokenByUserId` | 踢号 | MySQL+Redis 双删；改密=踢、直换号=不踢 |
| `TalentAuthServiceImpl` 类注释 | 一表多端 | 类注释"设计要点 1~5"就是讲稿 |
| `RoleDataPermissionRule` | 行级数据权限 | role_codes LIKE + user_ids JSON_CONTAINS + 超管 1=1 |
| `SensitivePlaintextService` | 敏感治理 | "不挡人只留痕"：类型→登录→权限→白名单→全审计 |
| new-oa `modules.ts` / `guard.tsx` / `staticRoutes.tsx` | 前端动态路由 | import.meta.glob / 整树重建 / 404 放 layout children 内 |
| new-oa `utils/request.ts` | 401 并发 | isRefreshToken + requestQueue 重放 + 裸 axios 防递归 |

## 讲哪几个的取舍

- 时间只够 **1 个**：多身份(后端)或动态路由(前端)。
- 时间够 **2 个**：后端 = 多身份 + 行级数据权限；前端岗 = 动态路由 + 401 并发。
- 时间够 **3 个**：多身份 + 行级数据权限 + 敏感治理(这条链最能体现"架构+安全")。
- 如果面试官是**安全向**：主动把"敏感治理"和"自查发现的风险"连起来讲。
- **别 5 个都讲**——会显得像在背文档，挑最贴对方业务(达人/客户/直播投放)的 2~3 个。

# 附录 B：连环追问演练（自测用）

> 面试官顺着你的口播往下问的常规连招，先遮住答案自测，再对答案。

**连招一：多身份**
1. "同一手机号登录多个账号，你怎么知道进哪个？" → 消歧：查 mobile 下多个账号→按身份匹配角色→唯一/空取首条、多身份无匹配就抛错让前端选。
2. "这个身份存在哪？请求进来怎么拿到？" → 存在 OAuth2 access token 记录，请求由 TokenAuthenticationFilter 还原 LoginUser 时带回。
3. "改密码后旧登录态还能用吗？" → 不能，removeAccessTokenByUserId 按 userId 删 MySQL+Redis 全部 token，多端即刻下线。
4. "刷新 token 会换身份吗？" → 不会，重建 access token 时把旧 currentIdentity 原样带出。
5. "外部用户(达人)拿管理端令牌不安全吧？" → 主动认：是取舍。角色只给最小集 + 行权靠派生业务ID 兜底，但角色若漏配权限面会扩大，上线有角色巡检。

**连招二：行级数据权限**
1. "行级权限怎么做的？" → MyBatis-Plus 在 SQL 执行期改 WHERE，规则按表注册。
2. "和功能权限什么关系？" → 功能权限管"能不能点"，行权管"能看哪些行"，两层独立叠加。
3. "你这个 LIKE/JSON_CONTAINS 走索引吗？" → 不走，是冗余列架构债；演进 = 倒排子表/预计算可见 id 集合。
4. "会不会有查询漏改越权？" → 会。同表可见性目前三份实现、主列表常 enable=false 再自过滤，是已识别的收敛项。主动承认 + 讲收口方案。

**连招三：敏感治理**
1. "明文怎么取？" → 走 SensitivePlaintextService 网关：loader 声明类型+权限+字段白名单，带 operation/reason，成败都审计。
2. "要是 loader 忘了写权限呢？" → 就是我复盘发现的真实漏洞(star 模块 loader getPermission 返回 null、某接口还 @PermitAll)，已列入整改。
3. "审计会不会数据量爆炸？" → 审计记 field_scope(放行了哪几个字段)而不是整行明文，够溯源、不落全文。

**连招四：前端**
1. "React Router 不能运行时加路由，你怎么做权限路由？" → 登录后整树重建，key 重挂载。
2. "刷新页面路由还在吗？" → 内存清空后守卫重拉 get-permission-info 自动恢复；404 通配符必须放 layout children 内否则刷新非根路径 404。
3. "一堆请求同时 401 怎么办？" → 单刷新 + 队列重放；isRelogin 防重复弹窗。
4. "这个 401 方案是你原创吗？" → 后端契约沿用、Vue 版也是这思路，React 侧实现是重写的；主动说比被问强。

---

*正文完。附录 A 是考前背诵、附录 B 是自测连招。讲之前按 checklist 核对行号与参与边界。*
