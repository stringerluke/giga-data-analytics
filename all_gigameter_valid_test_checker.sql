-- ==============================================================================
-- Script Name:     all_gigameter_valid_test_checker.sql
-- Table Created:   default.all_gigameter_valid_test_checker
-- Schema:          default
-- Pipeline Status: Active (Integrated: true)
--
-- Purpose:
--   Validates individual GigaMeter and MLab speed test measurements against
--   four quality criteria per direction (download / upload): completeness of
--   FinalSnapshot JSON, minimum bytes transferred (≥8192), minimum duration
--   (≥9 s), and maximum duration (≤60 s). Produces per-measurement pass/fail
--   flags and human-readable failure reasons.
--
-- Dependencies:
--   - default.all_gmeter_only_measurements (GigaMeter measurements, Pipeline Step 1)
--   - default.all_mlab_only_measurements (MLab measurements, Pipeline Step 2)
--
-- Output Columns:  ~15 columns
-- Primary Key:     measurement_id
-- Granularity:     One row per individual measurement (no aggregation)
--
-- Run Notes:
--   Recurring — refresh after each measurement pipeline run. Failure reasons
--   are deduplicated across download and upload directions before surfacing.
--
-- Last Updated:    2025-10-31 / Luke Stringer
-- ==============================================================================

CREATE TABLE IF NOT EXISTS default.all_gigameter_valid_test_checker AS (

-- ============================================================
-- CTE 1: data
-- Combines measurements from two sources (Gigameter & MLab)
-- into a single unified dataset via UNION ALL
-- ============================================================
WITH data AS (
  SELECT m1.* FROM default.all_gmeter_only_measurements m1
  UNION ALL
  SELECT m2.* FROM default.all_mlab_only_measurements m2
),

-- ============================================================
-- CTE 2: flagged
-- Applies individual pass/fail flags for both download (s2c)
-- and upload (c2s) directions across 4 quality checks:
--   1. IsComplete   - FinalSnapshot JSON must be populated
--   2. IsSmall      - Must have transferred >= 8192 bytes
--   3. IsShort      - Test must have run for >= 9 seconds
--   4. IsLong       - Test must not have run for > 60 seconds
-- ============================================================
flagged AS (
  SELECT
    -- Key identifiers
    measurement_id,
    rt_source,
    created_timestamp,
    school_id_giga,
    school_id_govt,
    device_id,

    -- Raw metrics passed through for downstream use
    s2c_lastclient_elapsed_time,
    s2c_bytes_Acked,
    c2s_lastclient_elapsed_time,
    c2s_bytes_Acked,
    s2c_FinalSnapshot,
    c2s_FinalSnapshot,

    -- Download (Server-to-Client) flags
    CASE WHEN s2c_FinalSnapshot IS NULL                                    THEN 'fail' ELSE 'pass' END AS s2c_IsComplete,    -- JSON not populated
    CASE WHEN CAST(s2c_bytes_Acked AS BIGINT) < 8192                       THEN 'fail' ELSE 'pass' END AS s2c_data_IsSmall,  -- Not enough data transferred
    CASE WHEN CAST(s2c_lastclient_elapsed_time AS DECIMAL(18,6)) < 9       THEN 'fail' ELSE 'pass' END AS s2c_IsShort_flag,  -- Test duration too short
    CASE WHEN CAST(s2c_lastclient_elapsed_time AS DECIMAL(18,6)) > 60      THEN 'fail' ELSE 'pass' END AS s2c_IsLong_flag,   -- Test duration too long

    -- Upload (Client-to-Server) flags
    CASE WHEN c2s_FinalSnapshot IS NULL                                    THEN 'fail' ELSE 'pass' END AS c2s_IsComplete,    -- JSON not populated
    CASE WHEN CAST(c2s_bytes_Acked AS BIGINT) < 8192                       THEN 'fail' ELSE 'pass' END AS c2s_data_IsSmall,  -- Not enough data transferred
    CASE WHEN CAST(c2s_lastclient_elapsed_time AS DECIMAL(18,6)) < 9       THEN 'fail' ELSE 'pass' END AS c2s_IsShort_flag,  -- Test duration too short
    CASE WHEN CAST(c2s_lastclient_elapsed_time AS DECIMAL(18,6)) > 60      THEN 'fail' ELSE 'pass' END AS c2s_IsLong_flag    -- Test duration too long

  FROM data
)

-- ============================================================
-- FINAL SELECT
-- Inherits all columns from flagged (*) and adds:
--   - Overall pass/fail across both directions
--   - Per-direction pass/fail (download & upload)
--   - Human-readable failure reason strings for each level
--   - Where a reason applies to both directions it is 
--     deduplicated into a single "(download & upload)" entry
-- ============================================================
SELECT
  *,

  -- Overall pass/fail: any single flag failure = overall fail
  CASE
    WHEN s2c_IsComplete = 'fail' OR s2c_data_IsSmall = 'fail' OR s2c_IsShort_flag = 'fail' OR s2c_IsLong_flag = 'fail'
      OR c2s_IsComplete = 'fail' OR c2s_data_IsSmall = 'fail' OR c2s_IsShort_flag = 'fail' OR c2s_IsLong_flag = 'fail'
    THEN 'fail'
    ELSE 'pass'
  END AS pass_fail_overall,

  -- Overall failure reasons: deduplicates where both directions fail for the same reason
  -- CONCAT_WS skips NULLs automatically, NULLIF converts empty string to NULL when all pass
  NULLIF(CONCAT_WS(', ',
    CASE
      WHEN s2c_IsComplete = 'fail' AND c2s_IsComplete = 'fail' THEN 'test incomplete (download & upload)'
      WHEN s2c_IsComplete = 'fail'                             THEN 'test incomplete (download)'
      WHEN c2s_IsComplete = 'fail'                             THEN 'test incomplete (upload)'
    END,
    CASE
      WHEN s2c_data_IsSmall = 'fail' AND c2s_data_IsSmall = 'fail' THEN 'insufficient data (download & upload)'
      WHEN s2c_data_IsSmall = 'fail'                               THEN 'insufficient data (download)'
      WHEN c2s_data_IsSmall = 'fail'                               THEN 'insufficient data (upload)'
    END,
    CASE
      WHEN s2c_IsShort_flag = 'fail' AND c2s_IsShort_flag = 'fail' THEN 'test too short (download & upload)'
      WHEN s2c_IsShort_flag = 'fail'                               THEN 'test too short (download)'
      WHEN c2s_IsShort_flag = 'fail'                               THEN 'test too short (upload)'
    END,
    CASE
      WHEN s2c_IsLong_flag = 'fail' AND c2s_IsLong_flag = 'fail'   THEN 'test too long (download & upload)'
      WHEN s2c_IsLong_flag = 'fail'                                 THEN 'test too long (download)'
      WHEN c2s_IsLong_flag = 'fail'                                 THEN 'test too long (upload)'
    END
  ), '') AS reasons_failed_overall,

  -- Upload pass/fail: any upload flag failure = upload fail
  CASE
    WHEN c2s_IsComplete = 'fail' OR c2s_data_IsSmall = 'fail' OR c2s_IsShort_flag = 'fail' OR c2s_IsLong_flag = 'fail'
    THEN 'fail'
    ELSE 'pass'
  END AS pass_fail_upload,

  -- Upload failure reasons
  NULLIF(CONCAT_WS(', ',
    CASE WHEN c2s_IsComplete   = 'fail' THEN 'test incomplete'              END,
    CASE WHEN c2s_data_IsSmall = 'fail' THEN 'insufficient data (<8192 bytes)' END,
    CASE WHEN c2s_IsShort_flag = 'fail' THEN 'test too short (<9s)'         END,
    CASE WHEN c2s_IsLong_flag  = 'fail' THEN 'test too long (>60s)'         END
  ), '') AS reasons_failed_upload,

  -- Download pass/fail: any download flag failure = download fail
  CASE
    WHEN s2c_IsComplete = 'fail' OR s2c_data_IsSmall = 'fail' OR s2c_IsShort_flag = 'fail' OR s2c_IsLong_flag = 'fail'
    THEN 'fail'
    ELSE 'pass'
  END AS pass_fail_download,

  -- Download failure reasons
  NULLIF(CONCAT_WS(', ',
    CASE WHEN s2c_IsComplete   = 'fail' THEN 'test incomplete'              END,
    CASE WHEN s2c_data_IsSmall = 'fail' THEN 'insufficient data (<8192 bytes)' END,
    CASE WHEN s2c_IsShort_flag = 'fail' THEN 'test too short (<9s)'         END,
    CASE WHEN s2c_IsLong_flag  = 'fail' THEN 'test too long (>60s)'         END
  ), '') AS reasons_failed_download

FROM flagged
)