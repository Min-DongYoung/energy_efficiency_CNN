`timescale 1ns/1ps

module line_buffer_tb;

// Clock and reset
reg clk;
reg rst_n;

// Input interface
reg [7:0] data_in;
reg valid_in;
wire ready_line;

// Output interface
wire [8*5-1:0] col_data;
wire valid_line_win;
reg ready_win;

// Test variables
integer i, j;
reg [7:0] test_count;

// Instantiate DUT
line_buffer dut (
    .clk(clk),
    .rst_n(rst_n),
    .data_in(data_in),
    .valid_in(valid_in),
    .ready_line(ready_line),
    .col_data(col_data),
    .valid_line_win(valid_line_win),
    .ready_win(ready_win)
);

// Clock generation
initial begin
    clk = 0;
    forever #5 clk = ~clk;
end

// Test stimulus
initial begin
    // Initialize
    rst_n = 0;
    data_in = 0;
    valid_in = 0;
    ready_win = 0;
    test_count = 0;
    
    // Reset
    #20 rst_n = 1;
    #10;
    
    // Test 1: Fill first 4 lines (112 pixels)
    $display("\n=== Test 1: Initial Fill (112 pixels) ===");
    for (i = 0; i < 112; i = i + 1) begin
        @(posedge clk);
        data_in = i;
        valid_in = 1;
        if (!ready_line) begin
            $display("ERROR: ready_line should be 1 during initial fill");
        end
    end
    @(posedge clk);
    valid_in = 0;
    
    // Check first_fill
    #10;
    if (!valid_line_win) begin
        $display("ERROR: valid_line_win should be 1 after first_fill");
    end
    $display("First fill complete, valid_line_win = %d", valid_line_win);
    
    // Test 2: Read some columns
    $display("\n=== Test 2: Read 5 columns ===");
    for (i = 0; i < 5; i = i + 1) begin
        @(posedge clk);
        ready_win = 1;
        #1;
        if (valid_line_win && ready_win) begin
            $display("Read col[%d]: %d %d %d %d %d", i,
                col_data[0], col_data[1], col_data[2], col_data[3], col_data[4]);
        end
    end
    @(posedge clk);
    ready_win = 0;
    
    // Test 3: Write more data while reading
    $display("\n=== Test 3: Simultaneous read/write ===");
    for (i = 0; i < 10; i = i + 1) begin
        @(posedge clk);
        data_in = 112 + i;
        valid_in = 1;
        ready_win = (i % 2 == 0);  // Read every other cycle
        #1;
        if (valid_line_win && ready_win) begin
            $display("Read while writing: %d %d %d %d %d",
                col_data[0], col_data[1], col_data[2], col_data[3], col_data[4]);
        end
    end
    @(posedge clk);
    valid_in = 0;
    ready_win = 0;
    
    // Test 4: Fill buffer to test overflow protection
    $display("\n=== Test 4: Overflow protection test ===");
    // Fill until ready goes low
    i = 0;
    while (ready_line && i < 50) begin
        @(posedge clk);
        data_in = 200 + i;
        valid_in = 1;
        i = i + 1;
    end
    @(posedge clk);
    valid_in = 0;
    
    if (ready_line) begin
        $display("ERROR: ready_line should be 0 when buffer is full");
    end else begin
        $display("PASS: Overflow protection active, ready_line = 0");
    end
    
    // Read to make space
    @(posedge clk);
    ready_win = 1;
    @(posedge clk);
    ready_win = 0;
    #10;
    
    if (!ready_line) begin
        $display("ERROR: ready_line should be 1 after making space");
    end else begin
        $display("PASS: ready_line = 1 after reading");
    end
    
    // End simulation
    #100;
    $display("\n=== Test Complete ===");
    $finish;
end

// Monitor key signals
initial begin
    $monitor("Time=%0t ready_line=%b valid_line_win=%b p_write=%0d p_read=%0d", 
        $time, ready_line, valid_line_win, dut.p_write, dut.p_read);
end

endmodule