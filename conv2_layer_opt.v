/*------------------------------------------------------------------------
 *
 *  File name  : conv2_layer_opt.v
 *  Design     : Optimized 2nd Convolution Layer with 5 MACs
 *
 *------------------------------------------------------------------------*/

module conv2_layer_opt (
    input clk,
    input rst_n,
    input valid_in,
    input [11:0] max_value_1, max_value_2, max_value_3,
    output reg [11:0] conv2_out_1, conv2_out_2, conv2_out_3,
    output reg valid_out,
    output reg busy
);

    // Parameters
    localparam WIDTH = 12;
    localparam HEIGHT = 12;
    localparam FILTER_SIZE = 5;
    localparam CHANNELS_IN = 3;
    localparam CHANNELS_OUT = 3;
    
    // Clock gating
    wire gclk;
    wire clk_en;
    assign clk_en = valid_in | busy | (state != IDLE);
    
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
    
    // Line buffers for 3 input channels
    reg signed [11:0] line_buffer_ch1 [0:WIDTH*FILTER_SIZE-1];
    reg signed [11:0] line_buffer_ch2 [0:WIDTH*FILTER_SIZE-1];
    reg signed [11:0] line_buffer_ch3 [0:WIDTH*FILTER_SIZE-1];
    reg [5:0] buf_write_idx;
    
    // Kernel buffers - 5x5 for each input channel
    reg signed [11:0] kernel_buffer_ch1 [0:24];
    reg signed [11:0] kernel_buffer_ch2 [0:24];
    reg signed [11:0] kernel_buffer_ch3 [0:24];
    integer load_idx;  // For loading kernel buffers
    
    // Position tracking
    reg [3:0] x_pos, y_pos;
    reg [2:0] conv_cycle;  // 0-5 for 6 cycles per convolution
    reg [1:0] out_channel;  // Current output channel
    
    // Weight storage (3x3 = 9 sets of 25 weights each)
    reg signed [7:0] weights_1_1 [0:24], weights_1_2 [0:24], weights_1_3 [0:24];
    reg signed [7:0] weights_2_1 [0:24], weights_2_2 [0:24], weights_2_3 [0:24];
    reg signed [7:0] weights_3_1 [0:24], weights_3_2 [0:24], weights_3_3 [0:24];
    reg signed [7:0] bias [0:2];
    
    // MAC accumulators
    reg signed [21:0] acc_1, acc_2, acc_3;
    
    // Load weights
    initial begin
        $readmemh("conv2_weight_11.txt", weights_1_1);
        $readmemh("conv2_weight_12.txt", weights_1_2);
        $readmemh("conv2_weight_13.txt", weights_1_3);
        $readmemh("conv2_weight_21.txt", weights_2_1);
        $readmemh("conv2_weight_22.txt", weights_2_2);
        $readmemh("conv2_weight_23.txt", weights_2_3);
        $readmemh("conv2_weight_31.txt", weights_3_1);
        $readmemh("conv2_weight_32.txt", weights_3_2);
        $readmemh("conv2_weight_33.txt", weights_3_3);
        $readmemh("conv2_bias.txt", bias);
    end
    
    // 5 MAC units (process all 3 input channels in parallel)
    wire signed [19:0] mac_out_ch1 [0:4];
    wire signed [19:0] mac_out_ch2 [0:4];
    wire signed [19:0] mac_out_ch3 [0:4];
    
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : mac_gen
            // MACs for output channel 1
            assign mac_out_ch1[i] = kernel_buffer_ch1[conv_cycle*5 + i] * weights_1_1[conv_cycle*5 + i] +
                                   kernel_buffer_ch2[conv_cycle*5 + i] * weights_1_2[conv_cycle*5 + i] +
                                   kernel_buffer_ch3[conv_cycle*5 + i] * weights_1_3[conv_cycle*5 + i];
            
            // MACs for output channel 2
            assign mac_out_ch2[i] = kernel_buffer_ch1[conv_cycle*5 + i] * weights_2_1[conv_cycle*5 + i] +
                                   kernel_buffer_ch2[conv_cycle*5 + i] * weights_2_2[conv_cycle*5 + i] +
                                   kernel_buffer_ch3[conv_cycle*5 + i] * weights_2_3[conv_cycle*5 + i];
            
            // MACs for output channel 3
            assign mac_out_ch3[i] = kernel_buffer_ch1[conv_cycle*5 + i] * weights_3_1[conv_cycle*5 + i] +
                                   kernel_buffer_ch2[conv_cycle*5 + i] * weights_3_2[conv_cycle*5 + i] +
                                   kernel_buffer_ch3[conv_cycle*5 + i] * weights_3_3[conv_cycle*5 + i];
        end
    endgenerate
    
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            buf_write_idx <= 0;
            x_pos <= 0;
            y_pos <= 0;
            conv_cycle <= 0;
            valid_out <= 0;
            busy <= 0;
            acc_1 <= 0;
            acc_2 <= 0;
            acc_3 <= 0;
        end else begin
            valid_out <= 0;
            
            case (state)
                IDLE: begin
                    if (valid_in) begin
                        state <= FILL;
                        busy <= 1;
                        buf_write_idx <= 0;
                    end
                end
                
                FILL: begin
                    // Fill line buffers
                    if (valid_in) begin
                        line_buffer_ch1[buf_write_idx] <= max_value_1;
                        line_buffer_ch2[buf_write_idx] <= max_value_2;
                        line_buffer_ch3[buf_write_idx] <= max_value_3;
                        buf_write_idx <= buf_write_idx + 1;
                        
                        if (buf_write_idx == WIDTH*FILTER_SIZE-1) begin
                            state <= COMPUTE;
                            x_pos <= 0;
                            y_pos <= 0;
                        end
                    end
                end
                
                COMPUTE: begin
                    // Load kernel buffers from line buffers (only on cycle 0)
                    if (conv_cycle == 0) begin
                        for (kernel_idx = 0; kernel_idx < 25; kernel_idx = kernel_idx + 1) begin
                            kernel_buffer_ch1[kernel_idx] <= 
                                line_buffer_ch1[(kernel_idx/5)*WIDTH + (kernel_idx%5) + x_pos + (y_pos%5)*WIDTH];
                            kernel_buffer_ch2[kernel_idx] <= 
                                line_buffer_ch2[(kernel_idx/5)*WIDTH + (kernel_idx%5) + x_pos + (y_pos%5)*WIDTH];
                            kernel_buffer_ch3[kernel_idx] <= 
                                line_buffer_ch3[(kernel_idx/5)*WIDTH + (kernel_idx%5) + x_pos + (y_pos%5)*WIDTH];
                        end
                        acc_1 <= 0;
                        acc_2 <= 0;
                        acc_3 <= 0;
                    end
                    
                    // Accumulate MAC outputs
                    if (conv_cycle < 5) begin
                        acc_1 <= acc_1 + mac_out_ch1[0] + mac_out_ch1[1] + mac_out_ch1[2] + 
                                         mac_out_ch1[3] + mac_out_ch1[4];
                        acc_2 <= acc_2 + mac_out_ch2[0] + mac_out_ch2[1] + mac_out_ch2[2] + 
                                         mac_out_ch2[3] + mac_out_ch2[4];
                        acc_3 <= acc_3 + mac_out_ch3[0] + mac_out_ch3[1] + mac_out_ch3[2] + 
                                         mac_out_ch3[3] + mac_out_ch3[4];
                    end
                    
                    conv_cycle <= conv_cycle + 1;
                    
                    if (conv_cycle == 5) begin
                        // Output results with bias
                        conv2_out_1 <= acc_1[18:7] + {{4{bias[0][7]}}, bias[0]};
                        conv2_out_2 <= acc_2[18:7] + {{4{bias[1][7]}}, bias[1]};
                        conv2_out_3 <= acc_3[18:7] + {{4{bias[2][7]}}, bias[2]};
                        valid_out <= 1;
                        conv_cycle <= 0;
                        
                        // Move to next position
                        if (x_pos < WIDTH - FILTER_SIZE) begin
                            x_pos <= x_pos + 1;
                        end else begin
                            x_pos <= 0;
                            if (y_pos < HEIGHT - FILTER_SIZE) begin
                                y_pos <= y_pos + 1;
                                
                                // Shift line buffers
                                if (valid_in) begin
                                    for (kernel_idx = 0; kernel_idx < WIDTH*4; kernel_idx = kernel_idx + 1) begin
                                        line_buffer_ch1[kernel_idx] <= line_buffer_ch1[kernel_idx + WIDTH];
                                        line_buffer_ch2[kernel_idx] <= line_buffer_ch2[kernel_idx + WIDTH];
                                        line_buffer_ch3[kernel_idx] <= line_buffer_ch3[kernel_idx + WIDTH];
                                    end
                                    buf_write_idx <= WIDTH*4;
                                end
                            end else begin
                                // Done
                                state <= IDLE;
                                busy <= 0;
                            end
                        end
                    end
                end
                
                default: state <= IDLE;
            endcase
            
            // Continue filling during computation
            if (state == COMPUTE && valid_in && buf_write_idx >= WIDTH*4) begin
                line_buffer_ch1[buf_write_idx] <= max_value_1;
                line_buffer_ch2[buf_write_idx] <= max_value_2;
                line_buffer_ch3[buf_write_idx] <= max_value_3;
                if (buf_write_idx < WIDTH*5-1)
                    buf_write_idx <= buf_write_idx + 1;
                else
                    buf_write_idx <= WIDTH*4;
            end
        end
    end

endmodule