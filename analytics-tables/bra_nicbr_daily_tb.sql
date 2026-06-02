
-- ==============================================================================
-- Script Name:     bra_nicbr_daily_tb.sql
-- Table Created:   default.bra_nicbr_daily_tb
-- Schema:          default
-- Region:          Brazil
-- Pipeline Status: Active (Integrated: true)
--
-- Purpose:
--   Daily aggregated Brazil school speed test measurements from NIC.BR (the
--   Brazilian government QoS provider). Enriches raw NIC.BR speed data with
--   school metadata, FUST program flags, benchmark comparisons, and per-student
--   performance ratios. Serves as the source for bra_benchmarkstatus_wow.sql.
--
-- Dependencies:
--   - qos.bra (NIC.BR daily aggregated measurements)
--   - school_master.bra (Brazil school master)
--   - default.bra_fust_schools (FUST program school list)
--
-- Output Columns:  ~25 columns
-- Primary Key:     school_id_giga + date
-- Granularity:     One row per school per day
--
-- Run Notes:
--   Recurring — refresh when NIC.BR data is updated. Benchmark defaults to
--   50 Mbps when school-specific benchmark is NULL. dl_benchmark_status:
--   good (≥100% of benchmark), moderate (≥50%), bad (<50%), unknown (NULL speed).
--
-- Last Updated:    2025-10-31 / Luke Stringer
-- ==============================================================================

CREATE TABLE IF NOT EXISTS default.bra_nicbr_daily_tb as (


WITH master AS (
    SELECT DISTINCT
        COALESCE(bm.school_id_govt, fs.school_id_govt) AS school_id_govt,
        COALESCE(bm.school_id_giga, fs.school_id_giga) AS school_id_giga,
        COALESCE(bm.school_name, fs.school_name) AS school_name,
        bm.admin1,
        bm.admin2,
        bm.connectivity,
        bm.connectivity_rt,
        bm.connectivity_type_govt,
        bm.cellular_coverage_availability,
        bm.cellular_coverage_type,
        bm.school_area_type,
        bm.school_funding_type,
        bm.education_level,
        bm.fiber_node_distance,
        CASE
            WHEN bm.num_students BETWEEN 1 AND 100 THEN '1-100'
            WHEN bm.num_students BETWEEN 101 AND 200 THEN '101-200'
            WHEN bm.num_students BETWEEN 201 AND 300 THEN '201-300'
            WHEN bm.num_students > 300 THEN '300+'
            ELSE 'Unknown'
        END AS students,
        bm.num_students,
        bm.num_computers,
        COALESCE(bm.download_speed_benchmark, 50) AS download_speed_benchmark,
        fs.fust_tax_exempt,
        fs.fust_install
    FROM school_master.bra bm
    FULL JOIN default.bra_fust_schools fs
        ON bm.school_id_govt = fs.school_id_govt
),
nic_br_realtime AS (

    SELECT
        school_id_govt,
        school_id_giga,
        date,
        avg(speed_download_mean)  as speed_download_mean,
        avg(speed_upload_mean) as speed_upload_mean,
        avg(roundtrip_time_mean)  AS roundtriptime_mean,
        CAST(NULL AS DOUBLE) AS jitter_download_mean,
        CAST(NULL AS DOUBLE) AS jitter_upload_mean,
        avg(rtt_packet_loss_pct_mean) AS packetloss_pct_mean,
        sum(count) num_measurements,
        CAST(NULL AS DOUBLE) AS num_agents
    FROM 
        qos.bra
    GROUP BY 
        date, 
        school_id_govt,
        school_id_giga
      
),
vt AS (
    SELECT
        r.*,
        m.school_name,
        m.admin1,
        m.admin2,
        m.connectivity,
        m.connectivity_rt,
        m.connectivity_type_govt,
        m.school_funding_type,
        m.num_students,
        m.cellular_coverage_type,
        m.education_level,
        m.fiber_node_distance,
        m.download_speed_benchmark,
        m.students,
        COALESCE(m.fust_tax_exempt, 'FALSE') AS fust_tax_exempt,
        COALESCE(m.fust_install, 'FALSE') AS fust_install,
        CASE
            WHEN m.school_name IS NULL THEN 0
            ELSE 1
        END AS in_school_master
    FROM nic_br_realtime r
    LEFT JOIN master m
        ON r.school_id_giga = m.school_id_giga
),
final AS (
    SELECT
        *,
        CASE
            WHEN speed_download_mean >= download_speed_benchmark THEN '1 - good'
            WHEN speed_download_mean < download_speed_benchmark AND speed_download_mean > 1 THEN '2 - moderate'
            WHEN speed_download_mean < 1 THEN '3 - bad'
            ELSE 'unknown'
        END AS dl_benchmark_status,
        CASE
            WHEN speed_download_mean >= download_speed_benchmark THEN 'pass'
            WHEN speed_download_mean < download_speed_benchmark AND speed_download_mean IS NOT NULL THEN 'fail'
            ELSE 'unknown'
        END AS dl_benchmark_pass_fail,
        CASE
            WHEN num_students > 0 AND speed_download_mean / num_students < 1 THEN 'fail'
            WHEN num_students > 0 THEN 'pass'
            ELSE 'unknown'
        END AS mbps_target_pass_fail,
        CASE
            WHEN num_students > 0 THEN speed_download_mean / num_students
            ELSE NULL
        END AS mbps_per_student,
        CASE
            WHEN num_students > 0 THEN (speed_download_mean / num_students) - 1
            ELSE NULL
        END AS mbps_per_student_gap,
        speed_download_mean - download_speed_benchmark AS dl_speed_benchmark_mbps_gap,
        CASE
            WHEN download_speed_benchmark > 0 THEN CAST(speed_download_mean / download_speed_benchmark AS DECIMAL(10,5))
            ELSE NULL
        END AS dl_speed_benchmark_ratio
    FROM vt
)
SELECT
    school_id_govt,
    school_id_giga,
    cast(date as date) as date,
    speed_download_mean,
    speed_upload_mean,
    roundtriptime_mean,
    jitter_download_mean,
    jitter_upload_mean,
    packetloss_pct_mean,
    num_measurements,
    num_agents,
    school_name,
    admin1,
    admin2,
    connectivity,
    connectivity_rt,
    connectivity_type_govt,
    school_funding_type,
    num_students,
    cellular_coverage_type,
    education_level,
    fiber_node_distance,
    download_speed_benchmark,
    students,
    fust_tax_exempt,
    fust_install,
    dl_benchmark_status,
    dl_benchmark_pass_fail,
    mbps_target_pass_fail,
    mbps_per_student,
    mbps_per_student_gap,
    dl_speed_benchmark_mbps_gap,
    dl_speed_benchmark_ratio,
    dl_benchmark_status AS rtm_status  -- same value reused for clarity
FROM final


)

;