//
// PCILeech FPGA — RTL8168 Private Firmware
//
// MSI-X Interrupt Generator
//
// Generates PCIe Memory Write TLPs to the host MSI-X address when triggered.
// Supports 2 MSI-X vectors (matching RTL8168 capability).
//
// Integration:
//   1. Instantiate alongside pcileech_tlps128_bar_controller in the top module.
//   2. Connect msix_v* ports from the bar controller to this module.
//   3. Connect tlps_irq_out to a free mux channel in pcileech_pcie_a7.sv.
//   4. Drive irq_req[0] or irq_req[1] when the emulated device needs to interrupt.
//
// TLP generated: MWr32 (if addr_hi==0) or MWr64 (addr_hi!=0)
//   Single-DWORD payload = MSI-X message data.
//   Latency: ~4 clocks from irq_req to first TLP beat output.
//
// Byte order note:
//   MSI-X registers are written by the host via MemWrite TLPs.
//   The pcileech write engine byte-reverses each DWORD on storage.
//   This module reverses them again before encoding them into the outgoing TLP,
//   restoring PCIe wire (big-endian) byte order in the header.
//
// (c) private — RTL8168 emulation layer

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module rtl8168_interrupt_generator(
    input               rst,
    input               clk,

    // Requester ID of this device (from PCIe core)
    input [15:0]        pcie_id,        // [15:8]=bus, [7:3]=dev, [2:0]=func

    // MSI-X vector table (LE byte order, from bar controller shadow registers)
    input [31:0]        v0_addr_lo,     // message address low  (LE)
    input [31:0]        v0_addr_hi,     // message address high (LE)
    input [31:0]        v0_data,        // message data         (LE)
    input               v0_masked,      // 1 = masked (do NOT send)

    input [31:0]        v1_addr_lo,
    input [31:0]        v1_addr_hi,
    input [31:0]        v1_data,
    input               v1_masked,

    // Interrupt request (pulse 1 CLK to request interrupt)
    input  [1:0]        irq_req,        // bit0 = vector 0, bit1 = vector 1
    output reg [1:0]    irq_ack,        // pulsed 1 CLK when TLP sent (or dropped if masked)

    // TLP output — connect to mux channel (e.g. TLP_STATIC or a dedicated mux slot)
    IfAXIS128.source    tlps_irq_out
);

    // ── Byte-reverse helper (LE→BE for PCIe header encoding) ────────────────
    function automatic [31:0] bswap32(input [31:0] v);
        bswap32 = {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction

    // ── State machine ────────────────────────────────────────────────────────
    // States
    localparam S_IDLE    = 2'd0;
    localparam S_MWR32   = 2'd1;   // send single-beat MWr32 (3DW header + data, fits 128b)
    localparam S_MWR64_H = 2'd2;   // send first beat of MWr64 (4DW header)
    localparam S_MWR64_D = 2'd3;   // send second beat of MWr64 (data DWORD)

    reg [1:0]   state = S_IDLE;

    // Latched vector selection
    reg [31:0]  laddr_lo, laddr_hi, ldata;
    reg [1:0]   irq_ack_pending;

    // ── Arbitrate and latch on irq_req ───────────────────────────────────────
    wire req_v0 = irq_req[0] && !v0_masked;
    wire req_v1 = irq_req[1] && !v1_masked;

    // ── TLP output registers ─────────────────────────────────────────────────
    reg [127:0] tdata_r;
    reg [3:0]   tkeepdw_r;
    reg         tlast_r;
    reg         tvalid_r;
    reg         tuser_first_r;

    // Tag counter (simple 8-bit counter; reuse is fine for interrupt writes)
    reg [7:0]   tag_cnt = 8'h00;

    always @ (posedge clk) begin
        irq_ack <= 2'b00;

        if (rst) begin
            state           <= S_IDLE;
            irq_ack_pending <= 2'b00;
            tvalid_r        <= 1'b0;
            tlast_r         <= 1'b0;
            tkeepdw_r       <= 4'b0000;
            tuser_first_r   <= 1'b0;
            tdata_r         <= 128'h0;
        end else case (state)

            S_IDLE: begin
                if (irq_req[0] && v0_masked)
                    irq_ack[0] <= 1'b1;
                if (irq_req[1] && v1_masked)
                    irq_ack[1] <= 1'b1;

                if (req_v0 || req_v1) begin
                    // Arbitrate: v0 wins if both
                    laddr_lo <= req_v0 ? v0_addr_lo : v1_addr_lo;
                    laddr_hi <= req_v0 ? v0_addr_hi : v1_addr_hi;
                    ldata    <= req_v0 ? v0_data    : v1_data;
                    irq_ack_pending <= req_v0 ? 2'b01 : 2'b10;
                    tag_cnt   <= tag_cnt + 8'h1;

                    if ((req_v0 ? v0_addr_hi : v1_addr_hi) != 32'h0) begin
                        tdata_r[31:0]   <= 32'h60000001;    // MWr64, Len=1
                        tdata_r[63:32]  <= {pcie_id[7:0], pcie_id[15:8], tag_cnt, 8'h0F};
                        tdata_r[95:64]  <= bswap32(req_v0 ? v0_addr_hi : v1_addr_hi);
                        tdata_r[127:96] <= bswap32(req_v0 ? v0_addr_lo : v1_addr_lo);
                        tkeepdw_r       <= 4'b1111;
                        tlast_r         <= 1'b0;
                        tvalid_r        <= 1'b1;
                        tuser_first_r   <= 1'b1;
                        state           <= S_MWR64_H;
                    end else begin
                        tdata_r[31:0]   <= 32'h40000001;    // MWr32, Len=1
                        tdata_r[63:32]  <= {pcie_id[7:0], pcie_id[15:8], tag_cnt, 8'h0F};
                        tdata_r[95:64]  <= bswap32(req_v0 ? v0_addr_lo : v1_addr_lo);
                        tdata_r[127:96] <= bswap32(req_v0 ? v0_data : v1_data);
                        tkeepdw_r       <= 4'b1111;
                        tlast_r         <= 1'b1;
                        tvalid_r        <= 1'b1;
                        tuser_first_r   <= 1'b1;
                        state           <= S_MWR32;
                    end
                end
            end

            // ── MWr32: 3DW header + 1DW data → one 128-bit beat ─────────────
            // tdata layout (PCIe big-endian within each DW):
            //   [31:0]   DW0: {Fmt=010, Type=00000, TC=0, TD=0, EP=0, Attr=00, Len=1}
            //   [63:32]  DW1: {ReqID[15:8], ReqID[7:0], Tag, LastBE=0, FirstBE=F}
            //   [95:64]  DW2: Address[31:0] in PCIe BE (= bswap of stored LE addr)
            //   [127:96] DW3: Data[31:0] in PCIe BE  (= bswap of stored LE data)
            S_MWR32: begin
                if (tlps_irq_out.tready) begin
                    irq_ack  <= irq_ack_pending;
                    tvalid_r <= 1'b0;
                    state    <= S_IDLE;
                end
            end

            // ── MWr64: 4DW header (beat 1) ───────────────────────────────────
            // [31:0]   DW0: {Fmt=011, Type=00000, TC=0, TD=0, EP=0, Attr=00, Len=1}
            // [63:32]  DW1: {ReqID[15:8], ReqID[7:0], Tag, LastBE=0, FirstBE=F}
            // [95:64]  DW2: Address[63:32] in PCIe BE
            // [127:96] DW3: Address[31:0]  in PCIe BE
            S_MWR64_H: begin
                if (tlps_irq_out.tready) begin
                    tdata_r[31:0]   <= bswap32(ldata);
                    tdata_r[127:32] <= 96'h0;
                    tkeepdw_r       <= 4'b0001;
                    tlast_r         <= 1'b1;
                    tvalid_r        <= 1'b1;
                    tuser_first_r   <= 1'b0;
                    state           <= S_MWR64_D;
                end
            end

            // ── MWr64: data beat (beat 2) ────────────────────────────────────
            // [31:0]   DW4: Data in PCIe BE
            // [127:32] unused (tkeepdw=0001)
            S_MWR64_D: begin
                if (tlps_irq_out.tready) begin
                    irq_ack  <= irq_ack_pending;
                    tvalid_r <= 1'b0;
                    state    <= S_IDLE;
                end
            end

        endcase
    end

    // ── Drive IfAXIS128 output ───────────────────────────────────────────────
    assign tlps_irq_out.tdata    = tdata_r;
    assign tlps_irq_out.tkeepdw  = tkeepdw_r;
    assign tlps_irq_out.tlast    = tlast_r;
    assign tlps_irq_out.tvalid   = tvalid_r;
    assign tlps_irq_out.tuser[0] = tuser_first_r;
    assign tlps_irq_out.tuser[1] = tlast_r;
    assign tlps_irq_out.tuser[8:2] = 7'h00;
    assign tlps_irq_out.has_data = tvalid_r;

endmodule


// ============================================================================
// ISR event injector — helper to drive isr_out from FPGA-side events
//
// Instantiate this in the top module to OR hardware events into BAR2's ISR.
// RTL8168 ISR bit definitions (16-bit):
//   bit15: SERR
//   bit14: TimeOut
//   bit13: LenChg
//   bit6:  RxFIFO Overflow
//   bit4:  RxDescUnavail
//   bit3:  TxErr
//   bit2:  TxOK
//   bit1:  RxErr
//   bit0:  RxOK
//
// Usage: assert isr_set[N] for 1 CLK to set bit N in isr_out.
// ============================================================================
module rtl8168_isr_event_injector(
    input               rst,
    input               clk,
    input [15:0]        isr_set,        // pulse high for 1 CLK to set ISR bits
    input [15:0]        isr_clear,      // from bar2_isr write-back (RW1C clears)
    output reg [15:0]   isr_out,        // ISR register value
    output reg          irq_req_v0      // pulse to interrupt_generator
);

    always @ (posedge clk) begin
        if (rst) begin
            isr_out    <= 16'h0;
            irq_req_v0 <= 1'b0;
        end else begin
            irq_req_v0 <= 1'b0;
            // RW1C clear (from BAR2 write)
            isr_out <= (isr_out & ~isr_clear) | isr_set;
            // Generate interrupt if any enabled ISR bit asserts
            if (isr_set != 16'h0)
                irq_req_v0 <= 1'b1;
        end
    end

endmodule
