-- ==============================================================================
-- Script Name:     all_gigameter_inc_ping_daily.sql
-- Table Created:   default.all_gigameter_inc_ping_daily
-- Schema:          default
-- Pipeline Status: Active (Integrated: true)
--
-- Purpose:
--   Daily aggregated data combining GigaMeter speed test measurements with
--   ping/connectivity checks. Aggregates hourly data to daily level for
--   broader trend analysis and reduced data volume.
--
-- Derived From:    all_gigameter_inc_ping_hourly_prd.sql
-- Key Differences:
--   - Aggregation at DAILY level instead of hourly
--   - Removed columns: local_date_hour, local_date_minus_1hr, local_hour
--   - School-hours metrics are daily sums (total pings 8am-8pm per day)
--   - Filters out dates before first ping and future dates
--   - Added: expected_pings_per_day (48), missing_pings columns
--
-- MEMORY OPTIMIZATION OPTIONS (uncomment as needed):
-- ==============================================================================
-- Option 1: Reduce lookback window (current: 75 days)
--   Change: date_add('day', -75, current_timestamp)
--   To:     date_add('day', -30, current_timestamp)
--
-- Option 2: Add session configuration for large queries
--   SET SESSION mark_distinct_strategy = 'none';
--   SET SESSION query_max_stage_count = 300;
--
-- Option 3: Use approximate distinct for high-cardinality counts
--   Change: COUNT(DISTINCT app_local_uuid)
--   To:     approx_distinct(app_local_uuid)
--
-- Option 4: Process by country (for very large datasets)
--   Add to WHERE: AND s.country_code = 'BRA'
-- 
-- Option 5: Limit to when ping test pilot started 
--   Added: WHERE cpc.timestamp >= cast('2025-05-01' as date)
--
-- ==============================================================================


 CREATE TABLE IF NOT EXISTS default.all_gigameter_inc_ping_daily AS


-- ==============================================================================
-- CTE: ping_base
-- Purpose: Extract and transform raw ping connectivity checks
-- Note: local_hour retained for school-hours classification but not for grouping
-- ==============================================================================
WITH ping_base AS (
    SELECT
        cpc.id AS connectivity_id,
        CAST(
            at_timezone(
                cpc.timestamp,
                COALESCE(tz.timezone, 'UTC')
            ) AS TIMESTAMP
        ) AS local_ts,
        -- Daily aggregation: only need date, not hour
        CAST(at_timezone(cpc.timestamp, COALESCE(tz.timezone, 'UTC')) AS DATE) AS local_created_date,
        -- Keep local_hour for school-hours classification only (not for grouping)
        EXTRACT(HOUR FROM at_timezone(cpc.timestamp, COALESCE(tz.timezone, 'UTC'))) AS local_hour,
        cpc.is_connected,
        cpc.error_message,
        cpc.giga_id_school AS school_id_giga,
        cpc.app_local_uuid,
        cpc.browser_id AS device_id,
        cpc.created_at AS connectivity_created_at,
        cpc.latency,
        s.external_id AS school_id_govt,
        s.name AS school_name,
        s.admin_1_name AS admin_1,
        s.admin_2_name AS admin_2,
        s.admin_3_name AS admin_3,
        s.admin_4_name AS admin_4,
        s.country_code,
        c.name AS country
    FROM gigameter_production_db.public.connectivity_ping_checks cpc
    JOIN gigameter_production_db.public.school s
        ON cpc.giga_id_school = s.giga_id_school
    LEFT JOIN gigameter_production_db.public.country c
        ON s.country_code = c.code
    LEFT JOIN default.country_timezones tz
        ON c.iso3_format = tz.iso3
    WHERE cpc.timestamp >= cast('2025-05-01' as date)
    --date_add('day', -75, current_timestamp)
),


-- ==============================================================================
-- CTE: ping_enriched
-- Purpose: Add time-of-day classification and connectivity counters
-- School hours: 8am-8pm = hours 8-19 (8:00 to 19:59)
-- ==============================================================================
ping_enriched AS (
    SELECT
        connectivity_id,
        local_created_date,
        local_hour,
        is_connected,
        error_message,
        school_id_giga,
        school_id_govt,
        school_name,
        admin_1,
        admin_2,
        admin_3,
        admin_4,
        country,
        app_local_uuid,
        device_id,
        latency,

        -- School hours (8am-8pm) connectivity counters
        CASE
            WHEN local_hour BETWEEN 8 AND 19 AND is_connected = TRUE
            THEN 1 ELSE 0
        END AS connected_8am_to_8pm_local,

        CASE
            WHEN local_hour BETWEEN 8 AND 19 AND is_connected <> TRUE
            THEN 1 ELSE 0
        END AS not_connected_8am_to_8pm_local,

        CASE
            WHEN local_hour BETWEEN 8 AND 19
            THEN 1 ELSE 0
        END AS valid_ping_8am_to_8pm_local,

        -- Outside school hours (8pm-8am = hours 0-7 and 20-23)
        CASE
            WHEN local_hour NOT BETWEEN 8 AND 19 AND is_connected = TRUE
            THEN 1 ELSE 0
        END AS invalid_connected_counter_local,

        CASE
            WHEN local_hour NOT BETWEEN 8 AND 19 AND is_connected = FALSE
            THEN 1 ELSE 0
        END AS not_connected_9pm_to_7am_local,

        CASE
            WHEN local_hour NOT BETWEEN 8 AND 19
            THEN 1 ELSE 0
        END AS invalid_ping_9pm_to_7am_local

    FROM ping_base
),


-- ==============================================================================
-- CTE: ping_aggr
-- Purpose: Aggregate ping data by school-device-DAY (not hour)
-- Key Change: Removed local_date_hour and local_hour from GROUP BY
-- ==============================================================================
ping_aggr AS (
    SELECT
        local_created_date,
        country,
        school_id_giga,
        school_id_govt,
        school_name,
        admin_1,
        admin_2,
        admin_3,
        admin_4,
        device_id,

        COUNT(*) AS ping_records,
        COUNT(DISTINCT app_local_uuid) AS is_connected_all,
        AVG(latency) AS avg_latency,

        -- School-hours metrics aggregated to daily sums
        SUM(valid_ping_8am_to_8pm_local) AS pings_8am_to_8pm_local,
        SUM(connected_8am_to_8pm_local) AS connected_8am_to_8pm_local,
        SUM(not_connected_8am_to_8pm_local) AS not_connected_8am_to_8pm_local,
        SUM(invalid_ping_9pm_to_7am_local) AS invalid_ping_9pm_to_7am_local,
        SUM(invalid_connected_counter_local) AS connected_9pm_to_7am_local,
        SUM(not_connected_9pm_to_7am_local) AS not_connected_9pm_to_7am_local,

        -- Uptime calculations (daily averages)
        SUM(connected_8am_to_8pm_local + invalid_connected_counter_local)
            / CAST(COUNT(*) AS DECIMAL(10,2)) AS uptime,

        SUM(connected_8am_to_8pm_local)
            / NULLIF(CAST(SUM(valid_ping_8am_to_8pm_local) AS DECIMAL(10,2)), 0)
            AS uptime_8am_to_8pm_local

    FROM ping_enriched
    GROUP BY
        local_created_date,
        country,
        school_id_giga,
        school_id_govt,
        school_name,
        admin_1,
        admin_2,
        admin_3,
        admin_4,
        device_id
),


-- ==============================================================================
-- CTE: gmeter_aggr
-- Purpose: Aggregate GigaMeter speed test measurements by school-device-DAY
-- Key Change: Group by DATE only, not hour
-- ==============================================================================
gmeter_aggr AS (
    SELECT
        CAST(local_created_timestamp AS DATE) AS local_created_date,
        country,
        iso3_format,
        school_id_giga,
        school_id_govt,
        school_name,
        app_version,
        admin1,
        admin2,
        device_id,
        rt_source,
        deleted,

        -- Measurement count for the day
        COUNT(*) AS measurement_records,

        AVG(avg_download_speed) AS avg_download_speed,
        AVG(avg_upload_speed) AS avg_upload_speed,
        AVG(avg_latency) AS avg_latency,

        AVG(avg_data_downloaded_gb) AS avg_data_downloaded_gb,
        AVG(avg_data_uploaded_gb) AS avg_data_uploaded_gb,
        AVG(avg_data_usage_gb) AS avg_data_usage_gb,

        SUM(total_data_downloaded_gb) AS total_data_downloaded_gb,
        SUM(total_data_uploaded_gb) AS total_data_uploaded_gb,
        SUM(total_data_usage_gb) AS total_data_usage_gb,

        -- Test type counters (daily totals)
        SUM(CASE WHEN notes = 'startup' THEN 1 ELSE 0 END) AS notes_startup_count,
        SUM(CASE WHEN notes = 'daily' THEN 1 ELSE 0 END) AS notes_daily_count,
        SUM(CASE WHEN notes = 'manual' THEN 1 ELSE 0 END) AS notes_manual_count,
        SUM(CASE WHEN notes NOT IN ('startup', 'daily', 'manual') THEN 1 ELSE 0 END) AS notes_other_count

    FROM default.all_gigameter_measurement_data_tb_physical
    WHERE rt_source = 'GigaMeter'
    AND CAST(local_created_timestamp AS DATE)  > CAST('2025-05-01' AS DATE)
    
    GROUP BY
        CAST(local_created_timestamp AS DATE),
        country,
        iso3_format,
        school_id_giga,
        school_id_govt,
        school_name,
        app_version,
        admin1,
        admin2,
        device_id,
        rt_source,
        deleted
),


-- ==============================================================================
-- CTE: first_ping_recorded
-- Purpose: Get first ping date per school for analysis period validation
-- ==============================================================================
first_ping_recorded AS (
    SELECT
        country,
        school_id_giga,
        MIN(local_created_date) AS first_ping_date
    FROM ping_aggr
    GROUP BY country, school_id_giga
)


-- ==============================================================================
-- FINAL SELECT
-- Purpose: FULL JOIN ping and measurement data at DAILY level
-- Filters: Only dates >= first_ping_date and <= CURRENT_DATE
-- Added: expected_pings_per_day (48), missing_pings
-- Removed: date_after_ping_start (now filtered instead of flagged)
-- ==============================================================================
SELECT
    COALESCE(p.local_created_date, m.local_created_date) AS local_created_date,

    -- Data availability flag
    CASE WHEN p.ping_records IS NULL THEN 'yes' ELSE 'no' END AS ping_records_null,

    -- Ping completeness metrics (48 expected = 12 hours × 4 pings/hour)
    48 AS expected_pings_per_day,
    48 - COALESCE(p.pings_8am_to_8pm_local, 0) AS missing_pings,

    -- Common fields
    COALESCE(p.device_id, m.device_id) AS device_id,
    COALESCE(p.school_id_govt, m.school_id_govt) AS school_id_govt,
    COALESCE(p.school_id_giga, m.school_id_giga) AS school_id_giga,
    COALESCE(p.school_name, m.school_name) AS school_name,
    COALESCE(p.country, m.country) AS country,
    COALESCE(p.admin_1, m.admin1) AS admin1,
    COALESCE(p.admin_2, m.admin2) AS admin2,

    -- App version
    COALESCE(m.app_version, a.most_recent_app_version_clean) AS app_version,

    -- Ping metrics (daily totals)
    p.ping_records,
    p.is_connected_all,
    p.pings_8am_to_8pm_local,
    p.connected_8am_to_8pm_local,
    p.not_connected_8am_to_8pm_local,
    p.invalid_ping_9pm_to_7am_local,
    p.connected_9pm_to_7am_local,
    p.not_connected_9pm_to_7am_local,
    p.avg_latency AS latency_ping,
    p.uptime,
    p.uptime_8am_to_8pm_local,

    -- GigaMeter metrics (daily totals/averages)
    m.measurement_records,
    m.avg_download_speed AS download_speed,
    m.avg_upload_speed AS upload_speed,
    m.avg_latency AS latency_meter,
    m.avg_data_downloaded_gb,
    m.avg_data_uploaded_gb,
    m.avg_data_usage_gb,
    m.total_data_downloaded_gb,
    m.total_data_uploaded_gb,
    m.total_data_usage_gb,
    m.notes_startup_count,
    m.notes_daily_count,
    m.notes_manual_count,
    m.notes_other_count,

    -- App version parsing
    TRY_CAST(split_part(m.app_version, '.', 1) AS INTEGER) AS major,
    TRY_CAST(split_part(m.app_version, '.', 2) AS INTEGER) AS minor,
    TRY_CAST(split_part(m.app_version, '.', 3) AS INTEGER) AS patch

FROM ping_aggr p

-- Join on DATE and device_id (not hour)
FULL JOIN gmeter_aggr m
    ON p.device_id = m.device_id
    AND p.local_created_date = m.local_created_date

LEFT JOIN default.all_gigameter_appversion_funnel a
    ON COALESCE(p.device_id, m.device_id) = a.device_id

LEFT JOIN first_ping_recorded f
    ON COALESCE(p.school_id_giga, m.school_id_giga) = f.school_id_giga

-- Filter: only dates from first ping onwards, no future dates
WHERE COALESCE(p.local_created_date, m.local_created_date) >= f.first_ping_date
  AND COALESCE(p.local_created_date, m.local_created_date) <= CURRENT_DATE
  
  
;
