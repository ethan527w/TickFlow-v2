`timescale 1ns / 1ps

module axis_skid_buffer #(
    parameter int DATA_WIDTH = 64,
    parameter int KEEP_WIDTH = DATA_WIDTH / 8
) (
    input logic clk,
    input logic rst_n,

    //upstream
    input logic [DATA_WIDTH-1:0] s_tdata,
    input logic [KEEP_WIDTH-1:0] s_tkeep,
    input logic s_tlast,
    input logic s_tvalid,
    output logic s_tready,


    //downstream
    output logic [DATA_WIDTH-1:0] m_tdata,
    output logic [KEEP_WIDTH-1:0] m_tkeep,
    output logic m_tlast,
    output logic m_tvalid,
    input logic m_tready

);

  //skid register
  logic [DATA_WIDTH-1:0] skid_data;
  logic [KEEP_WIDTH-1:0] skid_keep;
  logic skid_last;
  logic skid_valid;
  // signals
  logic main_ready, s_fire;
  assign main_ready = !m_tvalid || m_tready;
  assign s_fire = s_tready && s_tvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_tready <= 1'b1;
      m_tdata <= '0;
      m_tkeep <= '0;
      m_tlast <= '0;
      m_tvalid <= '0;
      skid_valid <= '0;
    end else begin

      if (main_ready) begin
        if (skid_valid) begin
          m_tdata  <= skid_data;
          m_tkeep  <= skid_keep;
          m_tlast  <= skid_last;
          m_tvalid <= 1'b1;
        end else begin
          //normal case - no backpressure
          m_tdata  <= s_tdata;
          m_tkeep  <= s_tkeep;
          m_tlast  <= s_tlast;
          m_tvalid <= s_tvalid;
        end
      end

      //backpressure
      if (s_fire && !main_ready) begin
        //when all registers being occupied
        skid_valid <= 1'b1;
        skid_data  <= s_tdata;
        skid_keep  <= s_tkeep;
        skid_last  <= s_tlast;
        s_tready   <= '0;
      end else if (skid_valid && main_ready) begin
        //backpressure deactivated (m_tready = 1)
        skid_valid <= '0;
        s_tready   <= 1'b1;
      end
    end
  end

endmodule
