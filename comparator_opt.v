/*------------------------------------------------------------------------
 *
 *  File name  : comparator_opt.v
 *  Design     : Streaming Comparator with Clock Gating
 *
 *------------------------------------------------------------------------*/

module comparator_opt (
    input clk,
    input rst_n,
    input valid_in,
    input signed [11:0] data_in,
    output reg [3:0] decision,
    output reg valid_out
);

    // Clock gating
    wire gclk;
    wire clk_en;
    assign clk_en = valid_in | (cnt != 0);
    
    clock_gate cg (
        .clk(clk),
        .enable(clk_en),
        .gclk(gclk)
    );
    
    // Running maximum and its index
    reg signed [11:0] max_value;
    reg [3:0] max_idx;
    reg [3:0] cnt;  // Counter for inputs (0-9)
    
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            max_value <= -12'h800;  // Most negative value
            max_idx <= 0;
            cnt <= 0;
            decision <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= 0;
            
            if (valid_in) begin
                // Compare with current maximum
                if (cnt == 0 || data_in > max_value) begin
                    max_value <= data_in;
                    max_idx <= cnt;
                end
                
                cnt <= cnt + 1;
                
                // Check if all 10 inputs processed
                if (cnt == 9) begin
                    decision <= max_idx;
                    valid_out <= 1;
                    cnt <= 0;
                    max_value <= -12'h800;
                    max_idx <= 0;
                end
            end
        end
    end

endmodule