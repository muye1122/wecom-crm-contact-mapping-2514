-- =====================================================================
-- 企业微信外部联系人与 CRM 联系人映射 — DDL 草案（MySQL 8.x）
-- 纯设计草案，含标准 org_id/site_id 与审计字段；示例值与命名均为虚构。
-- 一致性规则（应用层保证，DDL 以注释与 CHECK 标注）：
--   * confirmed 时 crm_contact_id 必须非空；其余状态必须为空；
--   * unionid 精确匹配且唯一是唯一允许系统自动写 confirmed 的路径；
--   * 其它匹配只写 suggested，须员工确认后才可写 crm_contact_id。
-- =====================================================================

CREATE TABLE IF NOT EXISTS wecom_external_contact (
  -- ---------- 技术主键 ----------
  id                 BIGINT        NOT NULL AUTO_INCREMENT COMMENT '技术主键，自增',

  -- ---------- 标准租户/站点字段 ----------
  org_id             VARCHAR(64)   NOT NULL COMMENT '标准组织ID，租户隔离，继承企微上下文',
  site_id            VARCHAR(64)   NOT NULL COMMENT '标准站点ID，站点隔离，继承企微上下文',

  -- ---------- 业务标识 ----------
  external_userid    VARCHAR(64)   NOT NULL COMMENT '企微外部联系人唯一标识',
  unionid            VARCHAR(128)  DEFAULT NULL COMMENT '微信unionid；未返回或未授权时为空',
  follow_userids     JSON          NOT NULL COMMENT '加过该客户的员工userid列表（去重，至少1个）',
  corp_name          VARCHAR(256)  DEFAULT NULL COMMENT '客户所属企业名（企微外部联系人企业字段）',
  remark             VARCHAR(512)  DEFAULT NULL COMMENT '员工备注文本；手机号/姓名线索来源',
  tag_ids            JSON          NOT NULL COMMENT '企微标签ID列表（去重，无标签为空数组）',
  first_add_time     DATETIME      NOT NULL COMMENT '本站点首次添加时间，创建后不变更',

  -- ---------- 映射与匹配状态 ----------
  crm_contact_id     VARCHAR(64)   DEFAULT NULL COMMENT '关联CRM联系人ID；仅confirmed或unionid自动匹配时非空',
  match_status       VARCHAR(16)   NOT NULL COMMENT '匹配状态枚举',
  last_synced_at     DATETIME      NOT NULL COMMENT '最近一次与企微/CRM对齐时间',

  -- ---------- 审计字段 ----------
  match_evidence     JSON          DEFAULT NULL COMMENT '匹配证据：候选列表/来源级别/相似度分/脱敏手机号/确认人/确认时间',
  created_at         DATETIME      NOT NULL COMMENT '审计：创建时间',
  created_by         VARCHAR(64)   NOT NULL COMMENT '审计：创建操作者（系统或员工userid）',
  updated_at         DATETIME      NOT NULL COMMENT '审计：最近更新时间',
  updated_by         VARCHAR(64)   NOT NULL COMMENT '审计：最近更新操作者',
  version            INT           NOT NULL DEFAULT 0 COMMENT '审计：乐观锁版本号',
  is_deleted         TINYINT       NOT NULL DEFAULT 0 COMMENT '审计：软删除标记 0正常 / 1已删除',

  PRIMARY KEY (id),

  -- ---------- 唯一约束 ----------
  UNIQUE KEY uk_org_site_external (org_id, site_id, external_userid),

  -- ---------- 普通索引 ----------
  KEY idx_org_site_status (org_id, site_id, match_status),
  KEY idx_org_site_crm (org_id, site_id, crm_contact_id),
  KEY idx_org_site_unionid (org_id, site_id, unionid),
  KEY idx_deleted_synced (is_deleted, last_synced_at),

  -- ---------- 检查约束 ----------
  CONSTRAINT chk_match_status
    CHECK (match_status IN ('unmatched','suggested','confirmed','conflict','ignored')),

  CONSTRAINT chk_confirmed_has_crm
    CHECK (match_status <> 'confirmed' OR crm_contact_id IS NOT NULL),

  CONSTRAINT chk_nonconfirmed_no_crm
    CHECK (match_status = 'confirmed' OR crm_contact_id IS NULL),

  CONSTRAINT chk_is_deleted
    CHECK (is_deleted IN (0,1))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '企微外部联系人与CRM联系人映射表';

-- =====================================================================
-- 说明（不落为 SQL 的业务规则，供评审）：
-- 1. org_id + site_id + external_userid 为业务唯一键，同一客户在站点内只一行；
--    多员工添加通过 follow_userids 表达，不新建重复行。
-- 2. match_status 语义：
--      unmatched  未匹配到候选；
--      suggested  有候选待员工确认（crm_contact_id 必须为空）；
--      confirmed  已确认关联（crm_contact_id 必须非空）；
--      conflict   多候选/互斥证据待人工裁决；
--      ignored    员工忽略，不再自动提示。
-- 3. 自动合并边界：只有 unionid 精确匹配且绑定唯一时，系统可自动写
--    crm_contact_id 并置 confirmed；手机号与相似度匹配只写 suggested，
--    所有 suggested 必须员工显式确认后才可合并，系统绝不自动合并。
-- 4. confirmed / ignored 状态在客户编辑回调中不因资料变化而自动重算或改写。
-- 5. 客户删除且无剩余跟进员工时置 is_deleted=1（软删除），保留 24 个月后清除。
-- 6. match_evidence 中手机号须脱敏（前3后4，中间★），不保存 CRM 联系人姓名/手机号副本。
-- =====================================================================
