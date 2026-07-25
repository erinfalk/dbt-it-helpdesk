-- KPI: % of tickets resolved within 7 days — fast-turnaround rate by month
-- Dense: every month in the data range gets a row (zero-filled)
with spine as (
    select distinct month_start from {{ ref('int_date_spine') }}
),

actuals as (
    select
        date_trunc('month', ticket_date)::date as month_start,
        count(*) as total_resolved,
        count_if(resolution_days <= 7) as resolved_within_7_days
    from {{ ref('stg_tickets') }}
    where resolution_days is not null
    group by 1
)

select
    s.month_start,
    coalesce(a.total_resolved, 0) as total_resolved,
    coalesce(a.resolved_within_7_days, 0) as resolved_within_7_days,
    case
        when coalesce(a.total_resolved, 0) = 0 then null
        else round(a.resolved_within_7_days * 100.0 / a.total_resolved, 2)
    end as first_week_resolution_pct
from spine s
left join actuals a on s.month_start = a.month_start
