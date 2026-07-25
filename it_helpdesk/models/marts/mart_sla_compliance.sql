-- KPI: SLA compliance rate — % of tickets resolved within 3 days, by issue type and month
-- Dense: every issue type gets a row for every month (zero-filled)
-- Includes explicit SLA fields: sla_target_days, is_within_sla flag (in actuals), and weighted compliance
with spine as (
    select distinct month_start from {{ ref('int_date_spine') }}
),

issue_types as (
    select distinct issue_type from {{ ref('stg_tickets') }}
),

issue_months as (
    select
        it.issue_type,
        s.month_start
    from issue_types it
    cross join spine s
),

actuals as (
    select
        issue_type,
        date_trunc('month', ticket_date)::date as month_start,
        3 as sla_target_days,
        count(*) as resolved_ticket_count,
        count_if(resolution_days <= 3) as tickets_within_sla,
        count_if(resolution_days > 3) as tickets_breached_sla
    from {{ ref('stg_tickets') }}
    where resolution_days is not null
    group by 1, 2
)

select
    im.issue_type,
    im.month_start,
    3 as sla_target_days,
    coalesce(a.resolved_ticket_count, 0) as resolved_ticket_count,
    coalesce(a.tickets_within_sla, 0) as tickets_within_sla,
    coalesce(a.tickets_breached_sla, 0) as tickets_breached_sla,
    case
        when coalesce(a.resolved_ticket_count, 0) = 0 then null
        else round(a.tickets_within_sla * 100.0 / a.resolved_ticket_count, 2)
    end as sla_compliance_pct,
    -- Weighted compliance: contribution of this cell to the overall monthly compliance
    -- (useful for roll-ups across issue types without double-counting)
    case
        when sum(coalesce(a.resolved_ticket_count, 0)) over (partition by im.month_start) = 0 then null
        else round(
            coalesce(a.tickets_within_sla, 0) * 100.0
            / sum(coalesce(a.resolved_ticket_count, 0)) over (partition by im.month_start),
            2
        )
    end as weighted_sla_compliance_pct
from issue_months im
left join actuals a
    on im.issue_type = a.issue_type
    and im.month_start = a.month_start
