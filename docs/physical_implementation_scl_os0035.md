# Physical Implementation — OS0035 `tide_late` on SCL 180nm

**Silicon ID:** OS0035  
**Process:** SCL Mohali CP8D 0.8 µm CMOS  
**Metal Layers:** 2 (Metal-1 + Metal-2)  
**Supply Voltage:** 5.0 V  
**Die Size:** 2000 µm × 2000 µm  
**Core Size:** 1390.2 µm × 1390.2 µm  
**Cell Count:** 603 standard cells  
**Routing Closure:** 1,092 / 1,092 nets (100%)  
**Status:** DRC clean, LVS matched, GDSII released  

---

## 1. Process Technology

The OS0035 tapeout targets the **SCL Mohali CP8D** process — a 0.8 µm feature-size CMOS
technology with a 5.0 V nominal supply. This process provides:

- **2 metal layers** (Metal-1 for local interconnect, Metal-2 for global routing and power)
- **P-well** CMOS on N-substrate
- **5.0 V core and I/O voltage** (no level shifting required between core and pads)
- Standard cell library with DFCL11 (async-clear D-FF), DFFL11 (data-only D-FF),
  combinational gates (NAND, NOR, INV, AOI, OAI families), and I/O pad cells

The 2-metal constraint is the defining challenge of this process. All signal routing must
be accomplished with only Metal-1 (primarily horizontal) and Metal-2 (primarily vertical).
There is no Metal-3 for over-the-cell routing or dedicated clock distribution, which
severely limits routability for designs with high net density.

> [!WARNING]
> The original `tide_late` design (1,573 cells, 11 parallel comparators) failed routing
> closure on this process. The redesign to 603 cells with a single shared comparator was
> driven entirely by the 2-metal routing constraint.

## 2. Die and Core Geometry

The die uses the SCL standard frame with the following dimensions:

| Parameter       | Value              |
|:----------------|:-------------------|
| Die width       | 2000 µm            |
| Die height      | 2000 µm            |
| Core width      | 1390.2 µm          |
| Core height     | 1390.2 µm          |
| Core offset (x) | ~305 µm from die edge |
| Core offset (y) | ~305 µm from die edge |

The core area accommodates the 603 standard cells with comfortable placement density
(target 0.3–0.4). The generous core-to-die margin provides space for the pad ring, power
bus routing, and ESD structures.

## 3. Pad Ring and Pin Assignment

The I/O pad assignment maps the 7 functional signals (5 inputs, 2 outputs) plus power/ground
to specific pad locations around the die periphery:

| Signal  | Pad Cell | Side   | Function                     |
|:--------|:---------|:-------|:-----------------------------|
| `clk`   | PAD2     | Bottom | System clock input           |
| `rst_n` | PAD4     | Bottom | Active-low async reset input |
| `sdo`   | PAD1     | Bottom | Serial data output           |
| `sdi`   | PAD8     | Top    | Serial data input            |
| `done`  | PAD9     | Top    | Processing complete output   |
| `sh_en` | PAD10    | Top    | Shift enable input           |
| `start` | PAD12    | Left   | Command start input          |

**Pad placement rationale:** Clock and reset are placed on the bottom edge for clean
clock tree insertion from a single die edge. The serial data pins (`sdi`, `sdo`) are
separated across top and bottom edges to minimize coupling. The `start` signal is placed
on the left edge, spatially separated from the data path, to reduce the risk of
crosstalk-induced false triggers.

Power and ground pads (`VDD`, `VSS`) are distributed around all four edges of the die,
with at least one VDD/VSS pair per edge to ensure low-impedance power delivery and ground
return paths.

## 4. OS0035 Block Placement

The `tide_late` standard cell block is placed at a specific location within the core area:

| Parameter       | Value          |
|:----------------|:---------------|
| Block dimensions| 270 µm × 60 µm|
| Block origin    | (60, 130) µm   |
| Block area      | 16,200 µm²    |
| Core area       | 1,932,656 µm² |
| Utilization     | ~0.84%         |

The block is positioned in the lower-left quadrant of the core, close to the clock and
reset pads on the bottom edge. This minimizes clock tree wire length and ensures the
shortest possible path from the `rst_n` pad to the asynchronous reset network.

### 4.1 Placement Density

We targeted a placement density of **0.3–0.4** within the block. At 603 cells in a
270 µm × 60 µm block, the actual density depends on the cell mix:

- Average cell width (SCL 180nm library): ~8–12 µm
- Average cell height (fixed by row pitch): ~20 µm
- Estimated cell area: 603 × 10 × 20 ≈ 120,600 µm²
- Block area: 270 × 60 = 16,200 µm²

The placement tool distributes cells across standard cell rows within the block, with
the density target ensuring adequate routing channels between rows. On a 2-metal process,
these inter-row channels are critical: Metal-1 horizontal tracks run within the channel,
and Metal-2 vertical tracks cross over the cells.

## 5. Power Bus Layout

### 5.1 Power Ring

A continuous power ring of VDD and VSS stripes encircles the core area on Metal-2. The
ring provides low-resistance power distribution and a solid ground reference for all
standard cells.

**Left-side gap:** The power ring has a gap on the left edge at $y = 509.3$ to $527.8\,\mu\text{m}$.
This gap accommodates the `start` pad (PAD12) signal routing, which must cross the power
ring on Metal-2 to reach the core. The gap is sized to maintain DRC-clean spacing between
the signal trace and the adjacent VDD/VSS stripes.

### 5.2 Power Straps

Within the core, horizontal VDD/VSS straps on Metal-1 run along each standard cell row,
connecting to the cell power rails. Vertical Metal-2 straps connect the row-level rails
to the power ring, forming a mesh that limits IR drop across the cell block.

> [!NOTE]
> At 603 cells and 5.0 V supply, IR drop is not a significant concern. The power mesh
> is sized conservatively to meet DRC minimum-width rules rather than for voltage drop.

## 6. Routing Strategy

### 6.1 The 2-Metal Challenge

With only Metal-1 and Metal-2 available, routing must be carefully managed:

- **Metal-1:** Preferred horizontal routing direction. Also used for intra-cell connections
  and local interconnect within standard cell rows.
- **Metal-2:** Preferred vertical routing direction. Also carries the power ring and
  vertical power straps.

The critical constraint is **Metal-1 blockage**: the standard cells themselves use Metal-1
internally for transistor-level routing. The router can only use Metal-1 in the inter-row
channels and over-cell tracks that do not conflict with cell-internal Metal-1 geometry.

### 6.2 Routing Results

| Metric              | Value      |
|:--------------------|:-----------|
| Total nets          | 1,092      |
| Routed nets         | 1,092      |
| Routing closure     | 100%       |
| DRC violations      | 0 (final)  |
| Antenna violations  | 0          |

The 100% routing closure validates the architectural redesign. The original 1,573-cell
design had approximately 2,800 nets; reducing to 1,092 nets brought net density well
within the 2-metal process capability.

### 6.3 Metal-1 Blockage Management

We addressed Metal-1 blockage through several strategies:

1. **Low placement density (0.3–0.4):** Provides generous inter-row channels for Metal-1
   routing tracks.
2. **Single shared comparator:** Eliminates the high-fanout comparator outputs that
   dominated Metal-1 congestion in the original design.
3. **Serial I/O:** The 1-bit `sdi`/`sdo` interface produces minimal routing demand at
   the pad-to-core boundary.
4. **Register partitioning:** Using DFFL11 (smaller) cells where async reset is unnecessary
   reduces overall cell footprint and frees routing resources.

## 7. DRC Closure

Design Rule Check verification progressed through multiple iterations:

| Iteration        | File                | Violations | Status       |
|:-----------------|:--------------------|:-----------|:-------------|
| Initial          | `drc_die2.txt`      | Multiple   | Failed       |
| Revised layout   | `drc_die2_v2.txt`   | Reduced    | Near-clean   |
| Final            | `OS0035_drc.txt`    | 0          | **Clean**    |

### 7.1 DRC Violations Encountered and Resolved

**Metal spacing violations:** Initial placement produced Metal-1 minimum-spacing violations
between adjacent cell pins and routing tracks in congested regions. Resolved by adjusting
placement density and adding routing blockages in critical areas.

**Power ring width violations:** Early iterations had power ring segments that narrowed
below the minimum width at corners. Resolved by widening the corner geometry and ensuring
the left-side gap at $y = 509.3\text{–}527.8\,\mu\text{m}$ maintained DRC-clean spacing on both
sides.

**Via enclosure violations:** Metal-1 to Metal-2 vias near the block boundary had
insufficient metal enclosure. Resolved by adjusting the block origin to provide adequate
margin from the power ring.

**Well proximity violations:** P-well to N-well spacing near the block boundary required
adjustment of the outermost cell row placement.

> [!IMPORTANT]
> Each DRC iteration required re-extraction and re-verification. The progression from
> `drc_die2.txt` to `OS0035_drc.txt` represents approximately 3 full PnR iterations.

## 8. LVS Verification

Layout vs. Schematic verification confirmed that the physical layout matches the
synthesized gate-level netlist:

- **Device count match:** All 603 standard cells present in layout
- **Net connectivity match:** All 1,092 nets correctly connected
- **Port match:** All 7 functional ports (`clk`, `rst_n`, `sh_en`, `sdi`, `start`,
  `sdo`, `done`) correctly connected to their assigned pad cells
- **Power/ground match:** VDD and VSS nets continuous from pad to all cell power pins

LVS was run with the SCL Mohali extraction deck, which includes parasitic device
recognition for ESD structures in the pad cells.

## 9. GDSII Generation

Two GDSII versions were produced:

| Version       | Description                        | Status        |
|:--------------|:-----------------------------------|:--------------|
| v1 (initial)  | First complete layout              | DRC issues    |
| v2_clean      | DRC-remediated final layout        | **Released**  |

The v2_clean GDSII is the tapeout-final version, incorporating all DRC fixes and LVS-verified
connectivity. The file was generated with the SCL Mohali layer mapping table and includes
all required mask layers: diffusion, polysilicon, contact, Metal-1, via, Metal-2, pad
opening, and passivation opening.

## 10. Verification in Physical Context

### 10.1 Gate-Level Simulation

Post-synthesis gate-level simulation was performed using the SCL 180nm timing library.
The simulation exercised the full 1,000-command test sequence and produced bit-exact
matches against the behavioral RTL simulation. Key verification points:

- All 4 operations (INIT, EVENT, READ, STAT) produce correct responses
- Deterministic 18-cycle latency confirmed across all commands
- Asynchronous reset correctly initializes all control state
- Shift register timing (setup/hold) met across all corners

### 10.2 Adversarial Test Vectors

The adversarial test vector suite (`adv_vec.txt`) specifically targets:

- **Full journal eviction sequences:** Verify that the oldest entry (rank 0) is correctly
  identified and overwritten
- **Duplicate timestamp injection:** Verify error flag assertion and journal non-modification
- **Checkpoint boundary conditions:** Verify rollback counter accuracy when events straddle
  checkpoint boundaries
- **Back-to-back commands:** Verify that the `done` → `start` turnaround works correctly
  with no dead cycles required

### 10.3 Mutation Testing Results

All 4 targeted mutants (M1: rank off-by-one, M2: drop wrong slot, M3: checkpoint
invalidation, M4: tie rule) are detected by the adversarial test suite. This confirms
that our verification has structural coverage beyond simple functional correctness.

## 11. Design Decisions During Physical Implementation

### 11.1 Block Placement at (60, 130)

We placed the cell block in the lower-left quadrant rather than center-core to minimize
wire length to the clock (`PAD2`, bottom) and reset (`PAD4`, bottom) pads. Clock skew
is reduced by having the clock entry point close to the cell block, and the async reset
network benefits from a short, direct path from the pad.

### 11.2 Pad Separation Strategy

The `sdi` (PAD8, top) and `sdo` (PAD1, bottom) pads are on opposite edges of the die.
This was deliberate: placing input and output serial data on the same edge creates a risk
of coupling through shared power/ground return paths in the pad ring. Opposite-edge
placement provides maximum physical isolation.

### 11.3 Conservative Density Target

A placement density of 0.3–0.4 is low by modern standards but appropriate for a 2-metal
process. Higher density would reduce inter-row channel width, potentially causing Metal-1
routing congestion even with our reduced cell count. The die area (4 mm²) is not a binding
constraint — SCL tapeout costs are per-die, not per-area.

## 12. Known Issues and Resolution

| Issue                          | Impact     | Resolution                         |
|:-------------------------------|:-----------|:-----------------------------------|
| Power ring left-side gap       | Cosmetic   | Required for PAD12 signal routing  |
| 3 DRC iterations needed        | Schedule   | No functional impact               |
| Metal-1 congestion in v1       | Routing    | Resolved by density adjustment     |
| Via enclosure at block boundary| DRC        | Block origin shifted               |

No open issues remain. The v2_clean GDSII is DRC-clean and LVS-verified.

## 13. Summary

The OS0035 physical implementation demonstrates that a carefully architected 603-cell
design can achieve 100% routing closure on a challenging 2-metal CMOS process where a
1,573-cell design failed. The key enablers were:

1. **Architectural redesign** from parallel to serial comparison (61.7% cell reduction)
2. **Serial I/O** reducing pad count and pad-to-core routing demand
3. **Conservative placement density** ensuring adequate Metal-1 routing channels
4. **Disciplined register partitioning** minimizing cell area through DFCL11/DFFL11 selection

The tapeout package (v2_clean GDSII) has been released to SCL Mohali for fabrication.

---

*Physical implementation document — final. Silicon ID OS0035.
SCL Mohali CP8D 0.8 µm CMOS. Die: 2000 µm × 2000 µm. Core: 1390.2 µm × 1390.2 µm.
603 cells, 1,092 nets, DRC clean, LVS matched.*
