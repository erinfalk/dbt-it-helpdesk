{% test numerator_lte_denominator(model, column_name, denominator) %}

select {{ column_name }}, {{ denominator }}
from {{ model }}
where {{ column_name }} > {{ denominator }}

{% endtest %}
