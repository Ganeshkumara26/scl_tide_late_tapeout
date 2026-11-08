# Design Document — `tide_late` Out-of-Sequence Measurement Journal FSM

**Silicon ID:** OS0035  
**Process:** SCL Mohali CP8D 0.8 µm CMOS (2-metal, 5.0 V)  
**Module:** `tide_late`  
**RTL Source:** `tide_late.sv` (267 lines)  
**Status:** Taped out, DRC clean, LVS verified  

---

## 1. Problem Statement: Out-of-Sequence Measurements in UAV State Estimation

Autonomous UAV platforms rely on Extended Kalman Filter (EKF) state estimation to fuse
heterogeneous sensor streams — IMU, GPS, magnetometer, barometer, and LiDAR — into a
single coherent state vector (position, velocity, attitude). Each sensor has a different
measurement latency:

| Sensor       | Typical Latency | Update Rate |
|:-------------|:----------------|:------------|
| IMU          | 1–2 ms          | 200–400 Hz  |
| Magnetometer | 5–8 ms          | 50–100 Hz   |
| Barometer    | 8–12 ms         | 25–50 Hz    |
| GPS          | 15–30 ms        | 5–10 Hz     |
| LiDAR        | 30–45 ms        | 10–20 Hz    |

When a GPS measurement arrives at $t = 100\,\text{ms}$ with a timestamp of $t = 70\,\text{ms}$,
the EKF has already propagated through $t = 70$, $71$, $72$, … $100\,\text{ms}$. Naively
incorporating this measurement at the current state produces biased estimates. The correct
procedure is **temporal rollback**: rewind the filter state to $t = 70\,\text{ms}$, incorporate
the GPS measurement, then re-propagate forward through all intervening IMU samples.

This is the **Out-of-Sequence Measurement (OOSM)** problem. The `tide_late` module provides
a hardware journal that tracks recent event timestamps, determines insertion order for
late-arriving measurements, and computes the rollback depth needed to rewind the EKF state
to the correct checkpoint.

## 2. Architectural Evolution: From 1,573 Cells to 603 Cells

The original design used **11 parallel comparators** to evaluate timestamp ordering across
all journal entries simultaneously. While functionally correct, this architecture consumed
1,573 standard cells and produced severe routing congestion on the SCL 2-metal process.
Metal-1-only routing could not accommodate the wide comparator fan-out, and placement
density exceeded routable limits. The design failed routing closure.

We redesigned the architecture around a **single shared comparator** that is time-multiplexed
across 18 FSM steps. This reduced cell count to **603 cells** — a 61.7% reduction — and
achieved **100% routing closure** (1,092 / 1,092 nets routed cleanly). The key insight was
that an unsorted journal with rank-based ordering, evaluated sequentially, trades latency
for area — an acceptable trade at the EKF's update rates.

> [!IMPORTANT]
> The 18-cycle deterministic latency is well within the EKF's minimum sensor period
> (~2.5 ms for IMU at 400 Hz). At any realistic clock frequency above 10 kHz, the
> journal's processing time is negligible.

## 3. Module Interface

### 3.1 Port List

| Port    | Direction | Width | Description                                      |
|:--------|:----------|:------|:-------------------------------------------------|
| `clk`   | input     | 1     | System clock                                     |
| `rst_n` | input     | 1     | Active-low asynchronous reset                    |
| `sh_en` | input     | 1     | Shift enable — gates serial data into `cr`       |
| `sdi`   | input     | 1     | Serial data in (MSB-first)                       |
| `start` | input     | 1     | Pulse high for one cycle to begin command execution |
| `sdo`   | output    | 1     | Serial data out (MSB-first, from `cr[17]`)       |
| `done`  | output    | 1     | Asserted for one cycle when processing completes |

### 3.2 Parameters

| Parameter | Default | Description                          |
|:----------|:--------|:-------------------------------------|
| `TS`      | 12      | Timestamp field width (bits)         |
| `JD`      | 4       | Journal depth (number of slots)      |

### 3.3 Command/Response Shift Register

The module uses a single 18-bit shift register `cr[17:0]` for both command input and
response output. Data is shifted **MSB-first** via the `sdi` pin when `sh_en` is asserted.
After processing, the response overwrites `cr` and can be shifted out via `sdo = cr[17]`.

**Command word format:**

```
cr[17:16]  →  op[1:0]    Operation code
cr[15:4]   →  ts[11:0]   12-bit timestamp (or index for READ)
cr[3:0]    →  id[3:0]    4-bit sensor ID
```

## 4. Operations

### 4.1 INIT (op = 2'b00)

Initializes the journal by setting the current time reference `tnow` to the provided
timestamp. Clears all slot valid bits (`slot_v[3:0] = 4'b0000`). Resets checkpoint state.

**Response:** `{2'b00, 16'h0000}` — acknowledgment with zeroed payload.

### 4.2 EVENT (op = 2'b01)

Records a sensor event. The FSM determines:
- Whether the timestamp is **in-order** ($ts \geq t_{\text{now}}$) or **late** ($ts < t_{\text{now}}$).
- The **insertion index**: how many valid journal entries have timestamps earlier than the incoming event.
- The **rollback counter**: how many valid entries have timestamps at or before the most recent checkpoint.
- Whether the event is a **duplicate** (timestamp matches `tnow` or any existing journal entry).
- Which slot to **evict** if the journal is full (the slot with rank 0, i.e., the oldest).

If the event is in-order, `tnow` is updated and a checkpoint may be recorded. If the
journal is full and the incoming event is older than all existing entries, it is **dropped**
(the drop flag is set in the response).

**Response:** `{2'b01, drop, rollback, ins_idx[2:0], rb_cnt[2:0], 8'b0}` (simplified).

### 4.3 READ (op = 2'b10)

Reads back the contents of journal slot specified by `ts[1:0]` (the lower 2 bits of the
timestamp field are repurposed as a slot index). Returns the stored timestamp and sensor ID.

**Response:** `{2'b10, slot_ts[11:0], slot_id[3:0]}`.

### 4.4 STAT (op = 2'b11)

Returns journal status: current `tnow` value and valid-bit vector.

**Response:** `{2'b11, tnow[11:0], slot_v[3:0]}`.

## 5. Journal Architecture

### 5.1 Unsorted Circular Journal

The journal consists of 4 slots, each storing:
- `slot_ts[i][TS-1:0]` — 12-bit timestamp
- `slot_id[i][3:0]` — 4-bit sensor identifier
- `slot_v[i]` — valid bit

Slots are **not** maintained in sorted order. Instead, relative ordering is determined
at query time through pairwise comparisons. A write pointer `wptr[1:0]` cycles through
slots in round-robin fashion. When eviction is necessary, the slot with the minimum
timestamp (rank 0) is overwritten.

### 5.2 Pairwise Comparison Flags

Six comparison flags capture the complete ordering of all 4 slots:

$$c_{ij} = \begin{cases} 1 & \text{if } ts_i < ts_j \\ 0 & \text{otherwise} \end{cases}$$

The six pairs are: $(0,1)$, $(0,2)$, $(0,3)$, $(1,2)$, $(1,3)$, $(2,3)$.

These flags are computed during FSM steps 4–9, one comparison per cycle, using the
single shared comparator. The complement $c_{ji} = \neg c_{ij}$ is implied and never
stored separately.

### 5.3 Rank Computation

The rank of slot $i$ is defined as the number of valid entries with strictly smaller
timestamps:

$$\text{rank}[i] = \sum_{\substack{j \neq i \\ \text{valid}[j]}} c_{ji}$$

For example, if slot 2 has the second-smallest timestamp among 4 valid entries,
$\text{rank}[2] = 1$. Rank computation is $O(1)$ per slot once the comparison flags
are available — it requires only 3 AND-sum operations per slot.

The **minimum slot** (eviction candidate) is the valid slot with rank 0. The
**insertion index** for a new event is the count of valid entries whose timestamps
are strictly less than the incoming timestamp.

## 6. Checkpoint Mechanism

The module maintains a ring buffer of 2 checkpoints: `ck0` and `ck1`, each storing a
12-bit timestamp. A parity toggle `ck_par` selects which checkpoint to update next.

**Update rule:** On every in-order EVENT (where $ts \geq t_{\text{now}}$), the checkpoint
indexed by `ck_par` is overwritten with the **previous** value of `tnow`, and `ck_par`
is toggled. This gives the EKF two rollback targets at different depths.

**Invalidation:** An INIT command resets both checkpoints and the parity toggle.

The rollback counter in the EVENT response counts how many valid journal entries have
timestamps $ts_j \leq ck_{\text{active}}$, telling the EKF how many filter states must
be re-propagated.

## 7. Duplicate Timestamp Detection

Before recording an event, the FSM checks for timestamp collisions:

1. $ts_{\text{in}} = t_{\text{now}}$ — incoming matches the current time reference.
2. $ts_{\text{in}} = ts_j$ for any valid slot $j$ — incoming duplicates an existing entry.

If a duplicate is detected, the event is flagged with an error bit in the response word.
The journal state is **not** modified. This prevents the EKF from double-incorporating
a measurement, which would corrupt the covariance matrix.

## 8. The 18-Step FSM Pipeline

All commands execute in exactly **18 clock cycles**, regardless of operation type. A
5-bit step counter `step[4:0]` sequences through the pipeline:

| Steps  | Operation                                                      |
|:-------|:---------------------------------------------------------------|
| 0      | Idle / latch command from `cr`, decode `op`, `ts`, `id`        |
| 1      | Compare incoming `ts` vs `tnow`                                |
| 2      | Compare incoming `ts` vs `ck0`                                 |
| 3      | Compare incoming `ts` vs `ck1`                                 |
| 4      | Pairwise compare: slot 0 vs slot 1 → `c01`                    |
| 5      | Pairwise compare: slot 0 vs slot 2 → `c02`                    |
| 6      | Pairwise compare: slot 0 vs slot 3 → `c03`                    |
| 7      | Pairwise compare: slot 1 vs slot 2 → `c12`                    |
| 8      | Pairwise compare: slot 1 vs slot 3 → `c13`                    |
| 9      | Pairwise compare: slot 2 vs slot 3 → `c23`                    |
| 10     | Count valid entries with $ts < ts_{\text{in}}$ (slot 0)        |
| 11     | Count valid entries with $ts < ts_{\text{in}}$ (slot 1)        |
| 12     | Count valid entries with $ts < ts_{\text{in}}$ (slot 2)        |
| 13     | Count valid entries with $ts < ts_{\text{in}}$ (slot 3)        |
| 14     | Count entries with $ts \leq ck$ (slot 0)                       |
| 15     | Count entries with $ts \leq ck$ (slot 1)                       |
| 16     | Count entries with $ts \leq ck$ (slot 2)                       |
| 17     | Count entries with $ts \leq ck$ (slot 3)                       |
| 18     | Write slot, form response word, assert `done`                  |

The `slot_sel` multiplexer routes the appropriate slot's timestamp to the shared
comparator input based on the current step value.

> [!NOTE]
> Steps 10–13 and 14–17 accumulate their respective counters incrementally. Each step
> adds 0 or 1 to a running sum based on the comparison result and the slot's valid bit.

## 9. Timing Contract

```
Cycle 0:    Assert start=1 (cr must contain valid command)
Cycle 1:    FSM begins step 1. start must return to 0.
Cycle 2-17: FSM executes comparison/counting pipeline
Cycle 18:   done=1 asserted. cr contains response word.
Cycle 19:   done returns to 0. cr may be shifted out via sh_en/sdo.
```

**Invariant:** From `start` assertion to `done` assertion, exactly 18 clock edges elapse.
This deterministic latency simplifies system-level scheduling — no variable-length
wait states, no handshaking, no backpressure.

## 10. Verification Summary

### 10.1 Functional Verification

- **Test depth:** 1,000 commands across randomized and directed test sequences.
- **Error count:** 0 mismatches between RTL simulation and reference model.
- **Coverage:** All 4 operations exercised; full/empty/partial journal states; duplicate
  timestamps; in-order and out-of-order events; all eviction paths.

### 10.2 Mutation Testing

Four mutants were explicitly designed into the verification plan, referenced in RTL
comments:

| Mutant | Description                          | Detection Method                       |
|:-------|:-------------------------------------|:---------------------------------------|
| M1     | Rank off-by-one (≤ instead of <)     | Insertion index mismatch on boundary   |
| M2     | Drop wrong slot (evict rank 1, not 0)| Journal contents diverge after eviction|
| M3     | Checkpoint invalidation skipped      | Rollback counter stale after INIT      |
| M4     | Tie rule error (equal timestamps)    | Duplicate detection fails silently     |

All 4 mutants are **killed** (detected) by the adversarial test vector suite
(`adv_vec.txt`).

### 10.3 Gate-Level Simulation

Post-synthesis gate-level simulation matches RTL behavioral simulation bit-for-bit
across the full 1,000-command test sequence. Timing closure verified at target frequency.

## 11. Synthesis Results

| Metric            | Original Design | Redesigned (OS0035) |
|:------------------|:----------------|:--------------------|
| Standard cells    | 1,573           | 603                 |
| Comparators       | 11 (parallel)   | 1 (shared)          |
| Latency (cycles)  | 1               | 18                  |
| Routing closure   | Failed (2-metal)| 100% (1,092 nets)   |
| DRC               | N/A             | Clean                |
| LVS               | N/A             | Matched              |

> [!TIP]
> The 18× latency increase is irrelevant at system level. Even at a conservative 1 MHz
> clock, 18 cycles = 18 µs — well under the fastest sensor period of ~2.5 ms (IMU at 400 Hz).
> The area savings are what enabled tapeout on the 2-metal process.

## 12. Design Decisions and Trade-offs

1. **Serial I/O over parallel bus:** The 18-bit shift register eliminates wide parallel
   buses, reducing pin count to 5 inputs + 2 outputs and dramatically simplifying pad ring
   routing.

2. **Unsorted journal over sorted insertion:** Sorted insertion requires a shift network
   that scales as $O(n^2)$ in area. Unsorted storage with rank computation is $O(n)$ in
   storage and $O(n^2)$ in time — but time is cheap when $n = 4$.

3. **Fixed 18-cycle pipeline over variable-length FSM:** Deterministic latency eliminates
   the need for ready/valid handshaking, simplifying the system-level integration.

4. **Two checkpoints over one:** A single checkpoint provides only one rollback target.
   Two checkpoints with parity-based rotation provide two targets at different depths,
   covering the common case where GPS and LiDAR measurements arrive with different delays.

---

*Document revision: Tapeout-final. Silicon ID OS0035. SCL Mohali CP8D 0.8 µm CMOS.*
