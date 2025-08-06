`timescale 1ns / 1ps
module window_buffer (
    input clk,
    input rst_n,
    // Input interface from line buffer
    input [5*8-1:0] col_data_in,  // 5x1 column data
    input valid_line_win,
    output reg ready_win,
    // Output interface to MAC unit
    output [5*5*8-1:0] window_data,  // 5x5 window data (direct from window)
    output reg valid_win_MAC,
    input ready_MAC
);

// Parameters
localparam KERNEL_SIZE = 5;
localparam CONV_PER_LINE = 24;  // WIDTH - KERNEL_SIZE + 1

// Window buffer storage
reg [7:0] window [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];

// Direct connection to output - flatten 2D array to 1D
genvar gi, gj;
generate
    for (gi = 0; gi < KERNEL_SIZE; gi = gi + 1) begin : gen_row
        for (gj = 0; gj < KERNEL_SIZE; gj = gj + 1) begin : gen_col
            assign window_data[(gi*KERNEL_SIZE+gj)*8 +: 8] = window[gi][gj];
        end
    end
endgenerate

// Control counters
reg [2:0] col_counter;      // Valid column counter (0-5)
reg [4:0] conv_counter;     // Convolutions per line counter (0-23)

// Next state calculations
reg [2:0] col_counter_next;
reg [4:0] conv_counter_next;

// Handshake signals (combinational for same-cycle response)
wire hs_line_win = valid_line_win & ready_win;
wire hs_win_MAC = valid_win_MAC & ready_MAC;

// Calculate next state values - FIXED LOGIC
always @(*) begin
    // Default: no change
    col_counter_next = col_counter;
    conv_counter_next = conv_counter;
    
    // Handle all four cases explicitly to avoid glitches
    case ({hs_win_MAC, hs_line_win})
        2'b00: begin
            // No handshake - maintain current values
            col_counter_next = col_counter;
            conv_counter_next = conv_counter;
        end
        
        2'b01: begin
            // Only line buffer input
            if (col_counter < 5) begin
                col_counter_next = col_counter + 1;
            end
            // conv_counter stays same
        end
        
        2'b10: begin
            // Only MAC output
            if (conv_counter == CONV_PER_LINE - 1) begin
                // End of line - reset counters
                col_counter_next = 0;
                conv_counter_next = 0;
            end else begin
                // Continue on same line
                col_counter_next = col_counter - 1;
                conv_counter_next = conv_counter + 1;
            end
        end
        
        2'b11: begin
            // Simultaneous read and write
            if (conv_counter == CONV_PER_LINE - 1) begin
                // End of line - reset col_counter, allow new column
                col_counter_next = 1;  // One new column coming in
                conv_counter_next = 0;
            end else begin
                // Middle of line - counter stays same (one in, one out)
                col_counter_next = col_counter;
                conv_counter_next = conv_counter + 1;
            end
        end
    endcase
end

// Ready logic - sequential update
always @(posedge clk) begin
    if (!rst_n) begin
        ready_win <= 1'b1;
    end else begin
        // Ready when not full (col_counter < 5) or when MAC is consuming data
        ready_win <= (col_counter_next < 5) | hs_win_MAC;
    end
end

// Valid logic - sequential update
always @(posedge clk) begin
    if (!rst_n) begin
        valid_win_MAC <= 1'b0;
    end else begin
        // Valid when we have full window
        valid_win_MAC <= (col_counter_next == 5);
    end
end

// Main control logic
always @(posedge clk) begin
    if (!rst_n) begin
        col_counter <= 0;
        conv_counter <= 0;
    end else begin
        // Update counters
        col_counter <= col_counter_next;
        conv_counter <= conv_counter_next;
    end
end

// Window shift and update logic
integer row, col;
always @(posedge clk) begin
    if (!rst_n) begin
        // Clear window
        for (row = 0; row < KERNEL_SIZE; row = row + 1) begin
            for (col = 0; col < KERNEL_SIZE; col = col + 1) begin
                window[row][col] <= 8'h0;
            end
        end
    end else if (hs_line_win) begin
        // Left shift window
        for (row = 0; row < KERNEL_SIZE; row = row + 1) begin
            for (col = 0; col < KERNEL_SIZE-1; col = col + 1) begin
                window[row][col] <= window[row][col+1];
            end
            // Insert new column at position 4
            window[row][KERNEL_SIZE-1] <= col_data_in[8*row+:8];
        end
    end
end

endmodule