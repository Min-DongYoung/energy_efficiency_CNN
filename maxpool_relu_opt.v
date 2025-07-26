/*------------------------------------------------------------------------
 *  File name  : maxpool_relu_opt.v
 *  Design     : Fixed MaxPooling + ReLU with proper 2x2 window handling
 *------------------------------------------------------------------------*/

module maxpool_relu_opt #(
    parameter CONV_BIT = 12,
    parameter INPUT_WIDTH = 24,
    parameter OUTPUT_WIDTH = 12
) (
    input clk,
    input rst_n,
    input valid_in,
    input signed [CONV_BIT-1:0] conv_out_1, conv_out_2, conv_out_3,
    output reg [CONV_BIT-1:0] max_value_1, max_value_2, max_value_3,
    output reg valid_out,
    output reg busy
);

    // Clock gating
    wire gclk;
    wire clk_en;
    assign clk_en = valid_in | busy | (state != IDLE);
    
    clock_gate cg (
        .clk(clk),
        .enable(clk_en),
        .gclk(gclk)
    );
    
    // States
    localparam IDLE = 2'b00;
    localparam COLLECT = 2'b01;
    localparam PROCESS = 2'b10;
    
    reg [1:0] state;
    
    // Line buffer for one row
    reg signed [CONV_BIT-1:0] row_buffer_1 [0:INPUT_WIDTH-1];
    reg signed [CONV_BIT-1:0] row_buffer_2 [0:INPUT_WIDTH-1];
    reg signed [CONV_BIT-1:0] row_buffer_3 [0:INPUT_WIDTH-1];
    
    // Position tracking
    reg [4:0] x_in, y_in;   // Input position (0-23)
    reg [3:0] x_out, y_out; // Output position (0-11)
    reg row_complete;
    
    // 2x2 window values
    wire signed [CONV_BIT-1:0] val_00_1, val_01_1, val_10_1, val_11_1;
    wire signed [CONV_BIT-1:0] val_00_2, val_01_2, val_10_2, val_11_2;
    wire signed [CONV_BIT-1:0] val_00_3, val_01_3, val_10_3, val_11_3;
    
    // Current and buffered values
    assign val_11_1 = conv_out_1;  // Current input
    assign val_11_2 = conv_out_2;
    assign val_11_3 = conv_out_3;
    
    assign val_10_1 = row_buffer_1[x_in-1];  // Left of current
    assign val_10_2 = row_buffer_2[x_in-1];
    assign val_10_3 = row_buffer_3[x_in-1];
    
    assign val_01_1 = row_buffer_1[x_in];    // Above current
    assign val_01_2 = row_buffer_2[x_in];
    assign val_01_3 = row_buffer_3[x_in];
    
    assign val_00_1 = row_buffer_1[x_in-1];  // Diagonal
    assign val_00_2 = row_buffer_2[x_in-1];
    assign val_00_3 = row_buffer_3[x_in-1];
    
    // Max and ReLU logic
    wire signed [CONV_BIT-1:0] max_1, max_2, max_3;
    
    assign max_1 = (val_00_1 > val_01_1) ? 
                   ((val_00_1 > val_10_1) ? 
                    ((val_00_1 > val_11_1) ? val_00_1 : val_11_1) :
                    ((val_10_1 > val_11_1) ? val_10_1 : val_11_1)) :
                   ((val_01_1 > val_10_1) ? 
                    ((val_01_1 > val_11_1) ? val_01_1 : val_11_1) :
                    ((val_10_1 > val_11_1) ? val_10_1 : val_11_1));
    
    assign max_2 = (val_00_2 > val_01_2) ? 
                   ((val_00_2 > val_10_2) ? 
                    ((val_00_2 > val_11_2) ? val_00_2 : val_11_2) :
                    ((val_10_2 > val_11_2) ? val_10_2 : val_11_2)) :
                   ((val_01_2 > val_10_2) ? 
                    ((val_01_2 > val_11_2) ? val_01_2 : val_11_2) :
                    ((val_10_2 > val_11_2) ? val_10_2 : val_11_2));
    
    assign max_3 = (val_00_3 > val_01_3) ? 
                   ((val_00_3 > val_10_3) ? 
                    ((val_00_3 > val_11_3) ? val_00_3 : val_11_3) :
                    ((val_10_3 > val_11_3) ? val_10_3 : val_11_3)) :
                   ((val_01_3 > val_10_3) ? 
                    ((val_01_3 > val_11_3) ? val_01_3 : val_11_3) :
                    ((val_10_3 > val_11_3) ? val_10_3 : val_11_3));
    
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            x_in <= 0;
            y_in <= 0;
            x_out <= 0;
            y_out <= 0;
            valid_out <= 0;
            busy <= 0;
            row_complete <= 0;
        end else begin
            valid_out <= 0;
            
            case (state)
                IDLE: begin
                    if (valid_in) begin
                        state <= COLLECT;
                        busy <= 1;
                        x_in <= 0;
                        y_in <= 0;
                    end
                end
                
                COLLECT: begin
                    if (valid_in) begin
                        // Store current value in row buffer
                        row_buffer_1[x_in] <= conv_out_1;
                        row_buffer_2[x_in] <= conv_out_2;
                        row_buffer_3[x_in] <= conv_out_3;
                        
                        // Check if we can output (odd x and odd y)
                        if (x_in[0] && y_in[0]) begin
                            max_value_1 <= (max_1 > 0) ? max_1 : 0;
                            max_value_2 <= (max_2 > 0) ? max_2 : 0;
                            max_value_3 <= (max_3 > 0) ? max_3 : 0;
                            valid_out <= 1;
                            
                            x_out <= x_out + 1;
                            if (x_out == OUTPUT_WIDTH - 1) begin
                                x_out <= 0;
                                y_out <= y_out + 1;
                            end
                        end
                        
                        // Update position
                        if (x_in == INPUT_WIDTH - 1) begin
                            x_in <= 0;
                            if (y_in == INPUT_WIDTH - 1) begin
                                // Done
                                state <= IDLE;
                                busy <= 0;
                                y_in <= 0;
                            end else begin
                                y_in <= y_in + 1;
                            end
                        end else begin
                            x_in <= x_in + 1;
                        end
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule