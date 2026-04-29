-- ==============================================================================
-- Script Name:     all_mlab_only_measurements.sql
-- Table Created:   default.all_mlab_only_measurements
-- Schema:          default
-- Pipeline Step:   2 of 3
--
-- Purpose:
--   Extracts and transforms raw MLAB network test measurements from the
--   source database. This is the second script in the refactored 3-script
--   pipeline, processing only 'MLab' source measurements.
--
-- Key Differences from GigaMeter Script:
--   1. School matching uses school_id_govt + client_country (not giga_id)
--   2. app_version defaults to 'mlab' when NULL
--   3. rt_source is 'Mlab' (not 'GigaMeter')
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
-- CAVEAT: MLAB matching is less reliable than GigaMeter
--   - Uses school_id from measurement record (government ID)
--   - Requires country match via client_info JSON
--   - May have NULL school matches if country/ID combination not found
--
-- Last Updated:    2025-01-27
-- ==============================================================================


 CREATE TABLE IF NOT EXISTS default.all_mlab_only_measurements as (


-- =============================================================================
-- CTE: school_lookup
-- Purpose: Creates a reusable lookup for school metadata with pre-computed timezone
--
-- IDENTICAL to GigaMeter script school_lookup CTE
-- Reused pattern ensures consistency across both source scripts
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
        -- PRE-COMPUTED: Timezone with fallback
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
        -- FILTER: Exclude deleted schools at source
        school.deleted IS NULL
       -- DEBUGGING: Uncomment to test specific school
       -- and school.external_id = 'bw10ps006'
),


-- =============================================================================
-- CTE: measurements_base
-- Purpose: Extracts raw MLAB measurement data with minimal transformation
--
-- DIFFERENCE from GigaMeter:
--   - Uses school_id field directly (government ID, not giga_id)
--   - Extracts client_country from JSON for school matching
--   - Filter: source = 'MLab'
-- =============================================================================
measurements_base AS (
    SELECT
        id AS measurement_id,
        giga_id_school AS school_id_giga,
        -- MLAB uses school_id (government ID) directly from measurement
        school_id as school_id_govt,
        created_at AS created_timestamp,
        CAST(DATE_TRUNC('day', created_at) AS date) AS date,
        -- Raw values - conversion done later
        download,
        upload,
        latency,
        data_downloaded,
        data_uploaded,
        data_usage,
        results,
        client_info,
        -- PRE-EXTRACT: Country code for school matching
        -- Used in JOIN condition for school_lookup
        json_extract_scalar(client_info, '$.Country') AS client_country,
        server_info,
        wifi_connections,
        app_version,
        notes,
        browser_id,
        device_hardware_id AS device_id, 
        installed_path,
        windows_username
    FROM
        gigameter_production_db.public.measurements
    WHERE
        source = 'MLab'  -- MLAB measurements only
)


-- =============================================================================
-- CTE: measurements_enriched
-- Purpose: Joins measurements with school lookup for enrichment
--
-- CRITICAL DIFFERENCE from GigaMeter:
--   JOIN uses client_country + school_id_govt (not school_id_giga)
--   This is because MLAB measurements don't have reliable giga_id_school
--
-- Original comment preserved:
--   "MLAB joins on school_id_govt + country, not school_id_giga"
-- =============================================================================
, measurements_enriched as (


SELECT
    m.measurement_id,
    -- NOTE: school_id_giga comes from school_lookup, not measurement
    -- MLAB measurements may have NULL or unreliable giga_id_school
    s.school_id_giga,
    s.school_name,
    s.school_id_govt,
    s.country,
    s.iso3_code,
    CAST(m.created_timestamp AS timestamp with time zone) as created_timestamp,
    m.date,
    -- TIMEZONE CONVERSION: Done here using pre-computed timezone
    CAST(at_timezone(m.created_timestamp, s.timezone) AS timestamp) AS local_created_timestamp,
    m.download,
    m.upload,
    m.latency,
    m.data_downloaded,
    m.data_uploaded,
    m.data_usage,
    m.results,
    m.client_info,
    m.client_country,
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
LEFT JOIN school_lookup s
    -- MLAB JOIN CONDITION:
    -- 1. Match country code from client_info to school's country
    -- 2. Match school_id (government ID) from measurement to school's external_id
    -- CAVEAT: If either doesn't match, school fields will be NULL
    ON TRIM(m.client_country) = TRIM(s.iso2_code)
    AND m.school_id_govt = s.school_id_govt


)




-- =============================================================================
-- FINAL SELECT
-- Purpose: Apply unit conversions, extract JSON fields, compute time analysis
--
-- IDENTICAL STRUCTURE to GigaMeter script with two exceptions:
--   1. app_version uses COALESCE to default to 'mlab' when NULL
--   2. rt_source is 'Mlab' instead of 'GigaMeter'
-- =============================================================================
select
    measurement_id,
    school_id_giga,
    school_name,
    school_id_govt,
    country,
    iso3_code,
    created_timestamp,
    date,
    local_created_timestamp,

    -- -------------------------------------------------------------------------
    -- Time Analysis Fields (Local Timezone)
    -- -------------------------------------------------------------------------
    EXTRACT(HOUR FROM local_created_timestamp) AS local_hour_of_measurement,
    format_datetime(local_created_timestamp, 'EEEE') AS local_day_of_week,

    -- Weekday vs weekend flag
    CASE
        WHEN day_of_week(local_created_timestamp) BETWEEN 1 AND 5
        THEN true
        ELSE false
    END AS is_weekday,

    -- School hours classification
    CASE
        WHEN EXTRACT(HOUR FROM local_created_timestamp) BETWEEN 8 AND 16
        THEN '8am-4pm(within school hrs)'
        ELSE '5pm-7am(outside school hrs)'
    END AS measurement_time_window,

    -- -------------------------------------------------------------------------
    -- Speed Metrics (kbps -> Mbps)
    -- -------------------------------------------------------------------------
    ROUND(CAST((download / 1000) AS REAL), 2) AS download_speed,
    ROUND(CAST((upload / 1000) AS REAL), 2) AS upload_speed,
    latency,

    -- -------------------------------------------------------------------------
    -- Data Volume Metrics (bytes -> GB)
    -- -------------------------------------------------------------------------
    (ROUND(CAST((data_downloaded / 1000) AS real), 2) / 1048576) AS data_downloaded_gb,
    (ROUND(CAST((data_uploaded / 1000) AS real), 2) / 1048576) AS data_uploaded_gb,
    (ROUND(CAST((data_usage / 1000) AS real), 2) / 1048576) AS data_usage_gb,

    -- -------------------------------------------------------------------------
    -- Server Detection (simplified from approx_most_frequent)
    -- -------------------------------------------------------------------------
    CAST(JSON_EXTRACT(server_info, '$.City') AS VARCHAR) AS server_location,

    -- -------------------------------------------------------------------------
    -- ISP/Client Information
    -- -------------------------------------------------------------------------
    CAST(JSON_EXTRACT(client_info, '$.ISP') AS VARCHAR) AS detected_isp_raw,
    json_extract_scalar(client_info, '$.ASN') AS detected_isp_asn,
    CAST(JSON_EXTRACT(client_info, '$.IP') AS VARCHAR) AS detected_isp_ip_address,
    client_country,

    -- MLAB-SPECIFIC: Default app_version to 'mlab' when NULL
    -- Original hardcoded 'mlab' AS app_version; this preserves actual version if present
    COALESCE(app_version, 'mlab') as app_version,
    'Mlab' as rt_source,                 -- MLAB source identifier
    notes,

    -- -------------------------------------------------------------------------
    -- WiFi Connection Details
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
-- MLAB-SPECIFIC NOTES
--
-- 1. SCHOOL MATCHING RELIABILITY
--    - MLAB uses client_info.Country + school_id (govt ID) for matching
--    - Less reliable than GigaMeter which uses giga_id_school directly
--    - Unmatched measurements will have NULL school metadata
--    - Consider data quality checks on match rate
--
-- 2. APP VERSION
--    - MLAB measurements often have NULL app_version
--    - COALESCE defaults to 'mlab' for identification
--    - Original script hardcoded 'mlab' AS app_version
--
-- 3. DOWNSTREAM JOIN
--    - Script 3 joins MLAB data on school_id_govt + iso3_code
--    - This differs from GigaMeter which joins on school_id_giga
--    - Maintains original matching logic for consistency
-- =============================================================================
