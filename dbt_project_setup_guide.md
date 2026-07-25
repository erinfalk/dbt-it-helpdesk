# IT Helpdesk dbt Project Setup Guide

## Architecture Overview

```
DEV_SOURCE.IT_HELPDESK     → Raw data (Fivetran-ingested)
DEV_STAGE.IT_HELPDESK      → Staging models (views, light cleanup/renaming)
DEV_MARTS.IT_HELPDESK      → Mart models (tables, business logic)
```

**Roles:**
- `DBT_DEVELOPER` — interactive development, uses `DBT_DEVELOPMENT_WH`
- `DBT_SERVICE` — scheduled production runs, uses `COMPUTE_WH`

---

## Step 1: Source Data Setup (Fivetran)

```sql
USE ROLE ACCOUNTADMIN;

-- Create dedicated Fivetran role
CREATE ROLE IF NOT EXISTS FIVETRAN
  COMMENT = 'Dedicated role for Fivetran';

-- Create Fivetran service user (key-pair auth)
CREATE USER FIVETRAN_SERVICE_ACCOUNT
  TYPE = 'SERVICE'
  RSA_PUBLIC_KEY = '<your-public-key>'
  DEFAULT_ROLE = 'FIVETRAN'
  COMMENT = 'Automated service account for Fivetran';

GRANT ROLE FIVETRAN TO USER FIVETRAN_SERVICE_ACCOUNT;

-- Fivetran warehouse (isolated for cost tracking)
CREATE WAREHOUSE FIVETRAN_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

GRANT USAGE ON WAREHOUSE FIVETRAN_WH TO ROLE FIVETRAN;

-- Source database
CREATE DATABASE DEV_SOURCE;
GRANT USAGE ON DATABASE DEV_SOURCE TO ROLE FIVETRAN;
GRANT CREATE SCHEMA ON DATABASE DEV_SOURCE TO ROLE FIVETRAN;

-- After Fivetran creates the schema and loads data:
GRANT SELECT ON ALL TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE ACCOUNTADMIN;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE ACCOUNTADMIN;
```

---

## Step 2: dbt Infrastructure

```sql
USE ROLE ACCOUNTADMIN;

-- Development role and warehouse
CREATE ROLE IF NOT EXISTS DBT_DEVELOPER
  COMMENT = 'Role for dbt interactive development';

CREATE WAREHOUSE IF NOT EXISTS DBT_DEVELOPMENT_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- Production execution role (uses existing COMPUTE_WH)
CREATE ROLE IF NOT EXISTS DBT_SERVICE
  COMMENT = 'Role for scheduled dbt execution';

-- Target databases and schemas
CREATE DATABASE IF NOT EXISTS DEV_STAGE;
CREATE SCHEMA IF NOT EXISTS DEV_STAGE.IT_HELPDESK;

CREATE DATABASE IF NOT EXISTS DEV_MARTS;
CREATE SCHEMA IF NOT EXISTS DEV_MARTS.IT_HELPDESK;
```

---

## Step 3: Grant Privileges

```sql
-- DBT_DEVELOPER grants
GRANT USAGE ON WAREHOUSE DBT_DEVELOPMENT_WH TO ROLE DBT_DEVELOPER;
GRANT USAGE ON DATABASE DEV_SOURCE TO ROLE DBT_DEVELOPER;
GRANT USAGE ON SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE DBT_DEVELOPER;
GRANT SELECT ON ALL TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE DBT_DEVELOPER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE DBT_DEVELOPER;
GRANT USAGE ON DATABASE DEV_STAGE TO ROLE DBT_DEVELOPER;
GRANT ALL ON SCHEMA DEV_STAGE.IT_HELPDESK TO ROLE DBT_DEVELOPER;
GRANT USAGE ON DATABASE DEV_MARTS TO ROLE DBT_DEVELOPER;
GRANT ALL ON SCHEMA DEV_MARTS.IT_HELPDESK TO ROLE DBT_DEVELOPER;

-- DBT_SERVICE grants
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE DBT_SERVICE;
GRANT USAGE ON DATABASE DEV_SOURCE TO ROLE DBT_SERVICE;
GRANT USAGE ON SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE DBT_SERVICE;
GRANT SELECT ON ALL TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE DBT_SERVICE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE DBT_SERVICE;
GRANT USAGE ON DATABASE DEV_STAGE TO ROLE DBT_SERVICE;
GRANT ALL ON SCHEMA DEV_STAGE.IT_HELPDESK TO ROLE DBT_SERVICE;
GRANT USAGE ON DATABASE DEV_MARTS TO ROLE DBT_SERVICE;
GRANT ALL ON SCHEMA DEV_MARTS.IT_HELPDESK TO ROLE DBT_SERVICE;

-- Grant development role to your user
GRANT ROLE DBT_DEVELOPER TO USER <your_username>;
```

---

## Step 4: GitHub Integration

```sql
-- API integration for Snowflake GitHub App auth
CREATE OR REPLACE API INTEGRATION git_api_integration
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/<your-org-or-user>')
  API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
  ENABLED = TRUE;
```

Then in Snowsight:
1. Go to **Projects > Workspaces**
2. Click **+ > From Git repository**
3. Paste your repo URL (e.g., `https://github.com/<your-user>/dbt-it-helpdesk`)
4. Select `GIT_API_INTEGRATION`
5. Authenticate via OAuth with GitHub

---

## Step 5: dbt Project Structure

Create the following files in the Git workspace:

```
it_helpdesk/
├── dbt_project.yml
├── profiles.yml
├── macros/
│   └── generate_schema_name.sql
└── models/
    ├── sources.yml
    ├── staging/
    │   ├── stg_tickets.sql
    │   └── stg_agents.sql
    └── marts/
```

### `dbt_project.yml`

```yaml
name: 'it_helpdesk'
version: '1.0.0'
profile: 'it_helpdesk'

model-paths: ["models"]
macro-paths: ["macros"]
seed-paths: ["seeds"]

models:
  it_helpdesk:
    staging:
      +database: DEV_STAGE
      +schema: IT_HELPDESK
      +materialized: view
    marts:
      +database: DEV_MARTS
      +schema: IT_HELPDESK
      +materialized: table
```

### `profiles.yml`

```yaml
it_helpdesk:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ""
      user: ""
      role: DBT_DEVELOPER
      database: DEV_STAGE
      warehouse: DBT_DEVELOPMENT_WH
      schema: IT_HELPDESK
      threads: 8
    prod:
      type: snowflake
      account: ""
      user: ""
      role: DBT_SERVICE
      database: DEV_STAGE
      warehouse: COMPUTE_WH
      schema: IT_HELPDESK
      threads: 8
```

> Note: `account` and `user` are empty strings because Snowflake workspace execution uses session context. Do NOT add `password`, `authenticator`, or `env_var()` calls.

### `macros/generate_schema_name.sql`

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

> This macro overrides dbt's default behavior of prepending the target schema. Without it, dbt would create `IT_HELPDESK_IT_HELPDESK` instead of just `IT_HELPDESK`.

### `models/sources.yml`

```yaml
version: 2

sources:
  - name: it_helpdesk
    database: DEV_SOURCE
    schema: IT_HELPDESK
    tables:
      - name: tickets
      - name: agents
```

### `models/staging/stg_agents.sql`

```sql
with source as (
    select * from {{ source('it_helpdesk', 'agents') }}
),

renamed as (
    select
        agent_id::number(38,0) as agent_id,
        initcap(split_part(split_part(email, '@', 1), '.', 1))::varchar(20) as first_name,
        initcap(split_part(split_part(email, '@', 1), '.', 2))::varchar(20) as last_name,
        (
            initcap(split_part(split_part(email, '@', 1), '.', 1))
            || ' ' ||
            initcap(split_part(split_part(email, '@', 1), '.', 2))
        )::varchar(50) as full_name,
        email::varchar(256) as email,
        year_of_birth::number(4,0) as year_of_birth,
        month_of_birth::number(2,0) as month_of_birth,
        day_of_birth::number(2,0) as day_of_birth,
        _fivetran_synced::timestamp_ntz(9) as source_load_timestamp
    from source
)

select * from renamed
```

### `models/staging/stg_tickets.sql`

```sql
with source as (
    select * from {{ source('it_helpdesk', 'tickets') }}
),

renamed as (
    select
        id_ticket::varchar(20) as ticket_id,
        agent_id::number(38,0) as agent_id,
        employee_id::number(38,0) as employee_id,
        try_to_date(date, 'MM/DD/YYYY')::date as ticket_date,
        issue_type::varchar(50) as issue_type,
        request_category::varchar(50) as request_category,
        split_part(priority, ' - ', 1)::number(1,0) as priority_level,
        trim(split_part(priority, ' - ', 2))::varchar(20) as priority_label,
        split_part(severity, ' - ', 1)::number(1,0) as severity_level,
        trim(split_part(severity, ' - ', 2))::varchar(20) as severity_label,
        satisfaction_rate::number(1,0) as satisfaction_rate,
        resolution_time_days_::number(4,0) as resolution_days,
        _fivetran_synced::timestamp_ntz(9) as source_load_timestamp
    from source
)

select * from renamed
```

---

## Step 6: Validate and Run

From the Git workspace with Cortex Code or the dbt terminal:

```bash
# Validate project compiles
dbt compile --project-dir it_helpdesk

# Materialize staging views
dbt run --project-dir it_helpdesk
```

---

## Step 7: Deploy as a Snowflake dbt Project (for scheduled execution)

```sql
-- Deploy from workspace
CREATE DBT PROJECT DEV_STAGE.IT_HELPDESK.IT_HELPDESK_PROJECT
  FROM 'snow://workspace/user$.public."dbt-it-helpdesk"/versions/live';

-- Run with production target
EXECUTE DBT PROJECT DEV_STAGE.IT_HELPDESK.IT_HELPDESK_PROJECT
  ARGS = 'run --target prod';

-- Schedule daily runs
CREATE TASK DEV_STAGE.IT_HELPDESK.RUN_DBT_DAILY
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
AS
  EXECUTE DBT PROJECT DEV_STAGE.IT_HELPDESK.IT_HELPDESK_PROJECT
    ARGS = 'run --target prod';
```

---

## Design Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Multi-database pattern (SOURCE/STAGE/MARTS) | Clear RBAC boundaries, prevents accidental access to raw data, easier cost attribution |
| Separate dev/prod roles | Workload isolation, least-privilege access, clear audit trail |
| Separate dev warehouse (XSMALL) | Prevents dev iteration from consuming production compute budget |
| `generate_schema_name` macro | Preserves explicit schema names without dbt's default prefix concatenation |
| Views for staging, tables for marts | Staging is lightweight renaming (no storage cost); marts are business-ready and benefit from materialization |
| Future table grants on source | Ensures new Fivetran tables are automatically accessible to dbt roles |
| Snowflake GitHub App auth | Simplest auth method — no PATs to rotate |

---

## Staging Layer: Implementation Details

### Purpose

Staging models (`stg_*`) sit between raw source and business marts. They are materialized as **views** in `DEV_STAGE.IT_HELPDESK` and serve as the single point of:

- Column renaming (clean names, no reserved words)
- Explicit type casting (constrained precision, not default Snowflake widths)
- Light parsing/transformation (splitting composite columns)
- No business logic, joins, or aggregations

### Source Tables

| Source | Staging Model | Primary Key |
|--------|---------------|-------------|
| `DEV_SOURCE.IT_HELPDESK.AGENTS` | `stg_agents` | `agent_id` |
| `DEV_SOURCE.IT_HELPDESK.TICKETS` | `stg_tickets` | `ticket_id` |

### stg_agents — Design Decisions

**Email-derived name columns:** The source `FULL_NAME` column contains inconsistent/messy data. Instead, `first_name`, `last_name`, and `full_name` are parsed from the `email` column, which follows the reliable format `firstname.lastname@fp20analytics.com`. This supports accented characters (e.g., `ñ`).

**Type casts:**

| Column | Type | Notes |
|--------|------|-------|
| `agent_id` | `NUMBER(38,0)` | PK, matches source |
| `first_name` | `VARCHAR(20)` | Derived from email local part |
| `last_name` | `VARCHAR(20)` | Derived from email local part |
| `full_name` | `VARCHAR(50)` | Concatenation of first + last |
| `email` | `VARCHAR(256)` | Matches source width |
| `year_of_birth` | `NUMBER(4,0)` | Tightened from NUMBER(38,0) |
| `month_of_birth` | `NUMBER(2,0)` | Max value: 12 |
| `day_of_birth` | `NUMBER(2,0)` | Max value: 31 |
| `source_load_timestamp` | `TIMESTAMP_NTZ(9)` | TZ intentionally dropped from source TIMESTAMP_TZ — pipeline always ingests UTC |

**Note on `full_name` cast:** The `::varchar(50)` must wrap the entire concatenation expression in parentheses, otherwise it only casts the last operand.

### stg_tickets — Design Decisions

**Priority/severity split:** Source columns store values as `"N - Label"` (e.g., `"3 - High"`). These are split into separate `_level` (numeric) and `_label` (text) columns. This was kept denormalized (no separate dimension tables) because:
- Only 4–5 distinct values per column
- Mapping is static and embedded in source data
- Avoids unnecessary joins in downstream marts

**Date parsing:** Source `DATE` column is a VARCHAR in `MM/DD/YYYY` format, parsed with `try_to_date()` to gracefully handle any malformed values (returns NULL instead of failing).

**Type casts:**

| Column | Type | Notes |
|--------|------|-------|
| `ticket_id` | `VARCHAR(20)` | PK, format: `XXXXX-NNNNNNNNNN` |
| `agent_id` | `NUMBER(38,0)` | FK to stg_agents |
| `employee_id` | `NUMBER(38,0)` | FK to employee (source TBD) |
| `ticket_date` | `DATE` | Parsed from VARCHAR `MM/DD/YYYY` |
| `issue_type` | `VARCHAR(50)` | e.g., "IT Request", "IT Error" |
| `request_category` | `VARCHAR(50)` | e.g., "System", "Hardware" |
| `priority_level` | `NUMBER(1,0)` | 0–3 |
| `priority_label` | `VARCHAR(20)` | Unassiged, Low, Mid, High |
| `severity_level` | `NUMBER(1,0)` | 0–4 |
| `severity_label` | `VARCHAR(20)` | Unclasified, Minor, Normal, Mayor, Urgent |
| `satisfaction_rate` | `NUMBER(1,0)` | Scale of 1–5 |
| `resolution_days` | `NUMBER(4,0)` | Days to resolve |
| `source_load_timestamp` | `TIMESTAMP_NTZ(9)` | TZ dropped, same rationale as agents |

**Known source data quirks (preserved as-is):**
- `"Unassiged"` — typo in source (not "Unassigned")
- `"Unclasified"` — typo in source (not "Unclassified")
- `"Mayor"` — typo in source (not "Major")

These are kept as-is in staging to reflect the source faithfully. If correction is needed, apply it in a mart model.

### Testing Strategy

Tests are defined in `stg_agents.yml` and `stg_tickets.yml`.

**stg_agents tests (4):**

| Test | Column | Purpose |
|------|--------|---------|
| `unique` | `agent_id` | PK uniqueness |
| `not_null` | `agent_id` | PK completeness |
| `matches_email_format` | `email` | Validates `<text>.<text>@fp20analytics.com` pattern |
| `valid_date_of_birth` | `agent_id` | Ensures year/month/day form a valid date when all present |

**stg_tickets tests (8):**

| Test | Column | Purpose |
|------|--------|---------|
| `unique` | `ticket_id` | PK uniqueness |
| `not_null` | `ticket_id` | PK completeness |
| `relationships` | `agent_id` → `stg_agents.agent_id` | Referential integrity (**warn**, not fail) |
| `not_in_future` | `ticket_date` | No dates beyond today |
| `accepted_values` | `satisfaction_rate` | Must be 1–5 |
| `non_negative` | `resolution_days` | No negative values |
| `valid_level_label_pairs` | `priority_label` + `priority_level` | Validates exact level↔label mapping |
| `valid_level_label_pairs` | `severity_label` + `severity_level` | Same for severity |

### Custom Generic Tests (in `macros/`)

| Macro | Parameters | Logic |
|-------|------------|-------|
| `test_matches_email_format` | `column_name`, `domain` | Regex: `^[^@\s]+\.[^@\s]+@{domain}$` |
| `test_valid_date_of_birth` | `column_name` | `try_to_date(year-month-day)` must not be NULL when all parts are present |
| `test_valid_level_label_pairs` | `column_name`, `level_column`, `valid_pairs` | Checks all (level, label) tuples match the expected mapping |
| `test_not_in_future` | `column_name` | Column must be ≤ `current_date()` |
| `test_non_negative` | `column_name` | Column must be ≥ 0 |

### File Structure (current)

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
    └── staging/
        ├── stg_agents.sql
        ├── stg_agents.yml
        ├── stg_tickets.sql
        └── stg_tickets.yml
```
