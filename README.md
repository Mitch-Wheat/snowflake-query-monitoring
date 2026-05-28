# Snowflake Monitoring

If you don't have a Snowflake DBA or you're a Snowflake DBA that wants to get some assistence across all the databases in your account, you can leverage Snowflake's built-in LLM functionality.

Things often fall through the cracks because it's no one's job to constantly monitor and improve the query workload. This can result in higher than necessary compute costs and slow queries. 

In Snowflake, this might fall into one or more categories:

1. Poorly designed schema
2. Queries that use inefficient anti-patterns (such as NOT IN, or accidental JOIN explosions)
3. Inefficient data loading patterns and long running ELT/ETL processes
4. Poorly clustered tables and insufficient partition pruning (see [Snowflake: Clustered Tables](https://mitchwheat.com/2026/04/03/snowflake-clustered-tables/))

This project leverages Snowflake's hosted LLM models to look for and analyze expensive or poorly performing queries.

When using Snowflake Cortex, your data never leaves Snowflake's security boundaries. Customer data is strictly isolated within your account boundary and is never used to train or fine-tune third-party large language models (LLMs).  See [Snowflake AI Trust and Safety FAQs](https://www.snowflake.com/en/legal/compliance/snowflake-ai-trust-and-safety/)

We can collect the most expensive queries (by cost and by duration) from the [SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/query_history) view, and from [SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS](https://docs.snowflake.com/en/sql-reference/account-usage/query_insights) Additionally,  we gather warehouse cost spikes from view [SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history).

The least permissions to query these are **GOVERNANCE_VIEWER** for query history and **USAGE_VIEWER** for metering history.

## Steps to create:

If you don't already have one that's suitable, create an email distribution list in your email system e.g. 'snowflake.monitoring@mycompany.com'

Then set up a Snowflake email notification integration to use that distribution list (or use an existing one): 

```SQL
    CREATE NOTIFICATION INTEGRATION IF NOT EXISTS MONITORING_EMAIL_NOTIFICATION_INTEGRATION
        TYPE = EMAIL
        ENABLED = TRUE
        ALLOWED_RECIPIENTS = ('snowflake.monitoring@mycompany.com');
```
        

