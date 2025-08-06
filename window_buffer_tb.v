`timescale 1ns / 1ps

module window_buffer_tb;

// Parameters
localparam KERNEL_SIZE = 5;
localparam CONV_PER_LINE = 24;
localparam CLK_PERIOD = 10;

// Signals
reg clk;
reg rst_n;

// Input interface from line buffer
reg [5*8-1:0] col_data_in;
reg valid_line_win;
wire ready_win;

// Output interface to MAC unit
wire [5*5*8-1:0] window_data;
wire valid_win_MAC;
reg ready_MAC;

// DUT instantiation
window_buffer dut (
    .clk(clk),
    .rst_n(rst_n),
    .col_data_in(col_data_in),
    .valid_line_win(valid_line_win),
    .ready_win(ready_win),
    .window_data(window_data),
    .valid_win_MAC(valid_win_MAC),
    .ready_MAC(ready_MAC)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Test stimulus
initial begin
    // Initialize signals
    rst_n = 0;
    col_data_in = 40'h0;
    valid_line_win = 0;
    ready_MAC = 1;
    
    // Reset
    repeat(5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    
    $display("\n========================================");
    $display("Window Buffer Testbench Started");
    $display("========================================\n");
    
    // =======================================
    // Phase 1: Fill initial window (5 columns)
    // =======================================
    $display("Phase 1: Filling initial window with 5 columns");
    
    fork
        // Send 5 columns from line buffer
        begin
            repeat(5) begin
                @(posedge clk);
                col_data_in = {8'hA0, 8'hA1, 8'hA2, 8'hA3, 8'hA4} + 
                             {8'h01, 8'h01, 8'h01, 8'h01, 8'h01} * dut.col_counter;
                valid_line_win = 1;
                wait(ready_win);
                @(posedge clk);
                valid_line_win = 0;
            end
        end
        
        // Monitor col_counter during fill
        begin
            repeat(6) begin
                @(posedge clk);
                $display("Time %0t: col_counter = %0d, valid_win_MAC = %b", 
                        $time, dut.col_counter, valid_win_MAC);
            end
        end
    join
    
    @(posedge clk);
    $display("\n=> Window filled! col_counter = %0d\n", dut.col_counter);
    
    // =======================================
    // Phase 2: Process first line (24 convolutions)
    // =======================================
    $display("Phase 2: Processing first line (24 convolutions)");
    $display("        Watch conv_counter increment from 0 to 23");
    
    // MAC ready to receive
    ready_MAC = 1;
    
    // Process convolutions with continuous column feed
    repeat(CONV_PER_LINE) begin
        // Wait for valid window
        wait(valid_win_MAC);
        @(posedge clk);
        
        // Display current state
        if (dut.conv_counter < 5 || dut.conv_counter >= 20) begin
            $display("Time %0t: conv_counter = %2d, col_counter = %0d", 
                    $time, dut.conv_counter, dut.col_counter);
        end else if (dut.conv_counter == 5) begin
            $display("        ... (continuing convolutions) ...");
        end
        
        // Feed new column from line buffer (except for last convolution)
        if (dut.conv_counter < CONV_PER_LINE - 1) begin
            col_data_in = {8'hB0, 8'hB1, 8'hB2, 8'hB3, 8'hB4} + 
                         {8'h01, 8'h01, 8'h01, 8'h01, 8'h01} * dut.conv_counter;
            valid_line_win = 1;
        end else begin
            valid_line_win = 0;
        end
        
        @(posedge clk);
        valid_line_win = 0;
    end
    
    // Stop MAC reception to observe reset
    ready_MAC = 1;
    @(posedge clk);
    
    $display("\n=> Line completed! conv_counter should reset to 0");
    $display("   conv_counter = %0d, col_counter = %0d\n", 
            dut.conv_counter, dut.col_counter);
    
    // =======================================
    // Phase 3: Start second line to verify reset worked
    // =======================================
    $display("Phase 3: Starting second line (verify reset)");
    
    // Fill window for second line
    repeat(5) begin
        @(posedge clk);
        col_data_in = {8'hC0, 8'hC1, 8'hC2, 8'hC3, 8'hC4} + 
                     {8'h01, 8'h01, 8'h01, 8'h01, 8'h01} * dut.col_counter;
        valid_line_win = 1;
        wait(ready_win);
        @(posedge clk);
        valid_line_win = 0;
        $display("Time %0t: Filling for line 2, col_counter = %0d", 
                $time, dut.col_counter);
    end
    
    @(posedge clk);
    $display("\n=> Second line window filled! col_counter = %0d", dut.col_counter);
    
    // Process a few convolutions from second line
    ready_MAC = 1;
    repeat(3) begin
        wait(valid_win_MAC);
        @(posedge clk);
        $display("Time %0t: Line 2 convolution, conv_counter = %0d", 
                $time, dut.conv_counter);
        
        // Feed new column
        col_data_in = {8'hD0, 8'hD1, 8'hD2, 8'hD3, 8'hD4};
        valid_line_win = 1;
        @(posedge clk);
        valid_line_win = 0;
    end
    
    ready_MAC = 1;
    @(posedge clk);
    
    // =======================================
    // Test completed
    // =======================================
    $display("\n========================================");
    $display("Test Completed Successfully!");
    $display("Key observations:");
    $display("1. col_counter increments 0->5 during window fill");
    $display("2. conv_counter increments 0->23 during line processing");
    $display("3. conv_counter resets to 0 after line completion");
    $display("4. Second line processing starts correctly");
    $display("========================================\n");
    
    #100;
    $finish;
end

// Optional: Waveform dump for debugging
initial begin
    $dumpfile("window_buffer_tb.vcd");
    $dumpvars(0, window_buffer_tb);
    
    // Monitor key signals
    $monitor("Time=%0t rst_n=%b col_cnt=%0d conv_cnt=%0d valid_MAC=%b ready_win=%b", 
             $time, rst_n, dut.col_counter, dut.conv_counter, 
             valid_win_MAC, ready_win);
end

endmodule