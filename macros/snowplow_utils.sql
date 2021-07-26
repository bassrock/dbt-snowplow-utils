{# Prints array as comma seperated, quoted items. #}
{% macro print_list(list) %}

  {%- for item in list %} '{{item}}' {%- if not loop.last %},{% endif %} {% endfor -%}

{% endmacro %}

{# Filters on app_id if provided #}
{% macro app_id_filter() %}

  {%- if var('snowplow__app_id', [])|length -%} 

    app_id in ({{ snowplow_utils.print_list(app_id_list) }}) --filter on app_id if provided

  {%- else -%}

    true

  {%- endif -%}

{% endmacro %}

{# Logs to console, with option to disable. #}
{% macro log_message(message, is_printed=var('snowplow__has_log_enabled', true)) %}
    {{ return(adapter.dispatch('log_message', ['snowplow_utils'])(message, is_printed)) }}
{% endmacro %}

{% macro default__log_message(message, is_printed) %}
    {{ log(dbt_utils.pretty_log_format(message), info=is_printed) }}
{% endmacro %}

{# When called by an incremental model, determines whether the model has previously consumed the data within the run
   If it has, returns false. This blocks the model from updating with old data #}
{% macro is_run_with_new_events(package_name) %}

  {% if snowplow_utils.snowplow_is_incremental() %}

    {%- set node_identifier = this.identifier -%}
    {%- set base_sessions_lifecycle_identifier = package_name+'_base_sessions_lifecycle_manifest' -%}

    {# base_sessions_lifecycle not included in manifest so query directly. Otherwise use the manifest for performance #}
    {%- if node_identifier == base_sessions_lifecycle_identifier -%}

      {% set has_been_processed_query %}
        select 
          case when 
            (select upper_limit from {{ snowplow_utils.get_current_incremental_tstamp_table_relation(package_name) }}) <= (select max(end_tstamp) from {{this}}) 
          then false 
        else true end
      {% endset %}

    {%- else -%}

      {% set has_been_processed_query %}
        select 
          case when 
            (select upper_limit from {{ snowplow_utils.get_current_incremental_tstamp_table_relation(package_name) }}) 
            <= (select last_success from {{ snowplow_utils.get_incremental_manifest_table_relation(package_name) }} where model = '{{node_identifier}}') 
          then false 
        else true end
      {% endset %}

    {%- endif -%}

    {% set results = run_query(has_been_processed_query) %}

    {% if execute %}
      {% set has_new_events = results.columns[0].values()[0] %}
    {% endif %}

  {% else %}

    {% set has_new_events = true %}

  {% endif %}

  {{ return(has_new_events) }}

{% endmacro %}

{# Drops the input table #}
{% macro snowplow_destroy_table(table) %}

  {% set table_name_str = table.include(database=false)|string %}

  {% do adapter.drop_relation(table) %}

  {% if execute %}

    {% do  snowplow_utils.log_message("Snowplow: Dropped table: "+table_name_str) %}

  {% endif %}

{% endmacro %}

{# Drops all manifest tables #}
{% macro snowplow_teardown_all(package_name) %}

  {# Using ref to identify correct schema #}
  {%- set base_sessions_lifecycle_ref = ref(package_name+'_base_sessions_lifecycle_manifest') -%}

  {%- set base_sessions_lifecycle_relation = adapter.get_relation(base_sessions_lifecycle_ref.database,
                                                                  base_sessions_lifecycle_ref.schema,
                                                                  base_sessions_lifecycle_ref.name) -%}

  {%- set user_manifest_ref = ref(package_name+'_users_manifest') -%}

  {%- set user_manifest_relation = adapter.get_relation(user_manifest_ref.database,
                                                        user_manifest_ref.schema,
                                                        user_manifest_ref.name) -%}
  

  {%- set tables_to_drop = [snowplow_utils.get_incremental_manifest_table_relation(package_name),
                            snowplow_utils.get_current_incremental_tstamp_table_relation(package_name),
                            base_sessions_lifecycle_relation,
                            user_manifest_relation] -%}

  {%- for table in tables_to_drop -%}
    {%- if table is not none -%}
      {# If initial run base_sessions_lifecycle doesn't exist i.e. table is none #}
      {{ snowplow_utils.snowplow_destroy_table(table) }}
    {%- endif -%}
{% endfor -%}

{% endmacro %}

{# Deletes specified models from the incremental_manifest table #}
{% macro snowplow_delete_from_manifest(package_name, models) %}

  {% if not execute %}
    {{ return(False) }}
  {% endif %}
  
  {%- if models is string -%}
    {%- set models = [models] -%}
  {%- endif -%}
    
  {%- set incremental_manifest_table = snowplow_utils.get_incremental_manifest_table_relation(package_name) -%}

  {%- set incremental_manifest_table_exists = adapter.get_relation(incremental_manifest_table.database,
                                                                  incremental_manifest_table.schema,
                                                                  incremental_manifest_table.name) -%}

  {%- if not incremental_manifest_table_exists -%}
    {{return(dbt_utils.log_info("Snowplow: "+incremental_manifest_table|string+" does not exist"))}}
  {%- endif -%}

  {%- set models_in_manifest = dbt_utils.get_column_values(table=incremental_manifest_table, column='model') -%}
  {%- set unmatched_models, matched_models = [], [] -%}

  {%- for model in models -%}

    {%- if model in models_in_manifest -%}
      {%- do matched_models.append(model) -%}
    {%- else -%}
      {%- do unmatched_models.append(model) -%}
    {%- endif -%}

  {%- endfor -%}

  {%- if not matched_models|length -%}
    {{return(dbt_utils.log_info("Snowplow: None of the supplied models exist in the manifest"))}}
  {%- endif -%}

  {% set delete_statement %}
    delete from {{ incremental_manifest_table }} where model in ({{ snowplow_utils.print_list(matched_models) }});
    commit;
  {% endset %}

  {%- do run_query(delete_statement) -%}

  {%- if matched_models|length -%}
    {% do snowplow_utils.log_message("Snowplow: Deleted models "+snowplow_utils.print_list(matched_models)+" from the manifest") %}
  {%- endif -%}

  {%- if unmatched_models|length -%}
    {% do snowplow_utils.log_message("Snowplow: Models "+snowplow_utils.print_list(unmatched_models)+" do not exist in the manifest") %}
  {%- endif -%}

{% endmacro %}