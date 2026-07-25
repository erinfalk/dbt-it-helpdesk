with source as (
    select * from {{ source('it_helpdesk', 'agents') }}
),

renamed as (
    select
        agent_id::number(38,0) as agent_id,
        initcap(split_part(split_part(email, '@', 1), '.', 1))::varchar(20) as first_name,
        initcap(split_part(split_part(email, '@', 1), '.', 2))::varchar(20) as last_name,
        (
            initcap(split_part(split_part(email, '@', 1), '.', 1))
            || ' ' ||
            initcap(split_part(split_part(email, '@', 1), '.', 2))
        )::varchar(50) as full_name,
        email::varchar(256) as email,
        year_of_birth::number(4,0) as year_of_birth,
        month_of_birth::number(2,0) as month_of_birth,
        day_of_birth::number(2,0) as day_of_birth,
        _fivetran_synced::timestamp_ntz(9) as source_load_timestamp
    from source
)

select * from renamed
