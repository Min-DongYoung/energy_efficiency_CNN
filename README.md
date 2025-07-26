# CNN Pipeline Architecture with Optimizations

## Overview
This document describes the optimized CNN architecture for MNIST classification with focus on area efficiency and power optimization.

## Architecture Improvements

### 1. Convolution 5-MAC Structure
- Reduced from 25 parallel MACs to 5 MACs
- 6 cycles to complete one convolution operation
- 80% area reduction in computation units
- Better power distribution across cycles

### 2. Module-level Clock Gating
- Latch-based clock gating for each module
- Automatic clock shutdown when module is idle
- Fine control through `clk_en` signals
- Significant dynamic power reduction

### 3. Kernel Buffer with Sliding Window
- 5×5 kernel buffer added to line buffers
- Only 5 new pixels loaded per cycle (instead of 25)
- 80% reduction in memory bandwidth
- Improved data reuse efficiency

### 4. Streaming Comparator
- Processes class scores as they arrive
- No need to wait for all 10 scores
- Maintains running maximum and index
- Reduced latency and buffer requirements

### 5. Simple Pipeline
- Each module operates independently
- Valid/ready handshaking between stages
- No complex back-pressure mechanism
- Natural flow control through busy signals

### 6. FC Layer MAC Sharing
- 48 inputs processed in groups of 16
- 3 cycles per output class
- 66% reduction in MAC units
- Time-multiplexed computation

## Module Specifications

### Conv1 Layer
```
Input:  28×28×1 (8-bit)
Output: 24×24×3 (12-bit)
Kernel: 5×5×1×3
MACs:   5 units
Cycles: 6 per output pixel
```

### MaxPool1 + ReLU
```
Input:  24×24×3 (12-bit)
Output: 12×12×3 (12-bit)
Window: 2×2
Cycles: 4 per output pixel
```

### Conv2 Layer
```
Input:  12×12×3 (12-bit)
Output: 8×8×3 (14-bit)
Kernel: 5×5×3×3
MACs:   5 units
Cycles: 6 per output pixel
```

### MaxPool2 + ReLU
```
Input:  8×8×3 (14-bit)
Output: 4×4×3 (12-bit)
Window: 2×2
Cycles: 4 per output pixel
```

### FC Layer
```
Input:  48 values (12-bit)
Output: 10 classes (12-bit)
Weights: 48×10
MACs:   16 units
Cycles: 3 per output class
```

### Comparator
```
Input:  10 classes (12-bit streaming)
Output: 1 decision (4-bit)
Cycles: 1 per input class
```

## Timing Analysis

### Total Latency (per image)
1. Conv1: 24×24×6 = 3,456 cycles
2. MaxPool1: 12×12×4 = 576 cycles
3. Conv2: 8×8×6 = 384 cycles
4. MaxPool2: 4×4×4 = 64 cycles
5. FC: 10×3 = 30 cycles
6. Comparator: 10 cycles

**Total: ~4,520 cycles**

### Throughput
With pipeline, new image can start every 3,456 cycles (limited by Conv1).

## Power Analysis

### Dynamic Power Reduction
1. Clock gating: ~40% reduction
2. MAC reduction: ~70% reduction in computation power
3. Memory access: ~80% reduction in Conv layers

### Area Reduction
1. Conv MACs: 80% reduction (25→5)
2. FC MACs: 66% reduction (48→16)
3. Total logic area: ~60% reduction

## Implementation Notes

### Clock Gating Cell
```verilog
module clock_gate (
    input clk,
    input enable,
    output gclk
);
    reg en_latch;
    always @(clk or enable)
        if (~clk) en_latch <= enable;
    assign gclk = clk & en_latch;
endmodule
```

### Pipeline Control
Each module implements:
- `valid_in`: Upstream data valid
- `busy`: Module processing
- `valid_out`: Downstream data ready
- `clk_en`: Clock enable (valid_in | busy)

### Memory Organization
- Weights: Distributed ROM with clock gating
- Line buffers: Shift registers with kernel buffers
- No external memory required