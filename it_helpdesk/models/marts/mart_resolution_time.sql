-- KPI: Median resolution time by issue type and request category
-- Two-level hierarchy: issue_type (2 values) → request_category (4 values)
-- Provides both the rolled-up issue_type view and granular category breakdown
with tickets as (
    select * from {{ ref('stg_tickets') }}
    where resolution_days is not null
)

select
    issue_type,
    request_category,
    count(*) as tickets_resolved,
    median(resolution_days) as median_resolution_days,
    avg(resolution_days)::number(10, 2) as avg_resolution_days,
    percentile_cont(0.75) within group (order by resolution_days)::number(10, 2) as p75_resolution_days,
    percentile_cont(0.95) within group (order by resolution_days)::number(10, 2) as p95_resolution_days,
    min(resolution_days) as min_resolution_days,
    max(resolution_days) as max_resolution_days
from tickets
group by 1, 2
