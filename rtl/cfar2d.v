`timescale 1ns/1ps
// ===========================================================================
// cfar2d.v   (plain Verilog-2001/2005)
// 2-D Cell-Averaging CFAR (CA-CFAR) detector.
//
//   detect  <=>  CUT * NTRAIN * 2^ALPHA_FRAC  >  sum_train * ALPHA
//
// Default geometry GUARD=1, TRAIN=2 -> 7x7 window, 3x3 guard, 40 training
// cells, ALPHA=640 (Q.8 = 2.5x). Streams one pixel/clock (raster order);
// emits a 1-bit detection per interior pixel with its (row,col).
// ===========================================================================
module cfar2d #(
    parameter IMG_W      = 32,
    parameter IMG_H      = 32,
    parameter DATA_W     = 16,
    parameter GUARD      = 1,
    parameter TRAIN      = 2,
    parameter ALPHA_FRAC = 8,
    parameter ALPHA      = 640
) (
    input  wire                        clk,
    input  wire                        rst_n,

    input  wire [DATA_W-1:0]           s_tdata,
    input  wire                        s_tvalid,
    output wire                        s_tready,

    output reg                         det,
    output reg                         det_valid,
    output reg  [$clog2(IMG_H)-1:0]    out_row,
    output reg  [$clog2(IMG_W)-1:0]    out_col
);

    // ---- derived geometry -------------------------------------------------
    localparam WH      = GUARD + TRAIN;             // 3
    localparam WIN     = 2*WH + 1;                  // 7
    localparam GUARD_S = 2*GUARD + 1;               // 3
    localparam NTRAIN  = WIN*WIN - GUARD_S*GUARD_S; // 40
    localparam SUM_W   = DATA_W + $clog2(NTRAIN) + 1; // 23
    localparam CMP_W   = 40;                         // headroom for products

    // =======================================================================
    // 1. Input handshake + raster position counters
    // =======================================================================
    assign s_tready = 1'b1;

    wire                       in_fire = s_tvalid & s_tready;
    reg [$clog2(IMG_W)-1:0]    col_q;
    reg [$clog2(IMG_H)-1:0]    row_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_q <= 0;
            row_q <= 0;
        end else if (in_fire) begin
            if (col_q == IMG_W-1) begin
                col_q <= 0;
                row_q <= (row_q == IMG_H-1) ? 0 : (row_q + 1'b1);
            end else begin
                col_q <= col_q + 1'b1;
            end
        end
    end

    // =======================================================================
    // 2. Line buffers: WIN-1 rows of history, each IMG_W deep (cascaded)
    // =======================================================================
    reg [DATA_W-1:0] lb [0:WIN-2][0:IMG_W-1];
    integer li;

    always @(posedge clk) begin
        if (in_fire) begin
            lb[0][col_q] <= s_tdata;
            for (li = 1; li < WIN-1; li = li + 1)
                lb[li][col_q] <= lb[li-1][col_q];
        end
    end

    // =======================================================================
    // 3. 7x7 window shift register. New vertical column inserted on the right.
    // =======================================================================
    reg [DATA_W-1:0] win [0:WIN-1][0:WIN-1];
    integer wr, wc;

    always @(posedge clk) begin
        if (in_fire) begin
            for (wr = 0; wr < WIN; wr = wr + 1) begin
                for (wc = 0; wc < WIN-1; wc = wc + 1)
                    win[wr][wc] <= win[wr][wc+1];
                if (wr == WIN-1)
                    win[wr][WIN-1] <= s_tdata;
                else
                    win[wr][WIN-1] <= lb[WIN-2-wr][col_q];
            end
        end
    end

    // position of the just-inserted pixel (one cycle behind)
    reg [$clog2(IMG_W)-1:0] col_d;
    reg [$clog2(IMG_H)-1:0] row_d;
    reg                     fire_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_d  <= 0;
            row_d  <= 0;
            fire_d <= 1'b0;
        end else begin
            col_d  <= col_q;
            row_d  <= row_q;
            fire_d <= in_fire;
        end
    end

    // =======================================================================
    // 4. CFAR compute (combinational)
    // =======================================================================
    reg [SUM_W-1:0]  train_sum;
    reg [DATA_W-1:0] cut;
    integer gi, gj;

    always @(*) begin
        train_sum = 0;
        for (gi = 0; gi < WIN; gi = gi + 1) begin
            for (gj = 0; gj < WIN; gj = gj + 1) begin
                if ((gi >= TRAIN) && (gi < TRAIN+GUARD_S) &&
                    (gj >= TRAIN) && (gj < TRAIN+GUARD_S))
                    train_sum = train_sum;          // guard / CUT: skip
                else
                    train_sum = train_sum + win[gi][gj];
            end
        end
        cut = win[WH][WH];
    end

    // integer-only threshold compare (products fit in 32 bits for default
    // ranges; CMP_W=40 leaves headroom)
    reg [CMP_W-1:0] lhs, rhs;
    reg             det_c;

    always @(*) begin
        lhs   = (cut * NTRAIN) << ALPHA_FRAC;
        rhs   = train_sum * ALPHA;
        det_c = (lhs > rhs);
    end

    // =======================================================================
    // 5. Output register + interior validity.
    //    CUT for pixel (row_d,col_d) sits at (row_d-WH, col_d-WH).
    // =======================================================================
    reg                     interior_c;
    reg [$clog2(IMG_H)-1:0] cut_row;
    reg [$clog2(IMG_W)-1:0] cut_col;

    always @(*) begin
        interior_c = fire_d && (row_d >= (2*WH)) && (col_d >= (2*WH));
        cut_row    = row_d - WH;
        cut_col    = col_d - WH;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            det       <= 1'b0;
            det_valid <= 1'b0;
            out_row   <= 0;
            out_col   <= 0;
        end else begin
            det       <= det_c;
            det_valid <= interior_c;
            out_row   <= cut_row;
            out_col   <= cut_col;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && det_valid) begin
            if (out_row < WH || out_row > IMG_H-1-WH)
                $display("ASSERT FAIL: out_row %0d out of interior", out_row);
            if (out_col < WH || out_col > IMG_W-1-WH)
                $display("ASSERT FAIL: out_col %0d out of interior", out_col);
        end
    end
`endif

endmodule
