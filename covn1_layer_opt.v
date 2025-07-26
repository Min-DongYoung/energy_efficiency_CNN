/*------------------------------------------------------------------------
 *
 *  File name  : conv1_layer_opt.v
 *  Design     : Optimized 1st Convolution Layer with 5 MACs and Kernel Buffer
 *
 *------------------------------------------------------------------------*/

module conv1_layer_opt (
    input clk,
    input rst_n,
    input [7:0] data_in,
    input valid_in,
    output reg [11:0] conv_out_1, conv_out_2, conv_out_3,
    output reg valid_out,
    output reg busy
);

    // Parameters
    localparam WIDTH = 28;
    localparam HEIGHT = 28;
    localparam FILTER_SIZE = 5;
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
    localparam OUTPUT = 2'b11;
    
    reg [1:0] state;
    
    // Line buffer - 5 lines of 28 pixels
    reg [7:0] line_buffer [0:WIDTH*FILTER_SIZE-1];
    reg [6:0] buf_write_idx;
    
    // Kernel buffer - 5x5 sliding window
    reg [7:0] kernel_buffer [0:24];
    integer load_idx;  // For loading kernel buffer
    
    // Position tracking
    reg [4:0] x_pos, y_pos;
    reg [2:0] conv_cycle;  // 0-5 for 6 cycles per convolution
    reg [1:0] channel;     // Current output channel
    
    // Weight storage (distributed for each channel)
    reg signed [7:0] weights_ch0 [0:24];
    reg signed [7:0] weights_ch1 [0:24];
    reg signed [7:0] weights_ch2 [0:24];
    reg signed [7:0] bias [0:2];
    
    // MAC accumulator
    reg signed [19:0] acc_ch0, acc_ch1, acc_ch2;
    
    // Load weights
    initial begin
        $readmemh("conv1_weight_1.txt", weights_ch0);
        $readmemh("conv1_weight_2.txt", weights_ch1);
        $readmemh("conv1_weight_3.txt", weights_ch2);
        $readmemh("conv1_bias.txt", bias);
    end
    
    // 5 MAC units
    wire signed [15:0] mac_out_ch0 [0:4];
    wire signed [15:0] mac_out_ch1 [0:4];
    wire signed [15:0] mac_out_ch2 [0:4];
    wire signed [8:0] data_ext [0:4];
    
    // Sign extend input data
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : mac_gen
            assign data_ext[i] = {1'b0, kernel_buffer[conv_cycle*5 + i]};
            assign mac_out_ch0[i] = data_ext * weights_ch0[conv_cycle*5 + i];
            assign mac_out_ch1[i] = data_ext * weights_ch1[conv_cycle*5 + i];
            assign mac_out_ch2[i] = data_ext * weights_ch2[conv_cycle*5 + i];
        end
    endgenerate
    
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            buf_write_idx <= 0;
            x_pos <= 0;
            y_pos <= 0;
            conv_cycle <= 0;
            channel <= 0;
            valid_out <= 0;
            busy <= 0;
            acc_ch0 <= 0;
            acc_ch1 <= 0;
            acc_ch2 <= 0;
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
                    // Fill line buffer
                    if (valid_in) begin
                        line_buffer[buf_write_idx] <= data_in;
                        buf_write_idx <= buf_write_idx + 1;
                        
                        if (buf_write_idx == WIDTH*FILTER_SIZE-1) begin
                            state <= COMPUTE;
                            x_pos <= 0;
                            y_pos <= 0;
                        end
                    end else begin
                        // No valid input - wait
                        // Don't process invalid data
                    end
                end
                
                COMPUTE: begin
                    // Load kernel buffer from line buffer (only on cycle 0)
                    if (conv_cycle == 0) begin
                        // Load 5x5 window into kernel buffer
                        for (load_idx = 0; load_idx < 25; load_idx = load_idx + 1) begin
                            kernel_buffer[load_idx] <= 
                                line_buffer[(load_idx/5)*WIDTH + (load_idx%5) + x_pos + ((y_pos%5)*WIDTH)];
                        end
                        acc_ch0 <= 0;
                        acc_ch1 <= 0;
                        acc_ch2 <= 0;
                    end
                    
                    // Accumulate MAC outputs
                    if (conv_cycle < 5) begin
                        acc_ch0 <= acc_ch0 + mac_out_ch0[0] + mac_out_ch0[1] + mac_out_ch0[2] + mac_out_ch0[3] + mac_out_ch0[4];
                        acc_ch1 <= acc_ch1 + mac_out_ch1[0] + mac_out_ch1[1] + mac_out_ch1[2] + mac_out_ch1[3] + mac_out_ch1[4];
                        acc_ch2 <= acc_ch2 + mac_out_ch2[0] + mac_out_ch2[1] + mac_out_ch2[2] + mac_out_ch2[3] + mac_out_ch2[4];
                    end
                    
                    conv_cycle <= conv_cycle + 1;
                    
                    if (conv_cycle == 5) begin
                        // Output results
                        conv_out_1 <= acc_ch0[19:8] + {{4{bias[0][7]}}, bias[0]};
                        conv_out_2 <= acc_ch1[19:8] + {{4{bias[1][7]}}, bias[1]};
                        conv_out_3 <= acc_ch2[19:8] + {{4{bias[2][7]}}, bias[2]};
                        valid_out <= 1;
                        conv_cycle <= 0;
                        
                        // Move to next position
                        if (x_pos < WIDTH - FILTER_SIZE) begin
                            x_pos <= x_pos + 1;
                        end else begin
                            x_pos <= 0;
                            if (y_pos < HEIGHT - FILTER_SIZE) begin
                                y_pos <= y_pos + 1;
                                
                                // Shift line buffer and prepare for new line
                                // This happens when we move to next row
                                integer shift_idx;
                                for (shift_idx = 0; shift_idx < WIDTH*4; shift_idx = shift_idx + 1) begin
                                    line_buffer[shift_idx] <= line_buffer[shift_idx + WIDTH];
                                end
                                // Reset write index for new line
                                buf_write_idx <= WIDTH*4;
                            end else begin
                                // Done with image
                                state <= IDLE;
                                busy <= 0;
                            end
                        end
                    end
                end
                
                default: state <= IDLE;
            endcase
            
            // Continue filling buffer during computation
            if (state == COMPUTE && valid_in && buf_write_idx >= WIDTH*4) begin
                line_buffer[buf_write_idx] <= data_in;
                if (buf_write_idx < WIDTH*5-1)
                    buf_write_idx <= buf_write_idx + 1;
                else
                    buf_write_idx <= WIDTH*4;
            end
        end
    end

endmodule