-- 0. Use an administrative role
USE ROLE ACCOUNTADMIN;

-- 1. Create a dedicated role for Fivetran to allow Least Privilege access control
CREATE ROLE IF NOT EXISTS FIVETRAN
  COMMENT = 'Dedicated role for Fivetran';

-- 2. Create Fivetran service user
CREATE USER FIVETRAN_SERVICE_ACCOUNT
  TYPE = 'SERVICE'          -- Restricts password/SAML interactive login
  RSA_PUBLIC_KEY = 'XXXXX'                   -- Paste your continuous public key string here
  DEFAULT_ROLE = 'FIVETRAN'                     -- Forces the user into the constrained role
  COMMENT = 'Automated service account for Fivetran';

-- 3. Bind the role to the user
GRANT ROLE FIVETRAN TO USER FIVETRAN_SERVICE_ACCOUNT;

-- 4. Create Fivetran-specific warehouse - This is important for cost tracking and workload isolation
CREATE WAREHOUSE FIVETRAN_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- 5. Grant access to the scoped role on the specified warehouse 
GRANT USAGE ON WAREHOUSE FIVETRAN_WH TO ROLE FIVETRAN;

-- 6. Create target datbase
CREATE DATABASE DEV_SOURCE;

-- 7. Grant usage on specified database and schema to the scoped role
-- Fivetran must be able to create schemas within the target database
-- After tables created within the schema, need to grant read permissions to the primary role
GRANT USAGE ON DATABASE DEV_SOURCE TO ROLE FIVETRAN;
GRANT CREATE SCHEMA ON DATABASE DEV_SOURCE TO ROLE FIVETRAN;
GRANT SELECT ON ALL TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE ACCOUNTADMIN;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DEV_SOURCE.IT_HELPDESK TO ROLE ACCOUNTADMIN;

-- 8. Check data landed by Fivetran
SELECT * FROM DEV_SOURCE.IT_HELPDESK.TICKETS; -- 97,498 rows, matches spreadsheet
SELECT * FROM DEV_SOURCE.IT_HELPDESK.AGENTS; -- 50 rows, matches spreadsheet