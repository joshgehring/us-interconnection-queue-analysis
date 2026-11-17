-- 1. Load raw LBNL Queued Up CSV into DuckDB
CREATE OR REPLACE TABLE raw_queue AS 
SELECT * 
FROM read_csv_auto(
    'queued_up_raw.csv', 
    ignore_errors=true
);

-- 2. Clean, standardize, and aggregate by county FIPS and resource category
COPY (
    WITH cleaned_projects AS (
        SELECT
            q_id,
            COALESCE(TRIM(region), 'Unknown') AS region,
            UPPER(TRIM(state)) AS state,
            TRIM(county) AS county_name,
            LPAD(CAST(fips_code AS VARCHAR), 5, '0') AS fips_5,
            LOWER(TRIM(q_status)) AS status_clean,
            CASE
                WHEN type_clean ILIKE '%Solar%' AND type_clean ILIKE '%Battery%' THEN 'Solar + Storage'
                WHEN type_clean ILIKE '%Solar%' THEN 'Standalone Solar'
                WHEN type_clean ILIKE '%Wind%' THEN 'Wind'
                WHEN type_clean ILIKE '%Battery%' OR type_clean ILIKE '%Storage%' THEN 'Standalone Storage'
                WHEN type_clean ILIKE '%Gas%' THEN 'Natural Gas'
                ELSE 'Other'
            END AS resource_category,
            COALESCE(mw_1, 0) 
                + COALESCE(TRY_CAST(mw_2 AS DOUBLE), 0) 
                + COALESCE(TRY_CAST(mw_3 AS DOUBLE), 0) AS total_mw,
            CASE
                WHEN LOWER(TRIM(q_status)) = 'withdrawn' THEN DATEDIFF('month', q_date, wd_date)
                WHEN LOWER(TRIM(q_status)) = 'operational' THEN DATEDIFF('month', q_date, on_date)
                ELSE NULL
            END AS months_in_queue
        FROM raw_queue
        WHERE fips_code IS NOT NULL
          AND fips_code > 0
          AND LOWER(TRIM(q_status)) != 'unknown'
    )
    SELECT
        fips_5 AS fips_code,
        state,
        county_name,
        region,
        resource_category,
        COUNT(DISTINCT q_id) AS total_projects,
        COUNT(DISTINCT CASE WHEN status_clean = 'active' THEN q_id END) AS active_projects,
        COUNT(DISTINCT CASE WHEN status_clean = 'withdrawn' THEN q_id END) AS withdrawn_projects,
        COUNT(DISTINCT CASE WHEN status_clean = 'operational' THEN q_id END) AS operational_projects,
        ROUND(SUM(CASE WHEN status_clean = 'active' THEN total_mw ELSE 0 END), 1) AS active_mw,
        ROUND(SUM(CASE WHEN status_clean = 'suspended' THEN total_mw ELSE 0 END), 1) AS suspended_mw,
        ROUND(SUM(CASE WHEN status_clean = 'withdrawn' THEN total_mw ELSE 0 END), 1) AS withdrawn_mw,
        ROUND(SUM(CASE WHEN status_clean = 'operational' THEN total_mw ELSE 0 END), 1) AS operational_mw,
        ROUND(
            100.0 * COUNT(DISTINCT CASE WHEN status_clean = 'withdrawn' THEN q_id END) /
            NULLIF(COUNT(DISTINCT CASE WHEN status_clean IN ('withdrawn', 'operational') THEN q_id END), 0),
        1) AS historical_withdrawal_rate_pct,
        ROUND(AVG(CASE WHEN months_in_queue BETWEEN 0 AND 360 THEN months_in_queue END), 1) AS avg_months_in_queue
    FROM cleaned_projects
    WHERE total_mw > 0
      AND LENGTH(fips_5) = 5
    GROUP BY fips_5, state, county_name, region, resource_category
    ORDER BY active_mw DESC
) TO 'tableau_county_queue_map.csv' (HEADER, DELIMITER ',');
