-- ============================================================================
-- IT Helpdesk Pipeline — Full Infrastructure Setup
-- ============================================================================
-- Run all commands as ACCOUNTADMIN unless otherwise noted.
-- Replace placeholder values (XXXXX, <your-...>) with actual credentials.
-- Sections are ordered by dependency — run top to bottom for a fresh setup.
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- ============================================================================
-- SECTION 1: Fivetran Ingestion Setup
-- ============================================================================

-- 1a. Dedicated Fivetran role (least privilege)
CREATE ROLE IF NOT EXISTS FIVETRAN
  COMMENT = 'Dedicated role for Fivetran ingestion';

-- 1b. Fivetran service user (key-pair auth, no password)
CREATE USER IF NOT EXISTS FIVETRAN_SERVICE_ACCOUNT
  TYPE = 'SERVICE'
  RSA_PUBLIC_KEY = 'XXXXX'  -- Paste your public key string here (no BEGIN/END lines)
  DEFAULT_ROLE = 'FIVETRAN'
  COMMENT = 'Automated service account for Fivetran';

GRANT ROLE FIVETRAN TO USER FIVETRAN_SERVICE_ACCOUNT;

-- 1c. Fivetran warehouse (isolated for cost tracking)
CREATE WAREHOUSE IF NOT EXISTS FIVETRAN_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

GRANT USAGE ON WAREHOUSE FIVETRAN_WH TO ROLE FIVETRAN;

-- 1d. Source database
CREATE DATABASE IF NOT EXISTS DEV_SOURCE;
GRANT USAGE ON DATABASE DEV_SOURCE TO ROLE FIVETRAN;
GRANT CREATE SCHEMA ON DATABASE DEV_SOURCE TO ROLE FIVETRAN;

-- 1e. After Fivetran creates schema and loads data:
GRANT SELECT ON ALL TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE ACCOUNTADMIN;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE ACCOUNTADMIN;

-- 1f. Verify data landed
-- SELECT * FROM DEV_SOURCE.IT_HELPDESK.TICKETS;  -- expect 97,498 rows
-- SELECT * FROM DEV_SOURCE.IT_HELPDESK.AGENTS;   -- expect 50 rows

-- ============================================================================
-- SECTION 2: dbt Infrastructure
-- ============================================================================

-- 2a. Development role and warehouse
CREATE ROLE IF NOT EXISTS DBT_DEVELOPER
  COMMENT = 'Role for dbt interactive development';

CREATE WAREHOUSE IF NOT EXISTS DBT_DEVELOPMENT_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- 2b. Production execution role (uses COMPUTE_WH — reserved for dbt jobs only)
CREATE ROLE IF NOT EXISTS DBT_SERVICE
  COMMENT = 'Role for scheduled dbt execution';

-- 2c. Target databases and schemas
CREATE DATABASE IF NOT EXISTS DEV_STAGE;
CREATE SCHEMA IF NOT EXISTS DEV_STAGE.IT_HELPDESK;

CREATE DATABASE IF NOT EXISTS DEV_MARTS;
CREATE SCHEMA IF NOT EXISTS DEV_MARTS.IT_HELPDESK;

-- ============================================================================
-- SECTION 3: dbt Role Grants
-- ============================================================================

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

-- Grant dev role to your user
GRANT ROLE DBT_DEVELOPER TO USER <your_username>;

-- ============================================================================
-- SECTION 4: GitHub Integration (for Snowsight Workspaces)
-- ============================================================================

CREATE OR REPLACE API INTEGRATION git_api_integration
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/<your-org-or-user>')
  API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
  ENABLED = TRUE;

-- ============================================================================
-- SECTION 5: Hex BI Integration
-- ============================================================================

-- 5a. Read-only role for Hex
CREATE ROLE IF NOT EXISTS HEX_READER;

GRANT USAGE ON DATABASE DEV_MARTS TO ROLE HEX_READER;
GRANT USAGE ON SCHEMA DEV_MARTS.IT_HELPDESK TO ROLE HEX_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA DEV_MARTS.IT_HELPDESK TO ROLE HEX_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DEV_MARTS.IT_HELPDESK TO ROLE HEX_READER;

-- 5b. Dedicated Hex warehouse (isolated from dbt on COMPUTE_WH)
CREATE WAREHOUSE IF NOT EXISTS HEX_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

GRANT USAGE ON WAREHOUSE HEX_WH TO ROLE HEX_READER;

-- 5c. Hex service user (key-pair auth, no password)
CREATE USER IF NOT EXISTS HEX
  LOGIN_NAME = 'HEX'
  DEFAULT_ROLE = HEX_READER
  DEFAULT_WAREHOUSE = HEX_WH
  MUST_CHANGE_PASSWORD = FALSE;

GRANT ROLE HEX_READER TO USER HEX;

-- 5d. Assign public key (generate with: openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out hex_rsa_key.p8 -nocrypt)
ALTER USER HEX SET RSA_PUBLIC_KEY = 'XXXXX';  -- Paste public key contents (no BEGIN/END lines)

-- ============================================================================
-- SECTION 6: Verification Queries
-- ============================================================================

-- Verify mart tables are accessible under HEX_READER
USE ROLE HEX_READER;
USE WAREHOUSE HEX_WH;

SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_TICKET_MIX LIMIT 5;
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_AGENT_THROUGHPUT LIMIT 5;
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_RESOLUTION_TIME LIMIT 5;
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_SLA_COMPLIANCE LIMIT 5;
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_CSAT_BY_CATEGORY LIMIT 5;
SELECT * FROM DEV_MARTS.IT_HELPDESK.MART_FIRST_WEEK_RESOLUTION_RATE LIMIT 5;
SELECT * FROM DEV_MARTS.IT_HELPDESK.DIM_SEVERITY;
SELECT * FROM DEV_MARTS.IT_HELPDESK.DIM_PRIORITY;

-- Verify persist_docs comments are visible
SELECT TABLE_NAME, COMMENT
FROM DEV_MARTS.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'IT_HELPDESK';
