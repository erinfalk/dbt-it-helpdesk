{% test valid_date_of_birth(model, column_name) %}

select {{ column_name }}
from {{ model }}
where
    year_of_birth is not null
    and month_of_birth is not null
    and day_of_birth is not null
    and try_to_date(
        year_of_birth || '-' || month_of_birth || '-' || day_of_birth,
        'YYYY-MM-DD'
    ) is null

{% endtest %}
