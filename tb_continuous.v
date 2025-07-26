/*------------------------------------------------------------------------
 *
 *  File name  : tb_continuous.v
 *  Design     : Testbench for continuous multi-image processing
 *
 *------------------------------------------------------------------------*/

module tb_continuous();

    // Clock and reset
    reg clk, rst_n;
    
    // Test data - multiple images
    reg [7:0] pixels [0:783999];  // Space for 1000 images
    reg [9:0] pixel_idx;
    reg [9:0] image_count;
    reg [7:0] data_in;
    reg valid_in;
    
    // Expected results
    reg [3:0] expected_results [0:999];
    
    // Outputs
    wire [3:0] decision;
    wire valid_out;
    wire busy;
    
    // Performance counters
    integer total_cycles;
    integer image_cycles;
    integer correct_count;
    
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
    
    // Initialize
    initial begin
        // Load test data
        $readmemh("input_1000.txt", pixels);
        $readmemh("labels_1000.txt", expected_results);
        
        clk = 0;
        rst_n = 1;
        valid_in = 0;
        pixel_idx = 0;
        image_count = 0;
        total_cycles = 0;
        image_cycles = 0;
        correct_count = 0;
        data_in = 8'h00;
        
        // Reset
        #10 rst_n = 0;
        #10 rst_n = 1;
        #20;
        
        // Start processing
        $display("Starting continuous image processing...");
        @(posedge clk);
        process_next_image();
    end
    
    // Process images task
    task process_next_image;
        begin
            $display("\nProcessing image %0d", image_count);
            pixel_idx = 0;
            image_cycles = 0;
            valid_in = 1;
        end
    endtask
    
    // Send pixel data
    always @(posedge clk) begin
        if (rst_n) begin
            total_cycles <= total_cycles + 1;
            
            if (valid_in) begin
                if (pixel_idx < 784) begin
                    // Send current pixel
                    data_in <= pixels[image_count * 784 + pixel_idx];
                    pixel_idx <= pixel_idx + 1;
                    image_cycles <= image_cycles + 1;
                end else begin
                    // Done with current image
                    valid_in <= 0;
                    data_in <= 8'hXX;
                end
            end else begin
                // Wait for result or start next image
                if (!busy && image_count < 999) begin
                    // Can start next image if pipeline is ready
                    #10;  // Small delay between images
                    image_count <= image_count + 1;
                    process_next_image();
                end
                image_cycles <= image_cycles + 1;
            end
        end
    end
    
    // Check results
    always @(posedge clk) begin
        if (valid_out) begin
            $display("Image %0d result: %d (expected: %d) - %s, cycles: %0d", 
                     image_count, 
                     decision, 
                     expected_results[image_count],
                     (decision == expected_results[image_count]) ? "PASS" : "FAIL",
                     image_cycles);
            
            if (decision == expected_results[image_count]) begin
                correct_count <= correct_count + 1;
            end
            
            // Check if all images processed
            if (image_count == 999) begin
                $display("\n=== FINAL RESULTS ===");
                $display("Total images: 1000");
                $display("Correct: %0d", correct_count);
                $display("Accuracy: %0.1f%%", correct_count / 10.0);
                $display("Total cycles: %0d", total_cycles);
                $display("Average cycles per image: %0d", total_cycles / 1000);
                $display("====================\n");
                #100 $finish;
            end
        end
    end
    
    // Timeout
    initial begin
        #100000000;
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule