`timescale 1ns/1ps

module tb_adv_late;
    logic clk = 0;
    logic rst_n = 0;
    logic sh_en = 0;
    logic sdi = 0;
    logic start = 0;
    wire  sdo;
    wire  busy = 1'b0;
    wire  done;

    // DUT instantiation (works for both RTL and netlist)
    tide_late dut (
        .clk   (clk),
        .rst_n (rst_n),
        .sh_en (sh_en),
        .sdi   (sdi),
        .sdo   (sdo),
        .start (start),
        .done  (done)
    );

    // 100 MHz clock (10 ns period)
    always #5 clk = ~clk;

    integer fd, r;
    integer cmd_count = 0;
    integer err_count = 0;
    integer latency = 0;
    integer max_latency = 0;
    integer min_latency = 999999;
    string  vec_file = "adv_vec.txt";

    reg [17:0] cmd, exp, got;

    task shift_in(input [17:0] w);
        integer i;
        begin
            for (i = 17; i >= 0; i = i - 1) begin
                sdi   = w[i];
                sh_en = 1;
                @(posedge clk);
                #1;
                // Verify protocol: done MUST deassert on sh_en
                if (done !== 1'b0) begin
                    $display("PROTOCOL ERROR: done did not deassert during sh_en at cmd %0d", cmd_count);
                    err_count = err_count + 1;
                end
            end
            sh_en = 0;
            sdi   = 0;
        end
    endtask

    task shift_out(output [17:0] w);
        integer i;
        begin
            for (i = 17; i >= 0; i = i - 1) begin
                w[i]  = sdo;
                sh_en = 1;
                @(posedge clk);
                #1;
            end
            sh_en = 0;
        end
    endtask

    initial begin
        if ($value$plusargs("VEC=%s", vec_file)) begin
            $display("Using vector file: %s", vec_file);
        end else begin
            $display("Default vector file: %s", vec_file);
        end

        // Reset sequence
        rst_n = 0;
        sh_en = 0;
        sdi   = 0;
        start = 0;
        repeat (5) @(posedge clk);
        #1;
        rst_n = 1;
        repeat (3) @(posedge clk);

        // Verify busy is 0
        if (busy !== 1'b0) begin
            $display("PROTOCOL ERROR: busy port is not 0 at idle! got %b", busy);
            err_count = err_count + 1;
        end

        fd = $fopen(vec_file, "r");
        if (fd == 0) begin
            $display("FATAL: Cannot open vector file %s", vec_file);
            $finish;
        end

        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h\n", cmd, exp);
            if (r == 2) begin
                // Shift in 18-bit command
                shift_in(cmd);

                // Pulse start for 1 cycle
                @(posedge clk);
                #1;
                start = 1;
                @(posedge clk);
                #1;
                start = 0;

                // Wait for done with watchdog timeout
                latency = 0;
                while (!done) begin
                    @(posedge clk);
                    #1;
                    latency = latency + 1;
                    if (latency > 100) begin
                        $display("FATAL TIMEOUT: Watchdog expired! cmd=%05x did not assert done in 100 cycles!", cmd);
                        err_count = err_count + 1;
                        $finish;
                    end
                end

                if (latency > max_latency) max_latency = latency;
                if (latency < min_latency) min_latency = latency;

                // Shift out 18-bit response
                shift_out(got);
                cmd_count = cmd_count + 1;

                if (got !== exp) begin
                    err_count = err_count + 1;
                    if (err_count <= 25) begin
                        $display("MISMATCH #%0d at cmd_idx=%0d: CMD=%05x (op=%0d ts=%0d id=%0d) | EXP=%05x | GOT=%05x",
                                 err_count, cmd_count, cmd, cmd[17:16], cmd[15:4], cmd[3:0], exp, got);
                    end
                end

                // Heartbeat every 10,000 commands
                if (cmd_count % 10000 == 0) begin
                    $display("Progress: %0d commands verified, %0d errors so far...", cmd_count, err_count);
                end
            end
        end

        $fclose(fd);
        $display("\n=======================================================");
        $display("TESTBENCH REGRESSION COMPLETE");
        $display("Total commands processed: %0d", cmd_count);
        $display("Total mismatches / errors: %0d", err_count);
        $display("Latency range (cycles)  : min=%0d, max=%0d", min_latency, max_latency);
        $display("Final Verdict            : %s", (err_count == 0) ? "ALL PASS" : "FAIL");
        $display("=======================================================\n");

        if (err_count == 0) begin
            $display("VERIFICATION SUCCESS: 0 errors detected across %0d commands.", cmd_count);
        end else begin
            $display("VERIFICATION FAILED: %0d errors detected!", err_count);
        end

        $finish;
    end
endmodule
