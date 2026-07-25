# IT Helpdesk dbt Project Setup Guide

## Architecture Overview

```
DEV_SOURCE.IT_HELPDESK     → Raw data (Fivetran-ingested)
DEV_STAGE.IT_HELPDESK      → Staging models (views) + intermediate utilities
DEV_MARTS.IT_HELPDESK      → Dims + Mart models (tables, business logic)
```

**Roles:**
- `FIVETRAN` — ingestion service account, uses `FIVETRAN_WH`
- `DBT_DEVELOPER` — interactive development, uses `DBT_DEVELOPMENT_WH`
- `DBT_SERVICE` — scheduled production runs, uses `COMPUTE_WH`
- `HEX_READER` — read-only BI access, uses `HEX_WH`

**Warehouse isolation:**
- `COMPUTE_WH` — reserved for dbt production jobs only
- `HEX_WH` — dedicated to Hex queries (XS, auto-suspend 60s)

> **All SQL setup commands are in [`Setup.sql`](Setup.sql)**, organized by section. This guide explains the *what* and *why*; `Setup.sql` has the executable *how*.

---

## Step 1: Source Data Setup (Fivetran)

**See:** `Setup.sql` → Section 1

Fivetran ingests from a Google Sheets source into `DEV_SOURCE.IT_HELPDESK` with two tables:
- `TICKETS` — 97,498 rows of IT support tickets
- `AGENTS` — 50 support agents

Key decisions:
- Fivetran gets its own role + warehouse for least-privilege and cost isolation
- Key-pair auth (no password) on a `SERVICE` type user
- Future table grants ensure new Fivetran-created tables are immediately accessible

---

## Step 2: dbt Infrastructure

**See:** `Setup.sql` → Sections 2–3

Creates the target databases (`DEV_STAGE`, `DEV_MARTS`), roles, and grants. The `DBT_DEVELOPER` role has full schema-level access to both targets; `DBT_SERVICE` mirrors this for production.

---

## Step 3: GitHub Integration

**See:** `Setup.sql` → Section 4

Uses Snowflake's native GitHub App integration for Snowsight Workspaces. After creating the API integration:
1. Go to **Projects > Workspaces**
2. Click **+ > From Git repository**
3. Paste your repo URL
4. Select `GIT_API_INTEGRATION` and authenticate

---

## Step 4: dbt Project Structure

### File Structure

```
it_helpdesk/
├── dbt_project.yml
├── profiles.yml
├── macros/
│   ├── generate_schema_name.sql
│   ├── test_matches_email_format.sql
│   ├── test_valid_date_of_birth.sql
│   ├── test_valid_level_label_pairs.sql
│   ├── test_not_in_future.sql
│   └── test_non_negative.sql
└── models/
    ├── sources.yml
    ├── staging/
    │   ├── stg_agents.sql
    │   ├── stg_agents.yml
    │   ├── stg_tickets.sql
    │   └── stg_tickets.yml
    ├── intermediate/
    │   ├── int_date_spine.sql
    │   └── _schema.yml
    ├── dims/
    │   ├── dim_severity.sql
    │   ├── dim_priority.sql
    │   └── _schema.yml
    └── marts/
        ├── _schema.yml
        ├── mart_ticket_mix.sql
        ├── mart_agent_throughput.sql
        ├── mart_resolution_time.sql
        ├── mart_sla_compliance.sql
        ├── mart_csat_by_category.sql
        ├── mart_backlog_trend.sql
        └── mart_first_week_resolution_rate.sql
```

### Layer Responsibilities

| Layer | Materialization | Database | Purpose |
|-------|----------------|----------|---------|
| `staging/` | View | DEV_STAGE | Light renaming, type casting, no business logic |
| `intermediate/` | View | DEV_STAGE | Reusable utilities (date spine) — not consumer-facing |
| `dims/` | Table | DEV_MARTS | Canonical dimensions with corrected labels and business mappings |
| `marts/` | Table | DEV_MARTS | Pre-aggregated KPI tables, one per business question |

### Key dbt Configuration

- **`persist_docs`** enabled on `dims/` and `marts/` — model and column descriptions from `_schema.yml` are written as Snowflake `COMMENT` metadata, visible in Hex's schema browser
- **Source freshness** — `sources.yml` defines `warn_after: 24h`, `error_after: 72h` on `_fivetran_synced`
- **dbt exposure** — `it_helpdesk_operations_dashboard` declared in `marts/_schema.yml` tracks the Hex dependency

---

## Canonical Dimensions

### dim_severity

Maps raw source severity labels (which contain typos) to clean display labels and business tiers.

| sort_key | raw_label | display_label | business_tier |
|----------|-----------|---------------|---------------|
| 0 | Unclasified | Unclassified | Unknown |
| 1 | Minor | Minor | Low |
| 2 | Normal | Normal | Medium |
| 3 | Mayor | Major | High |
| 4 | Urgent | Urgent | Critical |

### dim_priority

Maps raw source priority labels to clean display labels, P-codes, and business tiers.

| sort_key | raw_label | display_label | p_code | business_tier |
|----------|-----------|---------------|--------|---------------|
| 0 | Unassiged | Unassigned | P4 | Unassigned |
| 1 | Low | Low | P3 | Low |
| 2 | Mid | Medium | P2 | Medium |
| 3 | High | High | P1 | High |

**Design decisions:**
- Raw labels preserved in dims for traceability but **never exposed in marts**
- Marts only show `display_label` (as `severity`/`priority`), `business_tier`, `p_code`, and `sort_key`
- P-codes: P1 = highest priority, P4 = lowest (unassigned)

---

## Mart Layer: KPI Definitions & Assumptions

### Global Assumptions

| Assumption | Definition |
|------------|------------|
| **Resolved ticket** | `resolution_days IS NOT NULL`. Tickets with NULL resolution are open/unresolved. |
| **Week** | ISO week via `DATE_TRUNC('week', ticket_date)`. Week starts on Monday. |
| **Month** | Calendar month via `DATE_TRUNC('month', ticket_date)`. |
| **Date spine** | All time-series marts are zero-filled using `int_date_spine`. Periods with no activity show as 0, not as missing rows. |
| **Date range** | Dynamically bounded by `MIN(ticket_date)` to `MAX(ticket_date)`. Currently 2016-01-01 through 2020-12-31. Auto-extends with new data. |
| **Labels in marts** | Only corrected display labels appear. Raw/misspelled source labels are confined to staging and dims. |

---

### KPI 1: Ticket Mix by Severity & Priority

**Model:** `mart_ticket_mix`
**Business question:** What is the workload risk profile across the severity/priority matrix?

| Column | Description |
|--------|-------------|
| `severity` | Corrected display label (Unclassified, Minor, Normal, Major, Urgent) |
| `severity_tier` | Business tier (Unknown, Low, Medium, High, Critical) |
| `severity_sort` | Numeric key (0–4) for chart ordering |
| `priority` | Corrected display label (Unassigned, Low, Medium, High) |
| `priority_code` | P-code (P1=High, P2=Medium, P3=Low, P4=Unassigned) |
| `priority_tier` | Business tier |
| `priority_sort` | Numeric key (0–3) for chart ordering |
| `is_resolved` | TRUE = closed, FALSE = open — use as filter in Hex |
| `ticket_count` | Tickets in this combination |
| `pct_of_total` | Percentage of all tickets |

**Grain:** One row per (severity, priority, is_resolved).
**Hex usage:** Filter `WHERE is_resolved = FALSE` for open-ticket view; omit filter for all tickets.

---

### KPI 2: Tickets Resolved per Agent per Week

**Model:** `mart_agent_throughput`
**Business question:** How productive is each agent over time?

| Column | Description |
|--------|-------------|
| `agent_id` | Agent identifier |
| `agent_name` | Full name (derived from email) |
| `week_start` | Monday of the ISO week |
| `tickets_resolved` | Count resolved that week (0 if none) |

**Grain:** One row per (agent, week). Dense — every agent has a row for every week.
**Assumptions:** Week assigned by `ticket_date` (open date), not actual closure date.

---

### KPI 3: Median Resolution Time by Issue Type

**Model:** `mart_resolution_time`
**Business question:** Which categories are slowest to resolve?

| Column | Description |
|--------|-------------|
| `issue_type` | Top-level: IT Request, IT Error |
| `request_category` | Sub-category: System, Hardware, Login Access, Software |
| `tickets_resolved` | Total resolved tickets |
| `median_resolution_days` | Median calendar days to resolve |
| `avg_resolution_days` | Mean calendar days |
| `p75_resolution_days` | 75th percentile |
| `p95_resolution_days` | 95th percentile |
| `min_resolution_days` | Fastest resolution |
| `max_resolution_days` | Slowest resolution |

**Grain:** One row per (issue_type, request_category) — 8 rows total.
**Assumptions:** Calendar days, not business days. Median is primary (skew-resistant).

---

### KPI 4: SLA Compliance Rate

**Model:** `mart_sla_compliance`
**Business question:** What % of tickets meet the 3-day SLA, trending over time?

| Column | Description |
|--------|-------------|
| `issue_type` | Issue category |
| `month_start` | First day of month |
| `sla_target_days` | Always 3 — exposed for downstream parameterization |
| `resolved_ticket_count` | Resolved tickets in this cell |
| `tickets_within_sla` | Resolved in ≤ 3 days (boundary-inclusive) |
| `tickets_breached_sla` | Resolved in > 3 days |
| `sla_compliance_pct` | % meeting SLA (NULL if no resolved tickets) |
| `weighted_sla_compliance_pct` | Contribution to overall monthly compliance |

**Grain:** One row per (issue_type, month). Dense.
**Assumptions:** SLA = ≤ 3 calendar days. Exactly 3 days = compliant. NULL pct for empty periods (not 0% or 100%).

---

### KPI 5: Average CSAT by Request Category

**Model:** `mart_csat_by_category`
**Business question:** Which service areas have the happiest/unhappiest users?

| Column | Description |
|--------|-------------|
| `request_category` | System, Hardware, Login Access, Software |
| `responses` | Tickets with a satisfaction rating |
| `avg_csat` | Mean score (1–5 scale) |
| `promoters` | Count of scores ≥ 4 |
| `detractors` | Count of scores ≤ 2 |
| `pct_promoters` | % scoring 4 or 5 |

**Grain:** One row per request_category. All-time aggregate.

---

### KPI 6: Backlog Trend

**Model:** `mart_backlog_trend`
**Business question:** Is the team keeping up or falling behind?

| Column | Description |
|--------|-------------|
| `week_start` | Monday of the ISO week |
| `severity` | Corrected display label |
| `severity_tier` | Business tier |
| `severity_sort` | Numeric key for ordering |
| `tickets_opened` | Opened that week (0 if none) |
| `tickets_resolved` | Resolved that week (0 if none) |
| `net_new_backlog` | opened − resolved (positive = falling behind) |
| `cumulative_backlog` | Running sum within each severity |

**Grain:** One row per (week, severity). Dense.
**Assumptions:** Both opened/resolved attributed to `ticket_date`. Cumulative can go negative (team catching up).

---

### KPI 7: First-Week Resolution Rate

**Model:** `mart_first_week_resolution_rate`
**Business question:** What % of tickets are resolved within 7 days?

| Column | Description |
|--------|-------------|
| `month_start` | First day of month |
| `total_resolved` | All resolved tickets that month |
| `resolved_within_7_days` | Resolved in ≤ 7 days |
| `first_week_resolution_pct` | Percentage (NULL if no resolutions) |

**Grain:** One row per month. Dense.

---

## Intermediate Layer

### int_date_spine

Generates every ISO week from `MIN(ticket_date)` to `MAX(ticket_date)` using Snowflake's `ARRAY_GENERATE_RANGE`. Also derives `month_start`. Materialized as a view (no storage cost). Used by all four time-series marts to cross-join with dimension values and produce zero-filled dense output.

The spine is dynamic — extends automatically as new ticket data arrives.

---

## Hex Integration

**See:** `Setup.sql` → Section 5

### Connection Settings

| Setting | Value |
|---------|-------|
| Account | `ztc28823` |
| Username | `HEX` (service user, key-pair auth) |
| Role | `HEX_READER` |
| Warehouse | `HEX_WH` (XS, auto-suspend 60s) |
| Database | `DEV_MARTS` |
| Schema | `IT_HELPDESK` |

### Key-Pair Generation

```bash
# Run on your local machine (NOT in Snowflake)
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out hex_rsa_key.p8 -nocrypt
openssl rsa -in hex_rsa_key.p8 -pubout -out hex_rsa_key.pub
```

Then apply via `Setup.sql` Section 5d. Upload `hex_rsa_key.p8` to Hex's connection settings.

### Usage in Hex

Each mart is pre-aggregated — `SELECT *` and chart directly:

```sql
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_TICKET_MIX;
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_AGENT_THROUGHPUT WHERE week_start >= '2020-01-01';
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_SLA_COMPLIANCE;
```

Use Hex input parameters (dropdowns) bound to `WHERE` clauses for interactive filtering (e.g., `is_resolved`, date ranges, agent selection).

### Schema Discoverability

`persist_docs` is enabled — all model and column descriptions from `_schema.yml` appear as Snowflake `COMMENT` metadata, visible in Hex's schema browser without referencing the dbt project.

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| One model per KPI | Each mart answers one business question — easy to reason about, test, and document |
| Pre-aggregated grain | Hex consumers do `SELECT *` and chart — no SQL expertise required |
| Dense time-series (date spine) | Eliminates gaps in charts without Hex-side pandas transforms |
| NULL percentages for empty periods | Avoids misleading 0%/100% — Hex chart libraries skip NULLs gracefully |
| Display labels only in marts | Raw source typos confined to staging/dims — consumers never see them |
| Canonical dims as tables | Materialized for join performance; persist_docs makes mappings discoverable in Hex |
| persist_docs enabled | Column descriptions visible in BI tool schema browsers without dbt project access |
| Separate Hex warehouse | Isolates BI query cost from dbt build cost; straightforward chargeback |
| Read-only Hex role | Principle of least privilege — Hex can never modify mart data |
| Dedicated service users | Fivetran, dbt, and Hex each have their own user/role/warehouse for audit and isolation |
| SQL in Setup.sql | Single executable reference file; docs cross-reference without bloat |
