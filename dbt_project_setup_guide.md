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
| **Date spine** | `mart_agent_throughput` is zero-filled via `int_date_spine`. Other marts are not spine-filled (their grains are multi-dimensional). |
| **Date range** | Dynamically bounded by `MIN(ticket_date)` to `MAX(ticket_date)`. Currently 2016-01-01 through 2020-12-31. Auto-extends with new data. |
| **Labels in marts** | Only corrected display labels appear. Raw/misspelled source labels are confined to staging and dims. |
| **Additive measures only** | Marts expose counts and sums only — no pre-computed percentages. Rates must be calculated downstream as `100 * SUM(numerator) / NULLIF(SUM(denominator), 0)`. This ensures correct results under any filter or roll-up. |

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
| `ticket_count` | Tickets in this combination (additive) |

**Grain:** One row per (severity, priority, is_resolved).
**Hex usage:** Filter `WHERE is_resolved = FALSE` for open-ticket view. Calculate pct downstream: `100.0 * ticket_count / NULLIF(SUM(ticket_count) OVER (), 0)`.

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
| `p75_resolution_days` | 75th percentile |
| `p95_resolution_days` | 95th percentile |

**Grain:** One row per (issue_type, request_category) — 8 rows total.
**Assumptions:** Calendar days, not business days. Median is primary (skew-resistant). Percentiles are **not reaggregatable** — consume at this grain only.

---

### KPI 4: SLA Compliance Rate

**Model:** `mart_sla_compliance`
**Business question:** What % of tickets meet the 3-day SLA, drillable by category and severity?

| Column | Description |
|--------|-------------|
| `month_start` | First day of month |
| `issue_type` | IT Request or IT Error |
| `request_category` | System, Hardware, Login Access, Software |
| `severity` | Corrected display label |
| `severity_tier` | Business tier |
| `severity_sort` | Numeric sort key (0–4) |
| `sla_target_days` | Always 3 — exposed for downstream parameterization |
| `resolved_ticket_count` | Total resolved at this grain (denominator) |
| `tickets_within_sla` | Resolved in ≤ 3 days (numerator) |
| `tickets_breached_sla` | Resolved in > 3 days |

**Grain:** One row per (month_start, issue_type, request_category, severity_tier).
**Assumptions:** SLA = ≤ 3 calendar days. Exactly 3 days = compliant.
**Hex usage:** Roll up with `SUM()` for any slice: `100 * SUM(tickets_within_sla) / NULLIF(SUM(resolved_ticket_count), 0)`.

---

### KPI 5: CSAT by Request Category

**Model:** `mart_csat_by_category`
**Business question:** Which service areas have the happiest/unhappiest users?

| Column | Description |
|--------|-------------|
| `request_category` | System, Hardware, Login Access, Software |
| `responses` | Tickets with a satisfaction rating (denominator) |
| `csat_points_sum` | SUM(satisfaction_rate) — divide by responses for exact avg |
| `avg_csat` | Mean score at this grain (1–5) — use csat_points_sum for roll-ups |
| `promoters` | Count of scores ≥ 4 (numerator for promoter share) |
| `detractors` | Count of scores ≤ 2 |

**Grain:** One row per request_category. All-time aggregate.
**Hex usage:** Overall CSAT = `SUM(csat_points_sum) / NULLIF(SUM(responses), 0)`. Promoter share = `100 * SUM(promoters) / NULLIF(SUM(responses), 0)`.

---

### KPI 6: First-Week Resolution Rate

**Model:** `mart_first_week_resolution_rate`
**Business question:** What % of tickets are resolved within 7 days, drillable by category and severity?

| Column | Description |
|--------|-------------|
| `month_start` | First day of month |
| `request_category` | System, Hardware, Login Access, Software |
| `severity` | Corrected display label |
| `severity_tier` | Business tier |
| `severity_sort` | Numeric sort key (0–4) |
| `total_resolved` | All resolved tickets at this grain (denominator) |
| `resolved_within_7_days` | Resolved in ≤ 7 days (numerator) |

**Grain:** One row per (month_start, request_category, severity_tier).
**Hex usage:** Roll up with `SUM()`: `100 * SUM(resolved_within_7_days) / NULLIF(SUM(total_resolved), 0)`.

---

## Intermediate Layer

### int_date_spine

Generates every ISO week from `MIN(ticket_date)` to `MAX(ticket_date)` using Snowflake's `ARRAY_GENERATE_RANGE`. Also derives `month_start`. Materialized as a view (no storage cost). Used by `mart_agent_throughput` for zero-filled dense output.

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

Marts expose additive measures. Calculate rates downstream:

```sql
-- Overall SLA compliance
SELECT month_start,
       100 * SUM(tickets_within_sla) / NULLIF(SUM(resolved_ticket_count), 0) AS sla_pct
FROM DEV_MARTS.IT_HELPDESK.MART_SLA_COMPLIANCE
GROUP BY 1 ORDER BY 1;

-- First-week rate by severity
SELECT month_start, severity_tier,
       100 * SUM(resolved_within_7_days) / NULLIF(SUM(total_resolved), 0) AS first_week_pct
FROM DEV_MARTS.IT_HELPDESK.MART_FIRST_WEEK_RESOLUTION_RATE
GROUP BY 1, 2;

-- Ticket mix with computed pct
SELECT severity, priority, ticket_count,
       100.0 * ticket_count / NULLIF(SUM(ticket_count) OVER (), 0) AS pct_of_total
FROM DEV_MARTS.IT_HELPDESK.MART_TICKET_MIX
WHERE is_resolved = TRUE;
```

Use Hex input parameters (dropdowns) bound to `WHERE` clauses for interactive filtering (e.g., `is_resolved`, date ranges, severity_tier, request_category).

### Schema Discoverability

`persist_docs` is enabled — all model and column descriptions from `_schema.yml` appear as Snowflake `COMMENT` metadata, visible in Hex's schema browser without referencing the dbt project.

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| One model per KPI | Each mart answers one business question — easy to reason about, test, and document |
| Additive measures only | No pre-computed percentages — rates calculated downstream so filters/roll-ups are always correct |
| Multi-dimensional grains | SLA and first-week marts sliceable by severity/category without re-querying staging |
| Dense agent throughput | Date spine on the single agent×week mart; other marts don't need it (no expected gaps given their granularity) |
| Percentiles not reaggregatable | Resolution time mart is consumed at grain only — noted in docs to prevent incorrect roll-ups |
| Display labels only in marts | Raw source typos confined to staging/dims — consumers never see them |
| Canonical dims as tables | Materialized for join performance; persist_docs makes mappings discoverable in Hex |
| persist_docs enabled | Column descriptions visible in BI tool schema browsers without dbt project access |
| Separate Hex warehouse | Isolates BI query cost from dbt build cost; straightforward chargeback |
| Read-only Hex role | Principle of least privilege — Hex can never modify mart data |
| Dedicated service users | Fivetran, dbt, and Hex each have their own user/role/warehouse for audit and isolation |
| SQL in Setup.sql | Single executable reference file; docs cross-reference without bloat |
