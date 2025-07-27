/*------------------------------------------------------------------------
 *
 *  File name  : conv1_layer_opt.v
 *  Design     : Optimized 1st Conv Layer (v3.0)
 *  Author     : Gemini
 *  Description:
 *    - Renamed kernel_buffer to window_buffer for clarity.
 *    - Separated compute (5 cycles) and output/shift (1 cycle) stages
 *      for timing optimization. Bias addition is overlapped with shifting.
 *    - Implemented a circular line buffer with a write pointer (line_buf_w_ptr)
 *      to eliminate large, inefficient data shifts.
 *    - Data is transferred from line_buffer to window_buffer as-is, without
 *      reordering, to minimize routing complexity.
 *    - A read pointer (line_buf_r_ptr) is used to calculate the physical
 *      address of the logical top row within the window_buffer, ensuring
 *      correct MAC operation regardless of the circular buffer's state.
 *
 *------------------------------------------------------------------------*/

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
    localparam OUT_WIDTH = WIDTH - KERNEL_SIZE + 1;
    localparam OUT_HEIGHT = HEIGHT - KERNEL_SIZE + 1;

    // Clock gating
    wire gclk;
    wire clk_en;
    assign clk_en = valid_in | busy;

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

    // -- Optimized Buffer & Pointer Structures --

    // Circular Line Buffer (5 lines of 28 pixels)
    reg [7:0] line_buffer [0:KERNEL_SIZE-1][0:WIDTH-1];
    reg [4:0] line_buf_w_col_idx; // Column write index
    // p_line_to_win_col
    reg [2:0] line_buf_w_ptr;     // Row write pointer (for circular behavior)
    // p_line_row_wt
    reg [2:0] line_buf_r_ptr;     // Row read pointer (maps logical top row to physical index)
    // (p_line_row_wt + 1)%5  or 

    // Window Buffer (5x5 sliding window)
    reg [7:0] window_buffer [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];

    // Position & Cycle Tracking
    reg [4:0] x_pos, y_pos;
    reg [2:0] conv_cycle;  // 0: prep, 1-5: mac, 6: output/shift

    // Weight & Bias Storage
    reg signed [7:0] weights_ch0 [0:24];
    reg signed [7:0] weights_ch1 [0:24];
    reg signed [7:0] weights_ch2 [0:24];
    reg signed [7:0] bias [0:2];

    // MAC Accumulators
    reg signed [19:0] acc_ch0, acc_ch1, acc_ch2;

    // Load weights from memory files
    initial begin
        $readmemh("conv1_weight_1.txt", weights_ch0);
        $readmemh("conv1_weight_2.txt", weights_ch1);
        $readmemh("conv1_weight_3.txt", weights_ch2);
        $readmemh("conv1_bias.txt", bias);
    end

    // -- Parallel MAC Units with Smart Indexing --
    wire signed [15:0] mac_out_ch0 [0:4];
    wire signed [15:0] mac_out_ch1 [0:4];
    wire signed [15:0] mac_out_ch2 [0:4];

    genvar i;
    generate
        for (i = 0; i < KERNEL_SIZE; i = i + 1) begin : mac_gen
            // Calculate the physical row index in the window_buffer that corresponds to the logical row 'i'
            wire [2:0] physical_row_idx = (line_buf_r_ptr + i) % KERNEL_SIZE;
            
            // Use conv_cycle-1 because MAC cycles are 1-5, corresponding to columns 0-4
            wire [4:0] mac_col_idx = conv_cycle - 1;

            wire signed [8:0] data_ext = {1'b0, window_buffer[physical_row_idx][mac_col_idx]};

            assign mac_out_ch0[i] = data_ext * weights_ch0[mac_col_idx*5 + i];
            assign mac_out_ch1[i] = data_ext * weights_ch1[mac_col_idx*5 + i];
            assign mac_out_ch2[i] = data_ext * weights_ch2[mac_col_idx*5 + i];
        end
    endgenerate

    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            x_pos <= 0;
            y_pos <= 0;
            conv_cycle <= 0;
            valid_out <= 0;
            busy <= 0;
            acc_ch0 <= 0;
            acc_ch1 <= 0;
            acc_ch2 <= 0;
            line_buf_w_col_idx <= 0;
            line_buf_w_ptr <= 0;
            line_buf_r_ptr <= 0;
        end else begin
            valid_out <= 0; // Default to not valid

            // -- Concurrent Circular Line Buffer Filling --
            if (valid_in && (state == FILL || state == COMPUTE)) begin
                line_buffer[line_buf_w_ptr][line_buf_w_col_idx] <= data_in;
                if (line_buf_w_col_idx == WIDTH - 1) begin
                    line_buf_w_col_idx <= 0;
                    line_buf_w_ptr <= (line_buf_w_ptr == KERNEL_SIZE - 1) ? 0 : line_buf_w_ptr + 1;
                end else begin
                    line_buf_w_col_idx <= line_buf_w_col_idx + 1;
                end
            end

            // -- Main FSM --
            case (state)
                IDLE: begin
                    if (valid_in) begin
                        state <= FILL;
                        busy <= 1;
                        // Reset all pointers and positions for a new image
                        line_buf_w_col_idx <= 1;
                        line_buf_w_ptr <= 0;
                        line_buf_r_ptr <= 0;
                        x_pos <= 0;
                        y_pos <= 0;
                        conv_cycle <= 0;
                        line_buffer[0][0] <= data_in; // Store first pixel
                    end
                end

                FILL: begin
                    // Wait until the first KERNEL_SIZE-1 lines are filled.
                    // The KERNEL_SIZE-th line is being filled concurrently.
                    if (line_buf_w_ptr == KERNEL_SIZE - 1 && line_buf_w_col_idx == 0) begin
                        state <= COMPUTE;
                        // Start computation, conv_cycle 0 will load the initial window
                    end
                end

                COMPUTE: begin
                    case (conv_cycle)
                        0: begin // Cycle 0: Prepare for computation
                            // Load/Shift window_buffer based on position
                            if (x_pos == 0) begin // New row: Full load from line_buffer
                                for (integer r = 0; r < KERNEL_SIZE; r = r + 1) begin
                                    for (integer c = 0; c < KERNEL_SIZE; c = c + 1) begin
                                        window_buffer[r][c] <= line_buffer[r][c];
                                    end
                                end
                            end
                            // For x_pos > 0, the window is already shifted and loaded in cycle 6.
                            
                            // Reset accumulators for the new output pixel
                            acc_ch0 <= 0;
                            acc_ch1 <= 0;
                            acc_ch2 <= 0;
                            conv_cycle <= 1;
                        end

                        1, 2, 3, 4, 5: begin // Cycles 1-5: MAC accumulation
                            acc_ch0 <= acc_ch0 + mac_out_ch0[0] + mac_out_ch0[1] + mac_out_ch0[2] + mac_out_ch0[3] + mac_out_ch0[4];
                            acc_ch1 <= acc_ch1 + mac_out_ch1[0] + mac_out_ch1[1] + mac_out_ch1[2] + mac_out_ch1[3] + mac_out_ch1[4];
                            acc_ch2 <= acc_ch2 + mac_out_ch2[0] + mac_out_ch2[1] + mac_out_ch2[2] + mac_out_ch2[3] + mac_out_ch2[4];
                            conv_cycle <= conv_cycle + 1;
                        end

                        6: begin // Cycle 6: Output results and shift for next position
                            // -- 1. Output Calculation (Overlapped with Shift) --
                            conv_out_1 <= acc_ch0[19:8] + {{4{bias[0][7]}}, bias[0]};
                            conv_out_2 <= acc_ch1[19:8] + {{4{bias[1][7]}}, bias[1]};
                            conv_out_3 <= acc_ch2[19:8] + {{4{bias[2][7]}}, bias[2]};
                            valid_out <= 1;

                            // -- 2. Position and Pointer Update --
                            if (x_pos == OUT_WIDTH - 1) begin // End of a row
                                x_pos <= 0;
                                y_pos <= y_pos + 1;
                                // A new row of the image has been processed, so update the read pointer
                                line_buf_r_ptr <= (line_buf_r_ptr == KERNEL_SIZE - 1) ? 0 : line_buf_r_ptr + 1;

                                if (y_pos == OUT_HEIGHT - 1) begin // End of image
                                    state <= IDLE;
                                    busy <= 0;
                                end
                            end else begin // Middle of a row
                                x_pos <= x_pos + 1;
                            end

                            // -- 3. Window Buffer Shift (Overlapped with Output) --
                            // This shift prepares the window for the *next* position (x_pos+1)
                            // This is a horizontal shift. Vertical shift is implicit by loading on x_pos=0.
                            for (integer r = 0; r < KERNEL_SIZE; r = r + 1) begin
                                // Shift existing data left
                                for (integer c = 0; c < KERNEL_SIZE - 1; c = c + 1) begin
                                    window_buffer[r][c] <= window_buffer[r][c+1];
                                end
                                // Load only the new column from line_buffer
                                window_buffer[r][KERNEL_SIZE-1] <= line_buffer[r][x_pos + KERNEL_SIZE];
                            end
                            
                            conv_cycle <= 0; // Go to preparation cycle
                        end
                    endcase
                end
            endcase
        end
    end

endmodule