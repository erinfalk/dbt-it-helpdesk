{% test valid_level_label_pairs(model, column_name, level_column, valid_pairs) %}

select {{ column_name }}
from {{ model }}
where ({{ level_column }}, {{ column_name }}) not in (
    {% for pair in valid_pairs %}
    ({{ pair.level }}, '{{ pair.label }}'){% if not loop.last %},{% endif %}
    {% endfor %}
)

{% endtest %}
