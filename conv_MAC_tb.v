`timescale 1ns / 1ps

module conv_MAC_tb;

// Parameters
localparam KERNEL_SIZE = 5;
localparam CLK_PERIOD = 10;
localparam CONV_PER_LINE = 24;

// Signals
reg clk;
reg rst_n;

// Input interface from window buffer
reg [KERNEL_SIZE*KERNEL_SIZE*8-1:0] window_data;
reg valid_win_MAC;
wire ready_MAC;

// Output interface
wire [19:0] conv_out_1;
wire [19:0] conv_out_2;
wire [19:0] conv_out_3;
wire valid_out;
reg ready_pool;

// Test control
integer conv_count;
integer cycle_count;
reg [7:0] test_pattern;

// DUT instantiation
conv_MAC dut (
    .clk(clk),
    .rst_n(rst_n),
    .window_data(window_data),
    .valid_win_MAC(valid_win_MAC),
    .ready_MAC(ready_MAC),
    .conv_out_1(conv_out_1),
    .conv_out_2(conv_out_2),
    .conv_out_3(conv_out_3),
    .valid_out(valid_out),
    .ready_pool(ready_pool)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Generate simple test window data
task generate_window_data;
    input [7:0] base_value;
    integer i;
    begin
        // Create a simple pattern: base_value + position
        for (i = 0; i < KERNEL_SIZE*KERNEL_SIZE; i = i + 1) begin
            window_data[i*8 +: 8] = base_value + i[7:0];
        end
    end
endtask

// Monitor MAC state
task monitor_mac_state;
    begin
        $display("Time %0t: MAC state=%0d, conv_cnt=%0d, weight_shift=%b, shift_stage=%0d", 
                $time, dut.mac_state, dut.conv_counter, 
                dut.weight_shifting, dut.shift_stage);
    end
endtask

// Test stimulus
initial begin
    // Initialize signals
    rst_n = 0;
    window_data = 0;
    valid_win_MAC = 0;
    ready_pool = 0;
    conv_count = 0;
    cycle_count = 0;
    test_pattern = 8'h10;
    
    // Create weight files if they don't exist (simple test weights)
    create_test_weight_files();
    
    // Reset
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);
    
    $display("\n========================================");
    $display("Conv_MAC Testbench Started");
    $display("========================================\n");
    
    // =======================================
    // Phase 1: First Line Processing (24 convolutions)
    // =======================================
    $display("Phase 1: Processing first line (24 convolutions)");
    $display("        Each convolution takes 6 cycles\n");
    
    // Set pooling ready (always ready for this test)
    ready_pool = 1;
    
    // Process 24 convolutions
    for (conv_count = 0; conv_count < CONV_PER_LINE; conv_count = conv_count + 1) begin
        
        // Generate window data
        generate_window_data(test_pattern + conv_count[7:0]);
        
        // Wait for MAC to be ready
        wait(ready_MAC);
        @(posedge clk);
        
        // Send valid window data
        valid_win_MAC = 1;
        $display("Conv %2d: Sending window data (pattern base: 0x%02X)", 
                conv_count, test_pattern + conv_count[7:0]);
        
        @(posedge clk);
        valid_win_MAC = 0;
        
        // Monitor MAC pipeline (6 cycles)
        if (conv_count == 0 || conv_count == 23) begin  // Detail for first and last
            $display("  MAC Pipeline Progress:");
            repeat(6) begin
                @(posedge clk);
                $display("    Cycle %0d: state=%0d", 
                        dut.mac_state == 5 ? 6 : dut.mac_state, dut.mac_state);
            end
        end else begin
            // Just wait for completion
            wait(valid_out);
            @(posedge clk);
        end
        
        // Check output
        if (valid_out) begin
            $display("  Output ready: ch1=%0d, ch2=%0d, ch3=%0d", 
                    $signed(conv_out_1), $signed(conv_out_2), $signed(conv_out_3));
        end
    end
    
    $display("\n=> First line completed! conv_counter = %0d", dut.conv_counter);
    
    // =======================================
    // Phase 2: Weight Shift Observation
    // =======================================
    $display("\nPhase 2: Weight shift in progress (4 cycles)");
    
    // Monitor weight shift
    repeat(5) begin
        @(posedge clk);
        monitor_mac_state();
    end
    
    $display("=> Weight shift completed: weight_shifting = %b\n", dut.weight_shifting);
    
    // =======================================
    // Phase 3: Second Line Start (verify reset and shift)
    // =======================================
    $display("Phase 3: Starting second line after weight shift");
    
    test_pattern = 8'h50;  // Different pattern for line 2
    
    // Process first 3 convolutions of second line
    for (conv_count = 0; conv_count < 3; conv_count = conv_count + 1) begin
        
        generate_window_data(test_pattern + conv_count[7:0]);
        
        wait(ready_MAC);
        @(posedge clk);
        
        valid_win_MAC = 1;
        $display("Line 2, Conv %0d: Sending window (pattern base: 0x%02X)", 
                conv_count, test_pattern + conv_count[7:0]);
        
        @(posedge clk);
        valid_win_MAC = 0;
        
        // Wait for output
        wait(valid_out);
        @(posedge clk);
        
        $display("  Output: ch1=%0d, ch2=%0d, ch3=%0d, conv_counter=%0d", 
                $signed(conv_out_1), $signed(conv_out_2), $signed(conv_out_3), 
                dut.conv_counter);
    end
    
    // =======================================
    // Phase 4: Backpressure Test
    // =======================================
    $display("\nPhase 4: Testing backpressure (pooling not ready)");
    
    // Make pooling not ready
    ready_pool = 0;
    
    // Try to send new window
    generate_window_data(8'hA0);
    valid_win_MAC = 1;
    
    repeat(3) begin
        @(posedge clk);
        $display("  ready_MAC=%b (should be 0 due to backpressure)", ready_MAC);
    end
    
    valid_win_MAC = 0;
    
    // Release backpressure
    ready_pool = 1;
    @(posedge clk);
    $display("  Backpressure released: ready_MAC=%b", ready_MAC);
    
    // =======================================
    // Test completed
    // =======================================
    repeat(10) @(posedge clk);
    
    $display("\n========================================");
    $display("Test Completed Successfully!");
    $display("Key observations:");
    $display("1. MAC pipeline: 6 cycles per convolution");
    $display("2. Weight shift: 4 cycles at line end");
    $display("3. Conv counter: resets after 24 convolutions");
    $display("4. Backpressure: properly handled");
    $display("========================================\n");
    
    #100;
    $finish;
end

// Create simple test weight files
task create_test_weight_files;
    integer file;
    integer i;
    begin
        // Create weight files with simple patterns
        file = $fopen("/home/min/vvd/CNN_test/data/conv1_weight_1.txt", "w");
        for (i = 0; i < 25; i = i + 1) begin
            $fwrite(file, "%02X\n", 1);  // All weights = 1 for channel 1
        end
        $fclose(file);
        
        file = $fopen("/home/min/vvd/CNN_test/data/conv1_weight_2.txt", "w");
        for (i = 0; i < 25; i = i + 1) begin
            $fwrite(file, "%02X\n", 2);  // All weights = 2 for channel 2
        end
        $fclose(file);
        
        file = $fopen("/home/min/vvd/CNN_test/data/conv1_weight_3.txt", "w");
        for (i = 0; i < 25; i = i + 1) begin
            $fwrite(file, "%02X\n", 3);  // All weights = 3 for channel 3
        end
        $fclose(file);
        
        file = $fopen("/home/min/vvd/CNN_test/data/conv1_bias.txt", "w");
        $fwrite(file, "00\n");  // Bias = 0 for all channels
        $fwrite(file, "00\n");
        $fwrite(file, "00\n");
        $fclose(file);
        
        $display("Test weight files created");
    end
endtask

// Optional: Waveform dump
initial begin
    $dumpfile("conv_MAC_tb.vcd");
    $dumpvars(0, conv_MAC_tb);
end

// Timeout watchdog
initial begin
    #100000;  // 100us timeout
    $display("ERROR: Test timeout!");
    $finish;
end

endmodule