# Snowflake LLM Assisted Monitoring

This project leverages Snowflake's hosted LLM models to look for and analyze expensive or poorly performing queries. It sends an HTML formatted email to an email address or an email distribution list (preferrable).

If you don't have a Snowflake DBA or you're a Snowflake DBA that wants to get some assistence across all the databases in your account, you can leverage Snowflake's built-in LLM functionality.

Things often fall through the cracks because it's no one's job to constantly monitor and improve the query workload. This can result in higher than necessary compute costs and slow queries. 

In Snowflake, this might fall into one or more categories:

1. Poorly designed schema
2. Queries that use inefficient anti-patterns (such as NOT IN, or accidental JOIN explosions)
3. Inefficient data loading patterns and long running ELT/ETL processes
4. Poorly clustered tables and insufficient partition pruning (see [Snowflake: Clustered Tables](https://mitchwheat.com/2026/04/03/snowflake-clustered-tables/))

When using Snowflake Cortex, your data never leaves Snowflake's security boundaries. Customer data is strictly isolated within your account boundary and is never used to train or fine-tune third-party large language models (LLMs).  See [Snowflake AI Trust and Safety FAQs](https://www.snowflake.com/en/legal/compliance/snowflake-ai-trust-and-safety/) That said, you should check with the relevant people at your company to make sure it's allowed.

We can collect the most expensive queries (by cost and by duration) from the [SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/query_history) view, and from [SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS](https://docs.snowflake.com/en/sql-reference/account-usage/query_insights) Additionally,  we gather warehouse cost spikes from view [SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history).

The role permissions to query these are **GOVERNANCE_VIEWER** for query history and **USAGE_VIEWER** for metering history.

## Steps to create:

If you don't already have one that's suitable, create an email distribution list in your email system e.g. 'snowflake.monitoring@mycompany.com'

Then set up a Snowflake email notification integration to use that distribution list (or use an existing one): 

```SQL
    CREATE NOTIFICATION INTEGRATION IF NOT EXISTS MONITORING_EMAIL_NOTIFICATION_INTEGRATION
        TYPE = EMAIL
        ENABLED = TRUE
        ALLOWED_RECIPIENTS = ('snowflake.monitoring@mycompany.com');
```

By default, the script uses the following database and schema:

```SQL
	CREATE DATABASE IF NOT EXISTS MONITORING;
	CREATE SCHEMA IF NOT EXISTS MONITORING.AGENT;

	USE DATABASE MONITORING;
	USE SCHEMA AGENT;
```

Change these to suit your environment.
   
Then run in the query_monitoring.sql script to create tables and stored procedures.

This is the entry point:

```SQL
CREATE OR REPLACE PROCEDURE QUERY_MONITORING
(
    interval_days INT DEFAULT 7
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_last_run TIMESTAMP_NTZ;
BEGIN
    ALTER SESSION SET QUERY_TAG = 'QUERY_MONITORING';
   
    CALL RUN_MONITORING_QUERIES(:interval_days);

    SELECT MAX(run_timestamp) INTO :v_last_run FROM AGENT.QUERY_INSIGHTS_HISTORY;

    CALL SEND_FINDINGS_TO_CORTEX(:v_last_run, 'claude-opus-4-7');

    CALL SEND_FINDINGS_EMAIL(:v_last_run);
 
    ALTER SESSION UNSET QUERY_TAG;
    
    RETURN
        'SUCCESS' || ' | run_timestamp=' || :v_last_run;    
    
EXCEPTION
    WHEN OTHER THEN
        RETURN 'FAILED | ' || SQLERRM;    
END;
$$;
```

If you want to schedule to run periodically:

```SQL
	CREATE OR REPLACE TASK MONITORING.AGENT.WEEKLY_MONITORING_TASK
	    WAREHOUSE = PLATFORM_WH
	    SCHEDULE  = 'USING CRON 0 8 * * 1 Australia/Perth'  -- Runs every Monday at 8am AWST
	    COMMENT   = 'Runs the query monitoring agent weekly'
	AS
	    CALL MONITORING.AGENT.QUERY_MONITORING();
	 
	-- Activate the task
	ALTER TASK MONITORING.AGENT.WEEKLY_MONITORING_TASK RESUME;
```

## Things to be aware of:

1. Models get superceeded and deprecated 
2. Cost of different models and overall LLM token spend
3. Legal: make sure you are allowed to send query text to the LLM end point
4. LLM advice quality may vary. Experiment with various prompts and models to see what works best in your environment.


To determine if you have access and to find exactly which models are available for your specific region, you can run the following query:
```SQL
    SHOW CORTEX AI MODELS;
```

Models supported:
https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-regional-availability

