-- KPI: First-week resolution rate — % resolved within 7 calendar days
-- Grain: month_start × request_category × severity_tier
-- Additive: use SUM(resolved_within_7_days) / NULLIF(SUM(total_resolved), 0) to roll up
with dim_sev as (
    select * from {{ ref('dim_severity') }}
),

tickets as (
    select
        t.*,
        ds.display_label as severity,
        ds.business_tier as severity_tier,
        ds.sort_key as severity_sort
    from {{ ref('stg_tickets') }} t
    left join dim_sev ds on t.severity_level = ds.sort_key
    where t.resolution_days is not null
)

select
    date_trunc('month', ticket_date)::date as month_start,
    request_category,
    severity,
    severity_tier,
    severity_sort,
    count(*) as total_resolved,
    count_if(resolution_days <= 7) as resolved_within_7_days
from tickets
group by 1, 2, 3, 4, 5
