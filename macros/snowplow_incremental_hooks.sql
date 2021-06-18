{% macro get_snowplow_manifest_schema() %}
  {# Derive full schema name from generate_schema_name macro in root project if exists #}
  {% if context.get(project_name, {}).get('generate_schema_name') %}
    {% set schema_name = context[project_name].generate_schema_name(var("snowplow__manifest_custom_schema","snowplow_manifest")) %}
    {{ return(schema_name) }}
  {% else %}
    {% set schema_name = generate_schema_name(var("snowplow__manifest_custom_schema","snowplow_manifest")) %}
    {{ return(schema_name) }}
  {% endif %}

{% endmacro %}

{# Returns the incremental manifest table reference. This table contains 1 row/model with the latest tstamp consumed #}
{% macro get_incremental_manifest_table_relation(package_name) %}

  {%- set manifest_schema=snowplow_utils.get_snowplow_manifest_schema() -%}

  {%- set incremental_manifest_table =
    api.Relation.create(
        database=target.database,
        schema=manifest_schema,
        identifier=package_name+'_incremental_manifest',
        type='table'
  ) -%}

  {{ return(incremental_manifest_table) }}

{% endmacro %}

{# Returns the current incremental table reference. This table contains lower and upper tstamp limits of the current run #}
{% macro get_current_incremental_tstamp_table_relation(package_name) %}

  {%- set manifest_schema=snowplow_utils.get_snowplow_manifest_schema() -%}

  {%- set current_incremental_tstamp_table =
    api.Relation.create(
        database=target.database,
        schema=manifest_schema,
        identifier=package_name+'_current_incremental_tstamp',
        type='table'
  ) -%}

  {{ return(current_incremental_tstamp_table) }}

{% endmacro %}

{# Creates or mutates incremental manifest table #}
{% macro create_incremental_manifest_table(package_name) -%}

  {{ return(adapter.dispatch('create_incremental_manifest_table', ['snowplow_utils'])(package_name)) }}

{% endmacro %}


{% macro default__create_incremental_manifest_table(package_name) -%}

  {% set required_columns = [
     ["model", dbt_utils.type_string()],
     ["last_success", dbt_utils.type_timestamp()],
  ] -%}

  {% set incremental_manifest_table = snowplow_utils.get_incremental_manifest_table_relation(package_name) -%}

  {% set incremental_manifest_table_exists = adapter.get_relation(incremental_manifest_table.database,
                                                                  incremental_manifest_table.schema,
                                                                  incremental_manifest_table.name) -%}

  {% if incremental_manifest_table_exists -%}

    {%- set columns_to_create = [] -%}

    {# map to lower to cater for snowflake returning column names as upper case #}
    {%- set existing_columns = adapter.get_columns_in_relation(incremental_manifest_table)|map(attribute='column')|map('lower')|list -%}

    {%- for required_column in required_columns -%}
      {%- if required_column[0] not in existing_columns -%}
        {%- do columns_to_create.append(required_column) -%}
      {%- endif -%}
    {%- endfor -%}

    {%- for column in columns_to_create -%}
      alter table {{ incremental_manifest_table }}
      add column {{ column[0] }} {{ column[1] }}
      default null;
    {% endfor -%}

    {%- if columns_to_create|length > 0 %}
      commit;
    {% endif -%}

  {%- else -%}

    create table if not exists {{ incremental_manifest_table }}
    (
    {% for column in required_columns %}
        {{ column[0] }} {{ column[1] }}{% if not loop.last %},{% endif %}
    {% endfor %}
    );
    commit;

  {%- endif -%}

{%- endmacro %}

{# Returns the sql to calculate the lower/upper limits of the run #}
{% macro get_run_limits(incremental_manifest_table, models_in_run) -%}
    
  {% set start_tstamp = "cast('"+ var("snowplow__start_date") + "' as " + dbt_utils.type_timestamp() + ")" %}

  {% set incremental_manifest_table_exists = adapter.get_relation(incremental_manifest_table.database,
                                                                  incremental_manifest_table.schema,
                                                                  incremental_manifest_table.name) -%}

  {% if incremental_manifest_table_exists -%}

    {% set last_success_query %}
      select min(last_success) as min_last_success,
             max(last_success) as max_last_success,
             coalesce(count(*), 0) as models
      from {{ incremental_manifest_table }} 
      where model in ({{ snowplow_utils.print_list(models_in_run) }})
    {% endset %}

  {% elif not incremental_manifest_table_exists %}
    
    {% set last_success_query %}
      select cast(null as {{ dbt_utils.type_timestamp() }}) as min_last_success,
             cast(null as {{ dbt_utils.type_timestamp() }}) as max_last_success,
             0 as models
    {% endset %} 

  {% endif %}

    {% set results = run_query(last_success_query) %}

    {% if execute %}

      {% set min_last_success = results.columns[0].values()[0] %}
      {% set max_last_success = results.columns[1].values()[0] %}
      {% set models_matched_from_manifest = results.columns[2].values()[0] %}

      {% if models_matched_from_manifest == 0 %}
        {# If no snowplow models are in the manifest, start from start_tstamp #}
        {% do snowplow_utils.log_message("Snowplow: No data in manifest. Processing data from start_date") %}

        {% set run_limits_query %}
          select {{start_tstamp}} as lower_limit,
                 least({{ dbt_utils.dateadd('day', var("snowplow__backfill_limit_days", 30), start_tstamp) }},
                       {{ dbt_utils.current_timestamp_in_utc() }}) as upper_limit
        {% endset %}

      {% elif models_matched_from_manifest < models_in_run|length %}
        {# If a new Snowplow model is added which isn't already in the manifest, replay all events up to upper_limit #}
        {% do snowplow_utils.log_message("Snowplow: New Snowplow incremental model. Backfilling") %}

        {% set run_limits_query %}
          select {{ start_tstamp }} as lower_limit,
                 least(max(last_success), {{ dbt_utils.dateadd('day', var("snowplow__backfill_limit_days", 30), start_tstamp) }}) as upper_limit
          from {{ incremental_manifest_table }} 
          where model in ({{ snowplow_utils.print_list(models_in_run) }})
        {% endset %}

      {% elif min_last_success != max_last_success %}
        {# If all models in the run exists in the manifest but are out of sync, replay from the min last success to the max last success #}
        {% do snowplow_utils.log_message("Snowplow: Snowplow incremental models out of sync. Syncing") %}

        {% set run_limits_query %}
          select {{ dbt_utils.dateadd('hour', -var("snowplow__lookback_window_hours", 6), 'min(last_success)') }} as lower_limit,
                 least(max(last_success), {{ dbt_utils.dateadd('day', var("snowplow__backfill_limit_days", 30), 'min(last_success)') }}) as upper_limit
          from {{ incremental_manifest_table }} 
          where model in ({{ snowplow_utils.print_list(models_in_run) }})
        {% endset %}

      {% else %}
        {# Else standard run of the model #}
        {% do snowplow_utils.log_message("Snowplow: Standard incremental run") %}

        {% set run_limits_query %}
          select 
            {{ dbt_utils.dateadd('hour', -var("snowplow__lookback_window_hours", 6), 'min(last_success)') }} as lower_limit,
            least({{ dbt_utils.dateadd('day', var("snowplow__backfill_limit_days", 30), 'min(last_success)') }}, 
                  {{ dbt_utils.current_timestamp_in_utc() }}) as upper_limit

          from {{ incremental_manifest_table }} 
          where model in ({{ snowplow_utils.print_list(models_in_run) }})
        {% endset %}

      {% endif %}

    {% endif %}

    {{ return(run_limits_query) }}
    
{% endmacro %}

{# Prints the run limits for the run to the console #}
{% macro print_run_limits(run_limits_query) -%}
  {# Derive limits from manifest instead of selecting from limits table since run_query executes during 2nd parse the limits table is yet to be updated. #}
  {% set results = run_query(run_limits_query) %}
   
  {% if execute %}

    {% set lower_limit = results.columns[0].values()[0].strftime("%Y-%m-%d %H:%M:%S") %}
    {% set upper_limit = results.columns[1].values()[0].strftime("%Y-%m-%d %H:%M:%S") %}

    {% do snowplow_utils.log_message("Snowplow: Processing data between " + lower_limit + " and " + upper_limit) %}

  {% endif %}

{%- endmacro %}


{# Updates the current_incremental_tstamp_table using the sql provided by get_run_limits() #}
{% macro update_current_incremental_tstamp_table(package_name, models_in_run) -%}

  {{ return(adapter.dispatch('update_current_incremental_tstamp_table', ['snowplow_utils'])(package_name, models_in_run)) }}

{% endmacro %}


{% macro default__update_current_incremental_tstamp_table(package_name, models_in_run) -%}

  {% set incremental_tstamp_table = snowplow_utils.get_current_incremental_tstamp_table_relation(package_name) -%}

  {% set incremental_manifest_table = snowplow_utils.get_incremental_manifest_table_relation(package_name) -%}

  {% set run_limits_query = snowplow_utils.get_run_limits(incremental_manifest_table, models_in_run) -%}

  create or replace table {{ incremental_tstamp_table }} as {{ run_limits_query }};
  commit;

  {{ snowplow_utils.print_run_limits(run_limits_query) }}

{%- endmacro %}


{% macro redshift__update_current_incremental_tstamp_table(package_name, models_in_run) -%}

  {% set incremental_tstamp_table = snowplow_utils.get_current_incremental_tstamp_table_relation(package_name) -%}

  {% set incremental_manifest_table = snowplow_utils.get_incremental_manifest_table_relation(package_name) -%}

  {% set run_limits_query = snowplow_utils.get_run_limits(incremental_manifest_table, models_in_run) -%}

  drop table if exists {{ incremental_tstamp_table }};
  create table {{ incremental_tstamp_table }} as ( {{ run_limits_query }} );
  commit;

  {{ snowplow_utils.print_run_limits(run_limits_query) }}

{%- endmacro %}

{# Returns an array of enabled models tagged with snowplow_web_incremental using dbts graph object. 
   Throws an error if untagged models are found that depend on the base_events_this_run model#}
{% macro get_enabled_snowplow_models(package_name) -%}
  
  {# If models_to_run var passed as part of a job, convert space seperated list of models to list and set to selected_models #}
  {% if var("models_to_run","")|length %}
    {% set selected_models = var("models_to_run","").split(" ") %}
  {% else %}
    {% set selected_models = none %}
  {% endif %}

  {% set enabled_models = [] %}
  {% set untagged_snowplow_models = [] %}
  {% set snowplow_model_tag = package_name+'_incremental' %}
  {% set snowplow_events_this_run_path = 'model.'+package_name+'.'+package_name+'_base_events_this_run' %}

  {% if execute %}
    
    {% set nodes = graph.nodes.values() | selectattr("resource_type", "equalto", "model") %}
    
    {% for node in nodes %}
      {# If selected_models is specified, filter for these models #}
      {% if selected_models is none or node.name in selected_models %}

        {% if node.config.enabled and snowplow_model_tag not in node.tags and snowplow_events_this_run_path in node.depends_on.nodes %}

          {%- do untagged_snowplow_models.append(node.name) -%}

        {% endif %}

        {% if node.config.enabled and snowplow_model_tag in node.tags %}

          {%- do enabled_models.append(node.name) -%}

        {% endif %}

      {% endif %}
      
    {% endfor %}

    {% if untagged_snowplow_models|length %}
    {#
      Prints warning for models that reference snowplow_base_events_this_run but are untagged as 'snowplow_web_incremental'
      Without this tagging these models will not be inserted into the manifest, breaking the incremental logic.
      Only catches first degree dependencies rather than all downstream models
      This could be an error rather than warning?!
    #}
      {%- do exceptions.raise_compiler_error("Snowplow Warning: Untagged models referencing '"+package_name+"_base_events_this_run'. Please refer to the Snowplow docs on tagging. " 
      + "Models: "+ ', '.join(untagged_snowplow_models)) -%}
    
    {% endif %}

  {% endif %}

  {{ return(enabled_models) }}

{%- endmacro %}

{# Returns an array of successfully executed models tagged with snowplow_web_incremental #}
{% macro get_successful_snowplow_models(package_name) -%}

  {% set enabled_snowplow_models = snowplow_utils.get_enabled_snowplow_models(package_name) -%}

  {% set successful_snowplow_models = [] %}

  {% if execute %}

    {% for res in results -%}
    
      {% if res.status == 'success' and res.node.name in enabled_snowplow_models  %}
    
        {%- do successful_snowplow_models.append(res.node.name) -%}

      {% endif %}
      
    {% endfor %}

    {{ return(successful_snowplow_models) }}

  {% endif %}

{%- endmacro %}

{# Updates the incremental manifest table at the run end with the latest tstamp consumed per model #}
{% macro update_incremental_manifest_table(package_name, models) -%}

  {{ return(adapter.dispatch('update_incremental_manifest_table', ['snowplow_utils'])(package_name, models)) }}

{% endmacro %}

{#TODO: Add GBQ and Snowflake support. Can probably simplify with a merge statement #}
{% macro default__update_incremental_manifest_table(package_name, models) -%}

  {% set incremental_manifest_table = snowplow_utils.get_incremental_manifest_table_relation(package_name) -%}

  {% if models %}

    begin transaction;
      --temp table to find the greatest last_success per model.
      --this protects against partial backfills causing the last_success to move back in time.
      create temporary table snowplow_models_last_success as (
        select
          a.model,
          greatest(a.last_success, b.last_success) as last_success

        from (

          select 
            model, 
            last_success 

          from 
            (select max(collector_tstamp) as last_success from {{ ref(package_name+'_base_events_this_run') }}),
            ({% for model in models %} select '{{model}}' as model {%- if not loop.last %} union all {% endif %} {% endfor %})

          where last_success is not null -- if run contains no data don't add to manifest

        ) a
        left join {{ incremental_manifest_table }} b
        on a.model = b.model
        );

      delete from {{ incremental_manifest_table }} where model in (select model from snowplow_models_last_success);
      insert into {{ incremental_manifest_table }} (select * from snowplow_models_last_success);

    end transaction;

    drop table snowplow_models_last_success;
  {% endif %}

{%- endmacro %}

{# Calls functions to teardown all snowplow manifest tables or remove models from the manifest. Executes on-run-start  #}
{% macro snowplow_run_start_cleanup(package_name, teardown_all, models_to_remove) %}
  
  {%- if teardown_all -%}
    {%- do snowplow_utils.snowplow_teardown_all(package_name) -%}
  {%- endif -%}

  {%- if models_to_remove|length -%}
    {%- do snowplow_utils.snowplow_delete_from_manifest(package_name, models_to_remove) -%}
  {%- endif -%}

{% endmacro %}

{# pre-hook for incremental runs #}
{% macro snowplow_incremental_pre_hook(package_name) %}

  {{ snowplow_utils.create_incremental_manifest_table(package_name) }}

  {% set models_in_run = snowplow_utils.get_enabled_snowplow_models(package_name) -%}

  {{ snowplow_utils.update_current_incremental_tstamp_table(package_name, models_in_run) }}

{% endmacro %}

{# post-hook for incremental runs #}
{% macro snowplow_incremental_post_hook(package_name) %}

  {% set successful_snowplow_models = snowplow_utils.get_successful_snowplow_models(package_name) -%}
        
  {{ snowplow_utils.update_incremental_manifest_table(package_name, successful_snowplow_models) }}                  

{% endmacro %}
