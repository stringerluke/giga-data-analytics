-- ==============================================================================
-- Script Name:     all_gmeter_only_measurements.sql
-- Table Created:   default.all_gmeter_only_measurements
-- Schema:          default
-- Pipeline Step:   1 of 3
--
-- Purpose:
--   Extracts and transforms raw GigaMeter mobile app measurements from the
--   source database. This is the first script in the refactored 3-script
--   pipeline, processing only 'DailyCheckApp' source measurements.
--
-- Key Improvements over Original:
--   1. Timezone conversion performed here (not in final script)
--   2. No GROUP BY aggregation - preserves individual measurements
--   3. No approx_most_frequent() - uses direct server_location value
--   4. School lookup with timezone integrated into single CTE
--   5. Deleted schools filtered upstream in school_lookup
--
-- Dependencies:
--   - gigameter_production_db.public.measurements (source measurements)
--   - gigameter_production_db.public.school (school registration)
--   - gigameter_production_db.public.country (country lookup)
--   - default.country_timezones (timezone conversion)
--
-- Output Columns:  ~30 columns per individual measurement
-- Primary Key:     measurement_id
-- Downstream:      Used by all_gigameter_measurement_data.sql (Script 3)
--
-- Author:          Refactored by Luke Stringer
-- Last Updated:    2025-01-27
-- ==============================================================================


  CREATE TABLE IF NOT EXISTS default.all_gmeter_only_measurements as (


-- =============================================================================
-- CTE: school_lookup
-- Purpose: Creates a reusable lookup for school metadata with pre-computed timezone
--
-- IMPROVEMENT: Combines multiple JOINs from original into single CTE:
--   - School to country JOIN
--   - Two timezone JOINs with COALESCE fallback
--   - Deleted school filter applied once here
--
-- Timezone Fallback Chain:
--   1. Try timezone by ISO3 code (tz.timezone)
--   2. Try timezone by country name (tz_name.timezone)
--   3. Default to 'UTC'
-- =============================================================================
WITH school_lookup AS (
    SELECT
        school.giga_id_school AS school_id_giga,
        school.external_id AS school_id_govt,
        school.name AS school_name,
        country.name AS country,
        country.code AS iso2_code,
        -- RENAMED: iso3_format -> iso3_code for clarity
        UPPER(TRIM(country.iso3_format)) AS iso3_code,
        -- PRE-COMPUTED: Timezone with fallback, eliminates JOINs in final SELECT
        COALESCE(tz.timezone, tz_name.timezone, 'UTC') AS timezone
    FROM
        gigameter_production_db.public.school
    LEFT JOIN
        gigameter_production_db.public.country
        ON country.id = school.country_id
    -- Timezone lookup by ISO3 code (primary method)
    LEFT JOIN default.country_timezones tz
        ON country.iso3_format = tz.iso3
    -- Timezone lookup by country name (fallback method)
    LEFT JOIN default.country_timezones tz_name
        ON LOWER(country.name) = LOWER(tz_name.country)
    WHERE
        -- FILTER: Exclude deleted schools at source (was in final WHERE clause)
        school.deleted IS NULL
),


-- =============================================================================
-- CTE: measurements_base
-- Purpose: Extracts raw measurement data with minimal transformation
--
-- DIFFERENCE from original:
--   - No speed/data conversions yet (done in final SELECT)
--   - No JSON extraction yet (done in final SELECT)
--   - Simpler column selection
--
-- Filter: source = 'DailyCheckApp' (GigaMeter mobile app only)
-- =============================================================================
measurements_base AS (
    SELECT
        id AS measurement_id,
        giga_id_school AS school_id_giga,
        created_at AS created_timestamp,
        -- Date truncated to day for partitioning/filtering
        CAST(DATE_TRUNC('day', created_at) AS date) AS date,
        -- Raw values - conversion done later
        download,
        upload,
        latency,
        data_downloaded,
        data_uploaded,
        data_usage,
        -- JSON fields passed through for extraction in final SELECT
        results,
        client_info,
        server_info,
        wifi_connections,
        app_version,
        notes,
        browser_id,
        device_hardware_id AS device_id, 
        installed_path,
        windows_username
        -- select * 
    FROM
        gigameter_production_db.public.measurements
    WHERE
        source = 'DailyCheckApp'  -- GigaMeter app measurements only
      
      
        
)


-- =============================================================================
-- CTE: measurements_enriched
-- Purpose: Joins measurements with school lookup for enrichment
--
-- KEY DIFFERENCE: Timezone conversion happens HERE, not in final script
-- This distributes the computation and avoids applying timezone logic
-- to the full UNION of GigaMeter + MLAB data.
-- =============================================================================
, measurements_enriched as (
  SELECT
      m.measurement_id,
      m.school_id_giga,
      s.school_name,
      s.school_id_govt,
      s.country,
      s.iso3_code,
      -- Preserve timezone for timestamp
      CAST(m.created_timestamp AS timestamp with time zone) as created_timestamp,
      m.date,
      -- TIMEZONE CONVERSION: Done here using pre-computed timezone from school_lookup
      -- Original did this in final SELECT on combined dataset
      CAST(at_timezone(m.created_timestamp, s.timezone) AS timestamp) AS local_created_timestamp,
      -- Pass through raw values for final transformation
      m.download,
      m.upload,
      m.latency,
      m.data_downloaded,
      m.data_uploaded,
      m.data_usage,
      m.results,
      m.client_info,
      m.server_info,
      m.wifi_connections,
      m.app_version,
      m.notes,
      m.browser_id,
      m.device_id,
      m.installed_path,
      m.windows_username
  FROM
      measurements_base m
  LEFT JOIN
      school_lookup s
      -- GigaMeter uses giga_id_school for school matching
      ON m.school_id_giga = s.school_id_giga
  
 -- WHERE  
   --  m.date > cast('2024-01-01' as date)  
)



-- =============================================================================
-- FINAL SELECT
-- Purpose: Apply unit conversions, extract JSON fields, compute time analysis
--
-- Key Transformations:
--   - Speed: kbps -> Mbps (divide by 1000)
--   - Data volumes: bytes -> GB (divide by 1000, then by 1048576)
--   - JSON extraction for server_info, client_info, wifi_connections
--   - Local time analysis (hour, day of week, school hours)
--
-- NO AGGREGATION: Each row is one measurement (unlike original with GROUP BY)
-- =============================================================================
select
    measurement_id,
    school_id_giga,
    school_name,
    school_id_govt,
    country,
    iso3_code,                           -- RENAMED from iso3_format
    created_timestamp,
    date,
    local_created_timestamp,

    -- -------------------------------------------------------------------------
    -- Time Analysis Fields (Local Timezone)
    -- REMOVED: hour_of_measurement (UTC) - local hour is more useful
    -- -------------------------------------------------------------------------
    EXTRACT(HOUR FROM local_created_timestamp) AS local_hour_of_measurement,
    format_datetime(local_created_timestamp, 'EEEE') AS local_day_of_week,

    -- Weekday vs weekend flag (Monday=1 through Friday=5 are weekdays)
    CASE
        WHEN day_of_week(local_created_timestamp) BETWEEN 1 AND 5
        THEN true
        ELSE false
    END AS is_weekday,

    -- School hours classification: 8am-4pm vs outside school hours
    CASE
        WHEN EXTRACT(HOUR FROM local_created_timestamp) BETWEEN 8 AND 16
        THEN '8am-4pm(within school hrs)'
        ELSE '5pm-7am(outside school hrs)'
    END AS measurement_time_window,


    -- -------------------------------------------------------------------------
    -- Speed Metrics
    -- Conversion: kbps -> Mbps (divide by 1000)
    -- -------------------------------------------------------------------------
    ROUND(CAST((download / 1000) AS REAL), 2) AS download_speed,
    ROUND(CAST((upload / 1000) AS REAL), 2) AS upload_speed,
    latency,                              -- Already in milliseconds

    -- -------------------------------------------------------------------------
    -- Data Volume Metrics
    -- Conversion: bytes -> KB -> GB
    -- Formula: (bytes / 1000) / 1048576 = bytes / 1,048,576,000
    -- -------------------------------------------------------------------------
    (ROUND(CAST((data_downloaded / 1000) AS real), 2) / 1048576) AS data_downloaded_gb,
    (ROUND(CAST((data_uploaded / 1000) AS real), 2) / 1048576) AS data_uploaded_gb,
    (ROUND(CAST((data_usage / 1000) AS real), 2) / 1048576) AS data_usage_gb,

    -- -------------------------------------------------------------------------
    -- Server Detection
    -- SIMPLIFIED: Direct JSON extraction instead of approx_most_frequent()
    -- Original used: approx_most_frequent(5, server_location, 5)
    -- then: element_at(map_keys(detected_server_mode), 1)
    -- -------------------------------------------------------------------------
    CAST(JSON_EXTRACT(server_info, '$.City') AS VARCHAR) AS server_location,

    -- -------------------------------------------------------------------------
    -- ISP/Client Information
    -- Extract from client_info JSON field
    -- Note: ISP cleaning (removing ASN from name) done in Script 3
    -- -------------------------------------------------------------------------
    CAST(JSON_EXTRACT(client_info, '$.ISP') AS VARCHAR) AS detected_isp_raw,
    json_extract_scalar(client_info, '$.ASN') AS detected_isp_asn,
    CAST(JSON_EXTRACT(client_info, '$.IP') AS VARCHAR) AS detected_isp_ip_address,
    json_extract_scalar(client_info, '$.Country') AS client_country,

    app_version,
    'GigaMeter' as rt_source,            -- Hard-coded source identifier
    notes,

    -- -------------------------------------------------------------------------
    -- WiFi Connection Details
    -- Extracts first element [0] from wifi_connections JSON array
    -- Provides signal quality and connection metadata
    -- -------------------------------------------------------------------------
    json_extract_scalar(CAST(wifi_connections AS JSON), '$[0].ssid') AS detected_wifi_ssid,
    json_extract_scalar(CAST(wifi_connections AS JSON), '$[0].model') AS detected_wifi_model,
    CAST(json_extract_scalar(CAST(wifi_connections AS JSON), '$[0].quality') AS INTEGER) AS detected_wifi_quality,
    CAST(json_extract_scalar(CAST(wifi_connections AS JSON), '$[0].signalLevel') AS DECIMAL(10,2)) AS detected_wifi_signal,
    CAST(json_extract_scalar(CAST(wifi_connections AS JSON), '$[0].txRate') AS INTEGER) AS detected_wifi_tx_rate,
    CAST(json_extract_scalar(CAST(wifi_connections AS JSON), '$[0].channel') AS INTEGER) AS detected_wifi_channel,
    CAST(json_extract_scalar(CAST(wifi_connections AS JSON), '$[0].frequency') AS INTEGER) AS detected_wifi_frequency,

    -- -------------------------------------------------------------------------
    -- Device Identification
    -- -------------------------------------------------------------------------
    browser_id,
    device_id,
    

    -- -------------------------------------------------------------------------
    -- Installation 
    -- -------------------------------------------------------------------------
    installed_path,
    windows_username,

-- -------------------------------------------------------------------------
        -- Packet Loss Indicators (S2C - Server to Client)
    -- Extracted from results JSON: NDTResult.S2C.LastServerMeasurement.TCPInfo
    -- -------------------------------------------------------------------------
    CAST(json_extract_scalar(CAST(results AS JSON), '$.NDTResult.S2C.LastServerMeasurement.TCPInfo.Lost') AS INTEGER) AS s2c_lost,
    CAST(json_extract_scalar(CAST(results AS JSON), '$.NDTResult.S2C.LastServerMeasurement.TCPInfo.BytesRetrans') AS BIGINT) AS s2c_bytes_retrans,
    CAST(json_extract_scalar(CAST(results AS JSON), '$.NDTResult.S2C.LastServerMeasurement.TCPInfo.BytesSent') AS BIGINT) AS s2c_bytes_sent,
   ---------------
    -- elapsed time --
    ---------------
    JSON_EXTRACT_SCALAR(results, '$["NDTResult.S2C"].LastClientMeasurement.ElapsedTime') AS s2c_lastclient_elapsed_time,  -- download  time
    JSON_EXTRACT_SCALAR(results, '$["NDTResult.C2S"].LastClientMeasurement.ElapsedTime') AS c2s_lastclient_elapsed_time,  -- upload time
    ---------------
    -- DATA SIZE --
    ---------------
    JSON_EXTRACT_SCALAR(results, '$["NDTResult.S2C"].LastServerMeasurement.TCPInfo.BytesAcked') AS s2c_bytes_Acked,       -- download size
    JSON_EXTRACT_SCALAR(results, '$["NDTResult.C2S"].LastServerMeasurement.TCPInfo.BytesAcked') AS c2s_bytes_Acked,       -- upload size
    -------
    -- json
    -------
    JSON_FORMAT(CAST(JSON_EXTRACT(results, '$["NDTResult.S2C"].LastServerMeasurement') AS JSON)) AS s2c_FinalSnapshot,   --  download json populated
    JSON_FORMAT(CAST(JSON_EXTRACT(results, '$["NDTResult.C2S"].LastServerMeasurement') AS JSON)) AS c2s_FinalSnapshot   --  upload json populated
    -- select *
  

  

FROM
  measurements_enriched


 )

-- =============================================================================
-- NOTES ON REMOVED FEATURES
--
-- 1. GROUP BY AGGREGATION: Removed entirely
--    - Original grouped by 20+ columns and computed AVG/SUM/COUNT
--    - Each row now represents one individual measurement
--    - If aggregates needed, compute in downstream queries
--
-- 2. approx_most_frequent(): Removed
--    - Was used for server_location mode detection
--    - Now uses direct server_location value per measurement
--    - Saves significant memory during query execution
--
-- 3. num_measurements: Removed
--    - Was COUNT(*) in GROUP BY
--    - No longer meaningful since each row = 1 measurement
--
-- 4. deleted column: Filtered upstream
--    - Was passed through and filtered in final WHERE
--    - Now filtered in school_lookup CTE (more efficient)
-- =============================================================================

