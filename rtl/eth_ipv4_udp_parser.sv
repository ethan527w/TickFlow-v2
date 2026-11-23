`timescale 1ns / 1ps

module eth_ipv4_udp_parser #(
    parameter logic [15:0] TARGET_PORT = 16'd12345
) (
    input logic clk,
    input logic rst_n,

    // Upstream - gearbox
    input  logic [63:0] s_tdata,
    input  logic [ 7:0] s_tkeep,
    input  logic        s_tlast,
    input  logic        s_tvalid,
    output logic        s_tready,

    // Downstream
    output logic [63:0] m_tdata,
    output logic [ 7:0] m_tkeep,
    output logic        m_tlast,
    output logic        m_tvalid,
    input  logic        m_tready
);

  typedef enum logic [1:0] {
    HEADER = 2'b00,
    PAYLOAD = 2'b01,
    FLUSH = 2'b10,
    DROP = 2'b11
  } state_e;

  state_e curr_state, next_state;
  logic [ 2:0] beat_cnt;
  logic [63:0] skid_data;
  logic [ 7:0] skid_keep;
  logic m_fire, s_fire;

  assign m_fire = m_tready && m_tvalid;
  assign s_fire = s_tready && s_tvalid;

  always_ff @(posedge clk or negedge rst_n) begin : change_curr_state
    if (!rst_n) begin
      curr_state <= HEADER;
    end else begin
      curr_state <= next_state;
    end
  end

  always_comb begin : change_next_state
    next_state = curr_state;
    case (curr_state)
      HEADER: begin
        if (s_fire) begin
          if (s_tlast) begin
            if (beat_cnt == 3'd5 && |s_tkeep[7:2]) begin
              //short pkg with datagram left
              next_state = FLUSH;
            end else begin
              //short pkg
              next_state = HEADER;
            end
          end else if (beat_cnt == 3'd5) begin
            //most pkg will goes here, not ending too early
            next_state = PAYLOAD;
          end else begin
            //EtherType & IP Ver
            if ((beat_cnt == 3'd1) && (({s_tdata[39:32], s_tdata[47:40]} != 16'h0800) || (s_tdata[55:48] != 8'h45)))
              next_state = DROP;
            //IP Protocol
            else if ((beat_cnt == 3'd2) && (s_tdata[63:56] != 8'd17)) next_state = DROP;
            //UDP Dest Port
            else if ((beat_cnt == 3'd4) && ({s_tdata[39:32], s_tdata[47:40]} != TARGET_PORT))
              next_state = DROP;
          end
        end
      end

      PAYLOAD: begin
        if (s_fire && s_tlast) begin
          if (|s_tkeep[7:2]) begin
            next_state = FLUSH;
          end else begin
            next_state = HEADER;
          end
        end
      end

      FLUSH: begin
        if (m_fire) begin
          next_state = HEADER;
        end
      end

      DROP: begin
        if (s_fire && s_tlast) begin
          next_state = HEADER;
        end
      end
      default: ;
    endcase
  end

  always_comb begin : handshake_and_datapath
    //default reset
    s_tready = '0;
    m_tvalid = '0;
    m_tdata  = '0;
    m_tkeep  = '0;
    m_tlast  = '0;

    case (curr_state)
      HEADER, DROP: begin
        s_tready = 1'b1;
      end

      PAYLOAD: begin
        //due to no skid buffer, all as is
        s_tready = m_tready;
        m_tvalid = s_tvalid;

        m_tdata  = {s_tdata[15:0], skid_data[63:16]};
        m_tkeep  = {s_tkeep[1:0], skid_keep[7:2]};
        m_tlast  = s_tlast && (s_tkeep[7:2] == '0);
      end

      FLUSH: begin
        s_tready = '0;
        m_tvalid = 1'b1;

        m_tdata  = {16'b0, skid_data[63:16]};
        m_tkeep  = {2'b0, skid_keep[7:2]};
        m_tlast  = 1'b1;
      end
      default: ;
    endcase
  end


  always_ff @(posedge clk or negedge rst_n) begin : beat_cnt_and_skid_data
    if (!rst_n) begin
      beat_cnt  <= '0;
      skid_data <= '0;
      skid_keep <= '0;
    end else begin
      if (s_fire) begin
        skid_data <= s_tdata;
        skid_keep <= s_tkeep;

        // beat_cnt only counts in HEADER 
        if (curr_state == HEADER) begin
          if (beat_cnt == 3'd5 || s_tlast) begin
            beat_cnt <= '0;
          end else begin
            beat_cnt <= beat_cnt + 1'b1;
          end
        end else begin
          beat_cnt <= '0;
        end
      end
    end
  end

endmodule
