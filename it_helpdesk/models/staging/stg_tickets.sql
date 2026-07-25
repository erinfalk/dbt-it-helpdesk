with source as (
    select * from {{ source('it_helpdesk', 'tickets') }}
),

renamed as (
    select
        id_ticket::varchar(20) as ticket_id,
        agent_id::number(38,0) as agent_id,
        employee_id::number(38,0) as employee_id,
        try_to_date(date, 'MM/DD/YYYY')::date as ticket_date,
        issue_type::varchar(50) as issue_type,
        request_category::varchar(50) as request_category,
        split_part(priority, ' - ', 1)::number(1,0) as priority_level,
        trim(split_part(priority, ' - ', 2))::varchar(20) as priority_label,
        split_part(severity, ' - ', 1)::number(1,0) as severity_level,
        trim(split_part(severity, ' - ', 2))::varchar(20) as severity_label,
        satisfaction_rate::number(1,0) as satisfaction_rate,
        resolution_time_days_::number(4,0) as resolution_days,
        _fivetran_synced::timestamp_ntz(9) as source_load_timestamp
    from source
)

select * from renamed
