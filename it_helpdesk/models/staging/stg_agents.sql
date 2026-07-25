with source as (
    select * from {{ source('it_helpdesk', 'agents') }}
),

renamed as (
    select
        agent_id,
        full_name as agent_name,
        email,
        year_of_birth,
        month_of_birth,
        day_of_birth,
        _fivetran_synced
    from source
)

select * from renamed
