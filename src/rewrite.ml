(** Implementation of the REWRITE tactic. *)

open Timed
open Terms
open Print
open Console
open Proofs

(** Logging function for the rewrite tactic. *)
let log_rewr = new_logger 'w' "rewr" "informations for the rewrite tactic"
let log_rewr = log_rewr.logger

(** For now, a pattern is just a term. *)
type pattern = term

(** [term_match p t] is given a (pattern) term [p] and a term [t], and returns
    [true] if and only if [t] “matches” [p]. Note that, for the moment, we use
    syntactic equality. *)
let term_match : pattern -> term -> bool = Terms.eq

(** [bind_match p t] binds every occurence of the pattern [p] in the term [t].
    Note that [t] should not contain products, abstractions, metavariables, or
    other awkward terms. *)
let bind_match : pattern -> term -> (term, term) Bindlib.binder = fun p t ->
  let x = Bindlib.new_var mkfree "X" in
  (* NOTE we lift to the bindbox while matching (for efficiency). *)
  let rec lift_subst : term -> tbox = fun t ->
    if term_match p t then _Vari x else
    match unfold t with
    | Vari(y)     -> _Vari y
    | Type        -> _Type
    | Kind        -> _Kind
    | Symb(s)     -> _Symb s
    | Appl(t,u)   -> _Appl (lift_subst t) (lift_subst u)
    (* For now, we fail on products, abstractions and metavariables. *)
    | Prod(_)     -> fatal_no_pos "Cannot rewrite under products."
    | Abst(_)     -> fatal_no_pos "Cannot rewrite under abstractions."
    | Meta(_)     -> fatal_no_pos "Cannot rewrite metavariables."
    (* Forbidden cases. *)
    | Patt(_,_,_) -> assert false
    | TEnv(_,_)   -> assert false
  in
  Bindlib.unbox (Bindlib.bind_var x (lift_subst t))

(** [handle_rewrite t] rewrites according to the equality proved by [t] in the
    current goal. The term [t] should have a type corresponding to an equality
    (without any quantifier for now). All instances of the LHS are replaced by
    the RHS in the obtained goal. *)
let handle_rewrite : term -> unit = fun t ->
  (* Obtain the required symbols from the current signature. *)
  (* FIXME use a parametric noton of equality. *)
  let find_sym : string -> sym =
    let find_symb sign name =
      try Sign.find sign name with Not_found ->
      fatal_no_pos "Current signature does not define symbol [%s]." name
    in
    find_symb (Sign.current_sign ())
  in
  let sign_P = find_sym "P" in
  let sign_T = find_sym "T" in
  let sign_eq = find_sym "eq" in
  let sign_eqind = find_sym "eqind" in

  (* Get the focused goal, and related data. *)
  let thm = current_theorem () in
  let (g, gs) =
    match thm.t_goals with
    | []    -> fatal_no_pos "No remaining goals..."
    | g::gs -> (g, gs)
  in

  (* Infer the type of [t] (the argument given to the tactic). *)
  let g_ctxt = Ctxt.of_env g.g_hyps in
  let t_type =
    match Solve.infer g_ctxt t with
    | Some(a) -> a
    | None    ->
        fatal_no_pos "Cannot infer the type of [%a] (given to rewrite)." pp t
  in

  (* Check that the type of [t] is of the form “P (Eq a l r)”. *)
  (* TODO allow for quantifiers. *)
  let is_symb : sym -> term -> bool = fun s t ->
    match unfold t with
    | Symb(r) -> r == s
    | _       -> false
  in
  let (a, l, r) =
    match get_args t_type with
    | (p,[eq]) when is_symb sign_P p ->
        begin
          match get_args eq with
          | (e,[a;l;r]) when is_symb sign_eq e -> (a, l, r)
          | _                                  ->
              fatal_no_pos "Rewrite expected equality type (found [%a])." pp t
        end
    | _                              ->
        fatal_no_pos "Rewrite expected equality type (found [%a])." pp t
  in

  (* Extract the term from the goal type (get “t” from “P t”). *)
  let g_term =
    match get_args g.g_type with
    | (p, [t]) when is_symb sign_P p -> t
    | _                              ->
        fatal_no_pos "Rewrite expects a goal of the form “P t” (found [%a])."
          pp g.g_type
  in

  (* Build the predicate by matching [l] in [g_term]. *)
  (* TODO keep track of substitutions in the first instance of l in g. *)
  let pred_bind = bind_match l g_term in
  let pred = Abst(Appl(Symb(sign_T), a), pred_bind) in

  (* Construct new goal and it type. *)
  let goal_type = Appl(Symb(sign_P), Bindlib.subst pred_bind r) in
  let goal_term = Ctxt.make_meta g_ctxt goal_type in
  let new_goal =
    match goal_term with
    | Meta(m,_) -> m
    | _          -> assert false (* Cannot happen. *)
  in

  (* Build the final term produced by the tactic, and check its type. *)
  let term = add_args (Symb(sign_eqind)) [a; l; r; t; pred; goal_term] in
  if not (Solve.check g_ctxt term g.g_type) then
    begin
      match Solve.infer g_ctxt term with
      | Some(a) ->
          fatal_no_pos "The term produced by rewrite has type [%a], not [%a]."
            pp (Eval.snf a) pp g.g_type
      | None    ->
          fatal_no_pos "The term [%a] produced by rewrite is not typable."
            pp term
    end;

  (* Instantiate the current goal. *)
  let meta_env = Array.map Bindlib.unbox (Env.vars_of_env g.g_hyps)  in
  let b = Bindlib.bind_mvar (to_tvars meta_env) (lift term) in
  g.g_meta.meta_value := Some(Bindlib.unbox b);

  (* Update current theorem with the newly created goal. *)
  let new_g = {g_meta = new_goal; g_hyps = g.g_hyps; g_type = goal_type} in
  theorem := Some({thm with t_goals = new_g :: gs});

  log_rewr "Rewriting with:";
  log_rewr "  goal           = [%a]" pp g.g_type;
  log_rewr "  equality proof = [%a]" pp t;
  log_rewr "  equality type  = [%a]" pp t_type;
  log_rewr "  equality LHS   = [%a]" pp l;
  log_rewr "  equality RHS   = [%a]" pp r;
  log_rewr "  pred           = [%a]" pp pred;
  log_rewr "  new goal       = [%a]" pp goal_type;
  log_rewr "  produced term  = [%a]" pp term