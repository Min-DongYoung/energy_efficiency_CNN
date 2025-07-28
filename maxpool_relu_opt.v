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
    output reg busy,
    output reg ready
);

    // Clock gating
    wire gclk;
    wire clk_en;
    assign clk_en = valid_in | busy | valid_out;
    
    clock_gate cg (
        .clk(clk),
        .enable(clk_en),
        .gclk(gclk)
    );
    
    // States
    localparam IDLE = 1'b0;
    localparam PROCESS = 1'b1;
    
    reg state;
    
    // Pool buffers - one row of output width for each channel
    reg signed [CONV_BIT-1:0] pool_buf_1 [0:OUTPUT_WIDTH-1];
    reg signed [CONV_BIT-1:0] pool_buf_2 [0:OUTPUT_WIDTH-1];
    reg signed [CONV_BIT-1:0] pool_buf_3 [0:OUTPUT_WIDTH-1];
    
    // Position tracking
    reg [4:0] x_in;    // Input column (0-23)
    reg [4:0] y_in;    // Input row (0-23)
    
    // Control signals
    wire is_odd_row = y_in[0];
    wire is_odd_col = x_in[0];
    wire output_enable = is_odd_row & is_odd_col;
    wire [3:0] buf_idx = x_in >> 1;  // x_in / 2
    
    // Max comparison results
    wire signed [CONV_BIT-1:0] max_cmp_1, max_cmp_2, max_cmp_3;
    
    // Compare with zero for implicit ReLU
    wire signed [CONV_BIT-1:0] relu_in_1 = (conv_out_1 > 0) ? conv_out_1 : 0;
    wire signed [CONV_BIT-1:0] relu_in_2 = (conv_out_2 > 0) ? conv_out_2 : 0;
    wire signed [CONV_BIT-1:0] relu_in_3 = (conv_out_3 > 0) ? conv_out_3 : 0;
    
    // Max comparison
    assign max_cmp_1 = (relu_in_1 > pool_buf_1[buf_idx]) ? relu_in_1 : pool_buf_1[buf_idx];
    assign max_cmp_2 = (relu_in_2 > pool_buf_2[buf_idx]) ? relu_in_2 : pool_buf_2[buf_idx];
    assign max_cmp_3 = (relu_in_3 > pool_buf_3[buf_idx]) ? relu_in_3 : pool_buf_3[buf_idx];
    
    // Initialize buffers
    integer i;
    
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            x_in <= 0;
            y_in <= 0;
            valid_out <= 0;
            busy <= 0;
            ready <= 1;
            
            // Initialize pool buffers to 0
            for (i = 0; i < OUTPUT_WIDTH; i = i + 1) begin
                pool_buf_1[i] <= 0;
                pool_buf_2[i] <= 0;
                pool_buf_3[i] <= 0;
            end
        end else begin
            valid_out <= 0;
            ready <= 1;  // Always ready to accept input
            
            case (state)
                IDLE: begin
                    if (valid_in) begin
                        state <= PROCESS;
                        busy <= 1;
                        
                        // Process first input
                        pool_buf_1[0] <= relu_in_1;
                        pool_buf_2[0] <= relu_in_2;
                        pool_buf_3[0] <= relu_in_3;
                        
                        x_in <= 1;
                        y_in <= 0;
                    end
                end
                
                PROCESS: begin
                    if (valid_in) begin
                        // Update pool buffers with max value
                        if (output_enable) begin
                            // Output current max and reset buffer
                            max_value_1 <= max_cmp_1;
                            max_value_2 <= max_cmp_2;
                            max_value_3 <= max_cmp_3;
                            valid_out <= 1;
                            
                            // Reset buffer for next window
                            pool_buf_1[buf_idx] <= 0;
                            pool_buf_2[buf_idx] <= 0;
                            pool_buf_3[buf_idx] <= 0;
                        end else begin
                            // Update buffer with max value
                            pool_buf_1[buf_idx] <= max_cmp_1;
                            pool_buf_2[buf_idx] <= max_cmp_2;
                            pool_buf_3[buf_idx] <= max_cmp_3;
                        end
                        
                        // Position update
                        if (x_in == INPUT_WIDTH - 1) begin
                            x_in <= 0;
                            
                            if (y_in == INPUT_WIDTH - 1) begin
                                // Frame complete
                                state <= IDLE;
                                busy <= 0;
                                y_in <= 0;
                                
                                // Reset all buffers
                                for (i = 0; i < OUTPUT_WIDTH; i = i + 1) begin
                                    pool_buf_1[i] <= 0;
                                    pool_buf_2[i] <= 0;
                                    pool_buf_3[i] <= 0;
                                end
                            end else begin
                                y_in <= y_in + 1;
                                
                                // Reset buffers at even rows (start of new output row)
                                if (!y_in[0]) begin  // Current row is odd, next will be even
                                    for (i = 0; i < OUTPUT_WIDTH; i = i + 1) begin
                                        pool_buf_1[i] <= 0;
                                        pool_buf_2[i] <= 0;
                                        pool_buf_3[i] <= 0;
                                    end
                                end
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