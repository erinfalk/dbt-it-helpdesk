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

### `models/staging/stg_tickets.sql`

```sql
with source as (
    select * from {{ source('it_helpdesk', 'tickets') }}
),

renamed as (
    select
        id_ticket as ticket_id,
        agent_id,
        employee_id,
        date as ticket_date,
        issue_type,
        request_category,
        priority,
        severity,
        satisfaction_rate,
        resolution_time_days_ as resolution_days,
        _fivetran_synced
    from source
)

select * from renamed
```

### `models/staging/stg_agents.sql`

```sql
with source as (
    select * from {{ source('it_helpdesk', 'agents') }}
),

renamed as (
    select
        agent_id,
        full_name as agent_name,
        email,
        year_of_birth,
        month_of_birth,
        day_of_birth,
        _fivetran_synced
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
