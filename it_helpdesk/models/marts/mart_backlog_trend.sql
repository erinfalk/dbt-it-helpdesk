-- KPI: Weekly backlog trend — opened vs resolved by severity
-- Dense: every severity gets a row for every week (zero-filled)
-- Uses canonical display labels (typo-corrected)
with spine as (
    select distinct week_start from {{ ref('int_date_spine') }}
),

dim_sev as (
    select * from {{ ref('dim_severity') }}
),

severity_weeks as (
    select
        s.week_start,
        ds.display_label as severity,
        ds.business_tier as severity_tier,
        ds.sort_key as severity_sort,
        ds.raw_label as _raw_severity_label
    from spine s
    cross join dim_sev ds
),

actuals as (
    select
        date_trunc('week', ticket_date)::date as week_start,
        severity_label,
        count(*) as tickets_opened,
        count_if(resolution_days is not null) as tickets_resolved
    from {{ ref('stg_tickets') }}
    group by 1, 2
)

select
    sw.week_start,
    sw.severity,
    sw.severity_tier,
    sw.severity_sort,
    coalesce(a.tickets_opened, 0) as tickets_opened,
    coalesce(a.tickets_resolved, 0) as tickets_resolved,
    coalesce(a.tickets_opened, 0) - coalesce(a.tickets_resolved, 0) as net_new_backlog,
    sum(coalesce(a.tickets_opened, 0) - coalesce(a.tickets_resolved, 0)) over (
        partition by sw.severity order by sw.week_start
    ) as cumulative_backlog
from severity_weeks sw
left join actuals a
    on sw.week_start = a.week_start
    and sw._raw_severity_label = a.severity_label
