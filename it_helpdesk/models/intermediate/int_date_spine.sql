-- Generates a complete series of weeks and months spanning the ticket data range.
-- Used by time-series marts to ensure zero-filled dense output.
with date_bounds as (
    select
        date_trunc('week', min(ticket_date))::date as min_week,
        date_trunc('week', max(ticket_date))::date as max_week
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
