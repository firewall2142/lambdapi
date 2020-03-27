(** Scoping environment for variables. *)

open Terms

(** Type of an environment, used in scoping to associate names to
   corresponding Bindlib variables and types. Note that it cannot be
   implemented by a map as the order is important. *)
type env = (string * (tvar * tbox)) list

type t = env

(** [empty] is the empty environemnt. *)
let empty : env = []

(** [add v a env] extends the environment [env] by mapping the string
   [Bindlib.name_of v] to [(v,a)]. *)
let add : tvar -> tbox -> env -> env = fun v a env ->
  (Bindlib.name_of v, (v, a)) :: env

(** [find n env] returns the Bindlib variable associated to the variable  name
    [n] in the environment [env]. If none is found, [Not_found] is raised. *)
let find : string -> env -> tvar = fun n env ->
  fst (List.assoc n env)

(** [to_prod env t] builds a sequence of products whose  domains  are the
    variables of the environment [env] (from left to right), and which body is
    the term [t]: [to_prod [(xn,an);..;(x1,a1)] t = ∀x1:a1,..,∀xn:an,t]. *)
let to_prod : env -> tbox -> term = fun env t ->
  let fn t (_,(x,a)) = _Prod a (Bindlib.bind_var x t) in
  Bindlib.unbox (List.fold_left fn t env)

(** [to_abst env t] builds a sequence of abstractions whose  domains  are the
    variables of the environment [env] (from left to right), and which body is
    the term [t]: [to_prod [(xn,an);..;(x1,a1)] t = λx1:a1,..,λxn:an,t]. *)
let to_abst : env -> tbox -> term = fun env t ->
  let fn t (_,(x,a)) = _Abst a (Bindlib.bind_var x t) in
  Bindlib.unbox (List.fold_left fn t env)

(** [vars env] extracts the array of the Bindlib variables in [env]. Note that
    the order is reversed: [vars [(xn,an);..;(x1,a1)] = [|x1;..;xn|]]. *)
let vars : env -> tvar array = fun env ->
  Array.of_list (List.rev_map (fun (_,(x,_)) -> x) env)

(** [to_term env] extracts the array of the variables in [env] and inject them
    in the [tbox] type. This is the same as [Array.map _Vari (vars env)]. Note
    that the order is reversed: [vars [(xn,an);..;(x1,a1)] = [|x1;..;xn|]]. *)
let to_tbox : env -> tbox array = fun env ->
  Array.of_list (List.rev_map (fun (_,(x,_)) -> _Vari x) env)

(** [of_prod n t] returns the environment [(xn,an),..,(x1,a1)] and the term
   [b] if [t] is of the form [∀x1:a1,..,∀xn:an,b]. Raises [Invalid_argument]
   if [t] is not of this form. *)
let of_prod_arity : int -> term -> env * term = fun n t ->
  let rec build_env i env t =
    if i >= n then env, t
    else match Eval.whnf t with
         | Prod(a,b) ->
            let v,b = Bindlib.unbind b in
            let a = Eval.simplify a in
            let env = add v (lift a) env in
            build_env (i+1) env b
         | _ -> raise (Invalid_argument "of_prod")
  in build_env 0 [] t

(** [of_prod vs t] returns the environment [(vn,an{x1=v1,..,xn-1=vn-1}),..,
   (v1,a1)] and the term [b{x1=v1,..,xn=vn}] if [t] is of the form
   [∀x1:a1,..,∀xn:an,b]. Raises [Invalid_argument] if [t] is not of this
   form. *)
let of_prod_vars : tvar array -> term -> env * term = fun vars t ->
  let n = Array.length vars in
  let rec build_env i env t =
    if i >= n then env, t
    else match Eval.whnf t with
         | Prod(a,b) ->
            let v = vars.(i) in
            let env = add v (lift a) env in
            build_env (i+1) env (Bindlib.subst b (Vari v))
         | _ -> raise (Invalid_argument "of_prod")
  in build_env 0 [] t

(** Given a metavariable [m] of arity [n] and type [∀x1:A1,..,∀xn:An,B] (with
   [B] being a sort normally), [extend_meta_type m] returns
   [m[x1,..,xn],(∀y:p,q),bp,bq] where p=m1[x1,..,xn], q=m2[x1,..,xn,y], bp is
   a mbinder of [x1,..,xn] over p, and bq is a mbinder of [x1,..,xn] over q,
   where [y] is a fresh variable, and [m1] and [m2] are fresh metavariables of
   arity [n] and [n+1], and type [∀x1:A1,..,∀xn:An,TYPE] and
   [∀x1:A1,..,∀xn:An,∀y:m1[x1,..,xn],B] respectively. *)
let extend_meta_type : meta -> term * term
    * (term, term) Bindlib.mbinder * (term, tbinder) Bindlib.mbinder
  = fun m ->
  let n = m.meta_arity in
  let (env, s) = of_prod_arity n Timed.(!(m.meta_type)) in
  let vs = vars env in
  let xs = Array.map _Vari vs in

  let t1 = to_prod env _Type in
  let m1 = fresh_meta t1 n in

  let y = Bindlib.new_var mkfree "y" in
  let env = add y (_Meta m1 xs) env in
  let t2 = to_prod env (lift s) in
  let m2 = fresh_meta t2 (n+1) in

  let r1 = Bindlib.unbox (_Meta m xs) in
  let p = _Meta m1 xs in
  let q = Bindlib.bind_var y (_Meta m2 (Array.append xs [|_Vari y|])) in
  let r2 = Bindlib.unbox (_Prod p q) in

  let f x = Bindlib.unbox (Bindlib.bind_mvar vs x) in
  r1, r2, f p, f q
