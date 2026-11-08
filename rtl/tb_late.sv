`timescale 1ns/1ps
module tb_late;
    logic clk=0, rst_n=0, sh_en=0, sdi=0, start=0;
    wire sdo, busy, done;
    tide_late dut(.*);
    always #5 clk=~clk;
    integer fd, r, n, errs; reg [17:0] cmd, exp, got;
    task shift_in(input [17:0] w); integer i; begin for(i=17;i>=0;i=i-1) begin sdi=w[i]; sh_en=1; @(posedge clk); #1; end sh_en=0; end endtask
    task shift_out(output [17:0] w); integer i; begin for(i=17;i>=0;i=i-1) begin w[i]=sdo; sh_en=1; @(posedge clk); #1; end sh_en=0; end endtask
    initial begin
        errs=0; n=0; repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        fd=$fopen("vec2.txt","r");
        while(!$feof(fd)) begin
            r=$fscanf(fd,"%h %h\n",cmd,exp);
            if(r==2) begin
                shift_in(cmd);
                start=1; @(posedge clk); #1; start=0;
                while(!done) @(posedge clk);
                #1;
                shift_out(got);
                n=n+1;
                if(got!==exp) begin
                    errs=errs+1;
                    if(errs<=12) $display("FAIL cmd=%h exp=%h got=%h",cmd,exp,got);
                end
            end
        end
        $display("DONE commands=%0d errors=%0d",n,errs);
        $finish;
    end
endmodule
