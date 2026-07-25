# IT Helpdesk Analytics

An end-to-end pipeline that takes raw IT helpdesk ticket and agent data and turns it into a set of scalable, decision-ready KPIs — from ingestion (Fivetran) through transformation (dbt/Snowflake) to visualization (Hex).

**Hex dashboard:** [IT Helpdesk Operations](https://app.hex.tech/019f9a8a-9021-7358-8165-b7d0ba4d6fc9/app/IT-Helpdesk-Operations-033vlcxkClI8JKC0WSEXF7/latest)

---

## Stack

| Layer | Tool |
|-------|------|
| Warehouse | Snowflake |
| ELT | Fivetran |
| Transform | dbt |
| Notebook/BI | Hex |

## Architecture

```
DEV_SOURCE.IT_HELPDESK     → Raw data (Fivetran-ingested)
DEV_STAGE.IT_HELPDESK      → Staging models (views) + intermediate utilities
DEV_MARTS.IT_HELPDESK      → Dims + Mart models (tables, business logic)
```

Data flows staging (light typing/renaming) → canonical dims (severity/priority label cleanup + business tiers) → marts (one table per KPI, additive measures only — counts and sums, never pre-computed percentages, so rates stay correct under any filter or roll-up in Hex).

Each of the four roles involved (Fivetran, dbt dev, dbt scheduled runs, Hex) gets its own Snowflake role/warehouse for least-privilege access and clean cost isolation.

Full layer-by-layer breakdown, column-level docs, and design rationale: **[detailed_project_setup_guide.md](detailed_project_setup_guide.md)**.

## Setup Steps

1. **Warehouse/roles/grants** — run [`Setup.sql`](Setup.sql) top to bottom as `ACCOUNTADMIN` (fresh setup; sections are dependency-ordered). This provisions the Fivetran, dbt, and Hex roles/warehouses/databases.
2. **Ingest source data** — connect Fivetran to the Google Sheets source; it lands `TICKETS` (97,498 rows) and `AGENTS` (50 rows) into `DEV_SOURCE.IT_HELPDESK`.
3. **Run dbt** — `dbt run` from `it_helpdesk/` builds staging → dims → marts in `DEV_STAGE`/`DEV_MARTS`. `dbt test` runs schema + custom data tests (uniqueness, accepted values, non-negativity, numerator ≤ denominator, etc.).
4. **Connect Hex** — point a Hex connection at `DEV_MARTS.IT_HELPDESK` using the `HEX_READER` role/`HEX_WH` warehouse (key-pair auth; see `Setup.sql` Section 5). Marts are pre-aggregated, so Hex mostly does `SELECT *` plus a downstream rate calculation.

## Key Assumptions

- **Resolved ticket** — `resolution_days IS NOT NULL`; NULL means still open.
- **Week** — ISO week (`DATE_TRUNC('week', ticket_date)`), Monday start.
- **Additive measures only** — marts expose counts/sums, not pre-computed rates, so any downstream filter or roll-up stays accurate.
- **Raw label typos** (e.g. "Mayor" → Major, "Unclasified" → Unclassified, "Unassiged" → Unassigned, "Mid" → Medium) are corrected in canonical dims; only clean display labels ever reach the marts.
- **Date range** is dynamic (`MIN`/`MAX(ticket_date)`), currently 2016-01-01 through 2020-12-31, and auto-extends as new data lands.
- Full assumption list (including the SLA/first-week windows below): see the setup guide.

## KPIs

Across the full dataset (Dec 2015 – Nov 2020): **97.5K resolved tickets**, **50 agents**.

**Required:**

| KPI | Model | Definition | Headline result |
|-----|-------|------------|------------------|
| Ticket mix by severity & priority | `mart_ticket_mix` | Workload risk profile across severity × priority × resolution status | "Normal" severity dominates volume (~88.6K of 97.5K); Urgent/P1 tickets are a small slice (612) |
| Tickets resolved per agent per week | `mart_agent_throughput` | Weekly per-agent throughput, zero-filled via a date spine | Throughput is highly consistent across the team — top agent averages 7.74 tickets/week, and even the lowest-ranked agent still closes ~7.08/week |
| Median resolution time by issue type | `mart_resolution_time` | Median/p75/p95 calendar days to resolve, by issue type × category | Hardware (IT Request) is slowest at a 9-day median; Login Access resolves same-day (0-day median) for both issue types |
| SLA compliance rate (≤ 3 days) | `mart_sla_compliance` | % resolved within 3 calendar days, by month/category/severity | **48.2% overall** (47K within SLA, 50.5K breached) — consistent with several categories having medians above the 3-day target, not a data issue |

**Self-selected:**

| KPI | Model | Definition | Headline result |
|-----|-------|------------|------------------|
| CSAT by request category | `mart_csat_by_category` | Average satisfaction score and promoter/detractor split per category | 4.10/5 overall, tightly clustered (4.09–4.11) across categories — presented as an overall metric rather than a category comparison since the spread isn't meaningful |
| First-week resolution rate | `mart_first_week_resolution_rate` | % resolved within 7 calendar days, by month/category/severity | 77.0% overall (75.1K of 97.5K), stable month over month |

*(A backlog-trend KPI was explored and removed — see "Backlog Trend (Not Included)" in the setup guide for why.)*

### Notable Patterns

- **SLA compliance is low, but satisfaction isn't.** Only 48.2% of tickets are resolved within the 3-day SLA, yet overall CSAT sits at 4.10/5. Resolution speed and satisfaction aren't tightly coupled here — worth digging into further (e.g., whether users rate based on outcome quality rather than speed) before treating SLA as the primary lever for satisfaction.
- **Agent productivity is remarkably consistent.** Weekly throughput ranges narrowly from ~7.08 (lowest-ranked agent) to 7.74 tickets/week (top agent) across all 50 agents — no clear outliers or underperformers, suggesting ticket assignment/workload is well-balanced rather than concentrated on a few agents.

## Data Quality

dbt schema tests cover not-null, uniqueness at each mart's grain, accepted values on categorical fields, non-negativity on measures, and a custom `numerator_lte_denominator` test on every rate's numerator/denominator pair. Source freshness is checked on `_fivetran_synced` (warn at 24h, error at 72h).

## Next Steps

**Technical:**
1. Set up prod schemas and a proper deployment process in Snowflake/dbt (separate from the dev setup in `Setup.sql`).
2. Schedule the dbt job to run on a frequency aligned with how often the source data actually updates.
3. Move to schema-level role-based access control — read/write access roles per schema, granted to functional roles/service accounts, rather than grants sitting directly on users/accounts.

**Business/process:**
4. Investigate what's driving the volume of Unassigned-priority / Unclassified-severity tickets, and consider adding a submission control on the helpdesk side so tickets can't go in without these fields set.
5. Revisit the SLA policy with severity-differentiated targets — Minor-severity tickets currently show *higher* SLA compliance than Urgent ones, which suggests a single flat 3-day SLA isn't helping agents prioritize the tickets that matter most.
6. Consider morale-boosting incentives (team lunches, happy hours, etc.) tied to *positive* recognition rather than call-outs — e.g., a leaderboard/shoutout for agents with the most SLA-compliant closures (once SLA is realigned by severity) or the highest average CSAT, rather than one for lowest performers.

## Hours Spent

**4.5 hours total**

| Phase | Time |
|-------|------|
| Fivetran and Snowflake setup, source ingestion | 1 hour |
| dbt project initialization, staging layer, and initial metric buildout | 1.5 hours |
| Hex setup, initial buildout, iteration on metrics based on findings, finalizing dashboard | 2 hours |

## Repo Contents

- `it_helpdesk/` — the dbt project (models, macros, config)
- `Setup.sql` — all Snowflake setup commands, in order
- `detailed_project_setup_guide.md` — full technical reference: column-level KPI docs, canonical dimension mappings, Hex connection details, and design-decision rationale
