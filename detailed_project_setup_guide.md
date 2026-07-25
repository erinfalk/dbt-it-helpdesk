# IT Helpdesk Analytics - Detailed End-to-End Project Setup Guide

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

*(Optional dev convenience, not required for the pipeline itself: Snowflake's native GitHub App integration lets you browse/run this repo directly from Snowsight Workspaces — `Setup.sql` Section 4 has the one-time API integration setup.)*

---

## Step 3: dbt Project Structure

### File Structure

```
it_helpdesk/
├── dbt_project.yml
├── profiles.yml
├── macros/
│   ├── generate_schema_name.sql
│   ├── test_matches_email_format.sql
│   ├── test_non_negative.sql
│   ├── test_not_in_future.sql
│   ├── test_numerator_lte_denominator.sql
│   ├── test_valid_date_of_birth.sql
│   └── test_valid_level_label_pairs.sql
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
        └── mart_first_week_resolution_rate.sql
```

### Layer Responsibilities

| Layer | Materialization | Database | Purpose |
|-------|----------------|----------|---------|
| `staging/` | View | DEV_STAGE | Light renaming, type casting, no business logic |
| `intermediate/` | View | DEV_STAGE | Reusable utilities (date spine) — not consumer-facing |
| `dims/` | Table | DEV_MARTS | Canonical dimensions with corrected labels and business mappings |
| `marts/` | Table | DEV_MARTS | KPI tables with additive measures (counts/sums only, no pre-computed rates) |

### Key dbt Configuration

- **`persist_docs`** enabled on `dims/` and `marts/` — model and column descriptions from `_schema.yml` are written as Snowflake `COMMENT` metadata, visible in Hex's schema browser
- **Source freshness** — `sources.yml` defines `warn_after: 24h`, `error_after: 72h` on `_fivetran_synced`
- **dbt exposure** — `it_helpdesk_operations_dashboard` declared in `marts/_schema.yml` tracks the Hex dependency
- **`generate_schema_name` macro** — overridden so custom schemas (`DEV_STAGE`, `DEV_MARTS`) are used exactly as configured, without dbt's default `<target>_<custom_schema>` prefixing

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

## Testing Strategy

Beyond standard dbt tests (`unique`, `not_null`, `accepted_values`, `relationships`), the project defines custom generic tests in `macros/` for checks that come up more than once:

| Test | Checks | Used on |
|------|--------|---------|
| `non_negative` | Column value is not < 0 | `resolution_days`, all mart count/sum measures |
| `not_in_future` | Date column is not after `current_date()` | `ticket_date` |
| `numerator_lte_denominator` | One column doesn't exceed another (e.g. a rate's numerator vs. denominator) | SLA/first-week/CSAT numerator columns against their denominators |
| `valid_level_label_pairs` | A numeric level and its text label always co-occur as one of a fixed set of pairs (catches new/unexpected raw label variants) | `stg_tickets.priority_label`, `stg_tickets.severity_label` |
| `matches_email_format` | Column matches `firstname.lastname@<domain>` | `stg_agents.email` |
| `valid_date_of_birth` | `year_of_birth`/`month_of_birth`/`day_of_birth` combine into a real calendar date | `stg_agents` |

Tests run at the layer where a problem is cheapest to catch: raw label typos and malformed fields are caught in staging (before they can propagate), and rate-consistency checks (numerator ≤ denominator) run in the marts where those rates are computed.

> Note: `valid_date_of_birth` is attached to the `agent_id` column rather than one of the birth-date columns. This is deliberate: the macro's failing-rows query selects whatever column it's attached to, so attaching it to `agent_id` means a test failure surfaces *which agent* has the malformed birthdate — the actionable info for troubleshooting — rather than just an orphaned year/month/day value with no way to trace it back to a specific record.

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
**Assumptions:** Resolution attributed to closure week (`ticket_date + resolution_days`), not the open date.

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
| Account | `<your_account_locator>` |
| Username | `HEX` (service user, key-pair auth) |
| Role | `HEX_READER` |
| Warehouse | `HEX_WH` (XS, auto-suspend 60s) |
| Database | `DEV_MARTS` |
| Schema | `IT_HELPDESK` |

### Key-Pair Generation

Key pair is generated locally (not in Snowflake) and applied via `Setup.sql` Section 5d — see the inline comment there for the exact `openssl` commands. Upload `hex_rsa_key.p8` to Hex's connection settings.

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

## Hex Dashboard: IT Helpdesk Operations

A shareable Hex Generative app was built on top of the dbt marts, published for public viewing (see the link at the top of the README).

### KPI Views

**1. Ticket mix by severity and priority**
- Heatmap of ticket counts by canonical severity (Critical → Unknown) and priority (P1 High → P4 Unassigned).
- Notebook input toggles All / Open / Resolved. The current dataset contains no open tickets, so the Open view is empty — retained because it would be operationally important with live data.
- Percentages are calculated in Hex from additive ticket counts within the active filter context.

**2. Tickets resolved per agent**
- Weekly agent throughput at the agent_id × week_start grain (attributed to closure week).
- Agents ranked highest to lowest by total tickets resolved across the full period.
- Total resolved, rank, and weekly averages are presentation-level aggregations calculated in the notebook.

**3. Resolution time by issue type and request category**
- Uses the issue_type × request_category grain (8 rows).
- Median is the primary measure (right-skew resistant). P75 and P95 show the slower tail.

**4. SLA compliance**
- Defined as resolved within 3 calendar days (boundary-inclusive: exactly 3 days = compliant).
- Hex calculates: `100 * SUM(tickets_within_sla) / SUM(resolved_ticket_count)`.
- Default view: overall monthly trend. Optional breakouts by request category and severity.
- Category identifies work types causing breaches; severity shows whether high-risk tickets receive appropriate service.

**5. Customer satisfaction**
- Overall CSAT: `SUM(csat_points_sum) / SUM(responses)`.
- Share rating 4–5: `100 * SUM(promoters) / SUM(responses)`.
- CSAT averages vary negligibly across request categories, so CSAT is presented as an overall outcome KPI rather than a category comparison.
- Response count retained to communicate sample size.

**6. First-week resolution**
- Defined as resolved within 7 calendar days.
- Hex calculates: `100 * SUM(resolved_within_7_days) / SUM(total_resolved)`.
- Default view: overall monthly trend. Request-category breakout is the more diagnostic dimension (reveals structural complexity differences). Severity breakout also available.

### Dashboard Design Principles

- Overall trends shown by default; breakouts exposed through interactive controls to avoid cluttered multi-series charts.
- All rates calculated from additive counts in Hex, ensuring correct totals under any filter combination.
- Labels, units, tooltips, and calendar-day definitions retained where they help interpretation.
- Canonical display labels, P-codes, tiers, and sort keys come from dbt (stable business definitions, not presentation logic).

---

## Design Decisions

Most design choices are explained in context above (canonical dims, testing, Hex integration). A few don't have an obvious home elsewhere:

| Decision | Rationale |
|----------|-----------|
| One model per KPI | Each mart answers one business question — easy to reason about, test, and document |
| Multi-dimensional grains | SLA and first-week marts sliceable by severity/category without re-querying staging |
| Percentiles not reaggregatable | Resolution time mart is consumed at grain only — noted in docs to prevent incorrect roll-ups |
