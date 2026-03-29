//
// PCILeech FPGA — RTL8168 Private Firmware
//
// BAR Controller: RTL8168 emulation for Ducks 75T (Artix-7 XC7A75T)
//
// BAR layout (RTL8168 rev02):
//   BAR0 → I/O 256B       (not emulated, MMIO-only policy)
//   BAR2 → Mem64  4KB     (MMIO register space)
//   BAR4 → Mem64 64KB pref (MSI-X table + PBA)
//
// All read engines/write engines are unchanged from pcileech upstream.
// Only the BAR implementation instances and the new RTL8168 modules are custom.
//
// (c) private — RTL8168 emulation layer

`timescale 1ns / 1ps
`include "pcileech_header.svh"
`include "pcileech_bar_impl_rtl8168_io.sv"

// ============================================================================
// TOP-LEVEL BAR CONTROLLER (drop-in replacement)
// ============================================================================
module pcileech_tlps128_bar_controller(
    input                   rst,
    input                   clk,
    input                   bar_en,
    input [15:0]            pcie_id,
    IfAXIS128.sink_lite     tlps_in,
    IfAXIS128.source        tlps_out,
    // MSI-X vector outputs → connect to rtl8168_interrupt_generator
    output [31:0]           msix_v0_addr_lo,
    output [31:0]           msix_v0_addr_hi,
    output [31:0]           msix_v0_data,
    output                  msix_v0_masked,
    output [31:0]           msix_v1_addr_lo,
    output [31:0]           msix_v1_addr_hi,
    output [31:0]           msix_v1_data,
    output                  msix_v1_masked,
    // ISR register output (bit[15:0] = ISR value) → drive interrupt_generator
    output [15:0]           bar2_isr
);

    // ── RX: route incoming TLPs to read / write FIFOs ───────────────────────
    wire in_is_wr_ready;
    bit  in_is_wr_last;
    wire in_is_first    = tlps_in.tuser[0];
    wire in_is_bar      = bar_en && (tlps_in.tuser[8:2] != 0);
    wire in_is_rd       = (in_is_first && tlps_in.tlast &&
                           ((tlps_in.tdata[31:25] == 7'b0000000) ||
                            (tlps_in.tdata[31:25] == 7'b0010000) ||
                            (tlps_in.tdata[31:24] == 8'b00000010)));
    wire in_is_wr       = in_is_wr_last ||
                          (in_is_first && in_is_wr_ready &&
                           ((tlps_in.tdata[31:25] == 7'b0100000) ||
                            (tlps_in.tdata[31:25] == 7'b0110000) ||
                            (tlps_in.tdata[31:24] == 8'b01000010)));

    always @ (posedge clk)
        if (rst)            in_is_wr_last <= 0;
        else if (tlps_in.tvalid) in_is_wr_last <= !tlps_in.tlast && in_is_wr;

    wire [6:0]  wr_bar;
    wire [31:0] wr_addr;
    wire [3:0]  wr_be;
    wire [31:0] wr_data;
    wire        wr_valid;
    wire [87:0] rd_req_ctx;
    wire [6:0]  rd_req_bar;
    wire [31:0] rd_req_addr;
    wire        rd_req_valid;
    wire [87:0] rd_rsp_ctx;
    wire [31:0] rd_rsp_data;
    wire        rd_rsp_valid;

    pcileech_tlps128_bar_rdengine i_rdengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .pcie_id        ( pcie_id                       ),
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_rd ),
        .tlps_out       ( tlps_out                      ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_bar     ( rd_req_bar                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid                  ),
        .rd_rsp_ctx     ( rd_rsp_ctx                    ),
        .rd_rsp_data    ( rd_rsp_data                   ),
        .rd_rsp_valid   ( rd_rsp_valid                  )
    );

    pcileech_tlps128_bar_wrengine i_wrengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_wr ),
        .tlps_in_ready  ( in_is_wr_ready                ),
        .wr_bar         ( wr_bar                        ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid                      )
    );

    // ── BAR response mux ────────────────────────────────────────────────────
    wire [87:0] bar_rsp_ctx[7];
    wire [31:0] bar_rsp_data[7];
    wire        bar_rsp_valid[7];

    assign rd_rsp_ctx   = bar_rsp_valid[0] ? bar_rsp_ctx[0]  :
                          bar_rsp_valid[1] ? bar_rsp_ctx[1]  :
                          bar_rsp_valid[2] ? bar_rsp_ctx[2]  :
                          bar_rsp_valid[3] ? bar_rsp_ctx[3]  :
                          bar_rsp_valid[4] ? bar_rsp_ctx[4]  :
                          bar_rsp_valid[5] ? bar_rsp_ctx[5]  :
                          bar_rsp_valid[6] ? bar_rsp_ctx[6]  : 0;
    assign rd_rsp_data  = bar_rsp_valid[0] ? bar_rsp_data[0] :
                          bar_rsp_valid[1] ? bar_rsp_data[1] :
                          bar_rsp_valid[2] ? bar_rsp_data[2] :
                          bar_rsp_valid[3] ? bar_rsp_data[3] :
                          bar_rsp_valid[4] ? bar_rsp_data[4] :
                          bar_rsp_valid[5] ? bar_rsp_data[5] :
                          bar_rsp_valid[6] ? bar_rsp_data[6] : 0;
    assign rd_rsp_valid = |{bar_rsp_valid[6], bar_rsp_valid[5], bar_rsp_valid[4],
                             bar_rsp_valid[3], bar_rsp_valid[2], bar_rsp_valid[1],
                             bar_rsp_valid[0]};

    // BAR0 — I/O 256B: mirror the same RTL8168 register semantics as BAR2.
    // The Windows driver can probe either path during early init, so BAR0 must
    // at least answer the core reset / MAC / PHY / ERI accesses.
    pcileech_bar_impl_rtl8168_io i_bar0(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[0]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[0] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[0]                ),
        .rd_rsp_data    ( bar_rsp_data[0]               ),
        .rd_rsp_valid   ( bar_rsp_valid[0]              )
    );

    // BAR1 — not used (64-bit upper of BAR0)
    pcileech_bar_impl_none i_bar1(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[1]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[1] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[1]                ),
        .rd_rsp_data    ( bar_rsp_data[1]               ),
        .rd_rsp_valid   ( bar_rsp_valid[1]              )
    );

    // BAR2 — Mem64 4KB MMIO register space
    pcileech_bar_impl_rtl8168_mmio i_bar2(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[2]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[2] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[2]                ),
        .rd_rsp_data    ( bar_rsp_data[2]               ),
        .rd_rsp_valid   ( bar_rsp_valid[2]              ),
        .isr_out        ( bar2_isr                      )
    );

    // BAR3 — not used (upper 32 bits of BAR2 64-bit)
    pcileech_bar_impl_none i_bar3(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[3]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[3] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[3]                ),
        .rd_rsp_data    ( bar_rsp_data[3]               ),
        .rd_rsp_valid   ( bar_rsp_valid[3]              )
    );

    // BAR4 — Mem64 64KB prefetchable: MSI-X table + PBA
    pcileech_bar_impl_rtl8168_msix i_bar4(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[4]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[4] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[4]                ),
        .rd_rsp_data    ( bar_rsp_data[4]               ),
        .rd_rsp_valid   ( bar_rsp_valid[4]              ),
        // MSI-X vector info for interrupt generator
        .v0_addr_lo     ( msix_v0_addr_lo               ),
        .v0_addr_hi     ( msix_v0_addr_hi               ),
        .v0_data        ( msix_v0_data                  ),
        .v0_masked      ( msix_v0_masked                ),
        .v1_addr_lo     ( msix_v1_addr_lo               ),
        .v1_addr_hi     ( msix_v1_addr_hi               ),
        .v1_data        ( msix_v1_data                  ),
        .v1_masked      ( msix_v1_masked                )
    );

    // BAR5 — not used (upper 32 bits of BAR4 64-bit)
    pcileech_bar_impl_none i_bar5(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[5]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[5] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[5]                ),
        .rd_rsp_data    ( bar_rsp_data[5]               ),
        .rd_rsp_valid   ( bar_rsp_valid[5]              )
    );

    // BAR6 — ROM (not present on RTL8168)
    pcileech_bar_impl_none i_bar6_optrom(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[6]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[6] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[6]                ),
        .rd_rsp_data    ( bar_rsp_data[6]               ),
        .rd_rsp_valid   ( bar_rsp_valid[6]              )
    );

endmodule


// ============================================================================
// BAR2 — RTL8168 MMIO register space (4KB)
//
// Implementation: BRAM-backed 4KB R/W store with special-register overrides.
// The bram_bar_zero4k IP holds all register state; shadow registers intercept
// specific offsets to provide RTL8168-correct behaviour so that the Windows
// inbox rt640x64 driver initialises without error.
//
// Flag-toggle protocol (shared by PHYAR/CSIAR/ERIAR/EPHYAR/OCPAR):
//   Write command: host writes bit31=1 → FPGA clears bit31=0 after ~7 cycles
//   Read  command: host writes bit31=0 → FPGA sets  bit31=1 after ~7 cycles
//                  (read data also placed in register or separate data reg)
//
// Special register map (BAR2 byte offset → DWORD index):
//   0x37 / 0x0D  ChipCmd    RST bit (bit4) auto-clears after ~7 cycles
//   0x3E / 0x0F  ISR        RW1C shadow; reads return isr_out (not BRAM)
//   0x60 / 0x18  PHYAR      flag-toggle; read data = 0xFFFF in [15:0]
//   0x68 / 0x1A  CSIAR      flag-toggle; read data from ERIDR/CSIDR (BRAM 0x64)
//   0x6C / 0x1B  PHYstatus  return BRAM snapshot value (real dump: 0xFF800100)
//   0x70 / 0x1C  ERIAR      flag-toggle; read data from ERIDR/CSIDR (BRAM 0x64)
//   0x80 / 0x20  EPHYAR     flag-toggle; read data = 0xFFFF in [15:0]
//   0xB4 / 0x2D  OCPAR      flag-toggle; read data from OCPDR (BRAM 0xB0)
//
// Data registers returned from BRAM (default 0):
//   0x64 / 0x19  ERIDR/CSIDR   ERI and CSI read data
//   0xB0 / 0x2C  OCPDR         OCP read data
//
// Byte ordering within DWORD: data[7:0] = lowest byte address (little-endian).
// Latency = 2 CLKs (matches pcileech_bar_impl_zerowrite4k).
// ============================================================================
module pcileech_bar_impl_rtl8168_mmio(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid,
    // ISR register mirror for interrupt generator
    output reg [15:0]   isr_out
);

    // ── BRAM: bram_bar_zero4k, pre-loaded with RTL8168 register defaults ─────
    wire [31:0] doutb;
    bram_bar_zero4k i_bram_mmio(
        .addra  ( wr_addr[11:2]     ),
        .clka   ( clk               ),
        .dina   ( wr_data           ),
        .ena    ( wr_valid          ),
        .wea    ( wr_be             ),
        .addrb  ( rd_req_addr[11:2] ),
        .clkb   ( clk               ),
        .doutb  ( doutb             ),
        .enb    ( rd_req_valid      )
    );

    // ── Write address decode ─────────────────────────────────────────────────
    wire [9:0] wr_dw = wr_addr[11:2];

    wire chipcmd_wr = wr_valid && (wr_dw == 10'h00D) && wr_be[3]; // CR  byte3
    wire isr_wr     = wr_valid && (wr_dw == 10'h00F);              // ISR DW
    wire phyar_wr   = wr_valid && (wr_dw == 10'h018);              // PHYAR
    wire csiar_wr   = wr_valid && (wr_dw == 10'h01A);              // CSIAR
    wire eriar_wr   = wr_valid && (wr_dw == 10'h01C);              // ERIAR
    wire ephyar_wr  = wr_valid && (wr_dw == 10'h020);              // EPHYAR
    wire ocpar_wr   = wr_valid && (wr_dw == 10'h02D);              // OCPAR

    // ── ChipCmd shadow — RST bit (bit4 of byte = bit28 of DWORD) auto-clears ─
    reg [7:0] chipcmd;
    reg [2:0] chipcmd_cnt;

    always @ (posedge clk) begin
        if (rst) begin
            // Reset state taken from real RTL8168 BAR2 snapshot: 0x034 = 0x00000000.
            chipcmd <= 8'h00; chipcmd_cnt <= 3'd0;
        end else if (chipcmd_wr) begin
            chipcmd     <= wr_data[31:24];
            chipcmd_cnt <= wr_data[28] ? 3'd7 : 3'd0;
        end else if (chipcmd_cnt != 3'd0) begin
            chipcmd_cnt <= chipcmd_cnt - 3'd1;
            if (chipcmd_cnt == 3'd1) chipcmd[4] <= 1'b0;
        end
    end

    // ── ISR shadow — RW1C ────────────────────────────────────────────────────
    // DWORD 0x0F: data[23:16]=ISR[7:0] (0x3E), data[31:24]=ISR[15:8] (0x3F)
    always @ (posedge clk) begin
        if (rst) begin
            isr_out <= 16'h0000;
        end else if (isr_wr) begin
            if (wr_be[2]) isr_out[7:0]  <= isr_out[7:0]  & ~wr_data[23:16];
            if (wr_be[3]) isr_out[15:8] <= isr_out[15:8] & ~wr_data[31:24];
        end
    end

    // ── Flag-toggle shadow: PHYAR (0x60 / DWORD 0x18) ───────────────────────
    // PHY register address is in bits[20:16] of the PHYAR write command.
    // On read completion, return per-register values so that:
    //   - Reg 0 bit15 = 0  (no Reset-in-progress → driver does not spin)
    //   - Reg 1 bit2  = 1  (Link Status UP)
    //   - Reg 1 bit3  = 1  (AN Able)
    //   - Reg 1 bit5  = 1  (AN Complete)
    //   - Reg 2/3 carry RTL8211 PHY ID
    reg [31:0] phyar;
    reg [2:0]  phyar_cnt;
    reg        phyar_rd;

    always @ (posedge clk) begin
        if (rst) begin
            // Reset state taken from real RTL8168 BAR2 snapshot: 0x060 = 0x800A0000.
            phyar <= 32'h800A0000; phyar_cnt <= 0; phyar_rd <= 0;
        end else if (phyar_wr) begin
            if (wr_be[0]) phyar[7:0]   <= wr_data[7:0];
            if (wr_be[1]) phyar[15:8]  <= wr_data[15:8];
            if (wr_be[2]) phyar[23:16] <= wr_data[23:16];
            if (wr_be[3]) phyar[31:24] <= wr_data[31:24];
            if (wr_be[3]) begin phyar_cnt <= 3'd7; phyar_rd <= ~wr_data[31]; end
        end else if (phyar_cnt != 0) begin
            phyar_cnt <= phyar_cnt - 3'd1;
            if (phyar_cnt == 3'd1) begin
                phyar[31] <= phyar_rd;
                if (phyar_rd) begin
                    // Per-register PHY values (RTL8168c / RTL8211B-compatible)
                    case (phyar[20:16])
                        5'd0:  phyar[15:0] <= 16'h1140; // Basic Ctrl: AN, FD, 1000M, no Reset
                        5'd1:  phyar[15:0] <= 16'h782D; // Basic Status: link up, AN complete, AN able
                        5'd2:  phyar[15:0] <= 16'h001C; // PHY ID 1 (Realtek OUI)
                        5'd3:  phyar[15:0] <= 16'hC912; // PHY ID 2 (RTL8211)
                        5'd4:  phyar[15:0] <= 16'h01E1; // AN Advertisement (100/10T)
                        5'd5:  phyar[15:0] <= 16'h41E1; // Link Partner Ability (+ ACK)
                        5'd6:  phyar[15:0] <= 16'h0007; // AN Expansion
                        5'd9:  phyar[15:0] <= 16'h0300; // 1000BT Control (advertise FD+HD)
                        5'd10: phyar[15:0] <= 16'h2800; // 1000BT Status (LP: 1000T FD)
                        default: phyar[15:0] <= 16'h0000;
                    endcase
                end
            end
        end
    end

    // ── Flag-toggle shadow: CSIAR (0x68 / DWORD 0x1A) ───────────────────────
    // Data register: CSIDR shares address 0x64 with ERIDR (BRAM passthrough)
    reg [31:0] csiar;
    reg [2:0]  csiar_cnt;
    reg        csiar_rd;

    always @ (posedge clk) begin
        if (rst) begin
            csiar <= 0; csiar_cnt <= 0; csiar_rd <= 0;
        end else if (csiar_wr) begin
            if (wr_be[0]) csiar[7:0]   <= wr_data[7:0];
            if (wr_be[1]) csiar[15:8]  <= wr_data[15:8];
            if (wr_be[2]) csiar[23:16] <= wr_data[23:16];
            if (wr_be[3]) csiar[31:24] <= wr_data[31:24];
            if (wr_be[3]) begin csiar_cnt <= 3'd7; csiar_rd <= ~wr_data[31]; end
        end else if (csiar_cnt != 0) begin
            csiar_cnt <= csiar_cnt - 3'd1;
            if (csiar_cnt == 3'd1) csiar[31] <= csiar_rd;
        end
    end

    // ── Flag-toggle shadow: ERIAR (0x70 / DWORD 0x1C) ───────────────────────
    // Data register: ERIDR at 0x64 / DWORD 0x19 (shadow, address-decoded).
    //
    // ERI address is in ERIAR bits[11:0].  On read-toggle completion, eridr_shadow
    // is updated with the value appropriate for that address, so the driver reads
    // the correct data from ERIDR (0x64) after the flag clears.
    //
    // ERI MAC backup (EXGMAC type, RTL8168c):
    //   addr 0xE0 → MAC[0:3] = 00:E0:4C:68  → 0x684CE000 (little-endian DWORD)
    //   addr 0xE4 → MAC[4:5] = 11:4E        → 0x00004E11
    reg [31:0] eriar;
    reg [2:0]  eriar_cnt;
    reg        eriar_rd;
    reg [11:0] eriar_addr;   // ERI address captured from write command
    reg [31:0] eridr_shadow; // ERIDR value updated on each read completion

    always @ (posedge clk) begin
        if (rst) begin
            eriar <= 0; eriar_cnt <= 0; eriar_rd <= 0;
            eriar_addr <= 0; eridr_shadow <= 0;
        end else if (eriar_wr) begin
            if (wr_be[0]) eriar[7:0]   <= wr_data[7:0];
            if (wr_be[1]) eriar[15:8]  <= wr_data[15:8];
            if (wr_be[2]) eriar[23:16] <= wr_data[23:16];
            if (wr_be[3]) eriar[31:24] <= wr_data[31:24];
            if (wr_be[3]) begin eriar_cnt <= 3'd7; eriar_rd <= ~wr_data[31]; end
            eriar_addr <= wr_data[11:0]; // capture ERI address on every ERIAR write
        end else if (eriar_cnt != 0) begin
            eriar_cnt <= eriar_cnt - 3'd1;
            if (eriar_cnt == 3'd1) begin
                eriar[31] <= eriar_rd;
                if (eriar_rd) begin
                    // Populate ERIDR with per-address data so driver reads correct values
                    case (eriar_addr)
                        12'hE0: eridr_shadow <= 32'h684CE000; // MAC[0:3]: 00:E0:4C:68
                        12'hE4: eridr_shadow <= 32'h00004E11; // MAC[4:5]: 11:4E
                        default: eridr_shadow <= 32'h00000000;
                    endcase
                end
            end
        end
    end

    // ── Flag-toggle shadow: EPHYAR (0x80 / DWORD 0x20) ──────────────────────
    // External PHY access register; read data in [15:0] = 0xFFFF
    reg [31:0] ephyar;
    reg [2:0]  ephyar_cnt;
    reg        ephyar_rd;

    always @ (posedge clk) begin
        if (rst) begin
            // Reset state taken from real RTL8168 BAR2 snapshot: 0x080 = 0x00008E9C.
            ephyar <= 32'h00008E9C; ephyar_cnt <= 0; ephyar_rd <= 0;
        end else if (ephyar_wr) begin
            if (wr_be[0]) ephyar[7:0]   <= wr_data[7:0];
            if (wr_be[1]) ephyar[15:8]  <= wr_data[15:8];
            if (wr_be[2]) ephyar[23:16] <= wr_data[23:16];
            if (wr_be[3]) ephyar[31:24] <= wr_data[31:24];
            if (wr_be[3]) begin ephyar_cnt <= 3'd7; ephyar_rd <= ~wr_data[31]; end
        end else if (ephyar_cnt != 0) begin
            ephyar_cnt <= ephyar_cnt - 3'd1;
            if (ephyar_cnt == 3'd1) begin
                ephyar[31] <= ephyar_rd;
                // Return 0x0000 for EPHY reads: driver uses R/M/W so 0 is the correct base
                if (ephyar_rd) ephyar[15:0] <= 16'h0000;
            end
        end
    end

    // ── Flag-toggle shadow: OCPAR (0xB4 / DWORD 0x2D) ───────────────────────
    // OCP access register; data in OCPDR at 0xB0 / DWORD 0x2C (BRAM, returns 0)
    reg [31:0] ocpar;
    reg [2:0]  ocpar_cnt;
    reg        ocpar_rd;

    always @ (posedge clk) begin
        if (rst) begin
            ocpar <= 0; ocpar_cnt <= 0; ocpar_rd <= 0;
        end else if (ocpar_wr) begin
            if (wr_be[0]) ocpar[7:0]   <= wr_data[7:0];
            if (wr_be[1]) ocpar[15:8]  <= wr_data[15:8];
            if (wr_be[2]) ocpar[23:16] <= wr_data[23:16];
            if (wr_be[3]) ocpar[31:24] <= wr_data[31:24];
            if (wr_be[3]) begin ocpar_cnt <= 3'd7; ocpar_rd <= ~wr_data[31]; end
        end else if (ocpar_cnt != 0) begin
            ocpar_cnt <= ocpar_cnt - 3'd1;
            if (ocpar_cnt == 3'd1) ocpar[31] <= ocpar_rd;
        end
    end

    // ── Read pipeline — 2 stages, address tracked for override ───────────────
    bit [87:0] s1_ctx;
    bit        s1_valid;
    bit [9:0]  s1_dw;
    wire [31:0] rd_rsp_data_mux =
        (s1_dw == 10'h00D) ? {chipcmd,       doutb[23:0]} :
        (s1_dw == 10'h00F) ? {isr_out,       doutb[15:0]} :
        (s1_dw == 10'h018) ? phyar :
        (s1_dw == 10'h019) ? eridr_shadow :   // ERIDR (0x64): per-ERI-addr lookup
        (s1_dw == 10'h01A) ? csiar :
        (s1_dw == 10'h01B) ? doutb :
        (s1_dw == 10'h01C) ? eriar :
        (s1_dw == 10'h020) ? ephyar :
        (s1_dw == 10'h02D) ? ocpar :
                             doutb;

    always @ (posedge clk) begin
        // Stage 1: latch
        s1_ctx   <= rd_req_ctx;
        s1_valid <= rd_req_valid;
        s1_dw    <= rd_req_addr[11:2];

        // Stage 2: output — s1_dw and doutb are aligned to the same cycle-N request
        rd_rsp_ctx   <= s1_ctx;
        rd_rsp_valid <= s1_valid;
        rd_rsp_data  <= rd_rsp_data_mux;
    end

endmodule


// ============================================================================
// BAR4 — RTL8168 MSI-X table (2 vectors) + PBA
//
// MSI-X table layout (PCIe spec, 16 bytes / vector):
//   VecN offset 0x00: Message Address Low
//   VecN offset 0x04: Message Address High
//   VecN offset 0x08: Message Data
//   VecN offset 0x0C: Vector Control (bit0 = Masked)
//
// Vector 0: BAR4+0x000–0x00F
// Vector 1: BAR4+0x010–0x01F
// PBA:      BAR4+0x800–0x803  (1 DWORD, bit0=v0 pending, bit1=v1 pending)
//
// All other BAR4 offsets return 0xFFFFFFFF (reserved / unclaimed).
// Latency = 2 CLKs.
// ============================================================================
module pcileech_bar_impl_rtl8168_msix(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid,
    // MSI-X vector info for interrupt generator (LE byte order, as stored)
    output reg [31:0]   v0_addr_lo,
    output reg [31:0]   v0_addr_hi,
    output reg [31:0]   v0_data,
    output              v0_masked,
    output reg [31:0]   v1_addr_lo,
    output reg [31:0]   v1_addr_hi,
    output reg [31:0]   v1_data,
    output              v1_masked
);

    // ── MSI-X table registers (LE, as delivered by write engine) ────────────
    reg [31:0] v0_ctrl;   // bit0 = masked; host writes 1 to mask, 0 to unmask
    reg [31:0] v1_ctrl;
    reg [31:0] pba;       // pending bit array: bit0=v0, bit1=v1

    assign v0_masked = v0_ctrl[0];
    assign v1_masked = v1_ctrl[0];

    // ── Write handler ────────────────────────────────────────────────────────
    // BAR4 address bits [15:2] select the DWORD within 64KB space.
    wire [15:2] dw_idx = wr_addr[15:2];

    always @ (posedge clk) begin
        if (rst) begin
            v0_addr_lo <= 32'h0;
            v0_addr_hi <= 32'h0;
            v0_data    <= 32'h0;
            v0_ctrl    <= 32'h1;      // masked at reset
            v1_addr_lo <= 32'h0;
            v1_addr_hi <= 32'h0;
            v1_data    <= 32'h0;
            v1_ctrl    <= 32'h1;      // masked at reset
            pba        <= 32'h0;
        end else if (wr_valid) begin
            case (dw_idx)
                // Vector 0
                14'h000: v0_addr_lo <= apply_be(v0_addr_lo, wr_data, wr_be);
                14'h001: v0_addr_hi <= apply_be(v0_addr_hi, wr_data, wr_be);
                14'h002: v0_data    <= apply_be(v0_data,    wr_data, wr_be);
                14'h003: v0_ctrl    <= apply_be(v0_ctrl,    wr_data, wr_be);
                // Vector 1
                14'h004: v1_addr_lo <= apply_be(v1_addr_lo, wr_data, wr_be);
                14'h005: v1_addr_hi <= apply_be(v1_addr_hi, wr_data, wr_be);
                14'h006: v1_data    <= apply_be(v1_data,    wr_data, wr_be);
                14'h007: v1_ctrl    <= apply_be(v1_ctrl,    wr_data, wr_be);
                // PBA (RO from host perspective; FPGA clears on ACK)
                14'h200: pba        <= apply_be(pba,        wr_data, wr_be);
                default: ; // ignore writes to undefined offsets
            endcase
        end
    end

    // ── Read handler (2-stage pipeline) ─────────────────────────────────────
    bit [87:0]  rd_ctx_r;
    bit         rd_valid_r;
    bit [31:0]  rd_data_r;

    wire [31:0] rd_raw;
    wire [15:2] rd_dw = rd_req_addr[15:2];

    assign rd_raw =
        (rd_dw == 14'h000) ? v0_addr_lo :
        (rd_dw == 14'h001) ? v0_addr_hi :
        (rd_dw == 14'h002) ? v0_data    :
        (rd_dw == 14'h003) ? v0_ctrl    :
        (rd_dw == 14'h004) ? v1_addr_lo :
        (rd_dw == 14'h005) ? v1_addr_hi :
        (rd_dw == 14'h006) ? v1_data    :
        (rd_dw == 14'h007) ? v1_ctrl    :
        (rd_dw == 14'h200) ? pba        :
        32'hFFFFFFFF;   // all other offsets: reserved

    always @ (posedge clk) begin
        rd_ctx_r   <= rd_req_ctx;
        rd_valid_r <= rd_req_valid;
        rd_data_r  <= rd_raw;
        rd_rsp_ctx   <= rd_ctx_r;
        rd_rsp_valid <= rd_valid_r;
        rd_rsp_data  <= rd_data_r;
    end

    // ── Byte-enable apply helper ─────────────────────────────────────────────
    function automatic [31:0] apply_be;
        input [31:0] old_val, new_val;
        input [3:0]  be;
        begin
            apply_be[7:0]   = be[0] ? new_val[7:0]   : old_val[7:0];
            apply_be[15:8]  = be[1] ? new_val[15:8]  : old_val[15:8];
            apply_be[23:16] = be[2] ? new_val[23:16] : old_val[23:16];
            apply_be[31:24] = be[3] ? new_val[31:24] : old_val[31:24];
        end
    endfunction

endmodule
