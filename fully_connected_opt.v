module fully_connected_opt #(
    parameter INPUT_NUM = 48,      // 4x4x3
    parameter OUTPUT_NUM = 10,
    parameter DATA_BITS = 8,
    parameter MAC_UNITS = 15       // 5 outputs x 3 channels
) (
    input clk,
    input rst_n,
    input valid_in,
    input signed [11:0] data_in_1, data_in_2, data_in_3,
    output reg [11:0] data_out [0:9],  // 10 parallel outputs
    output reg valid_out,
    output reg busy,
    output reg ready
);

    // Separate clock gating for buffer and MAC
    wire buffer_gclk, mac_gclk;
    wire buffer_clk_en, mac_clk_en;
    
    // Buffer active only during data reception
    assign buffer_clk_en = valid_in && (state == BUFFER);
    // MAC active only during computation
    assign mac_clk_en = (state == COMPUTE);
    
    clock_gate cg_buffer (
        .clk(clk),
        .enable(buffer_clk_en),
        .gclk(buffer_gclk)
    );
    
    clock_gate cg_mac (
        .clk(clk),
        .enable(mac_clk_en),
        .gclk(mac_gclk)
    );
    
    // States
    localparam IDLE = 2'b00;
    localparam BUFFER = 2'b01;
    localparam COMPUTE = 2'b10;
    localparam OUTPUT = 2'b11;
    
    reg [1:0] state;
    
    // Row buffers - one per channel (4 values each)
    reg signed [11:0] buffer_ch1 [0:3];
    reg signed [11:0] buffer_ch2 [0:3];
    reg signed [11:0] buffer_ch3 [0:3];
    
    // Weight storage and bias (2D array for easy access)
    reg signed [DATA_BITS-1:0] weights [0:9][0:47];  // [output][input]
    reg signed [DATA_BITS-1:0] bias [0:9];
    
    // Load weights
    reg signed [DATA_BITS-1:0] weights_flat [0:479];
    initial begin
        $readmemh("fc_weight.txt", weights_flat);
        $readmemh("fc_bias.txt", bias);
        
        // Convert to 2D array with blocking assignment
        for (integer i = 0; i < 10; i = i + 1) begin
            for (integer j = 0; j < 48; j = j + 1) begin
                weights[i][j] = weights_flat[i*48 + j];
            end
        end
    end
    
    // Control counters
    reg [1:0] cnt_valid;       // 0-3: counts valid inputs
    reg [1:0] row_cnt;         // 0-3: tracks which row (0-3)
    reg [2:0] mac_cycle;       // 0-8: MAC computation cycle
    reg grp_select;            // 0: outputs 0-4, 1: outputs 5-9
    reg [1:0] buf_idx;         // 0-3: current buffer position for MAC
    
    // Accumulators for 10 outputs
    reg signed [21:0] acc [0:9];
    
    // MAC results - 15 units (5 outputs x 3 channels)
    reg signed [19:0] mac_result [0:14];
    
    // Weight index calculation
    wire [5:0] weight_base = row_cnt * 12 + buf_idx * 3;  // Base index for current position
    
    // Control signals
    wire row_complete = (cnt_valid == 3) && valid_in;
    
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cnt_valid <= 0;
            row_cnt <= 0;
            mac_cycle <= 0;
            grp_select <= 1;  // Initialize to 1 for correct sequencing
            buf_idx <= 0;
            valid_out <= 0;
            busy <= 0;
            ready <= 1;
            
            for (i = 0; i < 10; i = i + 1) begin
                acc[i] <= 0;
            end
        end else begin
            valid_out <= 0;
            ready <= 0;
            
            case (state)
                IDLE: begin
                    ready <= 1;
                    if (valid_in) begin
                        state <= BUFFER;
                        busy <= 1;
                        cnt_valid <= 0;
                        row_cnt <= 0;
                    end
                end
                
                BUFFER: begin
                    ready <= 1;
                    
                    // Buffer state management
                    if (valid_in) begin
                        cnt_valid <= cnt_valid + 1;
                        
                        if (row_complete) begin
                            // Start computation
                            state <= COMPUTE;
                            cnt_valid <= 0;
                            mac_cycle <= 0;
                            grp_select <= 1;  // Reset for each computation
                            buf_idx <= 0;
                            ready <= 0;
                        end
                    end
                end
                
                COMPUTE: begin
                    // MAC operations complete in 9 cycles
                    if (mac_cycle < 9) begin
                        mac_cycle <= mac_cycle + 1;
                        
                        // Toggle group select each cycle after cycle 0
                        if (mac_cycle > 0) begin
                            grp_select <= ~grp_select;
                        end
                        
                        // Update buffer index when switching back to group 0
                        if (mac_cycle > 0 && grp_select == 1) begin
                            buf_idx <= buf_idx + 1;
                        end
                    end else begin
                        // Computation done for this row
                        row_cnt <= row_cnt + 1;
                        
                        if (row_cnt == 3) begin
                            // All rows processed - output results
                            state <= OUTPUT;
                        end else begin
                            // Wait for next row
                            state <= BUFFER;
                            ready <= 1;
                        end
                    end
                end
                
                OUTPUT: begin
                    // Output all 10 results in parallel
                    for (i = 0; i < 10; i = i + 1) begin
                        data_out[i] <= acc[i][18:7] + {{4{bias[i][7]}}, bias[i]};
                        acc[i] <= 0;  // Clear for next frame
                    end
                    valid_out <= 1;
                    
                    // Return to IDLE
                    state <= IDLE;
                    busy <= 0;
                    row_cnt <= 0;
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    // Buffer write logic - only active with buffer_gclk
    always @(posedge buffer_gclk) begin
        if (state == BUFFER && valid_in) begin
            buffer_ch1[cnt_valid] <= data_in_1;
            buffer_ch2[cnt_valid] <= data_in_2;
            buffer_ch3[cnt_valid] <= data_in_3;
        end
    end
    
    // MAC computation logic - only active with mac_gclk
    always @(posedge mac_gclk) begin
        if (state == COMPUTE) begin
            if (mac_cycle == 0) begin
                // First cycle: Group 0 MAC only
                for (i = 0; i < 5; i = i + 1) begin
                    mac_result[i*3]   <= buffer_ch1[0] * weights[i][weight_base];
                    mac_result[i*3+1] <= buffer_ch2[0] * weights[i][weight_base + 16];
                    mac_result[i*3+2] <= buffer_ch3[0] * weights[i][weight_base + 32];
                end
            end else begin
                // Combined MAC and ACC for subsequent cycles
                for (i = 0; i < 5; i = i + 1) begin
                    if (grp_select == 0) begin
                        // Group 0 MAC + Group 1 ACC
                        mac_result[i*3]   <= buffer_ch1[buf_idx] * weights[i][weight_base];
                        mac_result[i*3+1] <= buffer_ch2[buf_idx] * weights[i][weight_base + 16];
                        mac_result[i*3+2] <= buffer_ch3[buf_idx] * weights[i][weight_base + 32];
                        
                        // Accumulate previous Group 1 results
                        acc[i+5] <= acc[i+5] + mac_result[i*3] + mac_result[i*3+1] + mac_result[i*3+2];
                    end else begin
                        // Group 1 MAC + Group 0 ACC
                        mac_result[i*3]   <= buffer_ch1[buf_idx] * weights[i+5][weight_base];
                        mac_result[i*3+1] <= buffer_ch2[buf_idx] * weights[i+5][weight_base + 16];
                        mac_result[i*3+2] <= buffer_ch3[buf_idx] * weights[i+5][weight_base + 32];
                        
                        // Accumulate previous Group 0 results
                        acc[i] <= acc[i] + mac_result[i*3] + mac_result[i*3+1] + mac_result[i*3+2];
                    end
                end
            end
            
            // Last cycle: final accumulation for Group 1
            if (mac_cycle == 8) begin
                for (i = 0; i < 5; i = i + 1) begin
                    acc[i+5] <= acc[i+5] + mac_result[i*3] + mac_result[i*3+1] + mac_result[i*3+2];
                end
            end
        end
    end

endmodule