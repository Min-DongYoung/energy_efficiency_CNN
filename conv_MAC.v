`timescale 1ns / 1ps

module conv_MAC (
    input clk,
    input rst_n,
    
    // Input interface from window buffer
    input [5*5*8-1:0] window_data,  // 5x5 window data (flattened)
    input valid_win_MAC,
    output reg ready_MAC,
    
    // Output interface
    output reg [19:0] conv_out_1,
    output reg [19:0] conv_out_2,
    output reg [19:0] conv_out_3,
    output reg valid_out,
    input ready_pool
);

// Parameters
localparam KERNEL_SIZE = 5;
localparam CHANNELS_OUT = 3;
localparam CONV_PER_LINE = 24;

// Weight storage
reg signed [7:0] weights_ch0 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
reg signed [7:0] weights_ch1 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
reg signed [7:0] weights_ch2 [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
reg signed [7:0] bias [0:CHANNELS_OUT-1];

// Temporary storage for weight circular shift
reg signed [7:0] weight_temp_ch0 [0:KERNEL_SIZE-1];
reg signed [7:0] weight_temp_ch1 [0:KERNEL_SIZE-1];
reg signed [7:0] weight_temp_ch2 [0:KERNEL_SIZE-1];

// MAC state machine
reg [2:0] mac_state;        // 0-5 states
reg [2:0] mac_state_next;
reg [2:0] mac_state_prev;   // Previous state for valid_out timing

// Convolution counter
reg [4:0] conv_counter;     // 0-23
reg [4:0] conv_counter_next;

// Weight shift control
reg weight_shift_pending;   // Weight shift is pending
reg weight_shifting;        // Weight shift in progress
reg [1:0] shift_stage;      // 0-3 for multi-cycle shift

// Handshake signals (single declaration)
wire hs_win_MAC = valid_win_MAC & ready_MAC;
wire hs_MAC_pool = valid_out & ready_pool;

// MAC computation units - 5 multipliers per channel
reg signed [15:0] mult_result_ch0 [0:KERNEL_SIZE-1];
reg signed [15:0] mult_result_ch1 [0:KERNEL_SIZE-1];
reg signed [15:0] mult_result_ch2 [0:KERNEL_SIZE-1];

// Accumulators - one per channel
reg signed [19:0] accumulator_ch0;
reg signed [19:0] accumulator_ch1;
reg signed [19:0] accumulator_ch2;

// Weight initialization arrays
reg signed [7:0] weights_ch0_flat [0:24];
reg signed [7:0] weights_ch1_flat [0:24];
reg signed [7:0] weights_ch2_flat [0:24];

// Loop variables
integer j, idx;

// Weight and bias initialization
initial begin
    // Load weights and bias from files
    $readmemh("/home/min/vvd/CNN_test/data/conv1_weight_1.txt", weights_ch0_flat);
    $readmemh("/home/min/vvd/CNN_test/data/conv1_weight_2.txt", weights_ch1_flat);
    $readmemh("/home/min/vvd/CNN_test/data/conv1_weight_3.txt", weights_ch2_flat);
    $readmemh("/home/min/vvd/CNN_test/data/conv1_bias.txt", bias);
    
    // Convert 1D to 2D weight arrays
    for (idx = 0; idx < 25; idx = idx + 1) begin
        weights_ch0[idx/5][idx%5] = weights_ch0_flat[idx];
        weights_ch1[idx/5][idx%5] = weights_ch1_flat[idx];
        weights_ch2[idx/5][idx%5] = weights_ch2_flat[idx];
    end
end

// Calculate next state values
always @(*) begin
    // Default values
    mac_state_next = mac_state;
    conv_counter_next = conv_counter;
    
    // Don't change state during weight shift
    if (weight_shifting) begin
        mac_state_next = 3'd5;  // Stay in idle during weight shift
        conv_counter_next = conv_counter;  // Hold counter value
    end else if (mac_state == 3'd5) begin
        // Idle state - wait for new input
        if (hs_win_MAC) begin
            // Start new MAC cycle
            mac_state_next = 3'd0;
            
            // Update convolution counter
            if (conv_counter == CONV_PER_LINE - 1) begin
                conv_counter_next = 0;
                // weight_shift_pending will be set in sequential logic
            end else begin
                conv_counter_next = conv_counter + 1;
            end
        end
        // else stay in state 5 waiting
    end else begin
        // MAC in progress, advance state
        mac_state_next = mac_state + 1;
    end
end

// Ready logic - considering weight shift and output buffer
always @(posedge clk) begin
    if (!rst_n) begin
        ready_MAC <= 1'b1;
    end else if (weight_shifting) begin
        ready_MAC <= 1'b0;  // Not ready during weight shift
    end else begin
        // Ready only in state 5 AND when no valid output or pooling ready
        ready_MAC <= (mac_state_next == 3'd5) && (!valid_out || ready_pool);
    end
end

// Valid output generation - aligned with actual output
always @(posedge clk) begin
    if (!rst_n) begin
        valid_out <= 1'b0;
    end else if (hs_MAC_pool) begin
        valid_out <= 1'b0;  // Clear when output consumed
    end else if (mac_state == 3'd5 && mac_state_prev == 3'd4) begin
        valid_out <= 1'b1;  // Set when MAC computation just completed
    end
    // else hold current value
end

// Main state machine
always @(posedge clk) begin
    if (!rst_n) begin
        mac_state <= 3'd5;  // Start in idle
        mac_state_prev <= 3'd5;
        conv_counter <= 0;
        weight_shift_pending <= 1'b0;
        weight_shifting <= 1'b0;
        shift_stage <= 0;
    end else begin
        // Update state and track previous
        mac_state_prev <= mac_state;
        mac_state <= mac_state_next;
        conv_counter <= conv_counter_next;
        
        // Set weight shift pending when reaching end of line
        if (mac_state == 3'd5 && hs_win_MAC && conv_counter == CONV_PER_LINE - 1) begin
            weight_shift_pending <= 1'b1;
        end
        
        // Handle weight shift
        if (weight_shift_pending && !weight_shifting && mac_state == 3'd5) begin
            // Start weight shift when MAC is idle
            weight_shifting <= 1'b1;
            weight_shift_pending <= 1'b0;
            shift_stage <= 0;
        end else if (weight_shifting) begin
            if (shift_stage == 3) begin
                weight_shifting <= 1'b0;
                shift_stage <= 0;
            end else begin
                shift_stage <= shift_stage + 1;
            end
        end
    end
end

// Optimized weight circular shift logic (could be done in 2 cycles)
always @(posedge clk) begin
    if (weight_shifting) begin
        case (shift_stage)
            2'd0: begin  // Save row 4 to temp
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    weight_temp_ch0[j] <= weights_ch0[4][j];
                    weight_temp_ch1[j] <= weights_ch1[4][j];
                    weight_temp_ch2[j] <= weights_ch2[4][j];
                end
            end
            
            2'd1: begin  // Shift rows 3→4, 2→3
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    weights_ch0[4][j] <= weights_ch0[3][j];
                    weights_ch1[4][j] <= weights_ch1[3][j];
                    weights_ch2[4][j] <= weights_ch2[3][j];
                    
                    weights_ch0[3][j] <= weights_ch0[2][j];
                    weights_ch1[3][j] <= weights_ch1[2][j];
                    weights_ch2[3][j] <= weights_ch2[2][j];
                end
            end
            
            2'd2: begin  // Shift rows 1→2, 0→1
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    weights_ch0[2][j] <= weights_ch0[1][j];
                    weights_ch1[2][j] <= weights_ch1[1][j];
                    weights_ch2[2][j] <= weights_ch2[1][j];
                    
                    weights_ch0[1][j] <= weights_ch0[0][j];
                    weights_ch1[1][j] <= weights_ch1[0][j];
                    weights_ch2[1][j] <= weights_ch2[0][j];
                end
            end
            
            2'd3: begin  // Move temp→0
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    weights_ch0[0][j] <= weight_temp_ch0[j];
                    weights_ch1[0][j] <= weight_temp_ch1[j];
                    weights_ch2[0][j] <= weight_temp_ch2[j];
                end
            end
        endcase
    end
end

// MAC computation pipeline
always @(posedge clk) begin
    if (!rst_n) begin
        conv_out_1 <= 0;
        conv_out_2 <= 0;
        conv_out_3 <= 0;
        accumulator_ch0 <= 0;
        accumulator_ch1 <= 0;
        accumulator_ch2 <= 0;
        // Clear mult_result
        for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
            mult_result_ch0[j] <= 16'd0;
            mult_result_ch1[j] <= 16'd0;
            mult_result_ch2[j] <= 16'd0;
        end
    end else if (!weight_shifting) begin
        case (mac_state)
            3'd0: begin
                // MAC0: Multiply row 0, initialize accumulator with bias
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    mult_result_ch0[j] <= $signed({1'b0, window_data[(0*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch0[0][j];
                    mult_result_ch1[j] <= $signed({1'b0, window_data[(0*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch1[0][j];
                    mult_result_ch2[j] <= $signed({1'b0, window_data[(0*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch2[0][j];
                end
                // Initialize accumulators with bias (sign-extended)
                accumulator_ch0 <= {{12{bias[0][7]}}, bias[0]};
                accumulator_ch1 <= {{12{bias[1][7]}}, bias[1]};
                accumulator_ch2 <= {{12{bias[2][7]}}, bias[2]};
            end
            
            3'd1: begin
                // MAC1: Multiply row 1, accumulate row 0 results
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    mult_result_ch0[j] <= $signed({1'b0, window_data[(1*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch0[1][j];
                    mult_result_ch1[j] <= $signed({1'b0, window_data[(1*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch1[1][j];
                    mult_result_ch2[j] <= $signed({1'b0, window_data[(1*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch2[1][j];
                end
                // Accumulate previous results
                accumulator_ch0 <= accumulator_ch0 + mult_result_ch0[0] + mult_result_ch0[1] + 
                                  mult_result_ch0[2] + mult_result_ch0[3] + mult_result_ch0[4];
                accumulator_ch1 <= accumulator_ch1 + mult_result_ch1[0] + mult_result_ch1[1] + 
                                  mult_result_ch1[2] + mult_result_ch1[3] + mult_result_ch1[4];
                accumulator_ch2 <= accumulator_ch2 + mult_result_ch2[0] + mult_result_ch2[1] + 
                                  mult_result_ch2[2] + mult_result_ch2[3] + mult_result_ch2[4];
            end
            
            3'd2: begin
                // MAC2: Multiply row 2, accumulate row 1 results
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    mult_result_ch0[j] <= $signed({1'b0, window_data[(2*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch0[2][j];
                    mult_result_ch1[j] <= $signed({1'b0, window_data[(2*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch1[2][j];
                    mult_result_ch2[j] <= $signed({1'b0, window_data[(2*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch2[2][j];
                end
                accumulator_ch0 <= accumulator_ch0 + mult_result_ch0[0] + mult_result_ch0[1] + 
                                  mult_result_ch0[2] + mult_result_ch0[3] + mult_result_ch0[4];
                accumulator_ch1 <= accumulator_ch1 + mult_result_ch1[0] + mult_result_ch1[1] + 
                                  mult_result_ch1[2] + mult_result_ch1[3] + mult_result_ch1[4];
                accumulator_ch2 <= accumulator_ch2 + mult_result_ch2[0] + mult_result_ch2[1] + 
                                  mult_result_ch2[2] + mult_result_ch2[3] + mult_result_ch2[4];
            end
            
            3'd3: begin
                // MAC3: Multiply row 3, accumulate row 2 results
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    mult_result_ch0[j] <= $signed({1'b0, window_data[(3*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch0[3][j];
                    mult_result_ch1[j] <= $signed({1'b0, window_data[(3*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch1[3][j];
                    mult_result_ch2[j] <= $signed({1'b0, window_data[(3*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch2[3][j];
                end
                accumulator_ch0 <= accumulator_ch0 + mult_result_ch0[0] + mult_result_ch0[1] + 
                                  mult_result_ch0[2] + mult_result_ch0[3] + mult_result_ch0[4];
                accumulator_ch1 <= accumulator_ch1 + mult_result_ch1[0] + mult_result_ch1[1] + 
                                  mult_result_ch1[2] + mult_result_ch1[3] + mult_result_ch1[4];
                accumulator_ch2 <= accumulator_ch2 + mult_result_ch2[0] + mult_result_ch2[1] + 
                                  mult_result_ch2[2] + mult_result_ch2[3] + mult_result_ch2[4];
            end
            
            3'd4: begin
                // MAC4: Multiply row 4, accumulate row 3 results
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    mult_result_ch0[j] <= $signed({1'b0, window_data[(4*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch0[4][j];
                    mult_result_ch1[j] <= $signed({1'b0, window_data[(4*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch1[4][j];
                    mult_result_ch2[j] <= $signed({1'b0, window_data[(4*KERNEL_SIZE+j)*8 +: 8]}) * weights_ch2[4][j];
                end
                accumulator_ch0 <= accumulator_ch0 + mult_result_ch0[0] + mult_result_ch0[1] + 
                                  mult_result_ch0[2] + mult_result_ch0[3] + mult_result_ch0[4];
                accumulator_ch1 <= accumulator_ch1 + mult_result_ch1[0] + mult_result_ch1[1] + 
                                  mult_result_ch1[2] + mult_result_ch1[3] + mult_result_ch1[4];
                accumulator_ch2 <= accumulator_ch2 + mult_result_ch2[0] + mult_result_ch2[1] + 
                                  mult_result_ch2[2] + mult_result_ch2[3] + mult_result_ch2[4];
            end
            
            3'd5: begin
                // MAC5: Accumulate row 4 results and generate output
                conv_out_1 <= accumulator_ch0 + mult_result_ch0[0] + mult_result_ch0[1] + 
                             mult_result_ch0[2] + mult_result_ch0[3] + mult_result_ch0[4];
                conv_out_2 <= accumulator_ch1 + mult_result_ch1[0] + mult_result_ch1[1] + 
                             mult_result_ch1[2] + mult_result_ch1[3] + mult_result_ch1[4];
                conv_out_3 <= accumulator_ch2 + mult_result_ch2[0] + mult_result_ch2[1] + 
                             mult_result_ch2[2] + mult_result_ch2[3] + mult_result_ch2[4];
                
                accumulator_ch0 <= accumulator_ch0 + mult_result_ch0[0] + mult_result_ch0[1] + 
                                  mult_result_ch0[2] + mult_result_ch0[3] + mult_result_ch0[4];
                accumulator_ch1 <= accumulator_ch1 + mult_result_ch1[0] + mult_result_ch1[1] + 
                                  mult_result_ch1[2] + mult_result_ch1[3] + mult_result_ch1[4];
                accumulator_ch2 <= accumulator_ch2 + mult_result_ch2[0] + mult_result_ch2[1] + 
                                  mult_result_ch2[2] + mult_result_ch2[3] + mult_result_ch2[4];
                
                // Clear mult_result to prevent re-accumulation during wait
                for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                    mult_result_ch0[j] <= 16'd0;
                    mult_result_ch1[j] <= 16'd0;
                    mult_result_ch2[j] <= 16'd0;
                end
            end
        endcase
    end
end

endmodule