{% test matches_email_format(model, column_name, domain) %}

select {{ column_name }}
from {{ model }}
where not regexp_like({{ column_name }}, '^[^@\\s]+\\.[^@\\s]+@' || '{{ domain }}' || '$')

{% endtest %}
