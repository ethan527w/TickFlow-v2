`timescale 1ns / 1ps

module axis_gearbox_8_to_64 (
    input logic clk,
    input logic rst_n,

    // Upstream - MAC, AXI4-Stream
    input  logic [7:0] s_tdata,
    input  logic       s_tlast,
    input  logic       s_tvalid,
    output logic       s_tready,

    // Downstream - AXI4-Stream
    output logic [63:0] m_tdata,
    output logic [ 7:0] m_tkeep,
    output logic        m_tlast,
    output logic        m_tvalid,
    input  logic        m_tready
);

  logic [2:0] byte_cnt;
  logic       s_fire;
  logic       m_fire;

  assign s_tready = !m_tvalid || m_tready;
  assign s_fire   = s_tvalid && s_tready;
  assign m_fire   = m_tvalid && m_tready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      byte_cnt <= '0;
      m_tdata  <= '0;
      m_tkeep  <= '0;
      m_tlast  <= '0;
      m_tvalid <= '0;
    end else begin
      case ({
        m_fire, s_fire
      })
        2'b10: begin
          m_tvalid <= '0;
          m_tkeep  <= '0;
          m_tlast  <= '0;
          byte_cnt <= '0;
          m_tdata  <= '0;
        end

        2'b01: begin
          m_tdata[byte_cnt*8+:8] <= s_tdata;
          m_tkeep[byte_cnt] <= 1'b1;
          if (byte_cnt == 3'd7 || s_tlast) begin
            m_tvalid <= 1'b1;
            m_tlast  <= s_tlast;
            byte_cnt <= '0;
          end else begin
            m_tvalid <= '0;
            byte_cnt <= byte_cnt + 1'b1;
          end
        end

        2'b11: begin
          m_tdata <= {56'd0, s_tdata};
          m_tkeep <= 8'b0000_0001;
          if (s_tlast) begin
            m_tvalid <= 1'b1;
            m_tlast  <= 1'b1;
            byte_cnt <= '0;
          end else begin
            m_tvalid <= '0;
            m_tlast  <= '0;
            byte_cnt <= 3'd1;
          end
        end

        default: ;
      endcase
    end
  end

endmodule
