let struct_tag_field = "discr";;
let arm_field = format_of_string "tag%d";;
let field_label = format_of_string "field%d";;
let tuple_field = field_label;;
let data_field = "data";;

let struct_tag_type = `Int (`Bit_Size 32);;

let rec instrument_return : Ir.expr -> Ir.expr = fun expr ->
  match (snd expr) with
  | `Unsafe (s,e) ->
	 (fst expr,`Unsafe (s,(instrument_return e)))
  | `Block (s,e) ->
	 (fst expr,`Block (s,(instrument_return e)))
  | `Return e -> expr
  | e -> (`Bottom,`Return expr)

type static_expr = [
  | `Var of string
  | `Literal of string
  | `Deref of static_expr
  | `Address_of of static_expr
  | `BinOp of Ir.bin_op * static_expr * static_expr
  | `Init of static_expr list
  | `Tagged_Init of string * static_expr list
  | `UnOp of Ir.un_op * static_expr
  | `Cast of Types.r_type * static_expr
]

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
  | `Assignment of simple_expr * t_simple_expr
  | `BinOp of Ir.bin_op * t_simple_expr * t_simple_expr
  | `UnOp of Ir.un_op * t_simple_expr
  | `Cast of t_simple_expr * Types.r_type
  | `Assign_Op of Ir.bin_op * simple_expr * t_simple_expr
  ]
 and t_simple_expr = Types.r_type * simple_expr
 and 'a complex_expr = [
   | `Block of ('a stmt list) * 'a
   | `Match of t_simple_expr * ('a match_arm list)
   | `While of t_simple_expr * 'a
   | `Return of t_simple_expr
 ]
 and struct_fields = struct_field list
 and struct_field = string * t_simple_expr (* field binding *)
 and 'a stmt = [
   | `Expr of 'a
   | `Let of string * Types.r_type * t_simple_expr
   | `Declare of string * Types.r_type
   | `Vec_Init of string * Types.r_type * (t_simple_expr list)
   | `Vec_Assign of int * simple_expr * t_simple_expr
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
let literal_unit = `Unit,`Literal "0"


let mk_assign = 
  let is_fix_vec = function
    | `Fixed_Vec _ -> true
    | _ -> false
  in
  let vec_size = function
    | `Fixed_Vec (n,_) -> n
    | _ -> assert false
  in
  let vec_component = function
    | `Fixed_Vec (_,t) -> t
    | _ -> assert false
  in
  fun nv_cb vcb lhs rhs ->
    let rhs_type = fst rhs in
    if is_fix_vec rhs_type then
      let assign_temp = fresh_temp () in
      let assign_var = rhs_type,`Var assign_temp in
      vcb [
        `Let (assign_temp,`Ptr (vec_component rhs_type),rhs);
        `Vec_Assign (vec_size rhs_type,lhs,assign_var)
      ]
    else
      nv_cb (`Unit,`Assignment (lhs,rhs))

let mk_assign_expr = mk_assign (fun i -> i) (fun l ->
    `Unit,`Block (l,literal_unit)
  );;

let rec push_assignment (lhs : simple_expr) (e : all_expr) = 
  match (snd e) with
  | `Return _ -> e
  | #simple_expr as s ->
    mk_assign_expr lhs (fst e,s)
  | `Match (e,m_arms) ->
    let m_arms' = List.map (fun (patt,m_arm) -> 
        (patt,(push_assignment lhs m_arm))
      ) m_arms in
    (`Unit,`Match (e,m_arms'))
  | `Block (s,e) -> (`Unit,(`Block (s,(push_assignment lhs e))))
  | `While _ -> 
    let assign = `Unit,(`Assignment (lhs,literal_unit)) in
    let new_block : all_expr = `Unit,(`Block ([`Expr e], assign)) in
    new_block

let lift_complex : Types.r_type -> all_expr complex_expr -> (string * all_expr) = fun ty expr ->
  match expr with
  | `Block (s,e)  ->
	 let out_var = fresh_temp () in
	 let e' = push_assignment (`Var out_var) e in
	 (out_var,(`Unit,`Block (s,e')))
  | `Match (e,m_arms) ->
	 let out_var = fresh_temp () in
	 let m_arms' = List.map (fun (patt,m_arm) -> (patt,(push_assignment (`Var out_var) m_arm))) m_arms in
	 (out_var,(`Unit,`Match (e,m_arms')))
  | (`While _ as w) -> 
    let out_var = fresh_temp () in
    out_var,(push_assignment (`Var out_var) (`Unit,w))
  | `Return e ->
    let out_var = fresh_temp () in
    (out_var,(ty,`Return e))

let rec apply_lift_cb : 'a. Ir.expr -> (all_expr stmt list -> t_simple_expr -> 'a) -> 'a = 
  fun expr cb ->
  let expr' = simplify_ir expr in
  let e_type = fst expr' in
  match (snd expr') with
  | #simple_expr as s -> cb [] (e_type,s)
  | #all_complex as c ->
	 let (out_var,lifted) = lift_complex e_type c in
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
          let s = mk_assign (fun a -> [`Expr a]) (fun i -> i) assign_lhs e' in
          stmts @ s
        )
    ) components in
  let post_stmts = List.map (fun e -> `Expr e) (post adt_var) in
  let stmts' = (declare :: (List.flatten stmts)) @ post_stmts in
  (e_type,(`Block (stmts',adt_var)))
and (simplify_ir : Ir.expr -> all_expr) = fun expr ->
  match (snd expr) with
  | `Call (f_name,l,t,args) ->
    (* this could be generalized by checking the DECLARED return type of a 
      function and checking for bottom... but all in time...
    *)
    if f_name = "crust_abort" then
      let temp_var = fresh_temp () in
      (fst expr,`Block ([
           `Declare (temp_var,(fst expr));
           `Expr (`Unit,`Call (f_name,l,t,[]))
         ],((fst expr),`Var temp_var)))
    else
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
						  | "1" -> "1"
						  | "false" -> "0"
						  | "0" -> "0"
						  | _ -> failwith @@ "Unknown boolean representation: " ^ s
					end
		 | `Unit -> "0"
		 | _ -> s
	   in
	   (fst expr,`Literal lit_rep)
	 end
  | `Return r ->
    let ret_type = fst expr in
	 apply_lift_cb r (fun stmt r ->
					  if stmt = [] then
						(ret_type,`Return r)
					  else
						(ret_type,`Block (stmt,(ret_type,`Return r)))
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
	   let tag_rhs = (struct_tag_type,(`Literal (string_of_int tag))) in
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
  | `UnOp (op,e) ->
	 apply_lift (fst expr) e (fun e' -> `UnOp (op,e'))
  | `BinOp (op,e1,e2) ->
	 let expr_type = (fst expr) in
	 simplify_binary e1 e2 (fun e1' e2' ->
							expr_type,(`BinOp (op,e1',e2'))
						   )
  | `Assignment (e1,e2) ->
    simplify_binary e1 e2 (fun t_e1 e2' ->
        mk_assign_expr (snd t_e1) e2'
      )
  | `Assign_Op (op,e1,e2) ->
    simplify_binary e1 e2 (fun t_e1 e2' ->
        let e1' = snd t_e1 in
        `Unit,(`Assign_Op (op,e1',e2'))
      )
  | `Cast e ->
	 apply_lift (fst expr) e (fun e' -> `Cast (e',(fst expr)))
  | `While (cond,b) ->
    let b' = simplify_ir b in
    apply_lift_cb cond (fun stmt c' ->
        match stmt with
        | [] -> (`Unit,`While (c',b'))
        | [`Declare _; s] ->
          let final_expr = `Unit,(`Literal "0") in
          let loop_body = `Block ([`Expr b';s],final_expr) in
          let t_loop_body : all_expr = `Unit,loop_body in
          let loop_ast : all_expr = `Unit,(`While (c',t_loop_body)) in
          let block_body = `Block ((stmt @ [`Expr loop_ast]),final_expr) in
          `Unit,block_body
        | _ -> assert false
      )
  | `Vec e_list ->
    let (stmts,e_list') = 
      List.fold_right (fun vec_e (stmt_accum,e_accum) ->
          apply_lift_cb vec_e (fun stmt e' ->
              (stmt @ stmt_accum,e'::e_accum)
            )
        ) e_list ([],[])
    in
    let temp = fresh_temp () in
    let vec_type = fst expr in
    vec_type,`Block (stmts @ [
        `Vec_Init (temp,vec_type,e_list')
      ],(vec_type,`Var temp)
      )
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
  | `Let (v_name,v_type,binding) ->
    begin
      match binding with
      | Some expr -> begin
          let e_type = fst expr in
          let expr = simplify_ir expr in
          match (snd expr) with
          | #simple_expr as s -> begin
              match v_type with 
              | `Fixed_Vec _ -> 
                [ `Declare (v_name,v_type) ] @ 
                (mk_assign (fun i -> assert false) (fun l -> l) (`Var v_name) (e_type,s))
              | _ -> [`Let (v_name,v_type,(e_type,s))]
            end
          | #complex_expr as c -> 
            let c' = push_assignment (`Var v_name) (e_type,c) in
            [`Declare (v_name,v_type); `Expr c']
        end
      | None -> [`Declare (v_name,v_type)]
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
and compile_pattern : ((t_simple_expr * t_simple_expr) list * 'b) -> 'c -> Ir.pattern -> 'd = 
  let get_addr_type = function
    | `Ref_Mut (_,t)
    | `Ptr t
    | `Ptr_Mut t
    | `Ref (_,t) -> t
    | _ -> failwith "the address of pattern was not applied to a pointer type?!"
  in
  fun (predicates,bindings) matchee patt ->
  let p_type = fst patt in
  match (snd patt) with
  | `Wild -> predicates,bindings
  | `Bind b_name ->
	 (predicates,(p_type,b_name,matchee)::bindings)
  | `Enum (_,tag,patts) -> 
	 let fields = List.mapi (fun i _ -> enum_field matchee tag i) patts in
	 let (predicates',bindings) = List.fold_left2 compile_pattern (predicates,bindings) fields patts in
	 let tag_rhs = (struct_tag_type,tag_field matchee) in
	 let tag_lhs = (struct_tag_type,`Literal (string_of_int tag)) in
	 (tag_lhs,tag_rhs)::predicates',bindings
  | `Ref b_name ->
    (* XXX(jtoman): THE WORST HACK
     * Welp, what's the type of the thing we're taking the address of?
     * We have NO idea: we erase this information as we walk the pattern!!
     * We're faking it here by trying to infer this info from the type of the bound
     * variable
     * The intermediate type information IS used during simplification, but
     * we should never revisit this node.
     *)
    let matchee = `Address_of (get_addr_type p_type,matchee) in
    (predicates,(p_type,b_name,matchee)::bindings)
  | `Addr_of p ->
    compile_pattern (predicates,bindings) (`Deref (p_type,matchee)) p
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

let get_simple_ir ir = 
  instrument_return ir
  |> simplify_ir
  |> flatten_blocks

exception Illegal_dynamic_expr;;

let rec simplify_static_ir : Ir.expr -> static_expr =
  let extract_type_name = function
    | `Adt_type { Types.type_name = a; _ } -> a
    | _ -> assert false
  in
  fun expr ->
    let e_type = fst expr in
    match (snd expr) with
    | `Call _ 
    | `While _
    | `Assignment _
    | `Unsafe _
    | `Return _
    | `Match _
    | `Block _
    | `Struct_Field _
    | `Assign_Op _ -> raise Illegal_dynamic_expr
    | `Var s -> `Var s
    | `Cast e -> `Cast (e_type, simplify_static_ir e)
    | `Literal l -> `Literal l
    | `BinOp (op,e1,e2) -> `BinOp (op,simplify_static_ir e1,simplify_static_ir e2)
    | `Vec e_list
    | `Tuple e_list ->
      `Init (List.map simplify_static_ir e_list)
    | `Struct_Literal sl ->
      let type_name = extract_type_name e_type in
      let struct_type = match Env.EnvMap.find Env.adt_env type_name with
        | `Struct_def s -> s
        | _ -> assert false
      in
      let field_order = List.mapi (fun ind (f_name,_) ->
          (f_name,ind)
        ) struct_type.Ir.struct_fields
      in
      let sorted_init = List.sort (fun (f1,_) (f2,_) ->
          Pervasives.compare (List.assoc f1 field_order) (List.assoc f2 field_order)
        ) sl in
      `Init (List.map (fun (_,e) -> simplify_static_ir e) sorted_init)
    | `Enum_Literal (_,tag,sf) ->
      `Init ([
          `Literal (string_of_int tag)
        ] @
          match sf with 
          | [] -> []
          | l -> [`Tagged_Init ((Printf.sprintf arm_field tag),List.map simplify_static_ir l)]
        )
    | `Address_of e -> 
      `Address_of (simplify_static_ir e)
    | `Deref e -> `Deref (simplify_static_ir e)
    | `UnOp (op,e) ->
      `UnOp (op,simplify_static_ir e)

let get_simple_static expr = 
  simplify_static_ir expr
