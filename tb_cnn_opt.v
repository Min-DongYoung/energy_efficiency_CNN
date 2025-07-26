/*------------------------------------------------------------------------
 *
 *  File name  : tb_cnn_opt.v
 *  Design     : Testbench for Optimized CNN Pipeline
 *
 *------------------------------------------------------------------------*/

module tb_cnn_opt();

    // Clock and reset
    reg clk, rst_n;
    
    // Test data
    reg [7:0] pixels [0:783];
    reg [9:0] pixel_idx;
    reg [7:0] data_in;
    reg valid_in;
    
    // Outputs
    wire [3:0] decision;
    wire valid_out;
    wire busy;
    
    // Performance counters
    integer cycle_count;
    integer start_time, end_time;
    
    // DUT instantiation
    cnn_top_opt dut (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .valid_in(valid_in),
        .decision(decision),
        .valid_out(valid_out),
        .busy(busy)
    );
    
    // Clock generation
    always #5 clk = ~clk;
    
    // Read test image
    initial begin
        $readmemh("3_0.txt", pixels);
        clk = 0;
        rst_n = 1;
        valid_in = 0;
        pixel_idx = 0;
        cycle_count = 0;
        
        // Reset
        #10 rst_n = 0;
        #10 rst_n = 1;
        
        // Wait a bit
        #20;
        
        // Start sending image data
        start_time = $time;
        @(posedge clk);
        valid_in = 1;
    end
    
    // Send pixel data
    always @(posedge clk) begin
        if (rst_n) begin
            if (valid_in && pixel_idx < 784) begin
                data_in <= pixels[pixel_idx];
                pixel_idx <= pixel_idx + 1;
            end else if (pixel_idx >= 784) begin
                valid_in <= 0;
                data_in <= 8'hXX;  // Don't care value after completion
            end
        end
    end
    
    // Monitor busy signal and count cycles
    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            
            // Monitor module states
            if (dut.conv1_busy) $display("Time %0t: Conv1 active", $time);
            if (dut.max1_busy) $display("Time %0t: MaxPool1 active", $time);
            if (dut.conv2_busy) $display("Time %0t: Conv2 active", $time);
            if (dut.max2_busy) $display("Time %0t: MaxPool2 active", $time);
            if (dut.fc_busy) $display("Time %0t: FC active", $time);
        end
    end
    
    // Check results
    always @(posedge clk) begin
        if (valid_out) begin
            end_time = $time;
            $display("\n=== RESULTS ===");
            $display("Decision: %d", decision);
            $display("Total cycles: %d", cycle_count);
            $display("Total time: %0t", end_time - start_time);
            $display("===============\n");
            
            // End simulation
            #100 $finish;
        end
    end
    
    // Timeout
    initial begin
        #1000000;
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule