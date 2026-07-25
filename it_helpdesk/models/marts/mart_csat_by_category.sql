-- KPI: Customer satisfaction by request category
-- Grain: one row per request_category
-- Additive: use SUM(csat_points_sum) / NULLIF(SUM(responses), 0) for overall CSAT
--           use SUM(promoters) / NULLIF(SUM(responses), 0) for promoter share
with tickets as (
    select * from {{ ref('stg_tickets') }}
    where satisfaction_rate is not null
)

select
    request_category,
    count(*) as responses,
    sum(satisfaction_rate) as csat_points_sum,
    round(avg(satisfaction_rate), 2) as avg_csat,
    count_if(satisfaction_rate >= 4) as promoters,
    count_if(satisfaction_rate <= 2) as detractors
from tickets
group by 1
