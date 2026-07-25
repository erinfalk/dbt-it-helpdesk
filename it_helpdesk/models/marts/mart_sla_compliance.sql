-- KPI: SLA compliance rate — % resolved within 3 calendar days
-- Grain: month_start × issue_type × request_category × severity_tier
-- Additive: use SUM(tickets_within_sla) / NULLIF(SUM(resolved_ticket_count), 0) to roll up
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
    issue_type,
    request_category,
    severity,
    severity_tier,
    severity_sort,
    3 as sla_target_days,
    count(*) as resolved_ticket_count,
    count_if(resolution_days <= 3) as tickets_within_sla,
    count_if(resolution_days > 3) as tickets_breached_sla
from tickets
group by 1, 2, 3, 4, 5, 6
