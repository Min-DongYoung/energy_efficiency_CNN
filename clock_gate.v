/*------------------------------------------------------------------------
 *
 *  File name  : clock_gate.v
 *  Written by : Optimized Design
 *  Design     : Latch-based Clock Gating Cell
 *
 *------------------------------------------------------------------------*/

module clock_gate (
    input clk,
    input enable,
    output gclk
);

    reg en_latch;
    
    // Latch enable signal when clock is low
    always @(clk or enable) begin
        if (~clk) 
            en_latch <= enable;
    end
    
    // Gate clock with latched enable
    assign gclk = clk & en_latch;

endmodule