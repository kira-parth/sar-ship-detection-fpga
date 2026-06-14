`timescale 1ns/1ps
// ===========================================================================
// cfar2d_axis.v  (plain Verilog-2001/2005)
// AXI4-Stream + frame-buffer wrapper around cfar2d for PYNQ AXI-DMA.
//   LOAD  : accept IMG_W*IMG_H pixels, feed core, write detections to fbuf
//   DRAIN : flush pipeline
//   SEND  : stream the detection mask out (1 bit/byte), m_tlast on last
// ===========================================================================
module cfar2d_axis #(
    parameter IMG_W      = 32,
    parameter IMG_H      = 32,
    parameter DATA_W     = 16,
    parameter GUARD      = 1,
    parameter TRAIN      = 2,
    parameter ALPHA_FRAC = 8,
    parameter ALPHA      = 640
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire [DATA_W-1:0]  s_tdata,
    input  wire               s_tvalid,
    output wire               s_tready,
    input  wire               s_tlast,

    output reg  [7:0]         m_tdata,
    output reg                m_tvalid,
    input  wire               m_tready,
    output reg                m_tlast
);

    localparam NPIX    = IMG_W*IMG_H;
    localparam WH      = GUARD + TRAIN;
    localparam DRAIN_N = 2*WH*IMG_W + 2*WH + 8;

    localparam IDX_W = $clog2(NPIX);
    localparam DR_W  = $clog2(DRAIN_N+1);
    localparam CRW   = $clog2(IMG_H);
    localparam CCW   = $clog2(IMG_W);

    localparam S_LOAD  = 2'd0,
               S_DRAIN = 2'd1,
               S_SEND  = 2'd2,
               S_DONE  = 2'd3;

    reg [1:0] state_q;

    // ---- core -------------------------------------------------------------
    wire              core_tvalid = s_tvalid & s_tready;
    wire              det, det_valid;
    wire [CRW-1:0]    out_row;
    wire [CCW-1:0]    out_col;

    cfar2d #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .DATA_W(DATA_W),
        .GUARD(GUARD), .TRAIN(TRAIN), .ALPHA_FRAC(ALPHA_FRAC), .ALPHA(ALPHA)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(core_tvalid), .s_tready(),
        .det(det), .det_valid(det_valid), .out_row(out_row), .out_col(out_col)
    );

    // ---- frame buffer (1 bit/pixel). Borders rely on zero-init (BRAM init);
    //      interior cells are rewritten every frame. ------------------------
    reg fbuf [0:NPIX-1];
    integer ii;
    initial begin
        for (ii = 0; ii < NPIX; ii = ii + 1) fbuf[ii] = 1'b0;
    end

    always @(posedge clk) begin
        if (det_valid && (state_q == S_LOAD || state_q == S_DRAIN))
            fbuf[out_row*IMG_W + out_col] <= det;
    end

    // ---- counters / FSM ---------------------------------------------------
    reg [IDX_W-1:0] in_cnt_q;
    reg [DR_W-1:0]  drain_q;
    reg [IDX_W-1:0] send_cnt_q;

    assign s_tready = (state_q == S_LOAD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q    <= S_LOAD;
            in_cnt_q   <= 0;
            drain_q    <= 0;
            send_cnt_q <= 0;
        end else begin
            case (state_q)
                S_LOAD: begin
                    if (s_tvalid && s_tready) begin
                        if (in_cnt_q == NPIX-1) begin
                            in_cnt_q <= 0;
                            drain_q  <= DRAIN_N;
                            state_q  <= S_DRAIN;
                        end else begin
                            in_cnt_q <= in_cnt_q + 1'b1;
                        end
                    end
                end
                S_DRAIN: begin
                    if (drain_q == 0) begin
                        send_cnt_q <= 0;
                        state_q    <= S_SEND;
                    end else begin
                        drain_q <= drain_q - 1'b1;
                    end
                end
                S_SEND: begin
                    if (m_tvalid && m_tready) begin
                        if (send_cnt_q == NPIX-1)
                            state_q <= S_DONE;
                        else
                            send_cnt_q <= send_cnt_q + 1'b1;
                    end
                end
                S_DONE: begin
                    in_cnt_q <= 0;
                    state_q  <= S_LOAD;
                end
                default: state_q <= S_LOAD;
            endcase
        end
    end

    // ---- output stream ----------------------------------------------------
    always @(*) begin
        m_tvalid = (state_q == S_SEND);
        m_tdata  = m_tvalid ? {7'b0, fbuf[send_cnt_q]} : 8'b0;
        m_tlast  = m_tvalid && (send_cnt_q == NPIX-1);
    end

endmodule
