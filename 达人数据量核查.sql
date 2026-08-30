-- ============================================================
-- 达人库数据量核查脚本
-- 用途：面试前查清真实数据量，避免口误。
--       注意：erp_talent 的 AUTO_INCREMENT 是雪花式大 ID 直插的副作用，
--       不代表行数，一定要用 COUNT(*) 查真实行数。
-- 运行环境：Navicat / DBeaver / DataGrip / mysql CLI 均可，连到目标库后直接跑。
--   local: jdbc:mysql://115.190.50.119:3306/mibo-local
--   dev:   jdbc:mysql://115.190.50.119:3306/mibo-dev
--   sit:   jdbc:mysql://115.190.50.119:3306/mibo-sit
--   prod:  jdbc:mysql://115.190.141.47:3306/mibo
--   （账号密码见 BE/mibo/mibo-server/src/main/resources/application-*.yaml）
-- ============================================================


-- ============================================================
-- 方式一（推荐）：精确统计所有达人相关表，一行一个表，自动汇总
-- 覆盖 erp_talent* / *_kols* / *_pool* 所有表
-- ============================================================
SET SESSION group_concat_max_len = 1000000;   -- GROUP_CONCAT 默认只有 1024 字节，先放大

SET @sql = NULL;
SELECT GROUP_CONCAT(
         CONCAT('SELECT ''', table_name, ''' AS 表名, COUNT(*) AS 真实行数 FROM ', table_name)
         SEPARATOR ' UNION ALL ')
  INTO @sql
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND ( table_name LIKE 'erp_talent%'
        OR table_name LIKE '%_kols%'
        OR table_name LIKE '%_pool%'
        OR table_name LIKE '%_pool_%' );
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- 如果不方便跑上面的动态 SQL，可以用下面这一条看估算值（来自元数据，秒回）：
-- SELECT table_name, table_rows
--   FROM information_schema.tables
--  WHERE table_schema = DATABASE()
--    AND ( table_name LIKE 'erp_talent%' OR table_name LIKE '%_kols%' OR table_name LIKE '%_pool%' )
--  ORDER BY table_rows DESC;


-- ============================================================
-- 方式二：核心表单独数（面试最常被问的几张）
-- ============================================================
SELECT
  (SELECT COUNT(*) FROM erp_talent)                                        AS 达人主表总数,
  (SELECT COUNT(*) FROM erp_talent WHERE deleted = 0)                     AS 达人主表未删除,
  (SELECT COUNT(*) FROM erp_talent_collect_task)                          AS 采集任务表总数,
  (SELECT COUNT(*) FROM erp_talent_update_task)                           AS 更新任务表总数,
  (SELECT COUNT(*) FROM erp_talent_work_stats)                            AS 作品表总数,
  (SELECT COUNT(*) FROM erp_talent_stage_log)                             AS 阶段审计日志总数;

-- 各平台原始达人表（爬虫来源层）
SELECT 'douyin_kols'  AS 表名, COUNT(*) AS 行数 FROM douyin_kols
UNION ALL SELECT 'kuaishou_kols',     COUNT(*) FROM kuaishou_kols
UNION ALL SELECT 'xiaohongshu_kols',  COUNT(*) FROM xiaohongshu_kols
UNION ALL SELECT 'bilibili_kols',     COUNT(*) FROM bilibili_kols;

-- 各平台详情池明细表（采集结果层，按你环境里实际存在的表调整）
SELECT 'douyin_pool_base_info' AS 表名, COUNT(*) AS 行数 FROM douyin_pool_base_info
UNION ALL SELECT 'douyin_pool_audience_portrait',      COUNT(*) FROM douyin_pool_audience_portrait
UNION ALL SELECT 'erp_talent_xiaohongshu_pool_talent_basic', COUNT(*) FROM erp_talent_xiaohongshu_pool_talent_basic
UNION ALL SELECT 'erp_talent_kuaishou_pool_base_info',      COUNT(*) FROM erp_talent_kuaishou_pool_base_info
UNION ALL SELECT 'erp_talent_bilibili_pool',               COUNT(*) FROM erp_talent_bilibili_pool;

-- 面试口径建议（查到数字后填进去，直接背）：
-- 「达人主表 X 行，未删除 X 行；抖音原始达人 X、小红书 X、B站 X、快手 X；
--   采集任务历史累计 X 条；作品数据 X 条。规模属中小型，架构为多平台垂直分表，
--   查询走 ES 检索、分析走 ClickHouse。」
