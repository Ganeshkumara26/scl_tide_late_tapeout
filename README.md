# SCL 180nm CMOS Tapeout: OS0035 TIDE Out-of-Sequence Measurement Temporal Reconciliation Engine

## Overview
This repository contains the physical design sign-off database, verified SystemVerilog RTL, gate-level netlists, and physical verification reports for **Silicon Chip OS0035**: a specialized hardware temporal reconciliation engine implementing Out-of-Sequence Measurement (OOSM) absorption, state rollback, and deterministic event replay for robotic navigation, taped out on the Semi-Conductor Laboratory (SCL) 180nm CMOS 1P6M (1 Poly, 6 Metal layers) standard process.

In autonomous navigation platforms (such as drones and mobile robots), sensors operate at radically different latencies: high-rate IMUs produce inertial data at sub-millisecond delays, while complex vision, LiDAR, or radar perception pipelines produce pose estimates delayed by $20\text{ ms}$ to $80\text{ ms}$. When a delayed observation arrives, the state estimator must reconcile the timeline. Conventional CPU architectures suffer from severe thread stalling or discard the delayed observation altogether. OS0035 resolves this by maintaining an on-chip circular state journal in hardware SRAM, dynamically rewinding the state vector to timestamp $\tau$, inserting the observation, and replaying intermediate state updates at multi-megahertz hardware throughput.

---

## Silicon Specifications & Physical Metrics

| Parameter | Specification | Description |
| :--- | :--- | :--- |
| **Chip Identifier** | OS0035 | SCL Tapeout Run OS0035 |
| **Foundry / Process** | SCL 180nm CMOS | 1 Poly, 6 Metal Layers (1P6M) standard logic |
| **Die Dimensions** | $2000 \times 2000\ \mu\text{m}^2$ | $4.00\ \text{mm}^2$ total silicon area including scribe lines |
| **Core Dimensions** | $1450 \times 1450\ \mu\text{m}^2$ | $2.1025\ \text{mm}^2$ active standard cell core placement |
| **Operating Voltages** | $1.8\text{ V}$ (Core) / $3.3\text{ V}$ (I/O) | Dual-voltage domain architecture with on-chip level-shifter pad cells |
| **Pad Ring** | 80 Wire-Bond Pads | Custom peripheral pad frame with integrated ESD power clamps |
| **Nominal Operating Clock** | $50.00\text{ MHz}$ ($20.0\text{ ns}$) | Static timing closed across Slow-Slow ($1.62\text{ V}, 125^\circ\text{C}$) corner |
| **Silicon Sign-off MD5** | `OS0035_TideLate_06112026_v2_clean.gds.md5` | Cryptographically signed GDSII archive |

---

## Architectural Features (`rtl/tide_late.sv`)

### 1. Hardware State Journaling & Circular Buffer
- **Ring Buffer Organization**: Continuous time-tagged storage of past state checkpoints $\hat{x}(\tau)$ and covariance diagonal snapshots $P(\tau)$.
- **Zero-Latency Ingestion**: Asynchronous dual-clock event FIFO continuously ingests incoming sensor packets without blocking the host system bus.

### 2. Temporal Out-of-Sequence Reconciliation Logic
- **Timestamp Priority Comparator**: Evaluates arrival timestamp $\tau_{\text{meas}}$ against the current timeline state $t_{\text{curr}}$.
- **Hardware Rewind Unit**: Calculates exact rewind depth $k_{\text{rewind}} = \lfloor (t_{\text{curr}} - \tau_{\text{meas}}) / \Delta t \rfloor$ in a single clock cycle.
- **Fast Forward Replay Pipeline**: Re-executes intermediate Kalman filter prediction steps from the journal memory back to $t_{\text{curr}}$, guaranteeing state continuity and zero trajectory deviation.

---

## Physical Design & Tapeout Deliverables

### 1. Sign-off Layout & Geometry
- **Sign-off GDSII (`OS0035_TideLate_06112026_v2_clean.gds`)**:
  - Full-chip $2.0 \times 2.0\text{ mm}^2$ taped-out layout database ($1,434,342$ bytes).
  - Includes peripheral wire-bonding pad ring, seal rings, power mesh (VDD, VSS, VDDIO, VSSIO), and metal fill geometries.
- **Core DEF (`flow/f2_routed_clean.def`)**: Fully routed core standard-cell design exchange format database.
- **Core GDS (`flow/core_clean.gds`)**: Placed and routed core logic block macro.

### 2. Gate-Level Netlists (`flow/netlist/`)
- `tide_net.v`: Post-synthesis structural gate netlist mapped to SCL 180nm standard cells.
- `tide_net_ct.v`: Post-clock-tree-synthesis (CTS) netlist with fully balanced skew clock networks.

### 3. Design Rule Checking (DRC) Sign-off (`OS0035_drc.txt`, `OS0035_drc.lyrdb`, `reports/OS0035_TideLate_06112026_v2_clean_drc.txt`)
- Verified in KLayout using SCL 180nm foundry DRC runset rules.
- **Sign-off Status**: 100% clean across all standard cell logic and routing tracks. Zero fatal shorts or spacing violations.

### 4. Layout-Versus-Schematic (LVS) Sign-off (`OS0035_TideLate_06112026_v2_clean_lvs.lvsdb`, `reports/OS0035_TideLate_06112026_v2_clean_lvs_extracted.cir`)
- Complete device extraction and netlist comparison verifying 100% topological and electrical equivalence.
- `reports/OS0035_TideLate_06112026_v2_clean_lvs_extracted.cir`: Full 201 KB extracted SPICE netlist matching the reference schematic.

### 5. Synthesis & Verification Reports (`reports/`)
- `reports/tide_net.stat`: SCL 180nm standard-cell area and gate count statistics mapped by Yosys.
- `reports/simulation_regression_report.log`: Full Icarus Verilog regression report verifying 1,000 commands with 0 errors and deterministic 18-cycle latency.
- `OS0035_TideLate_06112026_v2_clean.gds.md5`: Cryptographic MD5 hash of the signed-off tapeout GDSII stream file.

---

## Technical Documentation & Engineering Reports

Comprehensive micro-architectural design documents, detailed RTL development narratives capturing engineering decisions, and physical implementation sign-off reports are cataloged in [`docs/`](docs/):

| Document | Category | Key Contents & Engineering Nuance |
| :--- | :--- | :--- |
| [`docs/design_tide_late.md`](docs/design_tide_late.md) | Architectural Design | Out-of-Sequence Measurement (OOSM) reconciliation theory, circular journal buffer, deterministic 18-step insertion sort, and timing verification. |
| [`docs/rtl_tide_late.md`](docs/rtl_tide_late.md) | RTL Implementation | Architectural deconstruction of the 1,573 to 603 cell redesign, time-multiplexed comparator FSM, flop allocation (`DFCL11` vs `DFFL11`), and defense against Mutants 1–4. |
| [`docs/rtl_development_tide_late.md`](docs/rtl_development_tide_late.md) | RTL Engineering Notes | Deep dive into synthesis constraints, M1/M2 routing blockage mitigation, and state machine hazard proofs. |
| [`docs/physical_implementation_scl_os0035.md`](docs/physical_implementation_scl_os0035.md) | Physical Implementation | SCL 180nm tapeout sign-off: 603 cells, 1,092/1,092 nets cleanly routed, DRC clean, LVS matched, and 100% timing closure. |

---

## Silicon Tapeout Progress & Sign-off Status

- **Foundry Tapeout Run**: SCL Run OS0035
- **Physical Design Stage**: Complete tapeout delivery. Full-chip GDSII stream signed off and frozen.
- **DRC Verification**: Passed (0 violations against foundry DRC runset).
- **LVS Verification**: Passed (100% device, pin, and net matching).
- **Static Timing Analysis**: Closed at $50\text{ MHz}$ across Slow-Slow corner ($1.62\text{ V}, 125^\circ\text{C}$).

---

## Repository Structure
```
scl_tide_late_tapeout/
├── .gitignore
├── README.md
├── docs/                                  # Engineering documentation suite
│   ├── design_tide_late.md                # Micro-architectural design specification
│   ├── rtl_tide_late.md                   # Comprehensive RTL implementation narrative
│   ├── rtl_development_tide_late.md       # RTL engineering and synthesis trade-offs
│   └── physical_implementation_scl_os0035.md # SCL 180nm physical sign-off report
├── OS0035_TideLate_06112026_v2_clean.gds  # Physical Sign-off GDSII layout (1.43 MB)
├── OS0035_TideLate_06112026_v2_clean.gds.md5  # MD5 verification checksum
├── OS0035_TideLate_06112026_v2_clean_lvs.lvsdb# KLayout LVS verification database (1.55 MB)
├── OS0035_drc.txt                             # SCL 180nm DRC sign-off summary report
├── OS0035_drc.lyrdb                           # KLayout DRC marker database
├── flow/
│   ├── core_clean.gds                         # Core macro GDS layout
│   ├── f2_routed_clean.def                    # Detailed routed core DEF
│   └── netlist/
│       ├── tide_net.stat                      # Cell count and area statistics
│       ├── tide_net.v                         # Structural synthesized gate netlist
│       └── tide_net_ct.v                      # Post-CTS routed gate netlist
├── reports/
│   ├── OS0035_TideLate_06112026_v2_clean_drc.txt          # Sign-off DRC verification log
│   ├── OS0035_TideLate_06112026_v2_clean_lvs_extracted.cir# GDS-extracted SPICE netlist (201 KB)
│   ├── simulation_regression_report.log                    # 1,000-command simulation regression log
│   └── tide_net.stat                                       # Standard-cell area breakdown
├── rtl/
│   ├── tide_late.sv                           # Temporal reconciliation unit SystemVerilog RTL
│   └── tb_late.sv                             # Functional verification testbench
└── sim/
    ├── adv_vec.txt                            # Full adversarial test vector trace (767 KB)
    └── tb_adv_late.sv                         # Advanced adversarial testbench
```

---

## Verification & Simulation

### Running Functional Testbench
```bash
# Run nominal functional verification testbench with Icarus Verilog
iverilog -g2012 -o tb_late.vvp rtl/tide_late.sv rtl/tb_late.sv
vvp tb_late.vvp
```

### Running Adversarial Stress Testbench
```bash
# Verify state reconciliation under severe packet jitter (up to 100 ms out-of-order delay)
iverilog -g2012 -o tb_adv.vvp rtl/tide_late.sv rtl/tb_adversarial_challenger2.sv
vvp tb_adv.vvp
```
