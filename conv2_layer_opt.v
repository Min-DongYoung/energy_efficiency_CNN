module conv2_layer_opt (
    input clk,
    input rst_n,
    input valid_in,
    input [11:0] max_value_1, max_value_2, max_value_3,
    output reg [11:0] conv2_out_1, conv2_out_2, conv2_out_3,
    output reg valid_out,
    output reg busy,
    output reg ready
);

    // Parameters
    localparam WIDTH = 12;
    localparam HEIGHT = 12;
    localparam KERNEL_SIZE = 5;
    localparam CHANNELS_IN = 3;
    localparam CHANNELS_OUT = 3;
    
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
    localparam FILL = 2'b01;
    localparam COMPUTE = 2'b10;
    
    reg [1:0] state;
    
    // Circular Line Buffers - 5 lines of 12 pixels for each input channel
    reg signed [11:0] line_buffer_ch1 [0:KERNEL_SIZE-1][0:WIDTH-1];
    reg signed [11:0] line_buffer_ch2 [0:KERNEL_SIZE-1][0:WIDTH-1];
    reg signed [11:0] line_buffer_ch3 [0:KERNEL_SIZE-1][0:WIDTH-1];
    
    // Window Buffers - 5x5 sliding window for each input channel
    reg signed [11:0] window_buffer_ch1 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [11:0] window_buffer_ch2 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [11:0] window_buffer_ch3 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    
    // Position tracking
    reg [3:0] x_pos, y_pos;   // Current position (0-11)
    reg [2:0] conv_cycle;     // 0-4 for MAC cycles
    
    // Pointers
    wire [2:0] p_row_line;              // Line buffer write pointer
    wire [3:0] p_col_line_to_win;       // Column pointer for window buffer update
    
    assign p_row_line = y_pos % KERNEL_SIZE;
    assign p_col_line_to_win = (x_pos + KERNEL_SIZE) % WIDTH;
    
    // Weight storage (3 output x 3 input = 9 sets)
    reg signed [7:0] weights_1_1 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_1_2 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_1_3 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_2_1 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_2_2 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_2_3 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_3_1 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_3_2 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_3_3 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] bias [0:2];
    
    // Load weights (flatten for initialization)
    reg signed [7:0] weights_flat_1_1 [0:24], weights_flat_1_2 [0:24], weights_flat_1_3 [0:24];
    reg signed [7:0] weights_flat_2_1 [0:24], weights_flat_2_2 [0:24], weights_flat_2_3 [0:24];
    reg signed [7:0] weights_flat_3_1 [0:24], weights_flat_3_2 [0:24], weights_flat_3_3 [0:24];
    
    initial begin
        $readmemh("conv2_weight_11.txt", weights_flat_1_1);
        $readmemh("conv2_weight_12.txt", weights_flat_1_2);
        $readmemh("conv2_weight_13.txt", weights_flat_1_3);
        $readmemh("conv2_weight_21.txt", weights_flat_2_1);
        $readmemh("conv2_weight_22.txt", weights_flat_2_2);
        $readmemh("conv2_weight_23.txt", weights_flat_2_3);
        $readmemh("conv2_weight_31.txt", weights_flat_3_1);
        $readmemh("conv2_weight_32.txt", weights_flat_3_2);
        $readmemh("conv2_weight_33.txt", weights_flat_3_3);
        $readmemh("conv2_bias.txt", bias);
        
        // Convert to 2D arrays with blocking assignment
        for (integer i = 0; i < 25; i = i + 1) begin
            weights_1_1[i/5][i%5] = weights_flat_1_1[i];
            weights_1_2[i/5][i%5] = weights_flat_1_2[i];
            weights_1_3[i/5][i%5] = weights_flat_1_3[i];
            weights_2_1[i/5][i%5] = weights_flat_2_1[i];
            weights_2_2[i/5][i%5] = weights_flat_2_2[i];
            weights_2_3[i/5][i%5] = weights_flat_2_3[i];
            weights_3_1[i/5][i%5] = weights_flat_3_1[i];
            weights_3_2[i/5][i%5] = weights_flat_3_2[i];
            weights_3_3[i/5][i%5] = weights_flat_3_3[i];
        end
    end
    
    // MAC accumulators
    reg signed [21:0] acc_1, acc_2, acc_3;
    
    // MUX for logical row selection
    wire signed [11:0] mac_input_ch1 [0:KERNEL_SIZE-1];
    wire signed [11:0] mac_input_ch2 [0:KERNEL_SIZE-1];
    wire signed [11:0] mac_input_ch3 [0:KERNEL_SIZE-1];
    
    genvar k;
    generate
        for (k = 0; k < KERNEL_SIZE; k = k + 1) begin : row_mux
            assign mac_input_ch1[k] = window_buffer_ch1[(k + p_row_line + 1) % KERNEL_SIZE][conv_cycle];
            assign mac_input_ch2[k] = window_buffer_ch2[(k + p_row_line + 1) % KERNEL_SIZE][conv_cycle];
            assign mac_input_ch3[k] = window_buffer_ch3[(k + p_row_line + 1) % KERNEL_SIZE][conv_cycle];
        end
    endgenerate
    
    // MAC outputs - registered for pipeline
    reg signed [19:0] mac_out_1 [0:KERNEL_SIZE-1];
    reg signed [19:0] mac_out_2 [0:KERNEL_SIZE-1];
    reg signed [19:0] mac_out_3 [0:KERNEL_SIZE-1];
    
    // Compute MACs for all output channels
    integer i;
    always @(posedge gclk) begin
        for (i = 0; i < KERNEL_SIZE; i = i + 1) begin
            // Output channel 1
            mac_out_1[i] <= mac_input_ch1[i] * weights_1_1[i][conv_cycle] +
                           mac_input_ch2[i] * weights_1_2[i][conv_cycle] +
                           mac_input_ch3[i] * weights_1_3[i][conv_cycle];
            
            // Output channel 2
            mac_out_2[i] <= mac_input_ch1[i] * weights_2_1[i][conv_cycle] +
                           mac_input_ch2[i] * weights_2_2[i][conv_cycle] +
                           mac_input_ch3[i] * weights_2_3[i][conv_cycle];
            
            // Output channel 3
            mac_out_3[i] <= mac_input_ch1[i] * weights_3_1[i][conv_cycle] +
                           mac_input_ch2[i] * weights_3_2[i][conv_cycle] +
                           mac_input_ch3[i] * weights_3_3[i][conv_cycle];
        end
    end
    
    // Control signals
    wire mac_enable = (state == COMPUTE) && (x_pos <= 7);  // WIDTH - KERNEL_SIZE = 7
    wire shift_enable = (state == COMPUTE) && (conv_cycle == 4 || x_pos >= 8);
    wire conv_done = (conv_cycle == 4) && mac_enable;
    
    integer row, col;
    
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            x_pos <= 0;
            y_pos <= 0;
            conv_cycle <= 0;
            valid_out <= 0;
            busy <= 0;
            ready <= 1;  // Initialize to ready
            acc_1 <= 0;
            acc_2 <= 0;
            acc_3 <= 0;
        end else begin
            valid_out <= 0;
            ready <= 0;  // Default: not ready
            
            // Common line buffer write operation (only when ready)
            if (valid_in && ready && x_pos < WIDTH) begin
                line_buffer_ch1[p_row_line][x_pos] <= max_value_1;
                line_buffer_ch2[p_row_line][x_pos] <= max_value_2;
                line_buffer_ch3[p_row_line][x_pos] <= max_value_3;
            end
            
            case (state)
                IDLE: begin
                    ready <= 1;  // Ready to receive data
                    if (valid_in) begin
                        state <= FILL;
                        busy <= 1;
                        x_pos <= 1;  // Already wrote to position 0
                        y_pos <= 0;
                    end
                end
                
                FILL: begin
                    ready <= 1;  // Always ready during FILL
                    if (valid_in) begin
                        if (x_pos == WIDTH - 1) begin
                            x_pos <= 0;
                            if (y_pos == KERNEL_SIZE - 1) begin
                                // Transition to COMPUTE
                                state <= COMPUTE;
                                y_pos <= KERNEL_SIZE;  // Continue from row 5
                                conv_cycle <= 0;
                            end else begin
                                y_pos <= y_pos + 1;
                            end
                        end else begin
                            x_pos <= x_pos + 1;
                        end
                    end
                end
                
                COMPUTE: begin
                    // Ready signal control based on position and MAC state
                    if (x_pos < WIDTH) begin
                        // During MAC operation, only ready after conv_done or at x_pos 8-11
                        ready <= (conv_cycle == 4) || (x_pos >= 8);
                    end else begin
                        ready <= 0;  // Not ready when x_pos >= WIDTH
                    end
                    
                    // MAC operation
                    if (mac_enable) begin
                        if (conv_cycle == 0) begin
                            // First cycle - only accumulate current MACs
                            acc_1 <= mac_out_1[0] + mac_out_1[1] + mac_out_1[2] + 
                                    mac_out_1[3] + mac_out_1[4];
                            acc_2 <= mac_out_2[0] + mac_out_2[1] + mac_out_2[2] + 
                                    mac_out_2[3] + mac_out_2[4];
                            acc_3 <= mac_out_3[0] + mac_out_3[1] + mac_out_3[2] + 
                                    mac_out_3[3] + mac_out_3[4];
                        end else begin
                            // Accumulate with previous results
                            acc_1 <= acc_1 + mac_out_1[0] + mac_out_1[1] + mac_out_1[2] + 
                                    mac_out_1[3] + mac_out_1[4];
                            acc_2 <= acc_2 + mac_out_2[0] + mac_out_2[1] + mac_out_2[2] + 
                                    mac_out_2[3] + mac_out_2[4];
                            acc_3 <= acc_3 + mac_out_3[0] + mac_out_3[1] + mac_out_3[2] + 
                                    mac_out_3[3] + mac_out_3[4];
                        end
                        
                        if (conv_cycle == 4) begin
                            // Output with bias (can be done in parallel with shift)
                            conv2_out_1 <= acc_1[18:7] + {{4{bias[0][7]}}, bias[0]};
                            conv2_out_2 <= acc_2[18:7] + {{4{bias[1][7]}}, bias[1]};
                            conv2_out_3 <= acc_3[18:7] + {{4{bias[2][7]}}, bias[2]};
                            valid_out <= 1;
                            conv_cycle <= 0;
                            // Reset accumulators
                            acc_1 <= 0;
                            acc_2 <= 0;
                            acc_3 <= 0;
                        end else begin
                            conv_cycle <= conv_cycle + 1;
                        end
                    end
                    
                    // Window buffer shift - at cycle 4 or at x_pos 8-11
                    if (shift_enable) begin
                        // Shift columns left for all input channels
                        for (row = 0; row < KERNEL_SIZE; row = row + 1) begin
                            for (col = 0; col < KERNEL_SIZE - 1; col = col + 1) begin
                                window_buffer_ch1[row][col] <= window_buffer_ch1[row][col + 1];
                                window_buffer_ch2[row][col] <= window_buffer_ch2[row][col + 1];
                                window_buffer_ch3[row][col] <= window_buffer_ch3[row][col + 1];
                            end
                            // Load new column from line buffers
                            window_buffer_ch1[row][KERNEL_SIZE-1] <= 
                                line_buffer_ch1[row][p_col_line_to_win];
                            window_buffer_ch2[row][KERNEL_SIZE-1] <= 
                                line_buffer_ch2[row][p_col_line_to_win];
                            window_buffer_ch3[row][KERNEL_SIZE-1] <= 
                                line_buffer_ch3[row][p_col_line_to_win];
                        end
                    end
                    
                    // Position update - progress when MAC done or handshake succeeds
                    if ((valid_in && ready) || x_pos >= WIDTH || (mac_enable && conv_cycle == 4)) begin
                        if (x_pos == WIDTH - 1) begin
                            x_pos <= 0;
                            if (y_pos == HEIGHT - 1) begin
                                // Frame complete
                                state <= IDLE;
                                busy <= 0;
                                y_pos <= 0;  // Reset for next frame
                            end else begin
                                y_pos <= y_pos + 1;
                                conv_cycle <= 0;
                            end
                        end else begin
                            x_pos <= x_pos + 1;
                            // Reset conv_cycle for positions 8-11
                            if (x_pos == 7) begin
                                conv_cycle <= 0;
                            end
                        end
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule