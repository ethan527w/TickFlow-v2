`timescale 1ns / 1ps

module moldudp64_framer (
    input logic clk,
    input logic rst_n,

    //Upstream - ethernet ipv4 udp parser
    input  logic s_tvalid,
    output logic s_tready,

    input logic [63:0] s_tdata,
    input logic [7:0] s_tkeep,
    input logic s_tlast,

    //Downstream - M4b, price/qty parser(should be)
    output logic m_tvalid,
    input  logic m_tready,

    output logic [63:0] m_tdata,
    output logic [7:0] m_tkeep,
    output logic m_tlast,

    //Sideband telemetry
    output logic pkg_lost
);

  //declaring FSM states
  typedef enum logic [2:0] {
    HEADER1 = 3'b000,
    HEADER2 = 3'b001,
    LENGTH  = 3'b010,
    PAYLOAD = 3'b011,
    DROP    = 3'b100
  } state_e;

  state_e curr_state, next_state;

  //declare pool
  //more intuitive, from 0 to 15
  logic [ 7:0] pool                                     [0:15];
  logic [ 4:0] count;  // range 0-31, will only use 0-16

  //pool signals
  //next pool here is for calculation purpose
  logic [ 7:0] next_pool                                [0:15];
  logic [ 4:0] rem_count;
  logic [ 4:0] next_count;
  logic [ 3:0] consume;
  logic [ 3:0] in_bytes;
  logic [ 3:0] send_bytes;


  //protocol signals
  logic [15:0] rem_msgs;
  logic [15:0] rem_bytes;
  logic        packet_end_seen;

  // Extracted protocol fields - combinational
  logic [63:0] seq_num;
  logic [15:0] msg_count;
  logic [15:0] msg_len;

  // Sequence tracking - register
  logic [63:0] expected_seq;


  //handshake signals
  logic m_fire, s_fire;
  assign s_fire = s_tvalid && s_tready;
  assign m_fire = m_tvalid && m_tready;

  //examination entries
  //MoldUDP64 requirse big endian
  assign seq_num = {pool[2], pool[3], pool[4], pool[5], pool[6], pool[7], pool[8], pool[9]};
  assign msg_count = {pool[10], pool[11]};
  assign msg_len = {pool[0], pool[1]};

  //pool count
  assign rem_count = count - consume;
  assign next_count = rem_count + (s_fire ? {1'b0, in_bytes} : 5'd0);

  //comb assign - byte calculation
  assign in_bytes = 4'($countones(s_tkeep));
  assign send_bytes = (rem_bytes > 16'd8) ? 4'd8 : rem_bytes[3:0];


  assign s_tready = !packet_end_seen && (rem_count <= 5'd8);
  //to avoid overflow, consume must <= count
  //Account for bytes consumed in the current cycle
  //will introduce a bubble between pkgs, but doesn't really know how to improve

  always_ff @(posedge clk or negedge rst_n) begin : state_register
    if (!rst_n) begin
      curr_state <= HEADER1;
    end else begin
      curr_state <= next_state;
    end
  end

  always_comb begin : next_state_register
    next_state = curr_state;
    case (curr_state)
      HEADER1: begin
        //throw out the session 8B
        if (count >= 4'd8) begin
          next_state = HEADER2;
        end else if (packet_end_seen) begin
          next_state = DROP;
        end
      end
      HEADER2: begin
        //
        if (count >= 5'd12) begin
          if (seq_num != expected_seq) begin
            next_state = DROP;
          end else if (msg_count == 16'd0 || msg_count == 16'hFFFF) begin
            //check Heartbeat'0 and End of Session'1
            if (packet_end_seen && count == 5'd12) begin
              next_state = HEADER1;
            end else begin
              next_state = DROP;
            end
          end else begin
            next_state = LENGTH;
          end
        end else if (packet_end_seen) begin
          next_state = DROP;
        end
      end
      LENGTH: begin
        if (count >= 5'd2) begin
          if (msg_len != '0) begin
            next_state = PAYLOAD;
          end else begin
            next_state = DROP;
          end
        end else if (packet_end_seen) begin
          next_state = DROP;
        end
      end
      PAYLOAD: begin
        if (packet_end_seen && count < send_bytes) begin
          //pkg cut by upstream, incomplete msg
          next_state = DROP;
        end else if (rem_msgs == 16'd1 && rem_bytes <= 16'd8 && count > send_bytes) begin
          //extra bytes
          next_state = DROP;
        end else if (m_fire && rem_bytes <= 16'd8) begin
          if (rem_msgs > 16'd1) begin
            //got more information, start a new length check
            next_state = LENGTH;
          end else if (packet_end_seen && count == send_bytes) begin
            //finished all msgs in this moldudp pkg
            next_state = HEADER1;
          end
        end
      end
      DROP: begin
        if (packet_end_seen && count == '0) begin
          next_state = HEADER1;
        end
      end
      default: ;
    endcase
  end

  always_comb begin : output_and_consumption
    m_tvalid = '0;
    m_tdata  = '0;
    m_tkeep  = '0;
    m_tlast  = '0;
    consume  = '0;

    case (curr_state)
      HEADER1: begin
        if (count >= 5'd8) begin
          consume = 4'd8;
        end
      end
      HEADER2: begin
        if (next_state == LENGTH || next_state == HEADER1) begin
          consume = 4'd12;
        end
      end
      LENGTH: begin
        if (count >= 5'd2 && msg_len != '0) begin
          consume = 4'd2;
        end
      end
      PAYLOAD: begin
        //this is the only state legal to send sth to downstream
        if (count >= send_bytes && rem_bytes != 16'd0 && rem_msgs != 16'd0) begin
          if (rem_msgs > 16'd1 ||
            rem_bytes > 16'd8 ||
            (packet_end_seen && count == send_bytes)) begin
            //fire send
            m_tvalid = 1'b1;
            m_tkeep  = 8'hFF >> (4'd8 - send_bytes);  // {consume{1'b1}, (8-send_bytes){1'b0}}
            m_tlast  = (rem_bytes <= 16'd8);
            for (int i = 0; i < 8; i++) begin
              m_tdata[i*8+:8] = m_tkeep[i] ? pool[i] : 8'h00;
            end  // m_tdata = {pool[0 +:consume], '0};
            if (m_tready) begin
              consume = send_bytes;
            end
          end
        end
      end
      DROP: begin
        consume = (count < 5'd8) ? count[3:0] : 4'd8;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin : protocol_registers
    if (!rst_n) begin
      rem_msgs        <= '0;
      rem_bytes       <= '0;
      expected_seq    <= 64'd1;
      packet_end_seen <= 1'b0;
      pkg_lost        <= 1'b0;
    end else begin
      pkg_lost <= 1'b0;
      // Packet boundary tracking - packet_end_seen
      if (curr_state != HEADER1 && next_state == HEADER1) begin
        packet_end_seen <= '0;
      end else if (s_fire && s_tlast) begin
        packet_end_seen <= 1'b1;
      end
      // Protocol progress tracking
      case (curr_state)
        HEADER1: begin
          //if I don't put this, Verible goes wrong
          //but nothing changes in this state
        end
        HEADER2: begin
          if (next_state == LENGTH) begin
            //normal case
            rem_msgs <= msg_count;
          end
          if (count >= 5'd12 && seq_num != expected_seq) begin
            //Sequence Mismatch
            //see the state transition in 2nd always_comb PAYLOAD case
            pkg_lost <= 1'b1;
          end
        end
        LENGTH: begin
          if (next_state == PAYLOAD) begin
            rem_bytes <= msg_len;
          end
        end
        PAYLOAD: begin
          if (m_fire) begin
            rem_bytes <= rem_bytes - send_bytes;

            if (m_tlast) begin
              rem_msgs     <= rem_msgs - 16'd1;
              expected_seq <= expected_seq + 64'd1;
            end
          end
        end
        DROP: begin
          rem_msgs  <= '0;
          rem_bytes <= '0;
        end
        default: ;
      endcase
    end
  end

  always_comb begin : pool_next_logic
    // Step 1: Shift remaining old bytes and clear unused positions.
    ////require consume <= count <= 16
    for (int i = 0; i < 16; i++) begin
      if (i < rem_count) begin
        next_pool[i] = pool[i+consume];
      end else begin
        next_pool[i] = '0;
      end
    end
    // Step 2: Append incoming valid bytes.
    if (s_fire) begin
      for (int i = 0; i < 8; i++) begin
        if (i < in_bytes) begin  // TKEEP must be contiguous from LSB.
          next_pool[rem_count+i] = s_tdata[8*i+:8];
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin : pool_registers
    if (!rst_n) begin
      count <= '0;
      pool  <= '{default: '0};
    end else begin
      count <= next_count;
      pool  <= next_pool;
    end
  end

endmodule
