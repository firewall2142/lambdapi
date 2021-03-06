(** Toplevel commands. *)

open! Lplib
open Lplib.Extra

open Timed
open Console
open Terms
open Sign
open Pos
open Files
open Syntax
open Sig_state
open Scope
open Print
open Proof

(** Logging function for command handling. *)
let log_hndl = new_logger 'h' "hndl" "command handling"
let log_hndl = log_hndl.logger

(* Register a check for the type of the builtin symbols "0" and "+1". *)
let _ =
  let register = Builtin.register_expected_type (Unif.eq_noexn []) pp_term in
  let expected_zero_type ss _pos =
    try
      match !((StrMap.find "+1" ss.builtins).sym_type) with
      | Prod(a,_) -> a
      | _ -> assert false
    with Not_found -> Meta (Meta.fresh Type 0, [||])
  in
  register "0" expected_zero_type;
  let expected_succ_type ss _pos =
    let typ_0 =
      try lift !((StrMap.find "0" ss.builtins).sym_type)
      with Not_found -> _Meta (Meta.fresh Type 0) [||]
    in
    Bindlib.unbox (_Impl typ_0 typ_0)
  in
  register "+1" expected_succ_type

(** Representation of a yet unchecked proof. The structure is initialized when
    the proof mode is entered, and its finalizer is called when the proof mode
    is exited (i.e., when a terminator like “end” is used).  Note that tactics
    do not work on this structure directly,  although they act on the contents
    of its [pdata_p_state] field. *)
type proof_data =
  { pdata_stmt_pos : Pos.popt (* Position of the proof's statement.  *)
  ; pdata_p_state  : Proof.t  (* Initial proof state for the proof.  *)
  ; pdata_tactics  : p_tactic list (* Tactics for the proof.         *)
  ; pdata_finalize : sig_state -> Proof.t -> sig_state (* Finalizer. *)
  ; pdata_end_pos  : Pos.popt (* Position of the proof's terminator. *)
  ; pdata_expo     : Terms.expo (* Allow use of private symbols      *) }

(** [handle_open pos ss p] handles the command [open p] with [ss] as the
   signature state. On success, an updated signature state is returned. *)
let handle_open : popt -> sig_state -> Path.t -> sig_state =
    fun pos ss p ->
  (* Obtain the signature corresponding to [m]. *)
  let sign =
    try PathMap.find p !(Sign.loaded) with Not_found ->
      (* The signature has not been required... *)
      fatal pos "Module [%a] has not been required." Path.pp p
  in
  (* Open the module. *)
  open_sign ss sign

(** [handle_require b pos ss p] handles the command [require p] (or [require
   open p] if b is true) with [ss] as the signature state. On success, an
   updated signature state is returned. *)
let handle_require : bool -> popt -> sig_state -> Path.t -> sig_state =
    fun b pos ss p ->
  (* Check that the module has not already been required. *)
  if PathMap.mem p !(ss.signature.sign_deps) then
    fatal pos "Module [%a] is already required." Path.pp p;
  (* Add the dependency (it was compiled already while parsing). *)
  ss.signature.sign_deps := PathMap.add p [] !(ss.signature.sign_deps);
  if b then handle_open pos ss p else ss

(** [handle_modifiers ms] verifies that the modifiers in [ms] are compatible.
    If so, they are returned as a tuple, otherwise, the incompatible modifiers
    are returned. *)
let handle_modifiers : p_modifier list -> (prop * expo * match_strat) =
  fun ms ->
  let die (ms: p_modifier list) =
    let modifier oc (m: p_modifier) =
      Format.fprintf oc "%a:\"%a\"" Pos.print_short m.pos Pretty.modifier m
    in
    fatal_no_pos "%a" (List.pp modifier "; ") ms
  in
  let prop = List.filter is_prop ms in
  let prop =
    match prop with
    | _::_::_ ->
        fatal_msg "Only one property modifier can be used, \
                   %d have been found: " (List.length prop);
        die prop
    | [{elt=P_prop(p); _}] -> p
    | [] -> Defin
    | _ -> assert false
  in
  let expo = List.filter is_expo ms in
  let expo =
    match expo with
    | _::_::_ ->
        fatal_msg "Only one exposition marker can be used, \
                   %d have been found: " (List.length expo);
        die expo
    | [{elt=P_expo(e); _}] -> e
    | [] -> Public
    | _ -> assert false
  in
  let mstrat = List.filter is_mstrat ms in
  let mstrat =
    match mstrat with
    | _::_::_ ->
        fatal_msg "Only one strategy modifier can be used, \
                   %d have been found: " (List.length mstrat);
        die mstrat
    | [{elt=P_mstrat(s); _ }] -> s
    | [] -> Eager
    | _ -> assert false
  in
  (prop, expo, mstrat)

(** [handle_require_as pos ss p id] handles the command [require p as id] with
    [ss] as the signature state. On success, an updated signature state is
    returned. *)
let handle_require_as : popt -> sig_state -> Path.t -> ident -> sig_state =
  fun pos ss p id ->
  let ss = handle_require false pos ss p in
  let aliases = StrMap.add id.elt p ss.aliases in
  let path_map = PathMap.add p id.elt ss.path_map in
  {ss with aliases; path_map}

(** [handle_symbol ss e p strat x xs a] handles the command
    [e p strat symbol x xs : a] with [ss] as the signature state.
    On success, an updated signature state and the new symbol are returned. *)
let handle_symbol :
  sig_state -> expo -> prop -> match_strat -> ident -> p_args list ->
  p_type -> sig_state * sym = fun ss e p strat x xs a ->
  let scope_basic exp = Scope.scope_term exp ss Env.empty in
  (* We check that [x] is not already used. *)
  if Sign.mem ss.signature x.elt then
    fatal x.pos "Symbol [%s] already exists." x.elt;
  (* Desugaring of arguments of [a]. *)
  let a = if xs = [] then a else Pos.none (P_Prod(xs, a)) in
  (* Obtaining the implicitness of arguments. *)
  let impl = Scope.get_implicitness a in
  (* We scope the type of the declaration. *)
  let a = scope_basic e a in
  (* We check that [a] is typable by a sort. *)
  Infer.check_sort Unif.solve_noexn x.pos [] a;
  (* We check that no metavariable remains. *)
  if Basics.has_metas true a then
    (fatal_msg "The type of [%s] has unsolved metavariables.\n" x.elt;
     fatal x.pos "We have %s : %a." x.elt pp_term a);
  (* Actually add the symbol to the signature and the state. *)
  out 3 "(symb) %s : %a\n" x.elt pp_term a;
  let sig_symbol = {expo=e;prop=p;mstrat=strat;ident=x;typ=a;impl;def=None} in
  add_symbol ss sig_symbol

(** [handle_rule ss syms r] checks rule [r], adds it in [ss] and returns the
   set [syms] extended with the symbol [s] defined by [r]. However, it does
   not update the decision tree of [s]. *)
let handle_rule : sig_state -> p_rule -> sym = fun ss r ->
  let pr = scope_rule false ss r in
  let sym = pr.elt.pr_sym in
  if !(sym.sym_def) <> None then
    fatal pr.pos "Rewriting rules cannot be given for defined symbol [%s]."
      sym.sym_name;
  let rule = Sr.check_rule pr in
  Sign.add_rule ss.signature sym rule;
  out 3 "(rule) %a\n" pp_rule (sym, rule);
  sym

(** [handle_rules ss rs] handles the rules [rs] in signature state [ss], and
   update the decision trees of the symboles defined by [rs]. *)
let handle_rules : sig_state -> p_rule list -> sig_state = fun ss rs ->
  let handle_rule syms r = SymSet.add (handle_rule ss r) syms in
  let syms = List.fold_left handle_rule SymSet.empty rs in
  SymSet.iter Tree.update_dtree syms;
  ss

(** [data_proof] returns the datas needed for the symbol or definition
    [sig_symbol] to be added in the signature and the [goals] we wish to prove
    with the proof script [ts pe]. [pdata_expo] sets the authorized exposition
    of the symbols used in the proof script : Public (= only public symbols)
    or Privat (= public and private symbols) *)
let data_proof : sig_symbol -> expo -> p_tactic list ->
  p_proof_end -> Goal.t list -> meta option -> proof_data =
  fun sig_symbol pdata_expo ts pe goals proof_term ->
  let ident = sig_symbol.ident in
  let typ   = sig_symbol.typ   in
  let def   = sig_symbol.def   in
  let pos = ident.pos in
  (* Initialize proof state and save configuration data. *)
  let ps = {proof_name = ident ; proof_term ; proof_goals = goals} in
  Console.State.push ();
  (* Build proof checking data. *)
  let finalize ss ps =
    Console.State.pop ();
    match pe.elt with
    | P_proof_abort ->
      (* Just ignore the command, with a warning. *)
      wrn pos "Proof aborted."; ss
    | _ ->
      (* We try to solve remaining unification goals. *)
      let ps = Tactics.solve_tac ps pos in
      (* We check that no metavariable remains. *)
      if Basics.has_metas true typ then
        begin
          fatal_msg "The type of [%s] has unsolved metavariables.\n"
            ident.elt;
          fatal ident.pos "We have %s : %a." ident.elt pp_term typ
        end;
      begin
        match def with
        | Some(t) ->
          if Basics.has_metas true t then
            begin
              fatal_msg
                "The definition of [%s] has unsolved metavariables.\n"
                ident.elt;
              fatal ident.pos "We have %s : %a ≔ %a."
                ident.elt pp_term typ pp_term t
            end;
        | None -> ()
      end;
      match pe.elt with
      | P_proof_abort -> assert false (* Handled above *)
      | P_proof_admit ->
        (* If the proof is finished, display a warning. *)
        if finished ps then
          wrn pos "The proof is finished. You can use 'end' instead.";
        (* Add a symbol corresponding to the proof, with a warning. *)
        out 3 "(symb) %s (admit)\n" ident.elt;
        wrn pos "Proof admitted.";
        fst (add_symbol ss sig_symbol)
      | P_proof_end   ->
        (* Check that the proof is indeed finished. *)
        if not (finished ps) then
          (out 1 "%a" Proof.pp_goals ps;
           fatal pos "The proof is not finished.");
        (* Add a symbol corresponding to the proof. *)
        out 3 "(symb) %s (end)\n" ident.elt;
        fst (add_symbol ss sig_symbol)
  in
  let data =
    { pdata_stmt_pos = pos ; pdata_p_state = ps ; pdata_tactics = ts
    ; pdata_finalize = finalize ; pdata_end_pos = pe.pos
    ; pdata_expo = pdata_expo }
  in
  data

(** [handle_cmd ss cmd] tries to handle the command [cmd] with [ss] as the
    signature state. On success, an updated signature state is returned.  When
    [cmd] leads to entering the proof mode,  a [proof_data] is also  returned.
    This structure contains the list of the tactics to be executed, as well as
    the initial state of the proof.  The checking of the proof is then handled
    separately. Note that [Fatal] is raised in case of an error. *)
let handle_cmd : sig_state -> p_command -> sig_state * proof_data option =
  fun ss cmd ->
  let scope_basic exp pt = Scope.scope_term exp ss Env.empty pt in
  match cmd.elt with
  | P_require(b,ps)              ->
      let ps = List.map (List.map fst) ps in
      (List.fold_left (handle_require b cmd.pos) ss ps, None)
  | P_require_as(p,id)           ->
      let id = Pos.make id.pos (fst id.elt) in
      (handle_require_as cmd.pos ss (List.map fst p) id, None)
  | P_open(ps)                   ->
      let ps = List.map (List.map fst) ps in
      (List.fold_left (handle_open cmd.pos) ss ps, None)
  | P_rules(rs)                  ->
      let handle_rule syms r = SymSet.add (handle_rule ss r) syms in
      let syms = List.fold_left handle_rule SymSet.empty rs in
      SymSet.iter Tree.update_dtree syms;
      (ss, None)
  | P_inductive(ms, p_ind_list)     ->
      (* Check modifiers. *)
      let (prop, e, mstrat) = handle_modifiers ms in
      if prop <> Defin then
        fatal cmd.pos "Property modifiers cannot be used on inductive types.";
      if mstrat <> Eager then
        fatal cmd.pos "Pattern matching strategy modifiers cannot be used on \
                       inductive types.";
      (* Add inductive types in the signature. *)
      let add_ind_sym (ss, ind_sym_list) p_ind =
        let (id, pt, _) = p_ind.elt in
        let (ss, ind_sym) = handle_symbol ss e Injec Eager id [] pt in
        (ss, ind_sym::ind_sym_list)
      in
      let (ss, ind_sym_list_rev) =
        List.fold_left add_ind_sym (ss, []) p_ind_list in
      (* Add constructors in the signature. *)
      let add_constructors (ss, cons_sym_list_list) p_ind =
        let (_, _, p_cons_list) = p_ind.elt in
        let add_cons_sym (ss, cons_sym_list) (id, pt) =
          let (ss, cons_sym) = handle_symbol ss e Const Eager id [] pt in
          (ss, cons_sym::cons_sym_list)
        in
        let (ss, cons_sym_list_rev) =
          List.fold_left add_cons_sym (ss, []) p_cons_list in
        (* Reverse the list of constructors previously computed to preserve
           the initial order. *)
        let cons_sym_list = List.rev cons_sym_list_rev in
        (ss, cons_sym_list::cons_sym_list_list)
      in
      let (ss, cons_sym_list_list_rev) =
        List.fold_left add_constructors (ss, []) p_ind_list
      in
      let ind_list =
        List.fold_left2 (fun acc x y -> (x,y)::acc) []
          ind_sym_list_rev cons_sym_list_list_rev
      in
      (* Compute data useful for generating the induction principles. *)
      let c = Inductive.get_config ss cmd.pos in
      let p_str, x_str = Inductive.gen_safe_prefixes ind_list in
      let ind_pred_map =
        Inductive.create_ind_pred_map cmd.pos c ind_list p_str x_str
      in
      (* Compute the induction principles. *)
      let rec_typ_list_rev =
        Inductive.gen_rec_types c ss cmd.pos ind_list ind_pred_map x_str
      in
      (* Add the induction principles in the signature. *)
      let add_recursor (ss, rec_sym_list) ind_sym rec_typ =
        let rec_name = Inductive.rec_name ind_sym in
        if Sign.mem ss.signature rec_name then
          fatal cmd.pos "Symbol [%s] already exists." rec_name;
        (* If [ind_sym] is a declared identifier, then [rec_sym] must be
           declared too. *)
        if StrSet.mem ind_sym.sym_name !(ss.signature.sign_idents) then
          Sign.add_ident ss.signature rec_name;
        let (ss, rec_sym) =
          out 3 "(symb) %s : %a\n" rec_name pp_term rec_typ;
          let sig_symbol =
            {expo = e;
             prop = Defin;
             mstrat = Eager;
             ident = Pos.make cmd.pos rec_name;
             typ = rec_typ;
             impl = [];
             def = None}
          in
          Sig_state.add_symbol ss sig_symbol
        in
        (ss, rec_sym::rec_sym_list)
      in
      let (ss, rec_sym_list) =
        List.fold_left2 add_recursor (ss, [])
          ind_sym_list_rev rec_typ_list_rev
      in
      (* Add recursor rules in the signature. *)
      with_no_wrn
        (Inductive.iter_rec_rules cmd.pos ind_list ind_pred_map)
        (fun r -> ignore (handle_rule ss r));
      List.iter Tree.update_dtree rec_sym_list;
      (* Store the inductive structure in the signature *)
      List.iter2
        (fun (ind_sym, cons_sym_list) rec_sym ->
          Sign.add_inductive ss.signature ind_sym cons_sym_list rec_sym)
        ind_list
        rec_sym_list;
      (ss, None)
  | P_symbol {p_sym_mod;p_sym_nam;p_sym_arg;p_sym_typ;p_sym_trm;p_sym_prf;
              p_sym_def} ->
    (* Check that this is a syntactically valid symbol declaration. *)
    begin
      match (p_sym_typ, p_sym_def, p_sym_trm, p_sym_prf) with
      | (None, true, None, Some _) -> fatal p_sym_nam.pos "missing type"
      | (   _, true, None, None  ) -> fatal p_sym_nam.pos "missing definition"
      | _ -> ()
    end;
    (* Get opacity. *)
    let op = List.exists Syntax.is_opaq p_sym_mod in
    (* Verify modifiers. *)
    let (prop, expo, mstrat) = handle_modifiers p_sym_mod in
    (* We check that [x] is not already used. *)
    if Sign.mem ss.signature p_sym_nam.elt then
      fatal p_sym_nam.pos "Symbol [%s] already exists." p_sym_nam.elt;
    let data =
      (* Desugaring of arguments and scoping of [p_sym_trm]. *)
      let pt, t =
        match p_sym_trm with
        | Some pt ->
            let pt =
              if p_sym_arg = [] then pt
              else Pos.make p_sym_nam.pos (P_Abst(p_sym_arg,pt))
            in
            Some pt, Some (scope_basic expo pt)
        | None -> None, None
      in
      (* Argument impliciteness. *)
      let ao, impl =
        match p_sym_typ with
        | None    -> (None, List.map (fun (_,_,impl) -> impl) p_sym_arg)
        | Some(a) ->
            let a =
              if p_sym_arg = [] then a
              else Pos.make p_sym_nam.pos (P_Prod(p_sym_arg,a))
            in
            (Some(a), Scope.get_implicitness a)
      in
      (* Scope the type and get its metavariables. *)
      let ao, metas_a =
        begin
          match ao with
          | Some a ->
            let a = scope_basic expo a in
            let metas_a = Basics.get_metas true a in
            Some a, metas_a
          | None -> None, MetaSet.empty
        end
      in
      (* Proof script *)
      let ts, pe =
        match pt, p_sym_prf with
        | Some pt, None ->
            [Pos.make pt.pos (P_tac_refine pt)],
            Pos.make (Pos.end_pos cmd.pos) P_proof_end
        | Some pt, Some(ts,pe) -> Pos.make pt.pos (P_tac_refine pt)::ts, pe
        | None, Some(ts,pe) -> ts, pe
        | None, None -> [], Pos.make (Pos.end_pos cmd.pos) P_proof_end
      in
      (* If [ao = Some a], then we check that [a] is typable by a sort and
         that [t] has type [a]. Otherwise, we try to infer the type of
         [t]. Unification goals are collected. *)
      let typ_goals_a = goals_of_metas metas_a in
      let proof_term, goals, sig_symbol, pdata_expo =
        let sort_goals, a = goals_of_typ p_sym_nam.pos ao t in
        (* And the main "type" goal *)
        let proof_term, typ_goal =
          if p_sym_def then
            let proof_term = Meta.fresh ~name:p_sym_nam.elt a 0 in
            let proof_goal = Goal.of_meta proof_term in
            Some proof_term, proof_goal :: typ_goals_a
          else
            None, typ_goals_a
        in
        let goals = sort_goals @ typ_goal in
        let sig_symbol =
          {expo;prop;mstrat;ident=p_sym_nam;typ=a;impl;def=t} in
        (* Depending on opacity : theorem = false / definition = true *)
        let pdata_expo =
          match p_sym_def, op, ao, prop, mstrat with
          (* Theorem *)
          | false,     _,      _ ,    _ ,     _  -> expo
          |     _, true ,      _ , Defin, Eager  -> Privat
          |     _, true ,      _ , _    , Eager  ->
            fatal cmd.pos "Property modifiers can't be used in theorems."
          |     _, true ,      _ , _    , _      ->
            fatal cmd.pos "Pattern matching strategy modifiers cannot \
                           be used in theorems."
          (* Definition *)
          |     _, false, _      , _    , Sequen ->
            fatal cmd.pos "Pattern matching strategy modifiers cannot \
                           be used in definitions."
          |     _, false, _      , _    , _      -> expo
        in
        proof_term, goals, sig_symbol, pdata_expo
      in
      data_proof sig_symbol pdata_expo ts pe goals proof_term
    in
    (ss, Some(data))
  | P_set(cfg)                 ->
      let ss =
        let with_path : Path.t -> qident -> qident = fun path qid ->
          let path = List.map (fun s -> (s, false)) path in
          Pos.make qid.pos (path, snd qid.elt)
        in
        match cfg with
        | P_config_builtin(s,qid) ->
            (* Set the builtin symbol [s]. *)
            if StrMap.mem s ss.builtins then
              fatal cmd.pos "Builtin [%s] already exists." s;
            let sym = find_sym ~prt:true ~prv:true false ss qid in
            Builtin.check ss cmd.pos s sym;
            out 3 "(conf) set builtin \"%s\" ≔ %a\n" s pp_symbol sym;
            add_builtin ss s sym
        | P_config_unop(unop)     ->
            let (s, prio, qid) = unop in
            let sym = find_sym ~prt:true ~prv:true false ss qid in
            (* Make sure the operator has a fully qualified [qid]. *)
            let unop = (s, prio, with_path sym.sym_path qid) in
            out 3 "(conf) %a %a\n" pp_symbol sym pp_hint (Prefix unop);
            add_unop ss s (sym, unop)
        | P_config_binop(binop)   ->
            let (s, assoc, prio, qid) = binop in
            (* Define the binary operator [sym]. *)
            let sym = find_sym ~prt:true ~prv:true false ss qid in
            (* Make sure the operator has a fully qualified [qid]. *)
            let binop = (s, assoc, prio, with_path sym.sym_path qid) in
            out 3 "(conf) %a %a\n" pp_symbol sym pp_hint (Infix binop);
            add_binop ss s (sym, binop);
        | P_config_ident(id)      ->
            Sign.add_ident ss.signature id;
            out 3 "(conf) declared identifier \"%s\"\n" id; ss
        | P_config_quant(qid)     ->
            let sym = find_sym ~prt:true ~prv:true false ss qid in
            out 3 "(conf) %a quantifier\n" pp_symbol sym;
            add_quant ss sym
        | P_config_unif_rule(h)   ->
            (* Approximately same processing as rules without SR checking. *)
            let pur = (scope_rule true ss h).elt in
            let urule =
              { lhs = pur.pr_lhs
              ; rhs = Bindlib.(unbox (bind_mvar pur.pr_vars pur.pr_rhs))
              ; arity = List.length pur.pr_lhs
              ; arities = pur.pr_arities
              ; vars = pur.pr_vars
              ; xvars_nb = pur.pr_xvars_nb }
            in
            Sign.add_rule ss.signature Unif_rule.equiv urule;
            Tree.update_dtree Unif_rule.equiv;
            out 3 "(hint) [%a]\n" Print.pp_rule (Unif_rule.equiv, urule); ss
      in
      (ss, None)
  | P_query(q)                 ->
      Queries.handle_query ss None q; (ss, None)

(** [too_long] indicates the duration after which a warning should be given to
    indicate commands that take too long to execute. *)
let too_long = Stdlib.ref infinity

(** [handle_cmd ss cmd] adds to the previous [handle_cmd] some
    exception handling. In particular, the position of [cmd] is used on errors
    that lack a specific position. All exceptions except [Timeout] and [Fatal]
    are captured, although they should not occur. *)
let handle_cmd : sig_state -> p_command -> sig_state * proof_data option =
  fun ss cmd ->
  Print.sig_state := ss;
  try
    let (tm, ss) = time (handle_cmd ss) cmd in
    if Stdlib.(tm >= !too_long) then
      wrn cmd.pos "It took %.2f seconds to handle the command." tm;
    ss
  with
  | Timeout                as e -> raise e
  | Fatal(Some(Some(_)),_) as e -> raise e
  | Fatal(None         ,m)      -> fatal cmd.pos "Error on command.\n%s" m
  | Fatal(Some(None)   ,m)      -> fatal cmd.pos "Error on command.\n%s" m
  | e                           ->
      fatal cmd.pos "Uncaught exception [%s]." (Printexc.to_string e)
