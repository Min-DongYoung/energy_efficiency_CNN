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
    input signed [11:0] data_in [0:9],  // 10 parallel inputs
    output reg [3:0] decision,
    output reg valid_out
);

    // Clock gating
    wire gclk;
    wire clk_en;
    assign clk_en = valid_in;
    
    clock_gate cg (
        .clk(clk),
        .enable(clk_en),
        .gclk(gclk)
    );
    
    // Combinational logic to find maximum
    wire signed [11:0] max_01, max_23, max_45, max_67, max_89;
    wire [3:0] idx_01, idx_23, idx_45, idx_67, idx_89;
    wire signed [11:0] max_0123, max_4567;
    wire [3:0] idx_0123, idx_4567;
    wire signed [11:0] max_01234567;
    wire [3:0] idx_01234567;
    wire signed [11:0] final_max;
    wire [3:0] final_idx;
    
    // Level 1: Compare pairs
    assign max_01 = (data_in[0] > data_in[1]) ? data_in[0] : data_in[1];
    assign idx_01 = (data_in[0] > data_in[1]) ? 4'd0 : 4'd1;
    
    assign max_23 = (data_in[2] > data_in[3]) ? data_in[2] : data_in[3];
    assign idx_23 = (data_in[2] > data_in[3]) ? 4'd2 : 4'd3;
    
    assign max_45 = (data_in[4] > data_in[5]) ? data_in[4] : data_in[5];
    assign idx_45 = (data_in[4] > data_in[5]) ? 4'd4 : 4'd5;
    
    assign max_67 = (data_in[6] > data_in[7]) ? data_in[6] : data_in[7];
    assign idx_67 = (data_in[6] > data_in[7]) ? 4'd6 : 4'd7;
    
    assign max_89 = (data_in[8] > data_in[9]) ? data_in[8] : data_in[9];
    assign idx_89 = (data_in[8] > data_in[9]) ? 4'd8 : 4'd9;
    
    // Level 2: Compare level 1 results
    assign max_0123 = (max_01 > max_23) ? max_01 : max_23;
    assign idx_0123 = (max_01 > max_23) ? idx_01 : idx_23;
    
    assign max_4567 = (max_45 > max_67) ? max_45 : max_67;
    assign idx_4567 = (max_45 > max_67) ? idx_45 : idx_67;
    
    // Level 3: Compare groups of 4
    assign max_01234567 = (max_0123 > max_4567) ? max_0123 : max_4567;
    assign idx_01234567 = (max_0123 > max_4567) ? idx_0123 : idx_4567;
    
    // Level 4: Final comparison with last pair
    assign final_max = (max_01234567 > max_89) ? max_01234567 : max_89;
    assign final_idx = (max_01234567 > max_89) ? idx_01234567 : idx_89;
    
    // Register output
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            decision <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= 0;
            
            if (valid_in) begin
                decision <= final_idx;
                valid_out <= 1;
            end
        end
    end

endmodule