-- Generates a complete series of weeks and months spanning the ticket data range.
-- Extends to cover the latest possible closure date (ticket_date + resolution_days)
-- so that resolutions near the end of the data range aren't dropped.
with date_bounds as (
    select
        date_trunc('week', min(ticket_date))::date as min_week,
        date_trunc('week', max(dateadd('day', resolution_days, ticket_date)))::date as max_week
    from {{ ref('stg_tickets') }}
),

week_series as (
    select
        dateadd('week', row_number() over (order by null) - 1, min_week)::date as week_start
    from date_bounds,
        lateral flatten(input => array_generate_range(0, datediff('week', min_week, max_week) + 1))
)

select
    week_start,
    date_trunc('month', week_start)::date as month_start
from week_series
