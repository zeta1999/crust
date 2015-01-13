let struct_tag_field = "discr";;
let arm_field = format_of_string "tag%d";;
let field_label = format_of_string "field%d";;
let tuple_field = field_label;;
let data_field = "data";;

let rec instrument_return : Ir.expr -> Ir.expr = fun expr ->
  match (snd expr) with
  | `Unsafe (s,e) ->
	 (fst expr,`Unsafe (s,(instrument_return e)))
  | `Block (s,e) ->
	 (fst expr,`Block (s,(instrument_return e)))
  | `Return e -> expr
  | e -> (`Bottom,`Return expr)

(* A note on t_simple_expr vs. simple_expr: t_simple_expr is a simple
  expression with the type of the expression, and simple_expr is just
  the expression. With two exceptions sub-expressions also have type
  information because type information is easy to ignore and hard to
  recover (plus it makes implementing sub-expression simplification
  MUCH easier). Struct_Field and Assignment do not have type
  information in some of their sub-terms because these sub-terms can
  be generated by the simplification and this would require recovering
  type information. In both cases (the referent and lhs) the type
  information will almost certainly not be required in later
  compilation stages so it's okay to throw it away *)
type simple_expr = [
  | `Struct_Field of simple_expr * string
  | `Var of string
  | `Literal of string
  | `Deref of t_simple_expr
  | `Address_of of t_simple_expr
  | `Call of string * (Types.lifetime list) * (Types.r_type list) * (t_simple_expr list)
  | `Return of t_simple_expr
  | `Assignment of simple_expr * t_simple_expr
  | `BinOp of Ir.bin_op * t_simple_expr * t_simple_expr
  | `UnOp of Ir.un_op * t_simple_expr
  | `Cast of t_simple_expr * Types.r_type
  ]
 and t_simple_expr = Types.r_type * simple_expr
 and 'a complex_expr = [
   | `Block of ('a stmt list) * 'a
   | `Match of t_simple_expr * ('a match_arm list)
   ]
 and struct_fields = struct_field list
 and struct_field = string * t_simple_expr (* field binding *)
 and 'a stmt = [
   | `Expr of 'a
   | `Let of string * Types.r_type * t_simple_expr
   | `Declare of string * Types.r_type
   ]
 (* this is a t_simple_expr but the type will always be `Bool actually *)
 and 'a match_arm = (t_simple_expr * 'a)
type all_expr = Types.r_type * [ all_expr complex_expr | simple_expr ]
type all_complex = all_expr complex_expr

let enum_field (enum : simple_expr) tag field = 
  let data = `Struct_Field (enum,data_field) in
  let tag_field = `Struct_Field (data,(Printf.sprintf arm_field tag)) in
  let e_field = `Struct_Field (tag_field,(Printf.sprintf field_label field)) in
  e_field
let tag_field (enum: simple_expr) =
  `Struct_Field (enum,struct_tag_field)
let is_complex (_,e) = match e with
  | #complex_expr -> true
  | _ -> false

let counter = ref 0;;

let fresh_temp () = 
  let new_id = !counter in
  counter := !counter + 1;
  Printf.sprintf "__temp_%d" new_id

let trivial_expr = `Bool,(`Literal "1")

let rec push_assignment (lhs : simple_expr) (e : all_expr) = 
  match (snd e) with
  | #simple_expr as s -> 
	 let assign = `Assignment (lhs,((fst e),s)) in
	 ((`Unit,assign) : all_expr)
  | `Match (e,m_arms) ->
	 let m_arms' = List.map (fun (patt,m_arm) -> 
							 (patt,(push_assignment lhs m_arm))
							) m_arms in
	 (`Unit,`Match (e,m_arms'))
  | `Block (s,e) -> (`Unit,(`Block (s,(push_assignment lhs e))))

let lift_complex : all_expr complex_expr -> (string * all_expr) = fun expr ->
  match expr with
  | `Block (s,e)  ->
	 let out_var = fresh_temp () in
	 let e' = push_assignment (`Var out_var) e in
	 (out_var,(`Unit,`Block (s,e')))
  | `Match (e,m_arms) ->
	 let out_var = fresh_temp () in
	 let m_arms' = List.map (fun (patt,m_arm) -> (patt,(push_assignment (`Var out_var) m_arm))) m_arms in
	 (out_var,(`Unit,`Match (e,m_arms')))

let rec apply_lift_cb : 'a. Ir.expr -> (all_expr stmt list -> t_simple_expr -> 'a) -> 'a = 
  fun expr cb ->
  let expr' = simplify_ir expr in
  let e_type = fst expr' in
  match (snd expr') with
  | #simple_expr as s -> cb [] (e_type,s)
  | #all_complex as c ->
	 let (out_var,lifted) = lift_complex c in
	 let declaration = `Declare (out_var,e_type) in
	 let assign_block = `Expr lifted in
	 let replacement = e_type,(`Var out_var) in
	 cb [declaration ; assign_block] replacement
and apply_lift e_type sub_expr cb =
  apply_lift_cb sub_expr (fun stmt out_var -> 
						  let op = cb out_var in
						  match stmt with
						  | [] -> (e_type,op)
						  | _ -> 
							 let block_e = (e_type,op) in
							 let block = `Block (stmt,block_e) in
							 (e_type,block)
						 )
and simplify_adt : 'a. Types.r_type -> 'a list -> ?post:(t_simple_expr -> all_expr list) -> (t_simple_expr -> int -> 'a -> simple_expr) -> (int -> 'a -> Ir.expr) -> all_expr = fun e_type components ?(post=(fun _ -> [])) lhs rhs ->
  let out_var = fresh_temp () in
  let adt_var = e_type,`Var out_var in
  let declare = `Declare (out_var,e_type) in
  let stmts = List.mapi (fun i comp ->
						 let assign_lhs = lhs adt_var i comp in
						 let e = rhs i comp in
						 apply_lift_cb e (fun stmts e' ->
										  let assignment = `Assignment (assign_lhs,e') in
										  stmts @ [`Expr (`Unit,assignment)]
										 )
						) components in
  let post_stmts = List.map (fun e -> `Expr e) (post adt_var) in
  let stmts' = (declare :: (List.flatten stmts)) @ post_stmts in
  (e_type,(`Block (stmts',adt_var)))
and (simplify_ir : Ir.expr -> all_expr) = fun expr ->
  match (snd expr) with
  | `Call (f_name,l,t,args) ->
	 let (s,args') = List.fold_right 
					   (fun arg (s_accum,arg_accum) ->
						apply_lift_cb arg (fun stmt a -> (stmt @ s_accum,a::arg_accum))
					   ) args ([],[]) in
	 if s = [] then
	   (fst expr,`Call (f_name,l,t,args'))
	 else
	   (fst expr,`Block (s,(fst expr,`Call (f_name,l,t,args'))))
  | `Address_of t -> 
	 apply_lift (fst expr) t (fun e -> `Address_of e)
  | `Deref t -> 
	 apply_lift (fst expr) t (fun e -> `Deref e)
  | `Var s -> (fst expr,(`Var s))
  | `Literal s -> 
	 begin
	   let lit_rep = 
		 match (fst expr) with
		 | `Bool -> begin match s with
						  | "true" -> "1"
						  | "false" -> "0"
						  | _ -> failwith @@ "Unknown boolean representation: " ^ s
					end
		 | `Unit -> "0"
		 | _ -> s
	   in
	   (fst expr,`Literal lit_rep)
	 end
  | `Return r ->
	 apply_lift_cb r (fun stmt r ->
					  if stmt = [] then
						(`Bottom,`Return r)
					  else
						(`Bottom,`Block (stmt,(`Bottom,`Return r)))
					 )
  | `Struct_Field (s,f) -> apply_lift (fst expr) s (fun e -> `Struct_Field (snd e,f))
  | `Tuple t_fields ->
	 let tuple_type = fst expr in
	 let lhs = fun adt_var f_index _ ->
	   `Struct_Field ((snd adt_var),(Printf.sprintf tuple_field f_index))
	 in
	 let rhs = fun _ f -> f in
	 simplify_adt tuple_type t_fields lhs rhs
  | `Struct_Literal s_fields ->
	 let struct_type = fst expr in
	 let lhs = fun adt_var _ (f,_) ->
	   `Struct_Field (snd adt_var,f)
	 in
	 let rhs = fun _ (_,e) -> e in
	 simplify_adt struct_type s_fields lhs rhs
  | `Enum_Literal (_,tag,exprs) ->
	 let lhs = fun adt_var f_index _ ->
	   enum_field (snd adt_var) tag f_index
	 in
	 let rhs = fun _ e -> e in
	 let post = fun adt_var ->
	   let tag_rhs = (`Int 4,(`Literal (string_of_int tag))) in
	   let discriminant_field = tag_field (snd adt_var) in
	   let assignment = `Assignment (discriminant_field,tag_rhs) in
	   [(`Unit,assignment)] in
	 simplify_adt (fst expr) exprs ~post:post lhs rhs
  | `Unsafe (s,e) 
  | `Block (s,e) ->
	 let b_type = fst e in
	 let stmt_frag  = List.flatten (List.map simplify_stmt s) in
	 let e' = simplify_ir e in
	 (b_type,`Block (stmt_frag,e'))
  | `Match (e,m_arms) -> 
	 let expr_type = (fst expr) in
	 apply_lift_cb e (fun stmt e' ->
					  let (stmt',match_on) = match (snd e') with
						| `Var _ -> stmt,e'
						| _ -> 
						   let matchee_name = fresh_temp () in
						   let matchee_type = fst e' in
						   let matchee_var = (matchee_type,`Var matchee_name) in
						   (stmt @ [ `Let (matchee_name,matchee_type,e') ],matchee_var)
					  in
					  let simpl_match = (expr_type,(simplify_match m_arms match_on)) in
					  if stmt' = [] then simpl_match 
					  else (expr_type,(`Block (stmt',simpl_match)))
					 )
  (*		 apply_lift (fst expr) e (simplify_match m_arms)*)
  | `UnOp (op,e) ->
	 apply_lift (fst expr) e (fun e' -> `UnOp (op,e'))
  | `BinOp (op,e1,e2) ->
	 let expr_type = (fst expr) in
	 simplify_binary e1 e2 (fun e1' e2' ->
							expr_type,(`BinOp (op,e1',e2'))
						   )
  | `Assignment (e1,e2) ->
	 simplify_binary e1 e2 (fun t_e1 e2' ->
							let e1' = snd t_e1 in
							`Unit,(`Assignment (e1',e2'))
						   )
  | `Cast (e,t) ->
	 apply_lift (fst expr) e (fun e' -> `Cast (e',t))
and simplify_binary e1 e2 cb = 
  apply_lift_cb e1 (fun stmt1 e1' ->
					apply_lift_cb e2 (fun stmt2 e2' ->
									  let stmts = stmt1 @ stmt2 in
									  let b_op = cb e1' e2' in
									  let b_type = fst b_op in
									  if stmts = [] then b_op
									  else b_type,`Block (stmts,b_op)
									 )
				   )
and simplify_stmt : Ir.stmt -> all_expr stmt list = function
  | `Let (v_name,v_type,expr) ->
	 let expr' = simplify_ir expr in
	 let e_type = fst expr' in
	 begin
	   match (snd expr') with
	   | #simple_expr as s -> [`Let (v_name,v_type,(e_type,s))]
	   | #complex_expr as c -> 
		  let c' = push_assignment (`Var v_name) (e_type,c) in
		  [`Declare (v_name,v_type); `Expr c']
	 end
  | `Expr e ->
	 let e' = simplify_ir e in
	 [`Expr e']
and simplify_match : Ir.match_arm list -> t_simple_expr -> 'a = 
  fun m_arms t_matchee -> 
  let matchee = snd t_matchee in
  let m_arms' = List.map (simplify_match_arm matchee) m_arms in
  `Match (t_matchee,m_arms')
and simplify_match_arm matchee (patt,m_arm) = 
  let simpl_m_arm = simplify_ir m_arm in
  let (predicates,bindings) = compile_pattern ([],[]) matchee patt in
  let predicate_expr = List.fold_right (fun (lhs,rhs) accum ->
										let comp = (`Bool,(`BinOp (`BiEq,lhs,rhs))) in
										`Bool,(`BinOp (`BiAnd,comp,accum))
									   ) predicates trivial_expr
  in
  let assignments = List.map (fun (bind_type,bind_name,matchee) ->
							  let rhs = bind_type,matchee in
							  `Let (bind_name,bind_type,rhs)
							 ) bindings
  in
  let final_expr = match assignments with
	| [] -> simpl_m_arm
	| _ -> begin
		match (snd simpl_m_arm) with
		| `Block (s,m_e) -> (fst simpl_m_arm),`Block ((assignments @ s),m_e)
		| _ -> (fst simpl_m_arm),`Block (assignments,simpl_m_arm)
	  end
  in
  (predicate_expr,final_expr)
and compile_pattern : ((t_simple_expr * t_simple_expr) list * 'b) -> 'c -> Ir.pattern -> 'd = fun (predicates,bindings) matchee patt ->
  let p_type = fst patt in
  match (snd patt) with
  | `Wild -> predicates,bindings
  | `Bind b_name ->
	 (predicates,(p_type,b_name,matchee)::bindings)
  | `Enum (_,tag,patts) -> 
	 let fields = List.mapi (fun i _ -> enum_field matchee tag i) patts in
	 let (predicates',bindings) = List.fold_left2 compile_pattern (predicates,bindings) fields patts in
	 let tag_rhs = (`Int 32,tag_field matchee) in
	 let tag_lhs = (`Int 32,`Literal (string_of_int tag)) in
	 (tag_lhs,tag_rhs)::predicates',bindings
  | `Const l
  | `Literal l ->
	 let lhs = (p_type,`Literal l) in
	 let rhs = (p_type,matchee) in
	 (lhs,rhs)::predicates,bindings
  | `Tuple (patts) ->
	 let fields = List.mapi (fun i _ -> `Struct_Field (matchee,(Printf.sprintf tuple_field i))) patts in
	 List.fold_left2 compile_pattern (predicates,bindings) fields patts

let rec flatten_blocks (ir : all_expr) = 
  match (snd ir) with
  | `Block ([],((b_t,`Block e) as b)) -> flatten_blocks b
  | _ -> ir

let rec clean_abort_expr (expr : t_simple_expr) = 
  let e_type = fst expr in
  match (snd expr) with
  | `Cast (e,t) ->
    e_type,`Cast (clean_abort_expr e,t)
  | `Struct_Field (e,f) ->
    (* XXX: hack *)
    let e = snd (clean_abort_expr (`Bottom,e)) in
    e_type,`Struct_Field (e,f)
  | `Return e ->
    e_type,`Return (clean_abort_expr e)
  | `BinOp (o,e1,e2) ->
    e_type,`BinOp (o,clean_abort_expr e1,clean_abort_expr e2)
  | `UnOp (o,e1) ->
    e_type,`UnOp (o,clean_abort_expr e1)
  | `Address_of e ->
    e_type,`Address_of (clean_abort_expr e)
  | `Deref e ->
    e_type,`Deref (clean_abort_expr e)
  | `Var _ -> expr
  | `Literal _ -> expr
  | `Assignment (_,((_,`Call ("crust_abort",_,_,_)) as r)) ->
    r
  | `Assignment (e1,e2) ->
    (* XXX: also a hack *)
    let e1 = snd (clean_abort_expr (`Bottom,e1)) in
    (e_type,`Assignment (e1,clean_abort_expr e2))
  | `Call ("crust_abort", _, _, _) ->
    failwith "crust_abort found in unsupported position"
  | `Call (s,l,t,e) ->
    e_type,`Call (s,l,t,List.map clean_abort_expr e)

let rec clean_abort (expr : all_expr) = 
  let e_type = fst expr in
  match (snd expr) with
  | #simple_expr as s -> (clean_abort_expr (e_type,s) :> all_expr)
  | `Match (m,m_arms) ->
    e_type,`Match (clean_abort_expr m,List.map (fun (cond,m) ->
        clean_abort_expr cond,clean_abort m
      ) m_arms)
  | `Block (stmt,e) ->
    let stmt = List.map (function
        | (`Expr (_,`Call ("crust_abort",_,_,_))) as e -> e
        | `Expr e -> `Expr (clean_abort e)
        | `Let (v,t,e) -> `Let (v,t,clean_abort_expr e)
        | (`Declare _) as d -> d
      ) stmt 
    in
    e_type,(`Block (stmt,clean_abort e))

let get_simple_ir ir = 
  instrument_return ir
  |> simplify_ir
  |> clean_abort
  |> flatten_blocks 
