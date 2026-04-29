
-- ==============================================================================
-- Script Name:     bra_nicbr_registered_tb.sql
-- Table Created:   default.bra_nicbr_registered_tb
-- Schema:          default
-- Region:          Brazil
-- Pipeline Status: Active (Integrated: true)
--
-- Purpose:
--   School-level registration summary for Brazil combining NIC.BR (government
--   QoS provider) measurement history with the school master and FUST program
--   data. Captures which schools are registered with NIC.BR, their measurement
--   activity, and FUST tax-exempt / installation status.
--
-- Dependencies:
--   - school_master.bra (Brazil school master)
--   - default.bra_fust_schools (FUST program school list)
--   - qos.bra (NIC.BR daily aggregated measurements)
--
-- Output Columns:  ~25 columns
-- Primary Key:     school_id_giga
-- Granularity:     One row per school (FULL OUTER JOIN captures all schools
--                  present in either school_master.bra or qos.bra)
--
-- Run Notes:
--   Recurring — refresh when NIC.BR data is updated. Upstream of
--   bra_nicbr_daily_tb.sql and bra_benchmarkstatus_wow.sql.
--
-- Last Updated:    2025-10-31 / Luke Stringer
-- ==============================================================================

 CREATE TABLE IF NOT EXISTS default.bra_nicbr_registered_tb as (


WITH master AS (
  select 
      DISTINCT 
          COALESCE(bm.school_id_govt, fs.school_id_govt) as school_id_govt ,
          COALESCE(bm.school_id_giga, fs.school_id_giga) as school_id_giga, 
          COALESCE(bm.school_name, fs.school_name) as school_name,
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
          schools_within_1km,
         -- bm.electricity_availability,
          bm.fiber_node_distance, 
          (CASE 
            WHEN bm.num_students BETWEEN 1 AND 100 THEN '1-100'
            WHEN bm.num_students BETWEEN 101 AND 200 THEN '101-200'
            WHEN bm.num_students BETWEEN 201 AND 300 THEN '201-300'
            WHEN bm.num_students > 300 THEN '300+'
            ELSE 'Unknown'
              END) AS students,
          bm.num_students,
          bm.num_computers,
          case when bm.download_speed_benchmark is null then 50 else bm.download_speed_benchmark end as download_speed_benchmark,
          fs.fust_tax_exempt,
          fs.fust_install
    FROM
      custom_dataset.school_master_all  bm 
    FULL JOIN 
      default.bra_fust_schools  fs 
    on
      bm.school_id_govt=fs.school_id_govt
    WHERE
      bm.country='BRA'
    )  
      
      
, nic_br AS (
    SELECT school_id_govt, 
        school_id_giga,
        cast(null as DOUBLE) AS num_agents, 
        MIN(timestamp) AS first_measurement_date, 
        MAX(timestamp) AS last_measurement_date, 
        COUNT(DISTINCT date) AS num_days_measured,
        DATE_DIFF('day', MAX(timestamp), current_date) AS days_since_last_measurement
    FROM qos.bra
    GROUP BY school_id_giga, school_id_govt
)


SELECT 
  coalesce(master.school_id_govt, nic_br.school_id_govt) as school_id_govt, 
  coalesce(master.school_id_giga, nic_br.school_id_giga) as school_id_giga, 
  master.school_name,
  master.admin1, 
  master.admin2, 
  master.connectivity, 
  master.connectivity_rt,
  master.connectivity_type_govt,
  master.cellular_coverage_availability,
  master.cellular_coverage_type,
  master.school_area_type,
  master.school_funding_type,
  master.education_level, 
  master.students,
  master.num_students,
  master.num_computers,
  master.schools_within_1km,
  master.download_speed_benchmark,
  CASE WHEN master.fust_tax_exempt IS NULL THEN 'FALSE' ELSE master.fust_tax_exempt END AS fust_tax_exempt,
  CASE WHEN master.fust_install IS NULL THEN 'FALSE' ELSE master.fust_install END AS fust_install,
  nic_br.num_agents, 
  nic_br.first_measurement_date, 
  nic_br.last_measurement_date, 
  nic_br.num_days_measured, 
  nic_br.days_since_last_measurement,
  case when nic_br.first_measurement_date is null then 'no' else 'yes' end as registered_nicbr
FROM
  nic_br 
full JOIN
  master
ON
  nic_br.school_id_giga = master.school_id_giga


 )