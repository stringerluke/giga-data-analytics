# GigaMeter SQL Analytics — Script Library

SQL analytics scripts for the **Giga school connectivity monitoring pipeline**. These scripts run on **Trino/Presto** and power the measurement, registration, quality, and reporting layers of the GigaMeter platform.

---

## Overview

[Giga](https://giga.global/) is a UNICEF initiative to connect every school to the internet. This script library forms the analytics backbone for GigaMeter — the mobile app and hardware device network that measures real-time internet connectivity at schools worldwide.

The scripts ingest raw speed test data from two sources (the **GigaMeter app** and **MLab**), validate and aggregate it, track device and school registration, score school connectivity consistency, and produce country-level summaries. Regional extensions cover Brazil (NIC.BR government QoS) and Mongolia (LibreRouter hardware devices).

---

## Pipeline Architecture

```
━━━━━━━━━━━━━━━━━━━━━━━━━ RAW DATA SOURCES ━━━━━━━━━━━━━━━━━━━━━━━━━
  gigameter_production_db   │  delta_lake         │  qos / qos_raw
  (measurements, schools,   │  (school_master     │  (NIC.BR, LibreRouter,
   devices, ping checks)    │   delta tables)     │   Kenya providers)
━━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━

CORE REFERENCE
  country_versions.sql ──────────────────────────────────┐
  all_school_master.sql  (depends on country_versions)   │
                                                         │
MEASUREMENT PIPELINE                                     │
  [Step 1] all_gmeter_only_measurements.sql              │
  [Step 2] all_mlab_only_measurements.sql                │
  [Step 3] all_gigameter_measurement_data.sql ◄──────────┘
           (union of steps 1 & 2; placeholder pending)

CONNECTIVITY & PING
  all_ping_hourly.sql
  all_gigameter_inc_ping_daily.sql  (ping + speed tests, daily roll-up)
  all_gigamaps_realtimeconnectivity.sql

REGISTRATION & FUNNEL
  all_gigameter_appversion_funnel.sql
  all_gigameter_registered_schools.sql
  all_gigameter_registered_devices.sql

QUALITY & SCORING
  all_gigameter_valid_test_checker.sql
  all_gigameter_school_consistency_history.sql

AGGREGATION & REPORTING
  all_gigameter_funnelsummary.sql

━━━━━━━━━━━━━━━━━━━━ REGIONAL EXTENSIONS ━━━━━━━━━━━━━━━━━━━━━━━━━

BRAZIL (NIC.BR)                     MONGOLIA (LibreRouter)
  bra_nicbr_registered_tb.sql         mng_gigameter_qos_registered.sql
  bra_nicbr_daily_tb.sql              mng_gigameter_qos_measurements.sql
  bra_benchmarkstatus_wow.sql
```

---

## Script Reference

| Script | Creates Table | Purpose | Key Dependencies |
|---|---|---|---|
| `country_versions.sql` | `default.country_versions` | Latest delta version per country | `delta_lake.school_master.*` |
| `all_school_master.sql` | `default.all_school_master` | Master reference — ~2.1M schools, 69 columns | `country_versions` |
| `all_gmeter_only_measurements.sql` | `default.all_gmeter_only_measurements` | GigaMeter app raw measurements (Pipeline Step 1) | `gigameter_production_db` |
| `all_mlab_only_measurements.sql` | `default.all_mlab_only_measurements` | MLab network test measurements (Pipeline Step 2) | `gigameter_production_db` |
| `all_gigameter_measurement_data.sql` | `default.all_gigameter_measurement_data` | Consolidated union of Steps 1 & 2 (Step 3 — placeholder) | Steps 1 & 2 |
| `all_ping_hourly.sql` | `default.all_ping_hourly` | Hourly ping/uptime aggregation per device-school | `gigameter_production_db.connectivity_ping_checks` |
| `all_gigameter_inc_ping_daily.sql` | `default.all_gigameter_inc_ping_daily` | Daily roll-up combining ping + speed test data | `all_ping_hourly`, measurement data |
| `all_gigamaps_realtimeconnectivity.sql` | `default.all_gigamaps_realtimeconnectivity` | Daily school connectivity status by country | `gigamaps_production_db` |
| `all_gigameter_appversion_funnel.sql` | `default.all_gigameter_appversion_funnel` | Device registration → data sent → version upgrade funnel | `gigameter_production_db`, `all_school_master` |
| `all_gigameter_registered_schools.sql` | `default.all_gigameter_registered_schools` | School-level registration & activity summary | measurement data, `all_school_master` |
| `all_gigameter_registered_devices.sql` | `default.all_gigameter_registered_devices` | Device-level registration & activity summary | measurement data, appversion funnel |
| `all_gigameter_valid_test_checker.sql` | `default.all_gigameter_valid_test_checker` | Per-measurement quality validation (pass/fail flags) | Steps 1 & 2 |
| `all_gigameter_school_consistency_history.sql` | `default.all_gigameter_school_consistency_history` | Weekly 30-day rolling consistency score per school | measurement data |
| `all_gigameter_funnelsummary.sql` | `default.all_gigameter_funnelsummary_tb_physical` | Country-level adoption funnel & QoS source summary | measurement data, `all_school_master`, QoS tables |
| `bra_nicbr_registered_tb.sql` | `default.bra_nicbr_registered_tb` | Brazil school NIC.BR registration summary | `school_master.bra`, `qos.bra`, FUST |
| `bra_nicbr_daily_tb.sql` | `default.bra_nicbr_daily_tb` | Daily Brazil NIC.BR speed data with benchmark flags | `qos.bra`, `school_master.bra`, FUST |
| `bra_benchmarkstatus_wow.sql` | `default.bra_benchmarkstatus_wow` | Brazil weekly benchmark status with WoW changes | `bra_nicbr_daily_tb` |
| `mng_gigameter_qos_registered.sql` | `default.mng_gigameter_qos_registered` | Mongolia school registration (GigaMeter + LibreRouter) | `qos_raw.mng`, `school_master.mng` |
| `mng_gigameter_qos_measurements.sql` | `default.mng_gigameter_qos_measurements` | Mongolia daily measurements (GigaMeter + LibreRouter) | `qos.mng`, `school_master.mng` |

---

## Regional Implementations

### Brazil — NIC.BR

Brazil schools are monitored by **NIC.BR**, the Brazilian government's QoS measurement provider, in addition to the GigaMeter app. Three scripts handle the Brazil pipeline:

1. **`bra_nicbr_registered_tb.sql`** — Registration layer: which schools are sending NIC.BR data, their FUST program status, and measurement history.
2. **`bra_nicbr_daily_tb.sql`** — Daily aggregation: speed metrics enriched with benchmark thresholds (default 50 Mbps), per-student ratios, and benchmark status classification (good / moderate / bad / unknown).
3. **`bra_benchmarkstatus_wow.sql`** — Reporting layer: weekly benchmark status counts with week-over-week absolute and percentage changes.

FUST (Fundo de Universalização dos Serviços de Telecomunicações) schools are flagged via `default.bra_fust_schools` for tax-exempt and installation status tracking.

### Mongolia — LibreRouter

Mongolia schools are monitored by both the GigaMeter app and **LibreRouter** — Raspberry Pi-based hardware monitoring devices. Two scripts handle the Mongolia pipeline:

1. **`mng_gigameter_qos_registered.sql`** — Registration layer: which schools have GigaMeter and/or LibreRouter active, with a `rtm_source` field ('both' / 'gigameter' / 'libre').
2. **`mng_gigameter_qos_measurements.sql`** — Daily aggregation: unified view of GigaMeter and LibreRouter measurements with source-specific speed and traffic metrics.

---

## Running the Scripts

### Recommended Execution Order

Run in dependency order. Scripts at the same level can run in parallel.

```
Level 1 (no SQL dependencies):
  country_versions.sql

Level 2:
  all_school_master.sql
  all_gmeter_only_measurements.sql
  all_mlab_only_measurements.sql

Level 3:
  all_gigameter_measurement_data.sql   ← complete placeholder first
  all_ping_hourly.sql
  all_gigameter_appversion_funnel.sql

Level 4:
  all_gigameter_inc_ping_daily.sql
  all_gigameter_valid_test_checker.sql
  all_gigameter_registered_schools.sql
  all_gigameter_registered_devices.sql
  all_gigameter_funnelsummary.sql
  all_gigamaps_realtimeconnectivity.sql
  bra_nicbr_daily_tb.sql              ← bra_nicbr_registered_tb first
  mng_gigameter_qos_measurements.sql  ← mng_gigameter_qos_registered first

Level 5:
  all_gigameter_school_consistency_history.sql  ← run once for backfill
  bra_benchmarkstatus_wow.sql
```

### One-time vs Recurring Scripts

| Script | Cadence |
|---|---|
| `all_gigameter_school_consistency_history.sql` | **Run once** for historical backfill; use the weekly append variant for ongoing updates |
| All others | **Recurring** — daily or weekly depending on upstream data refresh |

### Trino Session Configuration

Some scripts include optional session settings to handle large query stages or memory pressure. Uncomment as needed:

```sql
SET SESSION mark_distinct_strategy = 'none';    -- avoids memory spikes on DISTINCT
SET SESSION query_max_stage_count = 400;        -- needed for country_versions.sql (200+ unions)
```

---

## Glossary

| Term | Definition |
|---|---|
| **GigaMeter** | UNICEF/Giga's mobile app installed on school devices to run daily speed tests |
| **MLab** | Measurement Lab — open-source, server-side network performance measurement platform |
| **QoS** | Quality of Service — generic term for government or hardware-based network monitoring |
| **NIC.BR** | Núcleo de Informação e Coordenação do Ponto BR — Brazil's government internet registry that operates a school QoS monitoring programme |
| **LibreRouter** | Open-source Raspberry Pi-based hardware device deployed in Mongolian schools to measure connectivity passively |
| **FUST** | Fundo de Universalização dos Serviços de Telecomunicações — Brazil's universal telecoms fund; FUST schools receive tax-exempt connectivity installations |
| **Consistency Score** | 0–100 weekly rolling score measuring how regularly a school runs GigaMeter tests (target: ≥4 tests/day on weekdays) |
| **dl_benchmark_status** | Brazil-specific flag: good (download ≥100% of benchmark), moderate (≥50%), bad (<50%), unknown (no data) |
| **rtm_source** | Mongolia-specific field indicating which monitoring system(s) a school is registered with: 'both', 'gigameter', 'libre' |
| **school_id_giga** | Giga's globally unique 36-character UUID for each school |
| **school_id_govt** | Government-assigned school identifier (varies by country) |
