module pcileech_bar_impl_rtl8168_io(
    input               rst,
    input               clk,
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    // MAC Address Registers (0x00-0x05)
    localparam [31:0] MAC0_RST      = 32'h684CE000;  // MAC[3:0]
    localparam [31:0] MAC1_RST      = 32'h00004E11;  // MAC[5:4]

    // Configuration Registers
    localparam [31:0] TXCFG_RST     = 32'h03000700;  // TxConfig
    localparam [31:0] RXCFG_RST     = 32'h0000E70F;  // RxConfig
    localparam [31:0] CFG_DW_RST    = 32'h1CDF0000;  // Cfg9346 + Config0-7
    localparam [31:0] PHYSTATUS_RST = 32'hFF800100;  // PHYstatus
    localparam [31:0] RMS_RST       = 32'h40000000;  // RMS (0xDA-0xDB)
    localparam [31:0] CPLCR_RST     = 32'h00002060;  // C+Command Register
    localparam [31:0] E4_RST        = 32'h140A7000;  // EPHYAR / ERIDR
    localparam [31:0] E8_RST        = 32'h00000001;  // RxDescAddrHigh
    localparam [31:0] MTPS_RST      = 32'h0000003F;  // MTPS

    // ======================== MAC & Basic Registers ========================
    bit [31:0] mac0 = MAC0_RST;
    bit [31:0] mac1 = MAC1_RST;

    // ======================== Interrupt Registers (0x3C-0x3F) ========================
    bit [15:0] intr_mask = 16'h0000;
    bit [15:0] intr_status = 16'h0000;

    // ======================== Transmit Descriptor Registers (0x20-0x2F) ========================
    bit [31:0] tnpds_low = 32'h00000000;   // TNPDS Low (0x20)
    bit [31:0] tnpds_high = 32'h00000000;  // TNPDS High (0x24)
    bit [31:0] thpds_low = 32'h00000000;   // THPDS Low (0x28)
    bit [31:0] thpds_high = 32'h00000000;  // THPDS High (0x2C)

    // ======================== Multicast Filter Registers (0x08, 0x0C) ========================
    bit [31:0] mar0 = 32'h00000000;
    bit [31:0] mar4 = 32'h00000000;

    // ======================== Statistics Counters (0x10-0x14) ========================
    bit [31:0] counter_addr_low = 32'h00000000;
    bit [31:0] counter_addr_high = 32'h00000000;

    // ======================== Flash/EEPROM Registers (0x30-0x36) ========================
    bit [31:0] flash_reg = 32'h00000000;
    bit [7:0]  ersr = 8'h00;

    // ======================== ChipCmd Register (0x37) ========================
    bit [7:0]  chipcmd = 8'h00;
    bit [2:0]  chipcmd_cnt;

    // ======================== TxPoll Register (0x38) ========================
    bit [7:0]  txpoll = 8'h00;

    // ======================== Tx/Rx Config Registers ========================
    bit [31:0] txconfig = TXCFG_RST;
    bit [31:0] rxconfig = RXCFG_RST;

    // ======================== Configuration/Lock Registers (0x50-0x58) ========================
    bit [7:0]  cfg9346 = 8'h00;    // EEPROM Command Register
    bit [7:0]  config0 = 8'h00;    // Config Register 0
    bit [7:0]  config1 = 8'h00;    // Config Register 1
    bit [7:0]  config2 = 8'h00;    // Config Register 2
    bit [7:0]  config3 = 8'h00;    // Config Register 3
    bit [7:0]  config4 = 8'h00;    // Config Register 4
    bit [7:0]  config5 = 8'h00;    // Config Register 5
    bit [7:0]  config6 = 8'h00;    // Config Register 6
    bit [7:0]  config7 = 8'h00;    // Config Register 7

    // ======================== PHY & Extended Registers ========================
    bit [31:0] phyar = 32'h800A0000;
    bit [2:0]  phyar_cnt;
    bit        phyar_rd;

    bit [31:0] pmch = 32'h00000000;   // Power control (0x61)
    bit [7:0]  gpio_pin = 8'h00;      // GPIO control (0x62)

    bit [31:0] csiar = 32'h00000000;
    bit [2:0]  csiar_cnt;
    bit        csiar_rd;

    bit [31:0] eriar = 32'h00000000;
    bit [2:0]  eriar_cnt;
    bit        eriar_rd;
    bit [11:0] eriar_addr;
    bit [31:0] eridr_shadow = 32'h00000000;

    bit [31:0] ephyar = 32'h00008E9C;
    bit [2:0]  ephyar_cnt;
    bit        ephyar_rd;

    // ======================== OCP Registers (0x78-0x7C) ========================
    bit [31:0] ocpdr = 32'h00000000;   // OCP Data Register
    bit [31:0] ocpar = 32'h00000000;   // OCP Address Register

    // ======================== Interrupt Mitigation & Timing (0xD4-0xD5) ========================
    bit [7:0]  time_int = 8'h00;       // Time interval (0xD4)
    bit [7:0]  tx_timer_int = 8'h00;   // Tx timer (0xD5)

    // ======================== Rx/Tx Max Size & RMS (0xDA-0xDB, 0xEC) ========================
    bit [15:0] rms = 16'h3FFF;

    // ======================== C+ Command Register (0xE0-0xE1) ========================
    bit [31:0] cpluscr = CPLCR_RST;

    // ======================== Interrupt Mitigation (0xE2-0xE3) ========================
    bit [15:0] intr_mitigate = 16'h0000;

    // ======================== Rx Descriptor Addresses (0xE4-0xE8) ========================
    bit [31:0] rxdesc_addr_low = 32'h00000000;   // RxDescAddrLow (0xE4)
    bit [31:0] rxdesc_addr_high = 32'h00000000;  // RxDescAddrHigh (0xE8)

    // ======================== Early Transmit Threshold (0xED) ========================
    bit [7:0]  etthr = 8'h00;

    // ======================== MTPS Register (0xEC) ========================
    bit [15:0] mtps = 16'h0800;

    // ======================== VLAN Tag Register (0x80-0x81) ========================
    bit [15:0] vlan_tag = 16'h0000;

    // ======================== Out-of-Band Control (0x90-0x98) ========================
    bit [31:0] oob_sig = 32'h00000000;    // OOB Signal (0x90)
    bit [31:0] oob_ctrl = 32'h00000000;   // OOB Control (0x94)
    bit [31:0] oob_base = 32'h00000000;   // OOB Base (0x98)

    wire [7:0] rd_dw_off = rd_req_addr[7:0];
    wire [7:0] wr_dw_off = wr_addr[7:0];

    // ======================== Write Condition Signals ========================
    wire mac0_wr        = wr_valid && (wr_dw_off == 8'h00);
    wire mac1_wr        = wr_valid && (wr_dw_off == 8'h04);
    wire mar0_wr        = wr_valid && (wr_dw_off == 8'h08);
    wire mar4_wr        = wr_valid && (wr_dw_off == 8'h0C);
    wire counter_low_wr = wr_valid && (wr_dw_off == 8'h10);
    wire counter_high_wr= wr_valid && (wr_dw_off == 8'h14);
    wire tnpds_low_wr   = wr_valid && (wr_dw_off == 8'h20);
    wire tnpds_high_wr  = wr_valid && (wr_dw_off == 8'h24);
    wire thpds_low_wr   = wr_valid && (wr_dw_off == 8'h28);
    wire thpds_high_wr  = wr_valid && (wr_dw_off == 8'h2C);
    wire flash_wr       = wr_valid && (wr_dw_off == 8'h30);
    wire ersr_wr        = wr_valid && (wr_dw_off == 8'h36);
    wire chipcmd_wr     = wr_valid && (wr_dw_off == 8'h34) && wr_be[3];
    wire txpoll_wr      = wr_valid && (wr_dw_off == 8'h38);
    wire intr_mask_wr   = wr_valid && (wr_dw_off == 8'h3C);
    wire intr_status_wr = wr_valid && (wr_dw_off == 8'h3E);
    wire txcfg_wr       = wr_valid && (wr_dw_off == 8'h40);
    wire rxcfg_wr       = wr_valid && (wr_dw_off == 8'h44);
    wire cfg9346_wr     = wr_valid && (wr_dw_off == 8'h50);
    wire config_wr      = wr_valid && (wr_dw_off[7:3] == 5'b01010) && (wr_dw_off[2:0] >= 3'b001);
    wire phyar_wr       = wr_valid && (wr_dw_off == 8'h60);
    wire pmch_wr        = wr_valid && (wr_dw_off == 8'h61);
    wire gpio_wr        = wr_valid && (wr_dw_off == 8'h62);
    wire csiar_wr       = wr_valid && (wr_dw_off == 8'h68);
    wire eriar_wr       = wr_valid && ((wr_dw_off == 8'h70) || (wr_dw_off == 8'h74));
    wire ocpdr_wr       = wr_valid && (wr_dw_off == 8'h78);
    wire ocpar_wr       = wr_valid && (wr_dw_off == 8'h7C);
    wire ephyar_wr      = wr_valid && (wr_dw_off == 8'h80);
    wire time_int_wr    = wr_valid && (wr_dw_off == 8'hD4);
    wire rms_wr         = wr_valid && (wr_dw_off == 8'hDA);
    wire intr_mit_wr    = wr_valid && (wr_dw_off == 8'hE2);
    wire cplus_wr       = wr_valid && (wr_dw_off == 8'hE0);
    wire rxdesc_low_wr  = wr_valid && (wr_dw_off == 8'hE4);
    wire rxdesc_high_wr = wr_valid && (wr_dw_off == 8'hE8);
    wire etthr_wr       = wr_valid && (wr_dw_off == 8'hED);
    wire mtps_wr        = wr_valid && (wr_dw_off == 8'hEC);
    wire vlan_tag_wr    = wr_valid && (wr_dw_off == 8'hC0);
    wire oob_sig_wr     = wr_valid && (wr_dw_off == 8'h90);
    wire oob_ctrl_wr    = wr_valid && (wr_dw_off == 8'h94);
    wire oob_base_wr    = wr_valid && (wr_dw_off == 8'h98);

    always @ (posedge clk) begin
        if (rst) begin
            // MAC Registers
            mac0              <= MAC0_RST;
            mac1              <= MAC1_RST;

            // Interrupt Registers
            intr_mask         <= 16'h0000;
            intr_status       <= 16'h0000;

            // Transmit Descriptor Registers
            tnpds_low         <= 32'h00000000;
            tnpds_high        <= 32'h00000000;
            thpds_low         <= 32'h00000000;
            thpds_high        <= 32'h00000000;

            // Multicast Registers
            mar0              <= 32'h00000000;
            mar4              <= 32'h00000000;

            // Statistics Registers
            counter_addr_low  <= 32'h00000000;
            counter_addr_high <= 32'h00000000;

            // Flash/EEPROM Registers
            flash_reg         <= 32'h00000000;
            ersr              <= 8'h00;

            // Chip Command
            chipcmd           <= 8'h00;
            chipcmd_cnt       <= 0;

            // TxPoll
            txpoll            <= 8'h00;

            // Tx/Rx Configuration
            txconfig          <= TXCFG_RST;
            rxconfig          <= RXCFG_RST;

            // Config Registers
            cfg9346           <= 8'h00;
            config0           <= 8'h00;
            config1           <= 8'h00;
            config2           <= 8'h00;
            config3           <= 8'h00;
            config4           <= 8'h00;
            config5           <= 8'h00;
            config6           <= 8'h00;
            config7           <= 8'h00;

            // PHY Registers
            phyar             <= 32'h800A0000;
            phyar_cnt         <= 0;
            phyar_rd          <= 0;
            pmch              <= 32'h00000000;
            gpio_pin          <= 8'h00;

            // Extended Interface Registers
            csiar             <= 32'h00000000;
            csiar_cnt         <= 0;
            csiar_rd          <= 0;
            eriar             <= 32'h00000000;
            eriar_cnt         <= 0;
            eriar_rd          <= 0;
            eriar_addr        <= 12'h000;
            eridr_shadow      <= 32'h00000000;
            ephyar            <= 32'h00008E9C;
            ephyar_cnt        <= 0;
            ephyar_rd         <= 0;

            // OCP Registers
            ocpdr             <= 32'h00000000;
            ocpar             <= 32'h00000000;

            // Timing Registers
            time_int          <= 8'h00;
            tx_timer_int      <= 8'h00;

            // Rx/Tx Size Registers
            rms               <= 16'h3FFF;
            mtps              <= 16'h0800;

            // C+ Command
            cpluscr           <= CPLCR_RST;

            // Interrupt Mitigation
            intr_mitigate     <= 16'h0000;

            // Rx Descriptor Registers
            rxdesc_addr_low   <= 32'h00000000;
            rxdesc_addr_high  <= 32'h00000000;

            // Early Transmit Threshold
            etthr             <= 8'h00;

            // VLAN Tag
            vlan_tag          <= 16'h0000;

            // Out-of-Band Registers
            oob_sig           <= 32'h00000000;
            oob_ctrl          <= 32'h00000000;
            oob_base          <= 32'h00000000;
        end else begin
            // ================== MAC Registers (0x00-0x05) ==================
            if (mac0_wr) begin
                if (wr_be[0]) mac0[7:0]   <= wr_data[7:0];
                if (wr_be[1]) mac0[15:8]  <= wr_data[15:8];
                if (wr_be[2]) mac0[23:16] <= wr_data[23:16];
                if (wr_be[3]) mac0[31:24] <= wr_data[31:24];
            end
            if (mac1_wr) begin
                if (wr_be[0]) mac1[7:0]   <= wr_data[7:0];
                if (wr_be[1]) mac1[15:8]  <= wr_data[15:8];
                if (wr_be[2]) mac1[23:16] <= wr_data[23:16];
                if (wr_be[3]) mac1[31:24] <= wr_data[31:24];
            end

            // ================== Multicast Filters (0x08, 0x0C) ==================
            if (mar0_wr) begin
                if (wr_be[0]) mar0[7:0]   <= wr_data[7:0];
                if (wr_be[1]) mar0[15:8]  <= wr_data[15:8];
                if (wr_be[2]) mar0[23:16] <= wr_data[23:16];
                if (wr_be[3]) mar0[31:24] <= wr_data[31:24];
            end
            if (mar4_wr) begin
                if (wr_be[0]) mar4[7:0]   <= wr_data[7:0];
                if (wr_be[1]) mar4[15:8]  <= wr_data[15:8];
                if (wr_be[2]) mar4[23:16] <= wr_data[23:16];
                if (wr_be[3]) mar4[31:24] <= wr_data[31:24];
            end

            // ================== Statistics Counters (0x10-0x14) ==================
            if (counter_low_wr) begin
                if (wr_be[0]) counter_addr_low[7:0]   <= wr_data[7:0];
                if (wr_be[1]) counter_addr_low[15:8]  <= wr_data[15:8];
                if (wr_be[2]) counter_addr_low[23:16] <= wr_data[23:16];
                if (wr_be[3]) counter_addr_low[31:24] <= wr_data[31:24];
            end
            if (counter_high_wr) begin
                if (wr_be[0]) counter_addr_high[7:0]   <= wr_data[7:0];
                if (wr_be[1]) counter_addr_high[15:8]  <= wr_data[15:8];
                if (wr_be[2]) counter_addr_high[23:16] <= wr_data[23:16];
                if (wr_be[3]) counter_addr_high[31:24] <= wr_data[31:24];
            end

            // ================== Tx Descriptor Registers (0x20-0x2F) ==================
            if (tnpds_low_wr) begin
                if (wr_be[0]) tnpds_low[7:0]   <= wr_data[7:0];
                if (wr_be[1]) tnpds_low[15:8]  <= wr_data[15:8];
                if (wr_be[2]) tnpds_low[23:16] <= wr_data[23:16];
                if (wr_be[3]) tnpds_low[31:24] <= wr_data[31:24];
            end
            if (tnpds_high_wr) begin
                if (wr_be[0]) tnpds_high[7:0]   <= wr_data[7:0];
                if (wr_be[1]) tnpds_high[15:8]  <= wr_data[15:8];
                if (wr_be[2]) tnpds_high[23:16] <= wr_data[23:16];
                if (wr_be[3]) tnpds_high[31:24] <= wr_data[31:24];
            end
            if (thpds_low_wr) begin
                if (wr_be[0]) thpds_low[7:0]   <= wr_data[7:0];
                if (wr_be[1]) thpds_low[15:8]  <= wr_data[15:8];
                if (wr_be[2]) thpds_low[23:16] <= wr_data[23:16];
                if (wr_be[3]) thpds_low[31:24] <= wr_data[31:24];
            end
            if (thpds_high_wr) begin
                if (wr_be[0]) thpds_high[7:0]   <= wr_data[7:0];
                if (wr_be[1]) thpds_high[15:8]  <= wr_data[15:8];
                if (wr_be[2]) thpds_high[23:16] <= wr_data[23:16];
                if (wr_be[3]) thpds_high[31:24] <= wr_data[31:24];
            end

            // ================== Flash/EEPROM (0x30-0x36) ==================
            if (flash_wr) begin
                if (wr_be[0]) flash_reg[7:0]   <= wr_data[7:0];
                if (wr_be[1]) flash_reg[15:8]  <= wr_data[15:8];
                if (wr_be[2]) flash_reg[23:16] <= wr_data[23:16];
                if (wr_be[3]) flash_reg[31:24] <= wr_data[31:24];
            end
            if (ersr_wr) begin
                if (wr_be[0]) ersr <= wr_data[7:0];
            end

            // ================== TxPoll (0x38) ==================
            if (txpoll_wr) begin
                if (wr_be[0]) txpoll <= wr_data[7:0];
            end

            // ================== Interrupt Registers (0x3C-0x3F) ==================
            if (intr_mask_wr) begin
                if (wr_be[0]) intr_mask[7:0]  <= wr_data[7:0];
                if (wr_be[1]) intr_mask[15:8] <= wr_data[15:8];
            end
            if (intr_status_wr) begin
                // Write 1 to clear (W1C) behavior
                if (wr_be[0]) intr_status[7:0]  <= intr_status[7:0] & ~wr_data[7:0];
                if (wr_be[1]) intr_status[15:8] <= intr_status[15:8] & ~wr_data[15:8];
            end

            // ================== Tx/Rx Configuration (0x40-0x47) ==================
            if (txcfg_wr) begin
                if (wr_be[0]) txconfig[7:0]   <= wr_data[7:0];
                if (wr_be[1]) txconfig[15:8]  <= wr_data[15:8];
                if (wr_be[2]) txconfig[23:16] <= wr_data[23:16];
                if (wr_be[3]) txconfig[31:24] <= wr_data[31:24];
            end

            if (rxcfg_wr) begin
                if (wr_be[0]) rxconfig[7:0]   <= wr_data[7:0];
                if (wr_be[1]) rxconfig[15:8]  <= wr_data[15:8];
                if (wr_be[2]) rxconfig[23:16] <= wr_data[23:16];
                if (wr_be[3]) rxconfig[31:24] <= wr_data[31:24];
            end

            // ================== Config Registers (0x50-0x58) ==================
            if (cfg9346_wr) begin
                if (wr_be[0]) cfg9346 <= wr_data[7:0];
            end
            // Config0 (0x51)
            if (config_wr && (wr_dw_off == 8'h50)) begin
                if (wr_be[1]) config0 <= wr_data[15:8];
            end
            // Config1 (0x52)
            if (config_wr && (wr_dw_off == 8'h50)) begin
                if (wr_be[2]) config1 <= wr_data[23:16];
            end
            // Config2 (0x53)
            if (config_wr && (wr_dw_off == 8'h50)) begin
                if (wr_be[3]) config2 <= wr_data[31:24];
            end
            // Config3 (0x54)
            if (config_wr && (wr_dw_off == 8'h54)) begin
                if (wr_be[0]) config3 <= wr_data[7:0];
            end
            // Config4 (0x55)
            if (config_wr && (wr_dw_off == 8'h54)) begin
                if (wr_be[1]) config4 <= wr_data[15:8];
            end
            // Config5 (0x56)
            if (config_wr && (wr_dw_off == 8'h54)) begin
                if (wr_be[2]) config5 <= wr_data[23:16];
            end
            // Config6 (0x57)
            if (config_wr && (wr_dw_off == 8'h54)) begin
                if (wr_be[3]) config6 <= wr_data[31:24];
            end
            // Config7 (0x58)
            if (config_wr && (wr_dw_off == 8'h58)) begin
                if (wr_be[0]) config7 <= wr_data[7:0];
            end

            // ================== C+ Command Register (0xE0) ==================
            if (cplus_wr) begin
                if (wr_be[0]) cpluscr[7:0]   <= wr_data[7:0];
                if (wr_be[1]) cpluscr[15:8]  <= wr_data[15:8];
                if (wr_be[2]) cpluscr[23:16] <= wr_data[23:16];
                if (wr_be[3]) cpluscr[31:24] <= wr_data[31:24];
            end

            // ================== Interrupt Mitigation (0xE2) ==================
            if (intr_mit_wr) begin
                if (wr_be[0]) intr_mitigate[7:0]  <= wr_data[7:0];
                if (wr_be[1]) intr_mitigate[15:8] <= wr_data[15:8];
            end

            // ================== Rx Descriptor Registers (0xE4-0xE8) ==================
            if (rxdesc_low_wr) begin
                if (wr_be[0]) rxdesc_addr_low[7:0]   <= wr_data[7:0];
                if (wr_be[1]) rxdesc_addr_low[15:8]  <= wr_data[15:8];
                if (wr_be[2]) rxdesc_addr_low[23:16] <= wr_data[23:16];
                if (wr_be[3]) rxdesc_addr_low[31:24] <= wr_data[31:24];
            end
            if (rxdesc_high_wr) begin
                if (wr_be[0]) rxdesc_addr_high[7:0]   <= wr_data[7:0];
                if (wr_be[1]) rxdesc_addr_high[15:8]  <= wr_data[15:8];
                if (wr_be[2]) rxdesc_addr_high[23:16] <= wr_data[23:16];
                if (wr_be[3]) rxdesc_addr_high[31:24] <= wr_data[31:24];
            end

            // ================== Max Packet Size Registers ==================
            // RMS (0xDA-0xDB)
            if (rms_wr) begin
                if (wr_be[0]) rms[7:0]  <= wr_data[7:0];
                if (wr_be[1]) rms[15:8] <= wr_data[15:8];
            end
            // MTPS (0xEC)
            if (mtps_wr) begin
                if (wr_be[0]) mtps[7:0]  <= wr_data[7:0];
                if (wr_be[1]) mtps[15:8] <= wr_data[15:8];
            end

            // ================== Early Transmit Threshold (0xED) ==================
            if (etthr_wr) begin
                if (wr_be[1]) etthr <= wr_data[15:8];
            end

            // ================== VLAN Tag Register (0xC0) ==================
            if (vlan_tag_wr) begin
                if (wr_be[0]) vlan_tag[7:0]  <= wr_data[7:0];
                if (wr_be[1]) vlan_tag[15:8] <= wr_data[15:8];
            end

            // ================== OCP Registers ==================
            if (ocpdr_wr) begin
                if (wr_be[0]) ocpdr[7:0]   <= wr_data[7:0];
                if (wr_be[1]) ocpdr[15:8]  <= wr_data[15:8];
                if (wr_be[2]) ocpdr[23:16] <= wr_data[23:16];
                if (wr_be[3]) ocpdr[31:24] <= wr_data[31:24];
            end
            if (ocpar_wr) begin
                if (wr_be[0]) ocpar[7:0]   <= wr_data[7:0];
                if (wr_be[1]) ocpar[15:8]  <= wr_data[15:8];
                if (wr_be[2]) ocpar[23:16] <= wr_data[23:16];
                if (wr_be[3]) ocpar[31:24] <= wr_data[31:24];
            end

            // ================== Out-of-Band Registers ==================
            if (oob_sig_wr) begin
                if (wr_be[0]) oob_sig[7:0]   <= wr_data[7:0];
                if (wr_be[1]) oob_sig[15:8]  <= wr_data[15:8];
                if (wr_be[2]) oob_sig[23:16] <= wr_data[23:16];
                if (wr_be[3]) oob_sig[31:24] <= wr_data[31:24];
            end
            if (oob_ctrl_wr) begin
                if (wr_be[0]) oob_ctrl[7:0]   <= wr_data[7:0];
                if (wr_be[1]) oob_ctrl[15:8]  <= wr_data[15:8];
                if (wr_be[2]) oob_ctrl[23:16] <= wr_data[23:16];
                if (wr_be[3]) oob_ctrl[31:24] <= wr_data[31:24];
            end
            if (oob_base_wr) begin
                if (wr_be[0]) oob_base[7:0]   <= wr_data[7:0];
                if (wr_be[1]) oob_base[15:8]  <= wr_data[15:8];
                if (wr_be[2]) oob_base[23:16] <= wr_data[23:16];
                if (wr_be[3]) oob_base[31:24] <= wr_data[31:24];
            end

            // ================== Timing Registers ==================
            if (time_int_wr) begin
                if (wr_be[0]) time_int <= wr_data[7:0];
            end

            // ================== Power Control (0x61) ==================
            if (pmch_wr) begin
                if (wr_be[0]) pmch[7:0]   <= wr_data[7:0];
                if (wr_be[1]) pmch[15:8]  <= wr_data[15:8];
                if (wr_be[2]) pmch[23:16] <= wr_data[23:16];
                if (wr_be[3]) pmch[31:24] <= wr_data[31:24];
            end

            // ================== GPIO Pin Control (0x62) ==================
            if (gpio_wr) begin
                if (wr_be[0]) gpio_pin <= wr_data[7:0];
            end

            if (chipcmd_wr) begin
            chipcmd <= wr_data[31:24];
            chipcmd_cnt <= wr_data[28] ? 3'd7 : 3'd0;
            end else if (chipcmd_cnt != 0) begin
                chipcmd_cnt <= chipcmd_cnt - 3'd1;
                if (chipcmd_cnt == 3'd1) begin
                    chipcmd[4] <= 1'b0;
                end
            end

            if (phyar_wr) begin
                if (wr_be[0]) phyar[7:0]   <= wr_data[7:0];
                if (wr_be[1]) phyar[15:8]  <= wr_data[15:8];
                if (wr_be[2]) phyar[23:16] <= wr_data[23:16];
                if (wr_be[3]) phyar[31:24] <= wr_data[31:24];
                if (wr_be[3]) begin
                    phyar_cnt <= 3'd7;
                    phyar_rd <= ~wr_data[31];
                end
            end else if (phyar_cnt != 0) begin
                phyar_cnt <= phyar_cnt - 3'd1;
                if (phyar_cnt == 3'd1) begin
                    phyar[31] <= phyar_rd;
                    if (phyar_rd) begin
                        case (phyar[20:16])
                            5'd0:  phyar[15:0] <= 16'h1140;
                            5'd1:  phyar[15:0] <= 16'h782D;
                            5'd2:  phyar[15:0] <= 16'h001C;
                            5'd3:  phyar[15:0] <= 16'hC912;
                            5'd4:  phyar[15:0] <= 16'h01E1;
                            5'd5:  phyar[15:0] <= 16'h41E1;
                            5'd6:  phyar[15:0] <= 16'h0007;
                            5'd9:  phyar[15:0] <= 16'h0300;
                            5'd10: phyar[15:0] <= 16'h2800;
                            default: phyar[15:0] <= 16'h0000;
                        endcase
                    end
                end
            end

            if (csiar_wr) begin
                if (wr_be[0]) csiar[7:0]   <= wr_data[7:0];
                if (wr_be[1]) csiar[15:8]  <= wr_data[15:8];
                if (wr_be[2]) csiar[23:16] <= wr_data[23:16];
                if (wr_be[3]) csiar[31:24] <= wr_data[31:24];
                if (wr_be[3]) begin
                    csiar_cnt <= 3'd7;
                    csiar_rd <= ~wr_data[31];
                end
            end else if (csiar_cnt != 0) begin
                csiar_cnt <= csiar_cnt - 3'd1;
                if (csiar_cnt == 3'd1) begin
                    csiar[31] <= csiar_rd;
                end
            end

            if (eriar_wr) begin
                if (wr_be[0]) eriar[7:0]   <= wr_data[7:0];
                if (wr_be[1]) eriar[15:8]  <= wr_data[15:8];
                if (wr_be[2]) eriar[23:16] <= wr_data[23:16];
                if (wr_be[3]) eriar[31:24] <= wr_data[31:24];
                eriar_addr <= wr_data[11:0];
                if (wr_be[3]) begin
                    eriar_cnt <= 3'd7;
                    eriar_rd <= ~wr_data[31];
                end
            end else if (eriar_cnt != 0) begin
                eriar_cnt <= eriar_cnt - 3'd1;
                if (eriar_cnt == 3'd1) begin
                    eriar[31] <= eriar_rd;
                    if (eriar_rd) begin
                        case (eriar_addr)
                            12'h0E0: eridr_shadow <= MAC0_RST;
                            12'h0E4: eridr_shadow <= MAC1_RST;
                            default: eridr_shadow <= 32'h00000000;
                        endcase
                    end
                end
            end

            if (ephyar_wr) begin
                if (wr_be[0]) ephyar[7:0]   <= wr_data[7:0];
                if (wr_be[1]) ephyar[15:8]  <= wr_data[15:8];
                if (wr_be[2]) ephyar[23:16] <= wr_data[23:16];
                if (wr_be[3]) ephyar[31:24] <= wr_data[31:24];
                if (wr_be[3]) begin
                    ephyar_cnt <= 3'd7;
                    ephyar_rd <= ~wr_data[31];
                end
            end else if (ephyar_cnt != 0) begin
                ephyar_cnt <= ephyar_cnt - 3'd1;
                if (ephyar_cnt == 3'd1) begin
                    ephyar[31] <= ephyar_rd;
                    if (ephyar_rd) begin
                        ephyar[15:0] <= 16'h0000;
                    end
                end
            end
        end
    end

    wire [31:0] rd_data =
        // ================== MAC Address Registers (0x00-0x05) ==================
        (rd_dw_off == 8'h00) ? mac0 :
        (rd_dw_off == 8'h04) ? mac1 :

        // ================== Multicast Filter Registers (0x08, 0x0C) ==================
        (rd_dw_off == 8'h08) ? mar0 :
        (rd_dw_off == 8'h0C) ? mar4 :

        // ================== Statistics Counter Registers (0x10-0x14) ==================
        (rd_dw_off == 8'h10) ? counter_addr_low :
        (rd_dw_off == 8'h14) ? counter_addr_high :

        // ================== Transmit Descriptor Registers (0x20-0x2F) ==================
        (rd_dw_off == 8'h20) ? tnpds_low :
        (rd_dw_off == 8'h24) ? tnpds_high :
        (rd_dw_off == 8'h28) ? thpds_low :
        (rd_dw_off == 8'h2C) ? thpds_high :

        // ================== Flash/EEPROM Registers (0x30-0x36) ==================
        (rd_dw_off == 8'h30) ? flash_reg :
        (rd_dw_off == 8'h36) ? {24'h000000, ersr} :

        // ================== ChipCmd Register (0x34-0x37) ==================
        (rd_dw_off == 8'h34) ? {chipcmd, 24'h000000} :

        // ================== TxPoll Register (0x38) ==================
        (rd_dw_off == 8'h38) ? {24'h000000, txpoll} :

        // ================== Interrupt Registers (0x3C-0x3F) ==================
        (rd_dw_off == 8'h3C) ? {16'h0000, intr_mask} :
        (rd_dw_off == 8'h3E) ? {16'h0000, intr_status} :

        // ================== Tx/Rx Configuration (0x40-0x47) ==================
        (rd_dw_off == 8'h40) ? txconfig :
        (rd_dw_off == 8'h44) ? rxconfig :

        // ================== Receive Buffer Address Legacy (0x4C) ==================
        (rd_dw_off == 8'h4C) ? 32'h00000000 :

        // ================== Config Registers (0x50-0x58) ==================
        (rd_dw_off == 8'h50) ? {config2, config1, config0, cfg9346} :
        (rd_dw_off == 8'h54) ? {config6, config5, config4, config3} :
        (rd_dw_off == 8'h58) ? {24'h000000, config7} :

        // ================== PHY Access Register (0x60-0x63) ==================
        (rd_dw_off == 8'h60) ? phyar :

        // ================== PMCH / GPIO / Reserved (0x61-0x63) ==================
        (rd_dw_off == 8'h61) ? {24'h000000, pmch[7:0]} :
        (rd_dw_off == 8'h62) ? {24'h000000, gpio_pin} :

        // ================== Enhanced Interface Registers (0x64-0x74) ==================
        (rd_dw_off == 8'h64) ? eridr_shadow :
        (rd_dw_off == 8'h68) ? csiar :
        (rd_dw_off == 8'h6C) ? PHYSTATUS_RST :
        (rd_dw_off == 8'h70) ? eriar :
        (rd_dw_off == 8'h74) ? eriar :

        // ================== OCP Registers (0x78-0x7C) ==================
        (rd_dw_off == 8'h78) ? ocpdr :
        (rd_dw_off == 8'h7C) ? ocpar :

        // ================== VLAN Tag Register (0x80-0x81) ==================
        (rd_dw_off == 8'hC0) ? {16'h0000, vlan_tag} :

        // ================== EPHYAR Register (0x80) - NOTE: Same offset as VLAN ==================
        (rd_dw_off == 8'h80) ? ephyar :

        // ================== Out-of-Band Registers (0x90-0x98) ==================
        (rd_dw_off == 8'h90) ? oob_sig :
        (rd_dw_off == 8'h94) ? oob_ctrl :
        (rd_dw_off == 8'h98) ? oob_base :

        // ================== Timing & Control Registers (0xD4-0xD5) ==================
        (rd_dw_off == 8'hD4) ? {time_int, 24'h000000} :

        // ================== RMS - Max Receive Packet Size (0xDA-0xDB) ==================
        (rd_dw_off == 8'hDA) ? {16'h0000, rms} :

        // ================== C+ Command Register (0xE0-0xE1) ==================
        (rd_dw_off == 8'hE0) ? {16'h0000, cpluscr[15:0]} :

        // ================== Interrupt Mitigation (0xE2-0xE3) ==================
        (rd_dw_off == 8'hE2) ? {16'h0000, intr_mitigate} :

        // ================== Rx Descriptor Registers (0xE4-0xE8) ==================
        (rd_dw_off == 8'hE4) ? rxdesc_addr_low :
        (rd_dw_off == 8'hE8) ? rxdesc_addr_high :

        // ================== Early Transmit Threshold (0xED) ==================
        (rd_dw_off == 8'hED) ? {etthr, 24'h000000} :

        // ================== MTPS - Max Transmit Packet Size (0xEC) ==================
        (rd_dw_off == 8'hEC) ? {16'h0000, mtps} :

        // ================== Default: Return 0 for unmapped registers ==================
        32'h00000000;

    bit [87:0] drd_req_ctx;
    bit        drd_req_valid;

    always @ (posedge clk) begin
        drd_req_ctx   <= rd_req_ctx;
        drd_req_valid <= rd_req_valid;
        rd_rsp_ctx    <= drd_req_ctx;
        rd_rsp_valid  <= drd_req_valid;
        rd_rsp_data   <= rd_data;
    end

endmodule
