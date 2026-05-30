CREATE DATABASE IF NOT EXISTS MONITORING;
CREATE SCHEMA IF NOT EXISTS MONITORING.AGENT;

USE DATABASE MONITORING;
USE SCHEMA AGENT;

-- You can use an existing email integration if you have one defined.
-- Best practice is to use one that notifies to an email distribution list:
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS MONITORING_EMAIL_NOTIFICATION_INTEGRATION
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('snowflake.monitoring@mycompany.com');
    
----------------------------------------------------------------

CREATE OR REPLACE TABLE QUERY_HISTORY_HISTORY
(
    id                       NUMBER AUTOINCREMENT PRIMARY KEY,
    run_timestamp            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    query_parameterized_hash VARCHAR,
    number_of_executions     INT,
    total_credits_used       NUMBER(38,2),
    avg_elapsed_time_s       NUMBER(38,2),
    total_elapsed_time_s     NUMBER(38,2),
    total_partitions_scanned INT,
    total_partitions         INT,
    total_spilled_to_local_storage  NUMBER(38,2),    
    total_spilled_to_remote_storage NUMBER(38,2),    
    last_query_text          VARCHAR,
    last_user_name           VARCHAR(128),
    last_warehouse_name      VARCHAR(128),
    last_database_name       VARCHAR(128),
    last_query_id            VARCHAR(60),
    execution_status         VARCHAR(50),
    error_message            VARCHAR
);

COMMENT ON TABLE MONITORING.AGENT.QUERY_HISTORY_HISTORY IS
    'Historical snapshots of the top 20 queries in the account via SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY. Populated by RUN_MONITORING_QUERIES()';

CREATE OR REPLACE TABLE QUERY_INSIGHTS_HISTORY
(
    id                       NUMBER AUTOINCREMENT PRIMARY KEY,
    run_timestamp            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    query_parameterized_hash VARCHAR,
    number_of_executions     INT,
    avg_elapsed_time_s       NUMBER(38,2),
    total_elapsed_time_s     NUMBER(38,2),
    warehouse_name           VARCHAR(128),
    message                  VARCHAR,
    suggestions              VARCHAR(4000),
    insight_topic            VARCHAR(100)
);

COMMENT ON TABLE MONITORING.AGENT.QUERY_INSIGHTS_HISTORY IS
    'Historical snapshots of the top 20 queries in the account via SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS. Populated by RUN_MONITORING_QUERIES()';

CREATE OR REPLACE TABLE COST_SPIKES
(
    id                          NUMBER AUTOINCREMENT PRIMARY KEY,
    run_timestamp               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    warehouse_name              VARCHAR(128),
    usage_date                  DATE,
    current_day_credits         NUMBER(10,2),
    avg_daily_credits_last_week NUMBER(10,2),
    spike_ratio                 NUMBER(10,2)
);

COMMENT ON TABLE MONITORING.AGENT.COST_SPIKES IS
    'Historical snapshots of any warehouse cost spikes via SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY. Populated by WAREHOUSE_COST_SPIKES()';
 
CREATE OR REPLACE TABLE AGENT_FINDINGS
(
    id               NUMBER AUTOINCREMENT PRIMARY KEY,
    RUN_TIMESTAMP    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CATEGORY         VARCHAR(50),
    PROMPT           VARCHAR,
    AI_MODEL         VARCHAR,
    AI_ANALYSIS      VARCHAR
);

COMMENT ON TABLE MONITORING.AGENT.AGENT_FINDINGS IS
    'Stores the prompt, model and LLM response. Populated by SEND_FINDINGS_TO_CORTEX()';
    
----------------------------------------------------------------

CREATE OR REPLACE PROCEDURE GET_SESSION_TIMEZONE()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    tz STRING;
BEGIN
    SHOW PARAMETERS LIKE 'TIMEZONE' IN SESSION;

    SELECT "value" 
    INTO :tz
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    WHERE LOWER("key") = 'timezone';

    RETURN tz;
END;
$$;

-------------------------------------------------------------------
 
CREATE OR REPLACE PROCEDURE WAREHOUSE_COST_SPIKES
(
    daily_credit_cost_threshold NUMBER DEFAULT 2, -- Only show warehouses exceeding this credit cost per day
    percent_increase_threshold  NUMBER DEFAULT 50 -- 50% increase = 1.5x, 100% increase = 2x etc.
)
RETURNS TABLE
(
    warehouse_name VARCHAR,
    usage_date DATE,
    current_day_credits NUMBER(10,2),
    avg_daily_credits_last_week NUMBER(10,2),
    spike_ratio NUMBER(10,2)
)
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    res RESULTSET;
BEGIN
 
    IF (:percent_increase_threshold < 2) THEN
        percent_increase_threshold := 50;
    END IF;
 
    res :=
    (
        WITH daily_usage AS
        (
            -- Calculate total credits used per warehouse per day
            SELECT
                warehouse_name,
                DATE(start_time) AS usage_date,
                SUM(credits_used) AS daily_credits
            FROM
                SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
            WHERE
                start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP()) -- Look back 2 weeks for context
            GROUP BY
                warehouse_name,
                usage_date
        ),
        weekly_stats AS
        (
            -- Calculate the average daily cost over the previous 7 days (sliding window)
            SELECT
                warehouse_name,
                usage_date,
                daily_credits,
                AVG(daily_credits) OVER (PARTITION BY warehouse_name ORDER BY usage_date
                                         ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING) AS avg_daily_credits_last_week
            FROM
                daily_usage
        )
        -- Spikes: current day > (1 + %increase_threshold/100) of last week's daily avg and cost > threshold
        SELECT
            warehouse_name,
            usage_date,
            ROUND(daily_credits, 2) AS current_day_credits,
            ROUND(avg_daily_credits_last_week, 2) AS avg_daily_credits_last_week,
            ROUND(daily_credits / NULLIF(avg_daily_credits_last_week, 0), 2) AS spike_ratio
        FROM
            weekly_stats
        WHERE
            avg_daily_credits_last_week IS NOT NULL
            AND daily_credits >= (avg_daily_credits_last_week * (1 + (:percent_increase_threshold/100.0))) -- % increase threshold
            AND daily_credits >= :daily_credit_cost_threshold  -- Only show warehouse if cost is higher than min cost threshold
        ORDER BY
            spike_ratio DESC,
            usage_date DESC
    );
 
    RETURN TABLE(res); 
END;
$$;
 
-------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE to_html_table(query_id VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.13'
PACKAGES = ('snowflake-snowpark-python', 'pandas', 'tabulate', 'regex', 'sqlparse')
HANDLER = 'to_html_table'
EXECUTE AS CALLER
AS $$
import pandas as pd
import tabulate
import regex
import sqlparse
import html
 
def df_to_outlook_html(df: pd.DataFrame) -> str:
    def td_style(header=False, zebra=False):
        base = "border:1.0pt solid #dddddd;padding:7.5pt;font-family:Arial,sans-serif;"
        if header:
            return base + "background:#0078d4;color:white;font-weight:bold;"
        if zebra:
            return base + "background:#f2f2f2;color:black;vertical-align:top;"
        return base + "color:black;vertical-align:top;"
 
    def escape_cell(val):
        escaped = html.escape("" if pd.isna(val) else str(val))
        return escaped.replace("\n", "<br>")
 
    html_parts = []
 
    html_parts.append(
        '<table border="0" cellspacing="0" cellpadding="0" width="100%" '
        'style="width:100%;border-collapse:collapse;">'
    )
 
    # Header
    html_parts.append("<tr>")
    for col in df.columns:
        html_parts.append(
            f'<td style="{td_style(header=True)}">{html.escape(str(col))}</td>'
        )
    html_parts.append("</tr>")
 
    # Body
    for i, row in enumerate(df.itertuples(index=False, name=None)):
        zebra = (i % 2 == 0)
        html_parts.append("<tr>")
        for val in row:
            html_parts.append(
                f'<td style="{td_style(zebra=zebra)}">{escape_cell(val)}</td>'
            )
        html_parts.append("</tr>")
 
    html_parts.append("</table>")
    return "".join(html_parts)
   
def to_html_table(session, queryOrQueryId = None):
    if(queryOrQueryId is None):
        df = session.sql("""SELECT * FROM table(result_scan(last_query_id()))""").to_pandas()
    elif(bool(regex.match("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", queryOrQueryId))):
        df = session.sql(f"""SELECT * FROM table(result_scan('{queryOrQueryId}'))""").to_pandas()
    else:
        statements = sqlparse.parse(queryOrQueryId)
        if statements and statements[0].get_type() == 'SELECT':
            df = session.sql(queryOrQueryId).to_pandas()
        else:
            raise ValueError("Invalid query type. Only SELECT statements are supported.")
   
    html = df_to_outlook_html(df)
   
    return html
$$;

-- Modified from here: https://stackoverflow.com/questions/72959274/how-to-generate-stackoverflow-table-markdown-from-snowflake 
CREATE OR REPLACE PROCEDURE to_markdown_table(query_id VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.13'
PACKAGES = ('snowflake-snowpark-python', 'pandas', 'tabulate', 'regex', 'sqlparse')
HANDLER = 'markdown_table'
EXECUTE AS CALLER
AS $$
import pandas as pd
import tabulate
import regex
import sqlparse

def markdown_table(session, queryOrQueryId = None):
    if(queryOrQueryId is None):
        pandas_result = session.sql("""SELECT * FROM table(result_scan(last_query_id()))""").to_pandas()
    elif(bool(regex.match("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", queryOrQueryId))):
        pandas_result = session.sql(f"""SELECT * FROM table(result_scan('{queryOrQueryId}'))""").to_pandas()
    else:
        statements = sqlparse.parse(queryOrQueryId)
        if statements and statements[0].get_type() == 'SELECT':
            pandas_result = session.sql(queryOrQueryId).to_pandas()
        else:
            raise ValueError("Invalid query type. Only SELECT statements are supported.")
    return pandas_result.to_markdown()
$$;
 
-------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE top_successful_queries_last_7_days
(
    run_timestamp TIMESTAMP_NTZ,
    sort_column VARCHAR(100) DEFAULT 'total_elapsed_time_s'
)
RETURNS TABLE
(
    RUN_TIMESTAMP TIMESTAMP_NTZ,
    QUERY_PARAMETERIZED_HASH VARCHAR,
    NUMBER_OF_EXECUTIONS INT,
    TOTAL_CREDITS_USED NUMBER(38,2),
    AVG_ELAPSED_TIME_S NUMBER(38,2),
    TOTAL_ELAPSED_TIME_S NUMBER(38,2),
    TOTAL_PARTITIONS_SCANNED INT,
    TOTAL_PARTITIONS INT,
    TOTAL_SPILLED_TO_LOCAL_STORAGE NUMBER(38,2),    
    TOTAL_SPILLED_TO_REMOTE_STORAGE NUMBER(38,2),
    LAST_QUERY_TEXT VARCHAR,
    LAST_USER_NAME VARCHAR,
    LAST_WAREHOUSE_NAME VARCHAR,
    LAST_DATABASE_NAME VARCHAR,
    LAST_QUERY_ID VARCHAR,
    EXECUTION_STATUS VARCHAR,
    ERROR_MESSAGE VARCHAR
)
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    res RESULTSET;
BEGIN

    res :=
    (
        SELECT * FROM
        (
            SELECT TOP 20
                :run_timestamp as run_timestamp,
                query_parameterized_hash,
                COUNT(1)::NUMBER as number_of_executions,
                SUM(credits_used_cloud_services)::NUMBER(38,2) as total_credits_used,
                (AVG(total_elapsed_time)/1000)::NUMBER(38,2) as avg_elapsed_time_s,
                (SUM(total_elapsed_time)/1000)::NUMBER(38,2) as total_elapsed_time_s,
                SUM(partitions_scanned)::INT as total_partitions_scanned,
                SUM(partitions_total)::INT as total_partitions,   
                (SUM(bytes_spilled_to_local_storage)/(1024 * 1024))::NUMBER(38,2) as total_spilled_to_local_storage_MB,                   
                (SUM(bytes_spilled_to_remote_storage)/(1024 * 1024))::NUMBER(38,2) as total_spilled_to_remote_storage_MB,   
                max_by(query_text, start_time)::VARCHAR as last_query_text,
                max_by(user_name, start_time)::VARCHAR as last_user_name,
                max_by(warehouse_name, start_time)::VARCHAR as last_warehouse_name,
                max_by(database_name, start_time)::VARCHAR as last_database_name,
                max_by(query_id, start_time)::VARCHAR as last_query_id,
                'SUCCESS' AS execution_status,
                NULL::VARCHAR AS error_message             
            FROM
                SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
            WHERE
                start_time >= current_date - 7 AND end_time < current_date
                AND execution_status = 'SUCCESS'
                AND QUERY_TYPE != 'SHOW'
                AND QUERY_TAG != 'QUERY_MONITORING'
            GROUP BY
                query_parameterized_hash
            HAVING
                (SUM(total_elapsed_time)/1000) > 60
            ORDER BY
                total_elapsed_time_s DESC
        )
 
        UNION
 
        SELECT * FROM
        (
            SELECT TOP 20
                :run_timestamp as run_timestamp,
                query_parameterized_hash,
                COUNT(1)::NUMBER as number_of_executions,
                SUM(credits_used_cloud_services)::NUMBER(38,2) as total_credits_used,
                (AVG(total_elapsed_time)/1000)::NUMBER(38,2) as avg_elapsed_time_s,
                (SUM(total_elapsed_time)/1000)::NUMBER(38,2) as total_elapsed_time_s,
                SUM(partitions_scanned)::NUMBER as total_partitions_scanned,
                SUM(partitions_total)::NUMBER as total_partitions,   
                SUM(bytes_spilled_to_local_storage)/(1024 * 1024) as total_spilled_to_local_storage_MB,                   
                SUM(bytes_spilled_to_remote_storage)/(1024 * 1024) as total_spilled_to_remote_storage_MB,                  
                max_by(query_text, start_time)::VARCHAR as last_query_text,
                max_by(user_name, start_time)::VARCHAR as last_user_name,
                max_by(warehouse_name, start_time)::VARCHAR as last_warehouse_name,
                max_by(database_name, start_time)::VARCHAR as last_database_name,
                max_by(query_id, start_time)::VARCHAR as last_query_id,
                'SUCCESS' AS execution_status,
                NULL::VARCHAR AS error_message      
            FROM
                SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
            WHERE
                start_time >= current_date - 7 AND end_time < current_date
                AND execution_status = 'SUCCESS'
                AND QUERY_TYPE != 'SHOW'
                AND QUERY_TAG != 'QUERY_MONITORING'
            GROUP BY
                query_parameterized_hash
            HAVING
                (SUM(total_elapsed_time)/1000) > 60           
            ORDER BY
                total_credits_used DESC
        )
        ORDER BY
            CASE WHEN :sort_column = 'total_elapsed_time_s' THEN total_elapsed_time_s END DESC,
            CASE WHEN :sort_column = 'total_credits_used'   THEN total_credits_used   END DESC
    );
  
    RETURN TABLE(res);

END;
$$;

-------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE top_duration_failed_queries_last_7_days
(
    run_timestamp TIMESTAMP_NTZ
)
RETURNS TABLE
(
    run_timestamp TIMESTAMP_NTZ,
    query_parameterized_hash VARCHAR,
    number_of_executions INT,
    total_credits_used NUMBER(38,2),
    avg_elapsed_time_s NUMBER(38,2),
    total_elapsed_time_s NUMBER(38,2),
    total_partitions_scanned INT,
    total_partitions INT,
    total_spilled_to_local_storage NUMBER(38,2),    
    total_spilled_to_remote_storage NUMBER(38,2),    
    last_query_text VARCHAR,
    last_user_name VARCHAR,
    last_warehouse_name VARCHAR,
    last_database_name VARCHAR,
    last_query_id VARCHAR,
    execution_status VARCHAR,
    error_message VARCHAR
)
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    res RESULTSET;
BEGIN

    res :=
    (
        SELECT
            :run_timestamp as run_timestamp,
            query_parameterized_hash,
            COUNT(1)::NUMBER as number_of_executions,
            SUM(credits_used_cloud_services)::NUMBER(38,2) as total_credits_used,
            (AVG(total_elapsed_time)/1000)::NUMBER(38,2) as avg_elapsed_time_s,
            (SUM(total_elapsed_time)/1000)::NUMBER(38,2) as total_elapsed_time_s,
            SUM(partitions_scanned)::NUMBER as total_partitions_scanned,
            SUM(partitions_total)::NUMBER as total_partitions,   
            SUM(bytes_spilled_to_local_storage)/(1024 * 1024) as total_spilled_to_local_storage_MB,                   
            SUM(bytes_spilled_to_remote_storage)/(1024 * 1024) as total_spilled_to_remote_storage_MB,             
            max_by(query_text, start_time)::VARCHAR as last_query_text,
            max_by(user_name, start_time)::VARCHAR as last_user_name,
            max_by(warehouse_name, start_time)::VARCHAR as last_warehouse_name,
            max_by(database_name, start_time)::VARCHAR as last_database_name,
            max_by(query_id, start_time)::VARCHAR as last_query_id,
            'FAIL' AS execution_status,
            max_by(error_message, start_time)::VARCHAR AS error_message
        FROM
            snowflake.account_usage.query_history
        WHERE
            start_time >= current_date - 7 AND end_time < current_date
            AND execution_status = 'FAIL'
            AND QUERY_TYPE != 'SHOW'
            AND QUERY_TAG != 'QUERY_MONITORING'
        GROUP BY
            query_parameterized_hash
        HAVING
            (SUM(total_elapsed_time)/1000) > 60
        ORDER BY
            total_elapsed_time_s DESC
    );
  
    RETURN TABLE(res);

END;
$$;

-------------------------------------------------------------------

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
 
-------------------------------------------------------------------

CREATE OR REPLACE FUNCTION GetLatestQueryHistory()
RETURNS TABLE
(
    NUMBER_OF_EXECUTIONS INT,
    TOTAL_CREDITS_USED NUMBER(38,2),
    AVG_ELAPSED_TIME_S NUMBER(38,2),
    TOTAL_ELAPSED_TIME_S NUMBER(38,2),
    TOTAL_PARTITIONS_SCANNED INT,
    TOTAL_PARTITIONS         INT,
    TOTAL_SPILLED_TO_LOCAL_STORAGE  NUMBER(38,2),    
    TOTAL_SPILLED_TO_REMOTE_STORAGE NUMBER(38,2),       
    LAST_QUERY_TEXT VARCHAR,
    LAST_DATABASE_NAME VARCHAR,
    EXECUTION_STATUS VARCHAR,
    ERROR_MESSAGE VARCHAR
)
LANGUAGE SQL
AS
$$
    SELECT
        NUMBER_OF_EXECUTIONS,
        ROUND(TOTAL_CREDITS_USED, 2)::NUMBER(38,2) AS TOTAL_CREDITS_USED,
        ROUND(AVG_ELAPSED_TIME_S, 2)::NUMBER(38,2) AS AVG_ELAPSED_TIME_S,
        ROUND(TOTAL_ELAPSED_TIME_S, 0)::NUMBER(38,2) AS TOTAL_ELAPSED_TIME_S,
        ROUND(TOTAL_PARTITIONS_SCANNED, 0)::NUMBER(38,2) AS TOTAL_PARTITIONS_SCANNED,
        ROUND(TOTAL_PARTITIONS, 0)::NUMBER(38,2) AS TOTAL_PARTITIONS,
        ROUND(TOTAL_SPILLED_TO_LOCAL_STORAGE, 2)::NUMBER(38,2) AS TOTAL_SPILLED_TO_LOCAL_STORAGE,        
        ROUND(TOTAL_SPILLED_TO_REMOTE_STORAGE, 2)::NUMBER(38,2) AS TOTAL_SPILLED_TO_REMOTE_STORAGE,        
        LEFT(LAST_QUERY_TEXT, 4000) AS LAST_QUERY_TEXT,
        LAST_DATABASE_NAME,
        EXECUTION_STATUS,
        IFNULL(ERROR_MESSAGE, '') AS ERROR_MESSAGE
    FROM
        AGENT.QUERY_HISTORY_HISTORY
    WHERE
        run_timestamp = (SELECT MAX(run_timestamp) FROM AGENT.QUERY_HISTORY_HISTORY)
$$;
 
-------------------------------------------------------------------
 
CREATE OR REPLACE FUNCTION GetLatestQueryInsights()
RETURNS TABLE
(
    NUMBER_OF_EXECUTIONS INT,
    AVG_ELAPSED_TIME_S NUMBER(38,2),
    TOTAL_ELAPSED_TIME_S NUMBER(38,2),
    MESSAGE VARCHAR,
    SUGGESTIONS VARCHAR(4000),
    INSIGHT_TOPIC VARCHAR(100)
)
LANGUAGE SQL
AS
$$
    SELECT
        NUMBER_OF_EXECUTIONS,
        AVG_ELAPSED_TIME_S,
        TOTAL_ELAPSED_TIME_S,
        LEFT(message, 4000) AS message,
        LEFT(suggestions, 4000) AS suggestions,
        insight_topic
    FROM
        AGENT.QUERY_INSIGHTS_HISTORY
    WHERE
        run_timestamp = (SELECT MAX(run_timestamp) FROM AGENT.QUERY_INSIGHTS_HISTORY)
$$;

-------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE RUN_MONITORING_QUERIES
(
    interval_days INT DEFAULT 7
)
RETURNS VARCHAR  -- returns NULL
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
BEGIN
 
    -- Query insights:
    INSERT INTO MONITORING.AGENT.QUERY_INSIGHTS_HISTORY
        (run_timestamp, query_parameterized_hash, number_of_executions, avg_elapsed_time_s, total_elapsed_time_s,
         warehouse_name, message, suggestions, insight_topic)
    SELECT TOP 10
        :v_run_ts,
        query_parameterized_hash,
        COUNT(1) as number_of_executions,
        (AVG(total_elapsed_time)/1000)::NUMBER(38,2) as avg_elapsed_time_s,
        (SUM(total_elapsed_time)/1000)::NUMBER(38,2) as total_elapsed_time_s,
        max_by(warehouse_name, start_time)::VARCHAR as warehouse_name,
        max_by(message, start_time)::VARCHAR as message,
        max_by(suggestions, start_time)::VARCHAR as suggestions,
        max_by(insight_topic, start_time)::VARCHAR  as insight_topic
    FROM
        SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS
    WHERE
        start_time >= current_date - 7 AND end_time < current_date
        AND is_opportunity = true
    GROUP BY
        query_parameterized_hash
    ORDER BY
        total_elapsed_time_s DESC;
 
    -- Query History (successes and failures):
    CALL MONITORING.AGENT.top_successful_queries_last_7_days(:v_run_ts);
    INSERT INTO MONITORING.AGENT.QUERY_HISTORY_HISTORY
        (run_timestamp, query_parameterized_hash, number_of_executions, total_credits_used, avg_elapsed_time_s,
         total_elapsed_time_s, total_partitions_scanned, total_partitions, total_spilled_to_local_storage, total_spilled_to_remote_storage,
         last_query_text, last_user_name, last_warehouse_name, last_database_name, last_query_id, execution_status, error_message)
    SELECT TOP 10 * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    CALL MONITORING.AGENT.top_duration_failed_queries_last_7_days(:v_run_ts);
    INSERT INTO MONITORING.AGENT.QUERY_HISTORY_HISTORY
        (run_timestamp, query_parameterized_hash, number_of_executions, total_credits_used, avg_elapsed_time_s,
         total_elapsed_time_s, total_partitions_scanned, total_partitions, total_spilled_to_local_storage, total_spilled_to_remote_storage,
         last_query_text, last_user_name, last_warehouse_name, last_database_name, last_query_id, execution_status, error_message)
    SELECT TOP 10 * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
   
    -- Cost spikes:
    CALL MONITORING.AGENT.WAREHOUSE_COST_SPIKES(daily_credit_cost_threshold => 2);
    INSERT INTO MONITORING.AGENT.COST_SPIKES(run_timestamp, warehouse_name, usage_date,
                                            current_day_credits, avg_daily_credits_last_week, spike_ratio)
    SELECT :v_run_ts, * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));   
   
END;
$$;
 
-------------------------------------------------------------------
 
-- https://docs.snowflake.com/en/guides-overview-ai-features
--
-- In my testing, the claude-sonnet models performed well (although more expensive than some of the other models).
-- 'claude-opus-4-7' is one of the more capable models.
-- You should experiment with different models to see which suits your needs best.
--
-- To show the models available in your region:
--    SHOW CORTEX AI MODELS;
--
CREATE OR REPLACE PROCEDURE SEND_FINDINGS_TO_CORTEX
(
    run_timestamp   TIMESTAMP_NTZ,
    ai_model        VARCHAR(100) DEFAULT 'claude-opus-4-7'
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_prompt          VARCHAR DEFAULT '';
    v_ai_analysis     VARCHAR DEFAULT '';
    v_markdown_table  VARCHAR DEFAULT '';
    v_prompt_preamble VARCHAR DEFAULT 'You are an expert Snowflake database developer. You focus on practical advice that will make big improvements in performance and cost savings. Do not waste time on pleasantries. You are working with other senior database developers who understand Snowflake deeply, so be concise and specific with your recommendations. Do not offer follow-up options: the user can only contact you once, so include all necessary information and scripts in your reply. Present your findings in a 3 column table with headings, "Issue", "Recommendation", "Estimated Impact", with a separate table for the Implementation Plan. Render your output as HTML tables with inline CSS styling for Microsoft Outlook. Ensure your answers are factual and that the HTML output is well formed. Today''s date is ' || TO_VARCHAR(CURRENT_DATE(), 'YYYY-MM-DD') || '.\n';
 
BEGIN
    -- Already exists?
    IF (EXISTS (SELECT 1 FROM AGENT.AGENT_FINDINGS WHERE RUN_TIMESTAMP = :run_timestamp)) THEN
        RETURN 'Already sent for timestamp ' || :run_timestamp;
    END IF;
 
    CALL MONITORING.AGENT.to_markdown_table('SELECT TOP 10 * FROM TABLE(MONITORING.AGENT.GetLatestQueryHistory()) WHERE EXECUTION_STATUS = ''SUCCESS'' ORDER BY TOTAL_ELAPSED_TIME_S DESC') INTO :v_markdown_table;
 
    v_markdown_table := REGEXP_REPLACE(:v_markdown_table, ' {2,}', ' ');

    v_prompt := :v_prompt_preamble || ' Here is a Markdown table of the top ten query history by elapsed time for the last 7 days, what is your advice?:\n' || :v_markdown_table; 
 
    SELECT SNOWFLAKE.CORTEX.AI_COMPLETE(:ai_model, :v_prompt) INTO :v_ai_analysis;
 
    IF (:v_ai_analysis IS NULL) THEN
        RETURN 'AI_COMPLETE() returned NULL. Does the model used exist?';
    END IF;

    INSERT INTO MONITORING.AGENT.AGENT_FINDINGS
    (RUN_TIMESTAMP, CATEGORY, PROMPT, AI_MODEL, AI_ANALYSIS)
    SELECT
        :run_timestamp,
        'QUERY_HISTORY',
        :v_prompt,
        :ai_model,
        :v_ai_analysis;

    CALL MONITORING.AGENT.to_markdown_table('SELECT TOP 10 * FROM AGENT.QUERY_INSIGHTS_HISTORY WHERE run_timestamp = \'' || :run_timestamp || '\'' )
    INTO :v_markdown_table;
 
    v_markdown_table := REGEXP_REPLACE(:v_markdown_table, ' {2,}', ' ');
 
    v_prompt := :v_prompt_preamble || 'Here is a Markdown table of Snowflake''s top ten query insights for the last 7 days, what is your advice?:\n' || :v_markdown_table;
   
    SELECT SNOWFLAKE.CORTEX.AI_COMPLETE(:ai_model, :v_prompt) INTO :v_ai_analysis;

    INSERT INTO MONITORING.AGENT.AGENT_FINDINGS
    (RUN_TIMESTAMP, CATEGORY, PROMPT, AI_MODEL, AI_ANALYSIS)
    SELECT
        :run_timestamp,
        'QUERY_INSIGHTS',
        :v_prompt,
        :ai_model,
        :v_ai_analysis;
 
    RETURN
        'Success. run_timestamp: ' || :run_timestamp;
       
EXCEPTION
    WHEN OTHER THEN
        RETURN 'FAILED | ' || SQLERRM;         
 
END;

$$;
 
-------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE SEND_FINDINGS_EMAIL
(
    run_timestamp TIMESTAMP_NTZ
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_email_body VARCHAR DEFAULT '';
    v_table VARCHAR DEFAULT '';
    v_model_used VARCHAR(100);
    v_session_timezone VARCHAR(100);
BEGIN

    CALL GET_SESSION_TIMEZONE() INTO :v_session_timezone;
 
    SELECT AI_MODEL INTO :v_model_used FROM MONITORING.AGENT.AGENT_FINDINGS 
    WHERE RUN_TIMESTAMP = :run_timestamp 
    LIMIT 1;
   
     -- Build email body
    v_email_body :=
    '<!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>Weekly Snowflake Report</title>
      <!--[if mso]>
      <style type="text/css">
          body, table, td, a { font-family: Arial, sans-serif !important; }
      </style>
      <![endif]-->      
    </head>                      
    <body>
      <h1 style="font-weight:bold; color: #007bff;">Snowflake Monitoring Report</h1>
      <p>Run Time: ' || TO_CHAR(CONVERT_TIMEZONE('UTC', :v_session_timezone, :run_timestamp), 'YYYY-MM-DD HH24:MI:SS') || ' (' || :v_session_timezone ||
         ')' || ' Model used: ' || :v_model_used || '</p>';
 
    SELECT LISTAGG(AI_ANALYSIS, '<p><br></p>') WITHIN GROUP (ORDER BY CATEGORY)
    INTO :v_table
    FROM MONITORING.AGENT.AGENT_FINDINGS
    WHERE RUN_TIMESTAMP = :run_timestamp;
 
    v_email_body := v_email_body || '<br><p><h2>Agent Findings</h2></p><p>' || :v_table || '</p><p><br></p>';
 
    CALL MONITORING.AGENT.to_html_table('SELECT * EXCLUDE (ID, RUN_TIMESTAMP) FROM AGENT.COST_SPIKES WHERE run_timestamp = ''' || :run_timestamp || '''') INTO :v_table;
   
    v_email_body := v_email_body || '<br><p><h2>Cost Spikes</h2></p><p>' || :v_table || '</p><br>';
 
    CALL MONITORING.AGENT.to_html_table('SELECT ID AS Id, QUERY_PARAMETERIZED_HASH, NUMBER_OF_EXECUTIONS AS "#Executions", ROUND(AVG_ELAPSED_TIME_S, 1) AS "Avg Elapsed(s)", TOTAL_ELAPSED_TIME_S::INT AS "Total Elapsed(s)", WAREHOUSE_NAME AS Warehouse, MESSAGE AS Message, SUGGESTIONS AS Suggestions FROM AGENT.QUERY_INSIGHTS_HISTORY WHERE run_timestamp = ''' || :run_timestamp || '''' ) INTO :v_table;
 
    v_email_body := v_email_body || '<br><p><h2>Query Insights</h2></p><p>' || :v_table || '</p><br>';  
 
    CALL MONITORING.AGENT.to_html_table('SELECT Id, QUERY_PARAMETERIZED_HASH, Number_of_Executions AS "#Executions", ROUND(AVG_ELAPSED_TIME_S, 1) AS Avg_Elapsed_Time_S, Total_Elapsed_Time_S::INT AS "Total Elapsed(s)", LAST_WAREHOUSE_NAME AS "Last Warehouse", LAST_QUERY_TEXT, LAST_USER_NAME, LAST_DATABASE_NAME AS "Last Database" FROM AGENT.QUERY_HISTORY_HISTORY WHERE run_timestamp = ''' || :run_timestamp || '''' ) INTO :v_table;
 
    v_email_body := v_email_body || '<br><p><h2>Query History</h2></p><p>' || :v_table || '</p>';
 
    CALL MONITORING.AGENT.to_html_table('SELECT Id, QUERY_PARAMETERIZED_HASH, Number_of_Executions AS "#Executions", Total_Elapsed_Time_S::INT AS "Total Elapsed(s)", LAST_WAREHOUSE_NAME AS "Last Warehouse", LAST_QUERY_TEXT, LAST_USER_NAME, LAST_DATABASE_NAME AS "Last Database", ERROR_MESSAGE FROM AGENT.QUERY_HISTORY_HISTORY WHERE EXECUTION_STATUS = ''FAIL'' AND run_timestamp = ''' || :run_timestamp || ''' ORDER BY Total_Elapsed_Time_S DESC' ) INTO :v_table;
 
    v_email_body := v_email_body || '<br><p><h2 style="color: red;"">Failing Queries</h2></p><p>' || :v_table || '</p>';   
 
    v_email_body := v_email_body || '</body></html>';
 
    CALL SYSTEM$SEND_EMAIL
    (
        'MONITORING_EMAIL_NOTIFICATION_INTEGRATION',
        'snowflake.monitoring@mycompany.com',
        'Snowflake Monitoring Report',
        :v_email_body,
        'text/html'
    );
    
    RETURN 'SUCCESS';
    
EXCEPTION
    WHEN OTHER THEN
        RETURN 'FAILED | ' || SQLERRM;      
    
END;
$$;
