/*------------------------------------------------------------------------
 *
 *  File name  : fully_connected_opt.v
 *  Design     : Optimized Fully Connected Layer with MAC Sharing
 *
 *------------------------------------------------------------------------*/

module fully_connected_opt #(
    parameter INPUT_NUM = 48,
    parameter OUTPUT_NUM = 10,
    parameter DATA_BITS = 8,
    parameter MAC_UNITS = 16
) (
    input clk,
    input rst_n,
    input valid_in,
    input signed [11:0] data_in_1, data_in_2, data_in_3,
    output reg [11:0] data_out,
    output reg valid_out,
    output reg busy
);

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
    
    // Input buffer
    reg signed [13:0] input_buffer [0:INPUT_NUM-1];
    reg [5:0] buf_idx;
    
    // Weight storage and bias
    reg signed [DATA_BITS-1:0] weights [0:INPUT_NUM*OUTPUT_NUM-1];
    reg signed [DATA_BITS-1:0] bias [0:OUTPUT_NUM-1];
    
    // Control signals
    reg [3:0] output_idx;  // 0-9 for 10 outputs
    reg [1:0] mac_cycle;   // 0-2 for 3 cycles per output
    
    // MAC accumulator
    reg signed [21:0] accumulator;
    
    // 16 MAC outputs
    wire signed [19:0] mac_out [0:MAC_UNITS-1];
    
    // Load weights
    initial begin
        $readmemh("fc_weight.txt", weights);
        $readmemh("fc_bias.txt", bias);
    end
    
    // Sign extend inputs
    wire signed [13:0] data1_ext, data2_ext, data3_ext;
    assign data1_ext = {{2{data_in_1[11]}}, data_in_1};
    assign data2_ext = {{2{data_in_2[11]}}, data_in_2};
    assign data3_ext = {{2{data_in_3[11]}}, data_in_3};
    
    // 16 MAC units
    genvar i;
    generate
        for (i = 0; i < MAC_UNITS; i = i + 1) begin : mac_gen
            assign mac_out[i] = input_buffer[mac_cycle*16 + i] * 
                               weights[output_idx*INPUT_NUM + mac_cycle*16 + i];
        end
    endgenerate
    
    // Sum of MAC outputs
    wire signed [23:0] mac_sum;
    assign mac_sum = mac_out[0] + mac_out[1] + mac_out[2] + mac_out[3] +
                     mac_out[4] + mac_out[5] + mac_out[6] + mac_out[7] +
                     mac_out[8] + mac_out[9] + mac_out[10] + mac_out[11] +
                     mac_out[12] + mac_out[13] + mac_out[14] + mac_out[15];
    
    always @(posedge gclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            buf_idx <= 0;
            output_idx <= 0;
            mac_cycle <= 0;
            valid_out <= 0;
            busy <= 0;
            accumulator <= 0;
        end else begin
            valid_out <= 0;
            
            case (state)
                IDLE: begin
                    if (valid_in) begin
                        state <= FILL;
                        busy <= 1;
                        buf_idx <= 0;
                    end
                end
                
                FILL: begin
                    // Fill input buffer with all 48 values
                    if (valid_in) begin
                        input_buffer[buf_idx] <= data1_ext;
                        input_buffer[16 + buf_idx] <= data2_ext;
                        input_buffer[32 + buf_idx] <= data3_ext;
                        buf_idx <= buf_idx + 1;
                        
                        if (buf_idx == 15) begin
                            // Buffer filled, start computation
                            state <= COMPUTE;
                            output_idx <= 0;
                            mac_cycle <= 0;
                            accumulator <= 0;
                        end
                    end
                end
                
                COMPUTE: begin
                    // Accumulate MAC results
                    if (mac_cycle == 0) begin
                        accumulator <= mac_sum;
                    end else begin
                        accumulator <= accumulator + mac_sum;
                    end
                    
                    mac_cycle <= mac_cycle + 1;
                    
                    if (mac_cycle == 2) begin
                        // Output result with bias
                        data_out <= accumulator[18:7] + {{4{bias[output_idx][7]}}, bias[output_idx]};
                        valid_out <= 1;
                        mac_cycle <= 0;
                        accumulator <= 0;
                        
                        if (output_idx == OUTPUT_NUM - 1) begin
                            // All outputs done
                            output_idx <= 0;
                            state <= IDLE;
                            busy <= 0;
                        end else begin
                            output_idx <= output_idx + 1;
                        end
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule