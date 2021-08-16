{# Tests both RS (delete/insert) and BQ (merge) snowplow_incremental materialization with lookback disabled.
   upsert_date_key: RS only. Key used to limit the table scan
   partition_by: BQ only. Key used to limit table scan #}

{{ 
  config(
    materialized='snowplow_incremental',
    unique_key='id',
    upsert_date_key='start_tstamp',
    disable_upsert_lookback=true,
    partition_by = {
      "field": "start_tstamp",
      "data_type": "timestamp",
      "granularity": "day"
    },
    tags=["requires_script"]
  ) 
}}

with data as (
  select * from {{ ref('data_snowplow_incremental') }}
)

{% if snowplow_utils.snowplow_is_incremental() %}

  select 
    id, 
    start_tstamp

  from data
  where run = 2

{% else %}
  
  select 
    id, 
    start_tstamp

  from data
  where run = 1

{% endif %}

