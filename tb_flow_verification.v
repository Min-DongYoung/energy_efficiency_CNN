/*------------------------------------------------------------------------
 *  File name  : flow_verification.v
 *  Design     : Detailed flow verification testbench
 *------------------------------------------------------------------------*/

module flow_verification();

    reg clk, rst_n;
    reg [7:0] test_data;
    reg valid_in;
    
    // Simple 4x4 test pattern for debugging
    reg [7:0] small_test [0:15];
    
    wire [3:0] decision;
    wire valid_out;
    wire busy;
    
    integer i, cycle_count;
    
    // DUT
    cnn_top_opt dut (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(test_data),
        .valid_in(valid_in),
        .decision(decision),
        .valid_out(valid_out),
        .busy(busy)
    );
    
    // Clock
    always #5 clk = ~clk;
    
    // Monitor all intermediate signals
    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            
            // Conv1 monitoring
            if (dut.conv1_valid) begin
                $display("[%0t] Conv1 output: ch1=%h, ch2=%h, ch3=%h", 
                    $time, dut.conv1_out_1, dut.conv1_out_2, dut.conv1_out_3);
            end
            
            // MaxPool1 monitoring
            if (dut.max1_valid) begin
                $display("[%0t] MaxPool1 output: ch1=%h, ch2=%h, ch3=%h", 
                    $time, dut.max1_out_1, dut.max1_out_2, dut.max1_out_3);
            end
            
            // Conv2 monitoring
            if (dut.conv2_valid) begin
                $display("[%0t] Conv2 output: ch1=%h, ch2=%h, ch3=%h", 
                    $time, dut.conv2_out_1, dut.conv2_out_2, dut.conv2_out_3);
            end
            
            // FC monitoring
            if (dut.fc_valid) begin
                $display("[%0t] FC output: %h", $time, dut.fc_out);
            end
            
            // Final result
            if (valid_out) begin
                $display("[%0t] Final decision: %d", $time, decision);
                $display("Total cycles: %0d", cycle_count);
            end
        end
    end
    
    // Test sequence
    initial begin
        // Initialize
        clk = 0;
        rst_n = 1;
        valid_in = 0;
        test_data = 0;
        cycle_count = 0;
        
        // Create gradient test pattern
        for (i = 0; i < 784; i = i + 1) begin
            small_test[i] = i % 256;
        end
        
        // Reset
        #10 rst_n = 0;
        #10 rst_n = 1;
        #20;
        
        // Send test data
        $display("Starting CNN flow test...");
        @(posedge clk);
        valid_in = 1;
        
        // Send 784 pixels
        for (i = 0; i < 784; i = i + 1) begin
            @(posedge clk);
            test_data = small_test[i % 16];  // Repeat pattern
        end
        
        @(posedge clk);
        valid_in = 0;
        test_data = 8'hXX;
        
        // Wait for completion
        wait(valid_out);
        #100;
        
        $display("\n=== Flow Verification Complete ===");
        $finish;
    end
    
    // Timeout
    initial begin
        #1000000;
        $display("ERROR: Timeout!");
        $finish;
    end

endmodule