module line_buffer (
    input clk,
    input rst_n,
    
    // Input interface
    input [7:0] data_in,
    input valid_in,
    output reg ready_line,
    
    // Output interface to window buffer
    output reg [5*8-1:0] col_data,  // 5x1 column data (flattened)
    output reg valid_line_win,
    input ready_win
);

// Parameters
localparam WIDTH = 28;
localparam HEIGHT = 28;
localparam KERNEL_SIZE = 5;

// Line buffer storage
reg [7:0] buffer [0:KERNEL_SIZE-1][0:WIDTH-1];

// Pointers
reg [4:0] p_write;  // Write pointer (0-27)
reg [4:0] p_read;   // Read pointer (0-27)

// Next pointers for calculating ready/valid
reg [4:0] p_write_next;
reg [4:0] p_read_next;

// Position tracking
reg [4:0] x_pos;    // Current x position in input image
reg [4:0] y_pos;    // Current y position in input image

// Control signals
reg first_fill;     // Indicates buffer has been filled initially
reg [6:0] fill_counter;  // Counts pixels until first_fill (28*4 = 112)

// Handshake signals (combinational for same-cycle response)
wire hs_in_line = valid_in & ready_line;
wire hs_line_win = valid_line_win & ready_win;

// Calculate which line to write to (circular buffer)
wire [2:0] write_line = y_pos % KERNEL_SIZE;

// Calculate next pointer values
always @(*) begin
    // Default: no change
    p_write_next = p_write;
    p_read_next = p_read;
    
    // Update based on handshakes
    if (hs_in_line) begin
        p_write_next = (p_write + 1) % WIDTH;
    end
    
    if (hs_line_win) begin
        p_read_next = (p_read + 1) % WIDTH;
    end
end

// Ready logic - sequential update based on next state
always @(posedge clk) begin
    if (!rst_n) begin
        ready_line <= 1'b1;
    end else if (!first_fill) begin
        // During initial fill, always ready to accept data
        ready_line <= 1'b1;
    end else begin
        // After first fill, prevent overflow
        ready_line <= ((p_write_next + 1) % WIDTH) != p_read_next;
    end
end

// Valid logic - sequential update based on next state
always @(posedge clk) begin
    if (!rst_n) begin
        valid_line_win <= 1'b0;
    end else begin
        // Valid when buffer filled and pointers will differ
        valid_line_win <= first_fill & (p_write_next != p_read_next);
    end
end

// Main control logic
always @(posedge clk) begin
    if (!rst_n) begin
        p_write <= 0;
        p_read <= 0;
        x_pos <= 0;
        y_pos <= 0;
        first_fill <= 0;
        fill_counter <= 0;
    end else begin
        // Update pointers
        p_write <= p_write_next;
        p_read <= p_read_next;
        
        // Handle input data
        if (hs_in_line) begin
            // Write data to buffer
            buffer[write_line][p_write] <= data_in;
            
            // Update position tracking
            if (x_pos == WIDTH-1) begin
                x_pos <= 0;
                y_pos <= (y_pos == HEIGHT-1) ? 0 : y_pos + 1;
            end else begin
                x_pos <= x_pos + 1;
            end
            
            // Track first fill
            if (!first_fill) begin
                if (fill_counter == 111) begin  // 28*4 - 1
                    first_fill <= 1;
                    fill_counter <= 0;
                end else begin
                    fill_counter <= fill_counter + 1;
                end
            end
        end
    end
end

// Output column data - registered for timing
integer i;
always @(posedge clk) begin
    if (!rst_n) begin
        col_data <= {KERNEL_SIZE{8'h0}};
    end else if (valid_line_win & ready_win) begin  // Pre-calculate for next cycle
        // Output 5x1 column at current p_read position
        for (i = 0; i < KERNEL_SIZE; i = i + 1) begin
            col_data[i*8 +: 8] <= buffer[i][p_read];
        end
    end
end

endmodule