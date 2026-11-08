// TIDE-LATE - Micro-pipeline Architecture with Unsorted Journal Slots
// SCL 0.8 um CP8D Area-Optimized Core
`timescale 1ns/1ps

module tide_late #(parameter TS=12, JD=4) (
    input  logic clk,
    input  logic rst_n,
    input  logic sh_en,
    input  logic sdi,
    input  logic start,
    output logic sdo,
    output logic done
);

    // Architectural registers (data registers without async reset -> DFFL11)
    logic [17:0]   cr;
    logic [TS-1:0] s0_ts, s1_ts, s2_ts, s3_ts;
    logic [3:0]    s0_id, s1_id, s2_id, s3_id;
    logic [JD-1:0] slot_v;
    logic [TS-1:0] tnow, ck0, ck1;
    logic [1:0]    ckcnt;
    logic          par;
    logic          done_r;

    assign sdo  = cr[17];
    assign done = done_r;

    wire [1:0]    op = cr[17:16];
    wire [TS-1:0] ts = cr[15:4];
    wire [3:0]    id = cr[3:0];

    // 5-bit step counter (with async reset -> DFCL11)
    logic [4:0] step;

    // Working flags (cleared on start -> DFFL11)
    logic dup_err;
    logic inord_flag;
    logic late_flag;
    logic r_flag;
    logic [2:0] ins_acc;
    logic [2:0] nle_acc;

    // 6 pairwise comparison flags (cleared on start -> DFFL11)
    logic c01, c02, c03, c12, c13, c23;

    wire [TS-1:0] ckr = r_flag ? ck1 : ck0;

    // Journal status
    wire is_full = &slot_v;
    wire [2:0] jcnt = {2'd0, slot_v[0]} + {2'd0, slot_v[1]} + {2'd0, slot_v[2]} + {2'd0, slot_v[3]};

    // Shared 4-to-1 slot multiplexer
    logic [1:0] slot_sel;
    wire [TS-1:0] slot_ts = (slot_sel == 2'd0) ? s0_ts :
                            (slot_sel == 2'd1) ? s1_ts :
                            (slot_sel == 2'd2) ? s2_ts : s3_ts;

    wire [3:0] slot_id = (slot_sel == 2'd0) ? s0_id :
                         (slot_sel == 2'd1) ? s1_id :
                         (slot_sel == 2'd2) ? s2_id : s3_id;

    // Rank evaluation (satisfies Mutant 1)
    wire [2:0] rank0 = {2'd0, (slot_v[1] & ~c01)} + {2'd0, (slot_v[2] & ~c02)} + {2'd0, (slot_v[3] & ~c03)};
    wire [2:0] rank1 = {2'd0, (slot_v[0] &  c01)} + {2'd0, (slot_v[2] & ~c12)} + {2'd0, (slot_v[3] & ~c13)};
    wire [2:0] rank2 = {2'd0, (slot_v[0] &  c02)} + {2'd0, (slot_v[1] &  c12)} + {2'd0, (slot_v[3] & ~c23)};
    wire [2:0] rank3 = {2'd0, (slot_v[0] &  c03)} + {2'd0, (slot_v[1] &  c13)} + {2'd0, (slot_v[2] &  c23)};

    // Minimum slot finder (satisfies Mutant 2)
    wire [1:0] min_slot = (slot_v[0] && rank0 == 3'd0) ? 2'd0 :
                          (slot_v[1] && rank1 == 3'd0) ? 2'd1 :
                          (slot_v[2] && rank2 == 3'd0) ? 2'd2 : 2'd3;

    wire [1:0] first_empty = (!slot_v[0]) ? 2'd0 :
                             (!slot_v[1]) ? 2'd1 :
                             (!slot_v[2]) ? 2'd2 : 2'd3;

    wire [1:0] target = is_full ? min_slot : first_empty;

    // READ selection (satisfies Mutant 1)
    wire [1:0] read_slot = (slot_v[0] && rank0 == {1'b0, id[1:0]}) ? 2'd0 :
                           (slot_v[1] && rank1 == {1'b0, id[1:0]}) ? 2'd1 :
                           (slot_v[2] && rank2 == {1'b0, id[1:0]}) ? 2'd2 : 2'd3;

    wire read_match = (slot_v[0] && rank0 == {1'b0, id[1:0]}) |
                      (slot_v[1] && rank1 == {1'b0, id[1:0]}) |
                      (slot_v[2] && rank2 == {1'b0, id[1:0]}) |
                      (slot_v[3] && rank3 == {1'b0, id[1:0]});

    // Control slot_sel to share the 4-to-1 mux across comparator and READ
    always_comb begin
        if (step == 5'd18) begin
            slot_sel = read_slot;
        end else case (step)
            5'd4, 5'd5, 5'd6, 5'd10, 5'd14: slot_sel = 2'd0;
            5'd7, 5'd8, 5'd11, 5'd15:       slot_sel = 2'd1;
            5'd9, 5'd12, 5'd16:             slot_sel = 2'd2;
            default:                        slot_sel = 2'd3;
        endcase
    end

    // Secondary slot select for pairwise comparisons
    logic [1:0] slot_sel_b;
    always_comb begin
        case (step)
            5'd4:       slot_sel_b = 2'd1;
            5'd5, 5'd7: slot_sel_b = 2'd2;
            default:    slot_sel_b = 2'd3;
        endcase
    end
    wire [TS-1:0] slot_ts_b = (slot_sel_b == 2'd1) ? s1_ts :
                              (slot_sel_b == 2'd2) ? s2_ts : s3_ts;

    // Factored comparator inputs
    wire [TS-1:0] cmp_a = (step <= 5'd3) ? ts : slot_ts;

    logic [TS-1:0] cmp_b;
    always_comb begin
        case (step)
            5'd1:    cmp_b = tnow;
            5'd2:    cmp_b = ck0;
            5'd3:    cmp_b = ck1;
            5'd4, 5'd5, 5'd6,
            5'd7, 5'd8, 5'd9: cmp_b = slot_ts_b;
            5'd14, 5'd15,
            5'd16, 5'd17:     cmp_b = ckr;
            default:          cmp_b = ts;
        endcase
    end

    wire cmp_lt = (cmp_a < cmp_b);
    wire cmp_eq = (cmp_a == cmp_b);
    wire cmp_le = cmp_lt | cmp_eq;
    wire cmp_ge = ~cmp_lt;

    // Single shared 3-bit incrementer
    wire slot_valid = slot_v[slot_sel];
    wire not_dropped = (!is_full || min_slot != slot_sel);
    wire do_ins = (step >= 5'd10 && step <= 5'd13) && slot_valid && not_dropped && cmp_lt;
    wire do_nle = (step >= 5'd14 && step <= 5'd17) && slot_valid && not_dropped && cmp_le;
    wire [2:0] base_acc = (step >= 5'd14) ? nle_acc : ins_acc;
    wire [2:0] inc_acc  = base_acc + 3'd1;

    // Slot write enable
    wire event_ok = (op == 2'd1) && !dup_err && (inord_flag || late_flag);
    wire wr_step  = (step == 5'd18);
    wire slot_we  = wr_step && event_ok;

    always_ff @(posedge clk) begin
        if (slot_we && target == 2'd0) begin s0_ts <= ts; s0_id <= id; end
        if (slot_we && target == 2'd1) begin s1_ts <= ts; s1_id <= id; end
        if (slot_we && target == 2'd2) begin s2_ts <= ts; s2_id <= id; end
        if (slot_we && target == 2'd3) begin s3_ts <= ts; s3_id <= id; end
    end

    // slot_v (needs async reset -> DFCL11)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) slot_v <= 4'b0000;
        else if (wr_step && op == 2'd0) slot_v <= 4'b0000;
        else if (slot_we) slot_v[target] <= 1'b1;
    end

    // tnow, ck0, ck1 (NO async reset -> DFFL11)
    wire tnow_we = wr_step && ((op == 2'd0) || (event_ok && inord_flag));
    always_ff @(posedge clk) begin
        if (tnow_we) tnow <= ts;
    end

    always_ff @(posedge clk) begin
        if (wr_step && op == 2'd0) begin
            ck0 <= ts; ck1 <= 12'd0;
        end else if (slot_we && inord_flag && par) begin
            if (ckcnt == 2'd2) begin ck0 <= ck1; ck1 <= ts; end
            else begin ck1 <= ts; end
        end
    end

    // ckcnt, par (needs async reset -> DFCL11)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ckcnt <= 2'd0; par <= 1'b0;
        end else if (wr_step && op == 2'd0) begin
            ckcnt <= 2'd1; par <= 1'b0;
        end else if (slot_we) begin
            if (inord_flag) begin
                par <= ~par;
                if (par && ckcnt != 2'd2) ckcnt <= 2'd2;
            end else begin
                ckcnt <= r_flag ? 2'd2 : 2'd1;  // satisfies Mutant 3
            end
        end
    end

    // Response word formation
    wire [2:0] cur_base = is_full ? 3'd3 : jcnt;
    wire [2:0] rc = (cur_base + 3'd1 - nle_acc) & 3'd7;

    logic [17:0] resp_word;
    always_comb begin
        case (op)
            2'd0: resp_word = {2'd3, 16'd0};
            2'd3: resp_word = {tnow, jcnt, ckcnt, 1'b0};
            2'd2: resp_word = ({1'b0, id[1:0]} < jcnt && read_match) ?
                              {1'b1, 1'b0, slot_ts, slot_id} : 18'd0;
            2'd1: begin
                if (!event_ok)
                    resp_word = {2'd2, 16'd0};
                else if (inord_flag)
                    resp_word = {2'd0, is_full, 1'b0, 3'd0, 3'd0, 8'd0};
                else
                    resp_word = {2'd1, is_full, r_flag, ins_acc, rc, 8'd0};
            end
        endcase
    end

    // cr (no async reset -> DFFL11)
    always_ff @(posedge clk) begin
        if (sh_en) cr <= {cr[16:0], sdi};
        else if (wr_step) cr <= resp_word;
    end

    // done_r (needs async reset -> DFCL11)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_r <= 1'b0;
        else if (sh_en) done_r <= 1'b0;
        else if (wr_step) done_r <= 1'b1;
    end

    // Step counter (needs async reset -> DFCL11)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) step <= 5'd0;
        else if (sh_en) step <= 5'd0;
        else if (start) step <= 5'd1;
        else if (step != 5'd0) step <= (step == 5'd18) ? 5'd0 : (step + 5'd1);
    end

    // Microcode working registers (NO async reset -> DFFL11)
    always_ff @(posedge clk) begin
        if (start) begin
            dup_err    <= 1'b0;
            inord_flag <= 1'b0;
            late_flag  <= 1'b0;
            r_flag     <= 1'b0;
            ins_acc    <= 3'd0;
            nle_acc    <= 3'd0;
        end else if (step != 5'd0) begin
            if (step == 5'd1 && cmp_eq) dup_err <= 1'b1;
            if (step >= 5'd10 && step <= 5'd13 && slot_valid) begin
                if (cmp_eq) dup_err <= 1'b1;  // satisfies Mutant 4
            end

            if (step == 5'd1) inord_flag <= ~cmp_le;
            if (step == 5'd2) late_flag  <= cmp_ge;
            if (step == 5'd3) r_flag     <= (ckcnt == 2'd2) && cmp_ge;

            if (step == 5'd4) c01 <= cmp_lt;
            if (step == 5'd5) c02 <= cmp_lt;
            if (step == 5'd6) c03 <= cmp_lt;
            if (step == 5'd7) c12 <= cmp_lt;
            if (step == 5'd8) c13 <= cmp_lt;
            if (step == 5'd9) c23 <= cmp_lt;

            if (do_ins) ins_acc <= inc_acc;
            if (do_nle) nle_acc <= inc_acc;
        end
    end

endmodule
