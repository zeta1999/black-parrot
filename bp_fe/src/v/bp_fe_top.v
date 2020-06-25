/*
 * bp_fe_top.v
 */

module bp_fe_top
 import bp_fe_pkg::*;
 import bp_fe_icache_pkg::*;
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_be_pkg::*;
 import bp_common_cfg_link_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_inv_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_fe_be_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p)
   `declare_bp_cache_service_if_widths(paddr_width_p, ptag_width_p, icache_sets_p, icache_assoc_p, dword_width_p, icache_block_width_p, icache_fill_width_p, icache)

   , localparam way_id_width_lp=`BSG_SAFE_CLOG2(icache_assoc_p)
   , localparam bank_width_lp = icache_block_width_p / icache_assoc_p
   , localparam num_dwords_per_bank_lp = bank_width_lp / dword_width_p
   , localparam data_mem_mask_width_lp=(bank_width_lp >> 3)
   , localparam byte_offset_width_lp=`BSG_SAFE_CLOG2(bank_width_lp >> 3)
   , localparam bank_offset_width_lp=`BSG_SAFE_CLOG2(icache_assoc_p)
   , localparam index_width_lp=`BSG_SAFE_CLOG2(icache_sets_p)
   , localparam block_offset_width_lp=(bank_offset_width_lp+byte_offset_width_lp)
   , localparam ptag_width_lp=(paddr_width_p-bp_page_offset_width_gp)

   , localparam stat_width_lp = `bp_cache_stat_info_width(icache_assoc_p)

   , localparam cfg_bus_width_lp = `bp_cfg_bus_width(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_pc_width_p, cce_instr_width_p)
   )
  (input                                              clk_i
   , input                                            reset_i

   , input [cfg_bus_width_lp-1:0]                     cfg_bus_i

   , input [fe_cmd_width_lp-1:0]                      fe_cmd_i
   , input                                            fe_cmd_v_i
   , output                                           fe_cmd_yumi_o

   , output [fe_queue_width_lp-1:0]                   fe_queue_o
   , output                                           fe_queue_v_o
   , input                                            fe_queue_ready_i

   // Interface to LCE

   , output logic [icache_req_width_lp-1:0]           cache_req_o
   , output logic                                     cache_req_v_o
   , input                                            cache_req_ready_i
   , output logic [icache_req_metadata_width_lp-1:0]  cache_req_metadata_o
   , output logic                                     cache_req_metadata_v_o

   , input                                            cache_req_complete_i
   , input                                            cache_req_critical_i
   , input [icache_data_mem_pkt_width_lp-1:0]         data_mem_pkt_i
   , input                                            data_mem_pkt_v_i
   , output logic                                     data_mem_pkt_yumi_o
   , output logic [icache_block_width_p-1:0]          data_mem_o

   , input [icache_tag_mem_pkt_width_lp-1:0]          tag_mem_pkt_i
   , input                                            tag_mem_pkt_v_i
   , output logic                                     tag_mem_pkt_yumi_o
   , output logic [ptag_width_lp-1:0]                 tag_mem_o

   , input [icache_stat_mem_pkt_width_lp-1:0]         stat_mem_pkt_i
   , input                                            stat_mem_pkt_v_i
   , output logic                                     stat_mem_pkt_yumi_o
   , output logic [stat_width_lp-1:0]                 stat_mem_o
   );

  `declare_bp_fe_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `declare_bp_cfg_bus_s(vaddr_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, cce_pc_width_p, cce_instr_width_p);
  `declare_bp_fe_branch_metadata_fwd_s(btb_tag_width_p, btb_idx_width_p, bht_idx_width_p, ghist_width_p);
  `declare_bp_fe_mem_structs(vaddr_width_p, icache_sets_p, icache_block_width_p, vtag_width_p, ptag_width_p)
  
  bp_cfg_bus_s cfg_bus_cast_i;
  assign cfg_bus_cast_i = cfg_bus_i;
  
  bp_fe_cmd_s fe_cmd_cast_i;
  assign fe_cmd_cast_i = fe_cmd_i;
  
  bp_fe_queue_s fe_queue_cast_o;
  assign fe_queue_o = fe_queue_cast_o;

  enum logic [1:0] {e_wait=2'd0, e_run} state_n, state_r;
  
  // Decoded state signals
  wire is_wait  = (state_r == e_wait);
  wire is_run   = (state_r == e_run);
  
  logic [rv64_priv_width_gp-1:0] shadow_priv_n, shadow_priv_r;
  logic shadow_translation_en_n, shadow_translation_en_r;

  wire state_reset_v    = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_state_reset); 
  wire pc_redirect_v    = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_pc_redirection);
  wire itlb_fill_v      = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_itlb_fill_response);
  wire icache_fence_v   = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_icache_fence);
  wire itlb_fence_v     = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_itlb_fence);
  wire attaboy_v        = fe_cmd_v_i & (fe_cmd_cast_i.opcode == e_op_attaboy);
  wire cmd_nonattaboy_v = fe_cmd_v_i & (fe_cmd_cast_i.opcode != e_op_attaboy);

  wire trap_v = pc_redirect_v & (fe_cmd_cast_i.operands.pc_redirect_operands.subopcode == e_subop_trap);
  wire br_miss_v = pc_redirect_v
                & (fe_cmd_cast_i.operands.pc_redirect_operands.subopcode == e_subop_branch_mispredict);
  wire br_res_taken = (attaboy_v & fe_cmd_cast_i.operands.attaboy.taken)
                      | (br_miss_v & (fe_cmd_cast_i.operands.pc_redirect_operands.misprediction_reason == e_incorrect_pred_taken));
  wire br_res_ntaken = (attaboy_v & ~fe_cmd_cast_i.operands.attaboy.taken)
                       | (br_miss_v & (fe_cmd_cast_i.operands.pc_redirect_operands.misprediction_reason == e_incorrect_pred_ntaken));
  wire br_miss_nonbr = br_miss_v & (fe_cmd_cast_i.operands.pc_redirect_operands.misprediction_reason == e_not_a_branch);
  bp_fe_branch_metadata_fwd_s fe_cmd_branch_metadata;
  assign fe_cmd_branch_metadata = br_miss_v ? fe_cmd_cast_i.operands.pc_redirect_operands.branch_metadata_fwd : fe_cmd_cast_i.operands.attaboy.branch_metadata_fwd;

  logic [vaddr_width_p-1:0] next_pc_lo;
  logic next_pc_v_lo, next_pc_ready_li;
  logic override_v_lo;
  logic [instr_width_p-1:0] fetch_instr_li;
  logic [vaddr_width_p-1:0] fetch_pc_lo;
  logic fetch_v_li;
  bp_fe_branch_metadata_fwd_s fetch_br_metadata_lo;
  logic [vaddr_width_p-1:0] redirect_pc_li;
  bp_fe_branch_metadata_fwd_s redirect_br_metadata_li;
  logic redirect_br_taken_li;
  logic redirect_v_li;
  bp_fe_pc_gen
   #(.bp_params_p(bp_params_p))
   pc_gen
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
  
     ,.next_pc_o(next_pc_lo)
     ,.next_pc_v_o(next_pc_v_lo)
     ,.next_pc_ready_i(next_pc_ready_li)
  
     ,.override_v_o(override_v_lo)
  
     ,.fetch_pc_o(fetch_pc_lo)
     ,.fetch_instr_i(fetch_instr_li)
     ,.fetch_br_metadata_o(fetch_br_metadata_lo)
     ,.fetch_v_i(fetch_v_li)
  
     ,.replay_v_i(replay_v_li)

     ,.redirect_pc_i(redirect_pc_li)
     ,.redirect_br_metadata_i(redirect_br_metadata_li)
     ,.redirect_br_taken_i(redirect_br_taken_li)
     ,.redirect_v_i(redirect_v_li)

     ,.attaboy_br_metadata_i(attaboy_)
     ,.attaboy_v_i()
     ,.attaboy_yumi_o()
     );

   , input [branch_metadata_fwd_width_p-1:0]         attaboy_br_metadata_i
   , input                                           attaboy_v_i
   , output                                          attaboy_yumi_o
     );
  
  logic vaddr_v_li, vaddr_ready_li;
  bp_fe_tlb_entry_s itlb_r_entry;
  logic itlb_r_v_lo;
  bp_tlb
   #(.bp_params_p(bp_params_p), .tlb_els_p(itlb_els_p))
   itlb
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.flush_i(itlb_fence_v)
     ,.translation_en_i(shadow_translation_en_r)
  
     ,.v_i(vaddr_v_li | itlb_fill_v)
     ,.w_i(itlb_fill_v)
     ,.vtag_i(itlb_fill_v
              ? fe_cmd_cast_i.vaddr[vaddr_width_p-1-:vtag_width_p]
              : next_pc_lo[vaddr_width_p-1-:vtag_width_p]
              )
     ,.entry_i(fe_cmd_cast_i.operands.itlb_fill_response.pte_entry_leaf)
  
     ,.v_o(itlb_r_v_lo)
     ,.miss_v_o(itlb_miss_lo)
     ,.entry_o(itlb_r_entry)
     );
  
  logic uncached_li;
  bp_pma
   #(.bp_params_p(bp_params_p))
   pma
    (.ptag_v_i(itlb_r_v_lo)
     ,.ptag_i(itlb_r_entry.ptag)
  
     ,.uncached_o(uncached_li)
     );
  
  logic instr_access_fault_v, instr_page_fault_v;
  logic [instr_width_p-1:0] icache_data_lo;
  logic icache_data_v_lo;
  assign next_pc_ready_li = vaddr_ready_li & fe_queue_ready_i & ~(state_n == e_wait);
  assign vaddr_v_li = next_pc_v_lo;
  wire [ptag_width_p-1:0] ptag_li = itlb_r_entry.ptag;
  wire ptag_v_li = itlb_r_v_lo & ~instr_access_fault_v & ~instr_page_fault_v;
  wire mem_poison_lo = cmd_nonattaboy_v | override_v_lo;
  bp_fe_icache 
   #(.bp_params_p(bp_params_p)) 
   icache
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
  
     ,.cfg_bus_i(cfg_bus_i)
  
     ,.vaddr_i(next_pc_lo)
     ,.vaddr_v_i(vaddr_v_li)
     ,.vaddr_ready_o(vaddr_ready_li)
     ,.fencei_v_i(icache_fence_v)
  
     ,.ptag_i(ptag_li)
     ,.ptag_v_i(ptag_v_li)
     ,.uncached_i(uncached_li)
     ,.poison_i(mem_poison_lo)
  
     ,.data_o(icache_data_lo)
     ,.data_v_o(icache_data_v_lo)
     ,.miss_o()
  
     // LCE Interface
  
     ,.cache_req_o(cache_req_o)
     ,.cache_req_v_o(cache_req_v_o)
     ,.cache_req_ready_i(cache_req_ready_i)
     ,.cache_req_metadata_o(cache_req_metadata_o)
     ,.cache_req_metadata_v_o(cache_req_metadata_v_o)
  
     ,.cache_req_complete_i(cache_req_complete_i)
     ,.cache_req_critical_i(cache_req_critical_i)
  
     ,.data_mem_pkt_i(data_mem_pkt_i)
     ,.data_mem_pkt_v_i(data_mem_pkt_v_i)
     ,.data_mem_pkt_yumi_o(data_mem_pkt_yumi_o)
     ,.data_mem_o(data_mem_o)
  
     ,.tag_mem_pkt_i(tag_mem_pkt_i)
     ,.tag_mem_pkt_v_i(tag_mem_pkt_v_i)
     ,.tag_mem_pkt_yumi_o(tag_mem_pkt_yumi_o)
     ,.tag_mem_o(tag_mem_o)
  
     ,.stat_mem_pkt_v_i(stat_mem_pkt_v_i)
     ,.stat_mem_pkt_i(stat_mem_pkt_i)
     ,.stat_mem_pkt_yumi_o(stat_mem_pkt_yumi_o)
     ,.stat_mem_o(stat_mem_o)
     );

  wire shadow_w = state_reset_v | trap_v;
  assign shadow_priv_n = fe_cmd_cast_i.operands.pc_redirect_operands.priv;
  assign shadow_translation_en_n = fe_cmd_cast_i.operands.pc_redirect_operands.translation_enabled;
  bsg_dff_reset_en
   #(.width_p(rv64_priv_width_gp+1))
   shadow_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(shadow_w)
  
     ,.data_i({shadow_priv_n, shadow_translation_en_n})
     ,.data_o({shadow_priv_r, shadow_translation_en_r})
     );
     
  logic fetch_v_r, fetch_v_rr;
  logic itlb_miss_r;
  logic instr_access_fault_r, instr_page_fault_r;
  always_ff @(posedge clk_i)
    begin
      if(reset_i) begin
        fetch_v_r   <= '0;
        fetch_v_rr  <= '0;
        itlb_miss_r <= '0;
  
        instr_access_fault_r <= '0;
        instr_page_fault_r   <= '0;
      end
      else begin
        fetch_v_r   <= next_pc_v_lo;
        fetch_v_rr  <= fetch_v_r & ~mem_poison_lo;
        itlb_miss_r <= itlb_miss_lo;
  
        instr_access_fault_r <= instr_access_fault_v;
        instr_page_fault_r   <= instr_page_fault_v;
      end
    end
  
  wire instr_priv_page_fault = ((shadow_priv_r == `PRIV_MODE_S) & itlb_r_entry.u)
                                 | ((shadow_priv_r == `PRIV_MODE_U) & ~itlb_r_entry.u);
  wire instr_exe_page_fault = ~itlb_r_entry.x;
  
  // Fault if in uncached mode but access is not for an uncached address
  wire is_uncached_mode = (cfg_bus_cast_i.icache_mode == e_lce_mode_uncached);
  wire mode_fault_v = (is_uncached_mode & ~uncached_li);
  // TODO: Enable other domains by setting enabled dids with cfg_bus
  wire did_fault_v = (ptag_li[ptag_width_p-1-:io_noc_did_width_p] != '0);
  assign instr_access_fault_v = fetch_v_r & (mode_fault_v | did_fault_v);
  assign instr_page_fault_v   = fetch_v_r & itlb_r_v_lo & shadow_translation_en_r & (instr_priv_page_fault | instr_exe_page_fault);

  wire fe_instr_v = fetch_v_rr & icache_data_v_lo;
  wire fe_exception_v = fetch_v_rr & (instr_access_fault_r | instr_page_fault_r | itlb_miss_r);

  assign fetch_v_li = fetch_v_rr & icache_data_v_lo;
  assign fetch_instr_li = icache_data_lo;

  assign redirect_pc_li = fe_cmd_yumi_o ? fe_cmd_cast_i.vaddr : fetch_pc_lo;
  // Separate cache miss and queue miss
  assign redirect_br_metadata_li = fe_cmd_branch_metadata;
  assign redirect_br_taken_li = br_res_taken;
  assign redirect_v_li = cmd_nonattaboy_v;

  assign redi

  assign fe_queue_v_o = fe_queue_ready_i & (fe_instr_v | fe_exception_v);
  always_comb
    begin
      // Set padding to 0
      fe_queue_cast_o = '0;
  
      if (fe_exception_v)
        begin
          fe_queue_cast_o.msg_type                     = e_fe_exception;
          fe_queue_cast_o.msg.exception.vaddr          = fetch_pc_lo;
          fe_queue_cast_o.msg.exception.exception_code = itlb_miss_r
                                                         ? e_itlb_miss
                                                         : instr_page_fault_r
                                                           ? e_instr_page_fault
                                                           : e_instr_access_fault;
        end
      else 
        begin
          fe_queue_cast_o.msg_type                      = e_fe_fetch;
          fe_queue_cast_o.msg.fetch.pc                  = fetch_pc_lo;
          fe_queue_cast_o.msg.fetch.instr               = icache_data_lo;
          fe_queue_cast_o.msg.fetch.branch_metadata_fwd = fetch_br_metadata_lo;
        end
    end

  assign fe_cmd_yumi_o = redirect_v_li | attaboy_yumi_lo;

  // synopsys sync_set_reset "reset_i"
  always_ff @(posedge clk_i)
    if (reset_i)
        state_r <= e_wait;
    else
      begin
        state_r <= state_n;
      end

  always_comb
    case (state_r)
      // Wait for FE command
      e_wait: state_n = cmd_nonattaboy_v ? e_run : e_wait;
      e_run : state_n = fe_exception_v ? e_wait : e_run;
      default: state_n = e_wait;
    endcase


endmodule
