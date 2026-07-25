-- Canonical severity dimension: preserves raw labels, adds corrected display labels,
-- numeric sort keys, and a business-approved Critical/High/Medium/Low tier mapping.
--
-- Mapping assumptions (business-approved):
--   "Mayor" (raw) → display "Major" → tier "High" (only Urgent = Critical)
--   "Unclasified" (raw) → display "Unclassified" → tier "Unknown" (own tier, not bucketed)
with distinct_severities as (
    select distinct
        severity_level,
        severity_label
    from {{ ref('stg_tickets') }}
)

select
    severity_level as sort_key,
    severity_label as raw_label,
    case severity_label
        when 'Unclasified' then 'Unclassified'
        when 'Mayor' then 'Major'
        else severity_label
    end as display_label,
    case severity_level
        when 0 then 'Unknown'
        when 1 then 'Low'
        when 2 then 'Medium'
        when 3 then 'High'
        when 4 then 'Critical'
    end as business_tier
from distinct_severities
