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

  logic [2:0] beat_cnt;
  logic s_fire;
  logic m_fire;
  assign s_fire = s_tvalid && s_tready;
  assign m_fire = m_tvalid && m_tready;
  //tmp reg
  logic [47:0] prev_data;
  logic [ 5:0] prev_keep;


  typedef enum logic [1:0] {
    HEADER = 2'b00,
    PAYLOAD = 2'b01,
    FLUSHING = 2'b10,
    DROP = 2'b11
  } state_e;

  state_e curr_state, next_state;

  assign s_tready = (curr_state != FLUSHING) && (!m_tvalid || m_tready);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      curr_state <= HEADER;
    end else begin
      curr_state <= next_state;
    end
  end

  always_comb begin
    next_state = curr_state;
    case (curr_state)
      HEADER: begin
        if (s_fire) begin

          if (beat_cnt == 3'd5) begin
            //transfer to PAYLOAD
            if (!s_tlast) begin
              next_state = PAYLOAD;
            end else if (s_tlast) begin
              if (|s_tkeep[7:2] == 1) begin
                //if this is a abonormally short pkg
                next_state = FLUSHING;
              end else begin
                //nothing useful here, no waiting time
                //no DROP, stay HEADER
                next_state = HEADER;
              end
            end
          end else if (s_tlast) begin
            next_state = HEADER;
          end else if (beat_cnt == 3'd1) begin
            //EtherType & IP Ver
            if (({s_tdata[39:32], s_tdata[47:40]} != 16'h0800) || s_tdata[55:48] != 8'h45) begin
              next_state = DROP;
            end
          end else if (beat_cnt == 3'd2) begin
            //IP Protocol
            if (s_tdata[63:56] != 8'd17) begin
              next_state = DROP;
            end
          end else if (beat_cnt == 3'd4) begin
            // UDP Dest Port
            if ({s_tdata[39:32], s_tdata[47:40]} != TARGET_PORT) begin
              next_state = DROP;
            end
          end
        end
      end
      PAYLOAD: begin
        if (s_fire) begin
          if (s_tlast) begin
            if (|s_tkeep[7:2] == 1) begin
              //still bits not included, has to stop the upstream
              next_state = FLUSHING;
            end else begin
              next_state = HEADER;
            end
          end
        end
      end
      FLUSHING: begin
        if (m_fire && m_tlast) begin
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


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      //tasks: 1. beat_cnt 2. handshakes 3. data fill
      beat_cnt  <= '0;
      m_tvalid  <= '0;
      prev_data <= '0;
      prev_keep <= '0;
      m_tdata   <= '0;
      m_tkeep   <= '0;
      m_tlast   <= '0;
    end else begin
      if (m_fire) begin
        m_tvalid <= 1'b0;
        m_tlast  <= 1'b0;
      end
      case (curr_state)
        HEADER: begin
          if (s_fire) begin
            prev_data <= s_tdata[63:16];
            prev_keep <= s_tkeep[7:2];
            if (!s_tlast) begin
              //normal case
              beat_cnt <= beat_cnt + 1'b1;

              m_tvalid <= '0;

              m_tdata  <= s_tdata;
              m_tkeep  <= s_tkeep;
              m_tlast  <= s_tlast;
            end else begin  //can only occur when carries no information
              beat_cnt <= '0;
              m_tvalid <= '0;
              m_tdata  <= '0;
              m_tkeep  <= '0;
              m_tlast  <= '0;
            end
          end
        end
        PAYLOAD: begin
          if (s_fire) begin
            m_tdata   <= {s_tdata[15:0], prev_data};
            m_tkeep   <= {s_tkeep[1:0], prev_keep};
            prev_data <= s_tdata[63:16];
            prev_keep <= s_tkeep[7:2];
            m_tvalid  <= 1'b1;
            if (s_tlast || beat_cnt == 3'd5) begin
              beat_cnt <= '0;
              if (s_tlast) begin
                m_tvalid <= 1'b1;
                //last: only be the last beat when all keep is 0
                //otherwise go FLUSHING, the always_comb will shift
                m_tlast  <= ~|s_tkeep[7:2];
              end
            end
          end
        end
        FLUSHING: begin
          if (!m_tvalid || (m_fire && !m_tlast)) begin
            m_tdata  <= {16'd0, prev_data};
            m_tkeep  <= {2'd0, prev_keep};
            m_tlast  <= 1'b1;
            m_tvalid <= 1'b1;
          end
          //   m_tvalid <= 1'b1;
          //   if (m_fire) begin
          //     m_tvalid <= 1'b0;
          //     m_tlast  <= 1'b0;
          //     m_tdata  <= {16'd0, prev_data};
          //     m_tkeep  <= {2'd0, prev_keep};
          //   end
          //   if (next_state == HEADER) begin
          //     beat_cnt <= '0;
          //   end
        end
        DROP: begin
          //wait until the end of this pkg
          //do nothing
          m_tvalid <= 0;
          if (s_fire && s_tlast) begin
            beat_cnt <= '0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
          end
        end
        default: ;
      endcase
    end
  end

endmodule
