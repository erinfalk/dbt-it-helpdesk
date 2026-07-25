-- KPI: Average CSAT score by request category
with tickets as (
    select * from {{ ref('stg_tickets') }}
    where satisfaction_rate is not null
)

select
    request_category,
    count(*) as responses,
    round(avg(satisfaction_rate), 2) as avg_csat,
    count_if(satisfaction_rate >= 4) as promoters,
    count_if(satisfaction_rate <= 2) as detractors,
    round(count_if(satisfaction_rate >= 4) * 100.0 / count(*), 2) as pct_promoters
from tickets
group by 1
