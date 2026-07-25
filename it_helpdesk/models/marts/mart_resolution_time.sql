-- KPI: Resolution time by issue type and request category
-- Grain: one row per (issue_type, request_category)
-- Percentiles cannot be reaggregated — keep as-is at this grain
with tickets as (
    select * from {{ ref('stg_tickets') }}
    where resolution_days is not null
)

select
    issue_type,
    request_category,
    count(*) as tickets_resolved,
    median(resolution_days) as median_resolution_days,
    percentile_cont(0.75) within group (order by resolution_days)::number(10, 2) as p75_resolution_days,
    percentile_cont(0.95) within group (order by resolution_days)::number(10, 2) as p95_resolution_days
from tickets
group by 1, 2
