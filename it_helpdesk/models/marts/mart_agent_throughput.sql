-- KPI: Tickets resolved per agent per week — individual throughput
-- Dense: every agent gets a row for every week (zero-filled)
with spine as (
    select distinct week_start from {{ ref('int_date_spine') }}
),

agents as (
    select agent_id, full_name as agent_name from {{ ref('stg_agents') }}
),

agent_weeks as (
    select
        a.agent_id,
        a.agent_name,
        s.week_start
    from agents a
    cross join spine s
),

actuals as (
    select
        agent_id,
        date_trunc('week', ticket_date)::date as week_start,
        count(*) as tickets_resolved
    from {{ ref('stg_tickets') }}
    where resolution_days is not null
    group by 1, 2
)

select
    aw.agent_id,
    aw.agent_name,
    aw.week_start,
    coalesce(ac.tickets_resolved, 0) as tickets_resolved
from agent_weeks aw
left join actuals ac
    on aw.agent_id = ac.agent_id
    and aw.week_start = ac.week_start
