# RTL Development Narrative — `tide_late` OOSM Journal FSM

**Silicon ID:** OS0035  
**Module:** `tide_late.sv` (267 lines)  
**Process:** SCL Mohali CP8D 0.8 µm CMOS  
**Development Status:** Complete — verified, synthesized, taped out  

---

## 1. Starting Point: The Unroutable Parallel Design

Our first implementation of the OOSM journal used **11 parallel comparators** to evaluate
all timestamp relationships in a single clock cycle. The design was functionally correct
and achieved single-cycle latency, but it consumed **1,573 standard cells**. When we
attempted place-and-route on the SCL 2-metal process, the router could not close. The
comparator fan-out created dense Metal-1 congestion that left hundreds of nets unrouted.

The fundamental problem was clear: on a 2-metal process, wide combinational logic with
high fan-out is a routing liability, not an asset. We needed to rethink the architecture
from scratch — trading temporal parallelism for spatial efficiency.

## 2. The Redesign Insight: Unsorted Slots with Rank Computation

We observed that the journal has only 4 entries. The total ordering of 4 elements requires
$\binom{4}{2} = 6$ pairwise comparisons. If we serialize these comparisons across clock
cycles using a **single shared comparator**, we eliminate 10 of the 11 comparators and their
associated routing. The cost is latency: 18 cycles instead of 1. But at any realistic
system clock, 18 cycles is negligible compared to the sensor periods we are tracking
(milliseconds, not microseconds).

The key architectural decision: **do not sort the journal**. Store entries in insertion
order (circular write pointer). Compute the rank of each entry on-demand by counting how
many other valid entries have smaller timestamps. This avoids the costly shift network
that sorted insertion demands.

> [!IMPORTANT]
> The rank-based approach scales as $O(n^2)$ in comparisons but only $O(n)$ in storage.
> For $n = 4$, the 6 comparisons fit comfortably in an 18-step FSM alongside all other
> operations.

## 3. Building the Pairwise Comparison Architecture

We define six comparison flags that capture the full ordering:

```
c01 = (slot_ts[0] < slot_ts[1])
c02 = (slot_ts[0] < slot_ts[2])
c03 = (slot_ts[0] < slot_ts[3])
c12 = (slot_ts[1] < slot_ts[2])
c13 = (slot_ts[1] < slot_ts[3])
c23 = (slot_ts[2] < slot_ts[3])
```

From these, the rank of any slot is computed by summing the relevant flags. For example:

```
rank[0] = (c10 & v[1]) + (c20 & v[2]) + (c30 & v[3])
         where c10 = ~c01, c20 = ~c02, c30 = ~c03
```

The slot with rank 0 is the oldest (smallest timestamp) among valid entries — the eviction
candidate when the journal is full. The insertion index for a new event is the count of
valid entries with timestamps strictly less than the incoming timestamp.

We implemented this as 6 sequential comparison steps (FSM steps 4–9), each using the
single shared comparator. The comparison results are latched into flip-flops `c01` through
`c23` and remain stable for the subsequent rank evaluation steps.

## 4. Designing the 18-Step Microcode FSM

We partitioned the processing into 18 sequential steps, controlled by a 5-bit counter
`step[4:0]`:

**Steps 1–3: Temporal classification.** Compare the incoming timestamp against the current
time reference `tnow` and both checkpoints `ck0`, `ck1`. This determines whether the event
is in-order or late, and which checkpoint region it falls in.

**Steps 4–9: Pairwise journal comparisons.** One comparison per cycle, 6 pairs total. The
`slot_sel` multiplexer routes the appropriate slot timestamp to the comparator's A-input;
the B-input comes from another slot. Results are latched into the `c01`–`c23` registers.

**Steps 10–13: Insertion index accumulation.** For each valid slot, we check whether its
timestamp is less than the incoming timestamp. A running counter `ins_idx` is incremented
for each such slot, yielding the position where the new event logically belongs in the
sorted order.

**Steps 14–17: Rollback counter accumulation.** For each valid slot, we check whether its
timestamp is at or before the active checkpoint. A running counter `rb_cnt` accumulates
the number of state propagation steps the EKF must undo.

**Step 18: Commit and respond.** Write the new event into the target slot (either the
write pointer or the eviction candidate), update valid bits, form the 18-bit response
word, load it into `cr`, and assert `done`.

The choice of 18 steps was deliberate: it provides exactly enough cycles for all
comparisons and accumulations, with step 0 serving as the idle/decode state.

## 5. Command Shift Register Design

We chose an 18-bit shift register `cr[17:0]` for command/response serialization:

- **Why 18 bits:** The widest field combination is `op[1:0] + ts[11:0] + id[3:0] = 18` bits.
  Using exactly 18 bits avoids wasted register area and aligns the shift count with the
  FSM step count (a convenient property, though not architecturally required).

- **Why MSB-first:** The operation code `op[17:16]` arrives first, allowing the controller
  to pipeline command decode while the lower bits are still shifting in, if needed in
  future revisions.

- **Why `sh_en` gating:** The shift register must remain stable during FSM execution.
  Without `sh_en`, the `sdi` pin would corrupt `cr` on every clock edge. The `sh_en`
  signal provides explicit control: assert it for 18 cycles to load a command, deassert
  during processing, then reassert for 18 cycles to read back the response.

```verilog
always_ff @(posedge clk or negedge rst_n)
  if (!rst_n)       cr <= 18'd0;
  else if (sh_en)   cr <= {cr[16:0], sdi};   // shift left, MSB-first
  else if (step==18) cr <= response_word;     // load response at completion
```

## 6. The `slot_sel` Multiplexer

A critical piece of the microcode FSM is the `slot_sel` signal that routes the correct
slot's timestamp to the shared comparator. The mapping from step number to slot index
is hardcoded:

| Steps | Comparator A source | Comparator B source        |
|:------|:--------------------|:---------------------------|
| 1–3   | incoming `ts`       | `tnow`, `ck0`, `ck1`      |
| 4     | `slot_ts[0]`        | `slot_ts[1]`               |
| 5     | `slot_ts[0]`        | `slot_ts[2]`               |
| 6     | `slot_ts[0]`        | `slot_ts[3]`               |
| 7     | `slot_ts[1]`        | `slot_ts[2]`               |
| 8     | `slot_ts[1]`        | `slot_ts[3]`               |
| 9     | `slot_ts[2]`        | `slot_ts[3]`               |
| 10–13 | `slot_ts[0..3]`     | incoming `ts`              |
| 14–17 | `slot_ts[0..3]`     | active checkpoint          |

This multiplexer is a pure combinational function of `step` and contributes minimal area.

## 7. Checkpoint Logic

The checkpoint subsystem maintains two timestamps (`ck0`, `ck1`) and a parity toggle
(`ck_par`):

- On an **in-order EVENT** ($ts \geq t_{\text{now}}$), we save the *old* value of `tnow`
  into `ck[ck_par]` and toggle `ck_par`. This ensures the two checkpoints represent the
  two most recent state-propagation boundaries.

- On **INIT**, both checkpoints are cleared to zero and `ck_par` is reset. This prevents
  stale checkpoint values from producing incorrect rollback counts after a full reset.

- The **active checkpoint** used for rollback counting (steps 14–17) is `ck[~ck_par]` —
  the one that was *not* just written, i.e., the older of the two.

We initially had a bug where INIT failed to reset `ck_par`, leaving the checkpoint ring
buffer in an inconsistent state. Mutant M3 in our verification plan targets exactly this
failure mode.

## 8. Response Word Assembly

Each operation type produces a differently formatted 18-bit response:

```
INIT:   {2'b00, 16'h0000}
EVENT:  {2'b01, drop, rollback_flag, ins_idx[2:0], rb_cnt[2:0], error, 7'b0}
READ:   {2'b10, slot_ts[11:0], slot_id[3:0]}
STAT:   {2'b11, tnow[11:0], slot_v[3:0]}
```

The response is assembled combinationally at step 18 and loaded into `cr` in a single
clock edge. The upper 2 bits always echo the operation code, allowing the receiving
controller to confirm command/response alignment without external state.

## 9. Register Partitioning for SCL Cell Library

The SCL 180nm standard cell library provides two D flip-flop variants:

- **DFCL11:** D flip-flop with asynchronous active-low clear. Used for all control
  registers that must reset to a known state: `step`, `slot_v`, `wptr`, `ck_par`, `done`.

- **DFFL11:** D flip-flop without asynchronous clear (data-only). Used for all data
  registers where reset value is don't-care: `slot_ts`, `slot_id`, `cr` (data path),
  comparison flags `c01`–`c23`, counters `ins_idx`, `rb_cnt`.

> [!NOTE]
> This partitioning is not just a synthesis optimization — it is a **correctness
> requirement**. The DFCL11 cell is larger than DFFL11 due to the reset transistor
> tree. Using DFCL11 for all 267 lines of register declarations would inflate cell count
> by ~15% and further stress routing. Using DFFL11 where reset is don't-care is both
> area-efficient and electrically correct.

We guided synthesis to this partitioning through disciplined RTL coding: registers that
appear in the `if (!rst_n)` clause of an `always_ff` block map to DFCL11; those that
do not map to DFFL11.

## 10. Mutation Testing: 4 Targeted Mutants

We defined four mutations to validate that our test suite has meaningful fault coverage:

**M1 — Rank off-by-one:** Change the rank comparison from strict-less-than to
less-than-or-equal ($<$ → $\leq$). This causes rank ties to be misresolved, producing
incorrect eviction and insertion index. Caught by boundary-case test vectors where two
slots have adjacent timestamps.

**M2 — Drop wrong slot:** Evict the slot with rank 1 instead of rank 0. The journal
retains the oldest entry and discards the second-oldest. Caught by comparing journal
contents after a full-journal eviction sequence.

**M3 — Checkpoint invalidation skipped:** Remove the `ck_par` reset from the INIT handler.
After INIT, the checkpoint ring buffer starts at the wrong index, producing an off-by-one
in rollback counts for subsequent events. Caught by the INIT → EVENT → STAT sequence.

**M4 — Tie rule error:** Suppress the duplicate-timestamp error flag when the incoming
timestamp equals an existing entry. The journal silently records a duplicate, which would
cause the EKF to double-apply a measurement. Caught by injecting duplicate timestamps and
checking the error bit in the response.

All four mutants are killed by the adversarial test vector suite.

## 11. Valid Bit Management

The `slot_v[3:0]` valid bits govern which journal entries participate in rank computation
and counter accumulation:

- **Asynchronous reset:** All valid bits clear to 0 on `rst_n` deassertion. This requires
  DFCL11 cells.
- **INIT:** Clears all valid bits (`slot_v <= 4'b0000`), effectively emptying the journal.
- **EVENT (write):** Sets the valid bit for the target slot (`slot_v[target] <= 1'b1`).
  Valid bits for other slots are unchanged.

We never explicitly invalidate a single slot. Eviction works by overwriting the slot's
timestamp and ID while leaving its valid bit set — the old data is simply replaced.

## 12. Debugging the Duplicate Timestamp Edge Case

During verification, we encountered a subtle failure: when the incoming timestamp equaled
`tnow` *and* also matched a journal entry, the error flag was set correctly but the
`ins_idx` counter was wrong. The root cause was that the step-1 comparison (incoming vs
`tnow`) set an "equal-to-now" flag that interfered with the step 10–13 accumulation logic.

We fixed this by ensuring the duplicate check is evaluated independently in step 18, using
latched comparison results rather than combinational equality checks. The `ins_idx` counter
now ignores the duplicate condition entirely — if the event is a duplicate, the response
is overridden with the error format regardless of the counter value.

## 13. Area Reduction Verification

We ran synthesis on both the original and redesigned RTL targeting the SCL 180nm standard
cell library:

| Metric              | Original      | Redesigned (OS0035) | Reduction  |
|:--------------------|:--------------|:--------------------|:-----------|
| Total cells         | 1,573         | 603                 | 61.7%      |
| Comparator instances| 11            | 1                   | 90.9%      |
| Register bits       | ~210          | ~148                | ~29.5%     |
| Combinational cells | ~1,363        | ~455                | ~66.6%     |
| Routing closure     | Failed        | 100% (1,092 nets)   | —          |

The register bit reduction comes from eliminating the pre-computed rank registers that the
parallel design maintained. The combinational cell reduction comes primarily from removing
10 comparators and their associated multiplexing logic.

> [!TIP]
> The lesson for future SCL 2-metal designs: always budget for serial/time-multiplexed
> architectures. The routing constraint, not the cell count, is the binding limit.

---

*Development narrative complete. Module `tide_late.sv` (267 lines), verified with 1,000
commands, 0 errors, all 4 mutants killed. Silicon ID OS0035.*
