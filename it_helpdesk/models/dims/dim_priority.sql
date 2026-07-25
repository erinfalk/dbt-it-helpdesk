-- Canonical priority dimension: preserves raw labels, adds corrected display labels,
-- numeric sort keys, P-codes, and a business-approved tier mapping.
--
-- Mapping assumptions (business-approved):
--   "Unassiged" (raw) → display "Unassigned" → P0 / tier "Unassigned" (own tier, not bucketed)
--   "Mid" (raw) → display "Medium" → P3 (standard ITIL)
with distinct_priorities as (
    select distinct
        priority_level,
        priority_label
    from {{ ref('stg_tickets') }}
)

select
    priority_level as sort_key,
    priority_label as raw_label,
    case priority_label
        when 'Unassiged' then 'Unassigned'
        when 'Mid' then 'Medium'
        else priority_label
    end as display_label,
    case priority_level
        when 0 then 'P4'
        when 1 then 'P3'
        when 2 then 'P2'
        when 3 then 'P1'
    end as p_code,
    case priority_level
        when 0 then 'Unassigned'
        when 1 then 'Low'
        when 2 then 'Medium'
        when 3 then 'High'
    end as business_tier
from distinct_priorities
