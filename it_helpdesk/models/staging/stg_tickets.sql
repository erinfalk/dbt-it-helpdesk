with source as (
    select * from {{ source('it_helpdesk', 'tickets') }}
),

renamed as (
    select
        id_ticket as ticket_id,
        agent_id,
        employee_id,
        date as ticket_date,
        issue_type,
        request_category,
        priority,
        severity,
        satisfaction_rate,
        resolution_time_days_ as resolution_days,
        _fivetran_synced
    from source
)

select * from renamed
