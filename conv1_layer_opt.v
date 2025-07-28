module conv1_layer_opt (
    input clk,
    input rst_n,
    input [7:0] data_in,
    input valid_in,
    output reg [11:0] conv_out_1, conv_out_2, conv_out_3,
    output reg valid_out,
    output reg busy
);
    // Parameters
    localparam WIDTH = 28;
    localparam HEIGHT = 28;
    localparam KERNEL_SIZE = 5;
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
    
    // Circular Line Buffer - 5 lines of 28 pixels
    reg [7:0] line_buffer [0:KERNEL_SIZE-1][0:WIDTH-1];
    
    // Window Buffer - 5x5 sliding window
    reg [7:0] window_buffer [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    
    // Position tracking
    reg [4:0] x_pos, y_pos;   // Current position (0-27)
    reg [2:0] conv_cycle;     // 0-4 for MAC cycles
    
    // Pointers
    wire [2:0] p_row_line;              // Line buffer write pointer
    wire [4:0] p_col_line_to_win;       // Column pointer for window buffer update
    
    assign p_row_line = y_pos % KERNEL_SIZE;
    assign p_col_line_to_win = (x_pos + KERNEL_SIZE) % WIDTH;
    
    // Weight storage (3 output channels)
    reg signed [7:0] weights_ch0 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_ch1 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] weights_ch2 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
    reg signed [7:0] bias [0:2];
    
    // Load weights (flatten for initialization)
    reg signed [7:0] weights_ch0_flat [0:24];
    reg signed [7:0] weights_ch1_flat [0:24];
    reg signed [7:0] weights_ch2_flat [0:24];
    
    initial begin
        $readmemh("conv1_weight_1.txt", weights_ch0_flat);
        $readmemh("conv1_weight_2.txt", weights_ch1_flat);
        $readmemh("conv1_weight_3.txt", weights_ch2_flat);
        $readmemh("conv1_bias.txt", bias);
        
        // Convert to 2D arrays
        for (integer i = 0; i < 25; i = i + 1) begin
            weights_ch0[i/5][i%5] <= weights_ch0_flat[i];
            weights_ch1[i/5][i%5] <= weights_ch1_flat[i];
            weights_ch2[i/5][i%5] <= weights_ch2_flat[i];
        end
    end
    
    // MAC accumulators
    reg signed [19:0] acc_ch0, acc_ch1, acc_ch2;
    
    // MUX for logical row selection
    wire [7:0] mac_input [0:KERNEL_SIZE-1];
    genvar k;
    generate
        for (k = 0; k < KERNEL_SIZE; k = k + 1) begin : row_mux
            assign mac_input[k] = window_buffer[(k + p_row_line + 1) % KERNEL_SIZE][conv_cycle];
        end
    endgenerate
    
    // MAC outputs - registered for pipeline
    reg signed [15:0] mac_out_ch0 [0:KERNEL_SIZE-1];
    reg signed [15:0] mac_out_ch1 [0:KERNEL_SIZE-1];
    reg signed [15:0] mac_out_ch2 [0:KERNEL_SIZE-1];
    
    // Compute MACs
    integer i;
    always @(posedge gclk) begin
        for (i = 0; i < KERNEL_SIZE; i = i + 1) begin
            mac_out_ch0[i] <= $signed({1'b0, mac_input[i]}) * weights_ch0[i][conv_cycle];
            mac_out_ch1[i] <= $signed({1'b0, mac_input[i]}) * weights_ch1[i][conv_cycle];
            mac_out_ch2[i] <= $signed({1'b0, mac_input[i]}) * weights_ch2[i][conv_cycle];
        end
    end
    
    // Control signals
    wire mac_enable = (state == COMPUTE) && (x_pos <= 23);
    wire shift_enable = (state == COMPUTE) && (conv_cycle == 4 || x_pos >= 24);
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
            acc_ch0 <= 0;
            acc_ch1 <= 0;
            acc_ch2 <= 0;
        end else begin
            valid_out <= 0;
            ready <= 0;  // Default: not ready to accept data
            
            // Common line buffer write operation (only when ready)
            if (valid_in && ready && x_pos < WIDTH) begin
                line_buffer[p_row_line][x_pos] <= data_in;
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
                        // During MAC operation, only ready after conv_done or at x_pos 24-27
                        ready <= (conv_cycle == 4) || (x_pos >= 24);
                    end else begin
                        ready <= 0;  // Not ready when x_pos >= WIDTH
                    end
                    
                    // MAC operation
                    if (mac_enable) begin
                        if (conv_cycle == 0) begin
                            // First cycle - only accumulate current MACs
                            acc_ch0 <= mac_out_ch0[0] + mac_out_ch0[1] + 
                                      mac_out_ch0[2] + mac_out_ch0[3] + mac_out_ch0[4];
                            acc_ch1 <= mac_out_ch1[0] + mac_out_ch1[1] + 
                                      mac_out_ch1[2] + mac_out_ch1[3] + mac_out_ch1[4];
                            acc_ch2 <= mac_out_ch2[0] + mac_out_ch2[1] + 
                                      mac_out_ch2[2] + mac_out_ch2[3] + mac_out_ch2[4];
                        end else begin
                            // Accumulate with previous results
                            acc_ch0 <= acc_ch0 + mac_out_ch0[0] + mac_out_ch0[1] + 
                                      mac_out_ch0[2] + mac_out_ch0[3] + mac_out_ch0[4];
                            acc_ch1 <= acc_ch1 + mac_out_ch1[0] + mac_out_ch1[1] + 
                                      mac_out_ch1[2] + mac_out_ch1[3] + mac_out_ch1[4];
                            acc_ch2 <= acc_ch2 + mac_out_ch2[0] + mac_out_ch2[1] + 
                                      mac_out_ch2[2] + mac_out_ch2[3] + mac_out_ch2[4];
                        end
                        
                        if (conv_cycle == 4) begin
                            // Output with bias (can be done in parallel with shift)
                            conv_out_1 <= acc_ch0[19:8] + {{4{bias[0][7]}}, bias[0]};
                            conv_out_2 <= acc_ch1[19:8] + {{4{bias[1][7]}}, bias[1]};
                            conv_out_3 <= acc_ch2[19:8] + {{4{bias[2][7]}}, bias[2]};
                            valid_out <= 1;
                            conv_cycle <= 0;
                            // Reset accumulators
                            acc_ch0 <= 0;
                            acc_ch1 <= 0;
                            acc_ch2 <= 0;
                        end else begin
                            conv_cycle <= conv_cycle + 1;
                        end
                    end
                    
                    // Window buffer shift - at cycle 4 or at x_pos 24-27
                    if (shift_enable) begin
                        // Shift columns left
                        for (row = 0; row < KERNEL_SIZE; row = row + 1) begin
                            for (col = 0; col < KERNEL_SIZE - 1; col = col + 1) begin
                                window_buffer[row][col] <= window_buffer[row][col + 1];
                            end
                            // Load new column from line buffer
                            window_buffer[row][KERNEL_SIZE-1] <= 
                                line_buffer[row][p_col_line_to_win];
                        end
                    end
                    
                    // Position update - only when handshake succeeds or at row end
                    if ((valid_in && ready) || x_pos >= WIDTH) begin
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
                            // Reset conv_cycle for positions 24-27
                            if (x_pos == 23) begin
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