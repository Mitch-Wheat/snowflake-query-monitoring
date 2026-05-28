----------------------------------------------------------------
-- Weekly Task
----------------------------------------------------------------
 
CREATE OR REPLACE TASK MONITORING.AGENT.WEEKLY_MONITORING_TASK
    WAREHOUSE = PLATFORM_WH
    SCHEDULE  = 'USING CRON 0 8 * * 1 Australia/Perth'  -- Runs every Monday at 8am AWST
    COMMENT   = 'Runs the query monitoring agent weekly'
AS
    CALL MONITORING.AGENT.QUERY_MONITORING();
 
-- Activate the task
ALTER TASK MONITORING.AGENT.WEEKLY_MONITORING_TASK RESUME;
 
----------------------------------------------------------------