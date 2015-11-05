(*--build-config
    options:--admit_fsi FStar.OrdSet --admit_fsi FStar.OrdMap --admit_fsi FStar.Set --admit_fsi Ffibridge --admit_fsi Runtime --admit_fsi FStar.IO --admit_fsi FStar.String --__temp_no_proj;
    other-files:ghost.fst listTot.fst ordset.fsi ordmap.fsi classical.fst set.fsi heap.fst st.fst all.fst list.fst io.fsti string.fsi prins.fst ast.fst ffibridge.fsi sem.fst runtime.fsi print.fst ckt.fst interpreter.fst
 --*)

module SecServer

open FStar.Ghost

open FStar.OrdMap
open FStar.OrdSet

open Runtime

open Prins
open AST
open Semantics
open Interpreter

exception Comp_error

type en_map = ordmap prin env p_cmp
type out_map = ordmap prin chan_out p_cmp

type tpre_assec' (ps:prins) (ps':prins) (pi:tpar ps') (x:varname) (e:exp) (en_m:en_map) =
  forall p. contains p pi ==>
       (contains p en_m /\
        (Let (Some.v (select p pi))
         (fun c ->
	  is_T_red (Conf.t c) /\
	  (Let (T_red.r (Conf.t c))
	   (fun r ->
	    is_R_assec r /\ R_assec.ps r = ps /\ is_clos (R_assec.v r) /\
	    MkTuple3._2 (get_en_b (R_assec.v r)) = x /\
	    MkTuple3._3 (get_en_b (R_assec.v r)) = e /\
	    Some.v (select p en_m) = MkTuple3._1 (get_en_b (R_assec.v r)))))))

type psmap_v =
  | Mk_psmap:
    ps:prins -> ps':prins{subset ps' ps}
    -> en_m:en_map{forall p. mem p ps' = contains p en_m}
    -> out_m:out_map{forall p. mem p ps' = contains p out_m}
    -> x:varname -> e:exp
    -> pi:tpar ps'{tpre_assec' ps ps' pi x e en_m}
    -> psmap_v

type psmap = ordmap prins psmap_v ps_cmp

// Forcing instantiation of type variables in extracted OCaml code
type psmap_ref_t =
  | Mk_ref: r:ref (ordmap prins psmap_v ps_cmp) -> psmap_ref_t

(* private *) let psmap_ref = Mk_ref (alloc (OrdMap.empty #prins #psmap_v #ps_cmp))

val send_output: ps:prins -> out_m:out_map{contains_ps ps out_m}
                 -> dv:dvalue -> ML unit
let rec send_output ps out_m dv =
  let Some p = choose ps in
  let Some out = select p out_m in
  let ps_rest = remove p ps in
  let out_m' = OrdMap.remove p out_m in
  server_write out (slice_v p (D_v.v dv));
  if ps_rest = empty then ()
  else send_output ps_rest out_m' dv

val do_sec_comp': c:config -> ML (c':config{is_sterminal c'} & (sstep_star c c'))
let do_sec_comp' c =
  let (| c_opt, h |) = step_star c in
  if is_sterminal c_opt then
    (| c_opt, h |)
    (* let T_val #meta v = Conf.t c_opt in *)
    (* D_v meta v *)
  else
    failwith "Secure computation did not end in terminal state"

assume val give_proof: #p:Type -> u:unit{p} -> Tot p
assume val open_exists: #a:Type -> #p:(a -> Type) -> proof:(exists (x:a). p x) -> Tot (x:a & p x)
assume val take_proof: #p:Type -> proof:p -> Tot (u:unit{p})

val pss_ps_to_pss:
  #ps:prins -> #pi:protocol ps -> #pi':protocol ps -> #pi'':protocol ps
  -> h1:pstep_star #ps pi pi' -> h2:pstep #ps pi' pi''
  -> Tot (pstep_star #ps pi pi'') (decreases h1)
let rec pss_ps_to_pss #ps #pi #pi' #pi'' h1 h2 = match h1 with
  | PS_refl _       -> PS_tran h2 (PS_refl pi'')
  | PS_tran h1' h2' ->
    let hh = pss_ps_to_pss h2' h2 in
    PS_tran h1' hh

#set-options "--z3timeout 25"

val create_pstep_star: data:psmap_v{Equal data.ps data.ps'} -> ML unit
let create_pstep_star data =
  let Mk_psmap ps _ en_m _ x e pi = data in

  let pi_init = (pi, (OrdMap.empty #prins #tconfig_sec #ps_cmp)) in

  let _ = cut (OrdMap.Equal (get_env_m #ps pi_init ps) en_m) in

  let pi_enter = tstep_assec #ps pi_init ps x e in
  let (pi_enter_par, pi_enter_sec) = pi_enter in
 
  let s1:pstep #ps pi_init pi_enter =
    P_sec_enter #ps pi_init ps x e pi_enter in

  let c_sec_init = Conf Target (Mode Sec ps) [] (update_env (compose_envs_m ps en_m) x V_unit) (T_exp e) (hide []) in

  let _ = cut (b2t (pi_enter_sec = update ps c_sec_init (snd pi_init))) in

  let (| c_sec_terminal, sstep_h |) = do_sec_comp' c_sec_init in

  let _ = sec_comp_step_star_same_mode #c_sec_init #c_sec_terminal sstep_h in

  let _ = cut (is_sec c_sec_terminal /\ Conf.l c_sec_terminal = Target) in

  let tsec_terminal:tsec = update ps c_sec_terminal (snd pi_init) in
  let pi_sec_terminal:(protocol ps) = (pi_enter_par, tsec_terminal) in
  
  let ss:pstep_star #ps pi_enter pi_sec_terminal =
    sec_sstep_star_to_pstep_star c_sec_init c_sec_terminal sstep_h ps pi_enter_par (snd pi_init) in

  let _ = cut (b2t (contains ps (snd pi_sec_terminal))) in
  let _ = cut (b2t (Some.v (select ps (snd pi_sec_terminal)) = c_sec_terminal)) in
  let _ = cut (b2t (Conf.m c_sec_terminal = Mode Sec ps)) in
  let _ = cut (b2t (is_value c_sec_terminal)) in
  let _ = cut (b2t (Conf.s c_sec_terminal = [])) in
  //let _ = cut (tpre_assec_ret #ps pi_sec_terminal ps) in

  //let _ = cut (is_sec c_sec_terminal /\ is_value c_sec_terminal) in
  let pi_final_par = ret_sec_value_to_ps #ps pi_enter_par c_sec_terminal ps in
  let pi_final = (pi_final_par, OrdMap.remove ps tsec_terminal) in

  (* let T_val #meta v = Conf.t c_sec_terminal in *)
  (* let _ = assert (forall p. mem p ps ==> *)
  (*                      (Let (Conf.t (Some.v (select p (pi_final_par)))) *)
  (* 		        (fun t -> *)
  (* 			 is_T_val t /\ *)
  (* 			 (D_v (T_val.meta t) (T_val.v t) = *)
  (* 			  slice_v #meta p v)))) in *)

  let s2:pstep #ps pi_sec_terminal pi_final =
    P_sec_exit #ps pi_sec_terminal ps pi_final in

  let h1:pstep_star #ps pi_enter pi_final =
    pss_ps_to_pss #ps #pi_enter #pi_sec_terminal #pi_final ss s2 in

  let h2:pstep_star #ps pi_init pi_final =
    PS_tran #ps #pi_init #pi_enter #pi_final s1 h1 in

  ()

#reset-options

val handle_connection: chan_in -> chan_out -> ML unit
let handle_connection c_in c_out =
  let p, r = server_read c_in in

  admitP (is_R_assec r /\ is_clos (R_assec.v r));
  admitP (exists c. Conf.t c = T_red r /\ Conf.l c = Target /\ is_par c);

  let R_assec #meta ps v = r in
  let (en, x, e) = get_en_b v in

  let _ = admitP (b2t (mem p ps)) in

  let c =
    let proof = give_proof #(exists c. Conf.t c = T_red r /\ Conf.l c = Target /\ is_par c) () in
    let (| c, proof |) = open_exists #config #(fun c -> Conf.t c = T_red r /\ Conf.l c = Target /\ is_par c) proof in
    let _ = take_proof proof in
    c
  in

  let psmap_ref = Mk_ref.r psmap_ref in

  let ps', pi, en_m, out_m =
    if contains ps !psmap_ref then
      let Some (Mk_psmap ps1 ps' en_m out_m  x' e' pi) = select ps !psmap_ref in
      let _ = admitP (b2t (e = e')) in
      if ps = ps1 && x = x' then
	let en_m = update #prin #env #p_cmp p en en_m in
	let out_m = update #prin #chan_out #p_cmp p c_out out_m in

        let pi = update #prin #tconfig_par #p_cmp p c pi in
        let ps' = union #prin #p_cmp ps' (singleton p) in

	ps', pi, en_m, out_m
      else failwith "Not a valid secure computation request"
    else
      let en_m = update #prin #env #p_cmp p en OrdMap.empty in
      let out_m = update #prin #chan_out #p_cmp p c_out OrdMap.empty in
      let pi = update #prin #tconfig_par #p_cmp p c OrdMap.empty in
      let ps' = singleton p in

      ps', pi, en_m, out_m
  in

  let _ = assert (Equal (dom #prin #env #p_cmp en_m) (dom #prin #chan_out #p_cmp out_m)) in

  if ps = ps' then
    let _ = create_pstep_star (Mk_psmap ps ps en_m out_m x e pi) in
    let c_sec_init = Conf Target (Mode Sec ps) [] (update_env (compose_envs_m ps en_m) x V_unit) (T_exp e) (hide []) in

    let (| c_sec_terminal, _ |) = do_sec_comp' c_sec_init in

    let _ = send_output ps out_m (c_value c_sec_terminal) in
    psmap_ref := OrdMap.remove ps (!psmap_ref)
  else
    psmap_ref := (update ps (Mk_psmap ps ps' en_m out_m x e pi) (!psmap_ref))


(*     //let _ = create_thread (do_sec_comp ps env_m' out_m' x e) in *)
