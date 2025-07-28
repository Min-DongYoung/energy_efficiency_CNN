/*------------------------------------------------------------------------
 *
 *  File name  : cnn_top_opt.v
 *  Design     : Top Module for Optimized CNN with Pipeline Control
 *
 *------------------------------------------------------------------------*/

module cnn_top_opt (
    input clk,
    input rst_n,
    input [7:0] data_in,
    input valid_in,
    output [3:0] decision,
    output valid_out,
    output busy  // Overall system busy signal
);

    // Inter-module connections
    wire [11:0] conv1_out_1, conv1_out_2, conv1_out_3;
    wire [11:0] max1_out_1, max1_out_2, max1_out_3;
    wire [11:0] conv2_out_1, conv2_out_2, conv2_out_3;
    wire [11:0] max2_out_1, max2_out_2, max2_out_3;
    wire [11:0] fc_out;
    
    // Valid signals
    wire conv1_valid, max1_valid, conv2_valid, max2_valid, fc_valid;
    
    // Busy signals
    wire conv1_busy, max1_busy, conv2_busy, max2_busy, fc_busy;
    
    // Ready signals
    wire conv1_ready, max1_ready, conv2_ready, max2_ready, fc_ready;
    
    // Overall busy signal
    assign busy = conv1_busy | max1_busy | conv2_busy | max2_busy | fc_busy;
    
    // Conv1 Layer
    conv1_layer_opt conv1 (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .valid_in(valid_in),
        .conv_out_1(conv1_out_1),
        .conv_out_2(conv1_out_2),
        .conv_out_3(conv1_out_3),
        .valid_out(conv1_valid),
        .busy(conv1_busy),
        .ready(conv1_ready)
    );
    
    // MaxPool1 + ReLU
    maxpool_relu_opt #(
        .CONV_BIT(12),
        .HALF_WIDTH(12),
        .HALF_HEIGHT(12),
        .HALF_WIDTH_BIT(4)
    ) maxpool1 (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(conv1_valid),
        .conv_out_1(conv1_out_1),
        .conv_out_2(conv1_out_2),
        .conv_out_3(conv1_out_3),
        .max_value_1(max1_out_1),
        .max_value_2(max1_out_2),
        .max_value_3(max1_out_3),
        .valid_out(max1_valid),
        .busy(max1_busy),
        .ready(max1_ready)
    );
    
    // Conv2 Layer
    conv2_layer_opt conv2 (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(max1_valid),
        .max_value_1(max1_out_1),
        .max_value_2(max1_out_2),
        .max_value_3(max1_out_3),
        .conv2_out_1(conv2_out_1),
        .conv2_out_2(conv2_out_2),
        .conv2_out_3(conv2_out_3),
        .valid_out(conv2_valid),
        .busy(conv2_busy),
        .ready(conv2_ready)
    );
    
    // MaxPool2 + ReLU
    maxpool_relu_opt #(
        .CONV_BIT(12),
        .HALF_WIDTH(4),
        .HALF_HEIGHT(4),
        .HALF_WIDTH_BIT(3)
    ) maxpool2 (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(conv2_valid),
        .conv_out_1(conv2_out_1),
        .conv_out_2(conv2_out_2),
        .conv_out_3(conv2_out_3),
        .max_value_1(max2_out_1),
        .max_value_2(max2_out_2),
        .max_value_3(max2_out_3),
        .valid_out(max2_valid),
        .busy(max2_busy),
        .ready(max2_ready)
    );
    
    // Fully Connected Layer
    fully_connected_opt #(
        .INPUT_NUM(48),
        .OUTPUT_NUM(10),
        .DATA_BITS(8),
        .MAC_UNITS(16)
    ) fc (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(max2_valid),
        .data_in_1(max2_out_1),
        .data_in_2(max2_out_2),
        .data_in_3(max2_out_3),
        .data_out(fc_out),
        .valid_out(fc_valid),
        .busy(fc_busy),
        .ready(fc_ready)
    );
    
    // Streaming Comparator
    comparator_opt comp (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(fc_valid),
        .data_in(fc_out),
        .decision(decision),
        .valid_out(valid_out)
    );

endmodule