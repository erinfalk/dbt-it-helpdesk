-- KPI: Ticket mix by severity & priority — shows workload risk profile
-- Grain: severity × priority × is_resolved
-- Additive: use SUM(ticket_count) / NULLIF(SUM(SUM(ticket_count)) OVER (), 0) for pct downstream
with tickets as (
    select
        *,
        case when resolution_days is not null then true else false end as is_resolved
    from {{ ref('stg_tickets') }}
),

dim_sev as (
    select * from {{ ref('dim_severity') }}
),

dim_pri as (
    select * from {{ ref('dim_priority') }}
)

select
    ds.display_label as severity,
    ds.business_tier as severity_tier,
    ds.sort_key as severity_sort,
    dp.display_label as priority,
    dp.p_code as priority_code,
    dp.business_tier as priority_tier,
    dp.sort_key as priority_sort,
    t.is_resolved,
    count(*) as ticket_count
from tickets t
left join dim_sev ds on t.severity_level = ds.sort_key
left join dim_pri dp on t.priority_level = dp.sort_key
group by 1, 2, 3, 4, 5, 6, 7, 8
