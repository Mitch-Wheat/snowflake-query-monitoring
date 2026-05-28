# Snowflake Monitoring

If you don't have a Snowflake DBA or you're a Snowflake DBA that wants to get some assistence across all the databases in your account, you can leverage Snowflake's built-in LLM functionality.

Things often fall through the cracks because it's no one's job to constantly monitor and improve the query workload. This can result in higher than necessary compute costs and slow queries. 

In Snowflake, this might fall into one or more categories:

1. Poorly designed schema
2. Queries that use inefficient anti-patterns (such as NOT IN, or accidental JOIN explosions)
3. Inefficient data loading patterns and long running ELT/ETL processes
4. Poorly clustered tables and insufficient partition pruning (see [Snowflake: Clustered Tables](https://mitchwheat.com/2026/04/03/snowflake-clustered-tables/))

This project leverages Snowflake's hosted LLM models to look for and analyze expensive or poorly performing queries.
