open Asttypes
open Typedtree
open Btype
open Types
open Frame

open Printf
open Format

(***********************************************)
(************ Symbolic Execution ***************)
(***********************************************)		

exception Datatype

let qual_test_var = Path.mk_ident "KAPA"
let qual_test_expr = Predicate.Var qual_test_var

(** added for datatype ---> **)
let main_function = ref "main"

type function_const = {pre: Predicate.t; post: Predicate.t}
type function_env = {
	(** Scan the structure to find all function bindings *)
	funbindings: (Path.t, (bool * expression)) Hashtbl.t;
	funframebindings: (Path.t, Frame.t) Hashtbl.t;
	(** Scan the log to find all higher order function instantiations *)
	(*hobindings: (Path.t, Path.t) Hashtbl.t; *)
	(** Store the results of bad constraints *)
	badbindings : (Path.t, function_const) Hashtbl.t;
	(** Store function effect (very underapproximate) *)
	effectbindings : (Path.t, Predicate.t) Hashtbl.t;
	(** Strore funcion rturn (very simple for local use only) *)
	returnbindings : (Path.t, Predicate.t) Hashtbl.t;
	(** Find frame from log *)
	frames: (expression -> Frame.t);
	builtin_funs : Path.t list;
	funcalls : string list ref;
	funcallenvs: (Location.t, (Path.t * Frame.t) list) Hashtbl.t;
	fundefenvs : (Path.t, (Path.t * Frame.t) list) Hashtbl.t;
	(* record how each higher order function parameter is mapped to a concrete function *)
	hobindings: (Path.t, Predicate.pexpr) Hashtbl.t;
	(* Indicating if commons should be used for guarding the inferred refinements *)
	partial_used : bool ref;
	(* Indicating if data type is defined in the source program *)
	dty : bool ref;
	(* If dty is set, there are possibly measures defined for the data type *)
	measures : (Path.t, (Path.t * bool) list) Hashtbl.t;
	(* Measure's definition; key : type + constructor; value : measure + args + def *)
	measure_defs : ((Path.t * string), (string * Path.t list * Predicate.t) list) Hashtbl.t
	}



(** We carefully negate a precondition in which we avoid negating the path condition *)
let rec negate_precondition pred =
	let _ = Format.fprintf Format.std_formatter "Negate %a@." Predicate.pprint pred in
	match pred with
	(* List is supported internally *)
	| Predicate.Or (Predicate.And (p1, ((Predicate.Atom (p, Predicate.Eq, Predicate.PInt 0)) as p2)), 
									Predicate.And (p1', ((Predicate.Atom (p', Predicate.Gt, Predicate.PInt 0)) as p2'))) 
									when p = p'->
		Predicate.Or (Predicate.And (negate_precondition p1, p2), Predicate.And (negate_precondition p1', p2'))
	(* if-then-else is surely supported *)
	| Predicate.Or (Predicate.And (p1, p2), Predicate.And (Predicate.Not p1', p2')) when p1 = p1' -> 
		(* Must fixme *) Predicate.Not pred			
	| Predicate.Or (p1 ,p2) -> (*Predicate.Or (negate_precondition p1, negate_precondition p2)*)
		Predicate.Not pred
	| Predicate.Not Predicate.True -> pred
	| Predicate.Not p -> p					
	| _ -> Predicate.Not pred

			
(** We analyze the bad constraint to see, for array, if adjacent elements are compared
    Note we see the badf in a way that is UF based *)	
let detect_arr_adj_pattern badf allbindings unsounds = 	
	let arrs = List.fold_left (fun res (p, f) -> match f with
		| Frame.Fconstr (x,_,_,_,_) when x = Predef.path_array -> 
			(** check whether adjacent elements of p is constrainted in badf *)
			res @ [p]
		|	_ -> res
	) [] allbindings in
	let cons_arrs = ref [] in
	let _ = (ignore (Predicate.map_expr (fun pexpr -> match pexpr with
		| Predicate.FunApp (fn, es) -> (** Fixme? *)
			if (String.compare fn "UF" = 0) then
				let (fpath, fn) = match List.hd es with 
					| Predicate.Var fpath  -> (fpath, Path.name fpath)
					| _ -> assert false in
				let es = List.tl es in
				if (List.exists (fun u -> (Predicate.FunApp (fn, es)) = u) unsounds) then pexpr 
				else if (List.exists (fun arr -> Path.same arr fpath) arrs) then 
					(cons_arrs := (pexpr, fpath, es)::(!cons_arrs); pexpr)
				else pexpr
			else pexpr
		| _ -> pexpr
		) badf);
	(!cons_arrs)) in
	let cons_arrs = Common.remove_duplicates (!cons_arrs) in
	List.fold_left (fun res (pexpr, arr, inds) -> 
		(try 
			let pairs = List.find_all (fun (_,arr',_) -> Path.same arr arr') cons_arrs in
			let pairs = List.filter (fun (_,_,inds') -> 
				List.for_all2 (fun ind ind' -> 
				match (ind, ind') with
					| (Predicate.Var p, Predicate.Binop (_, Predicate.Minus, Predicate.Var q))
					| (Predicate.Var p, Predicate.Binop (Predicate.Var q, Predicate.Minus, _))
					| (Predicate.Var p, Predicate.Binop (Predicate.Var q, Predicate.Plus, _))
					| (Predicate.Var p, Predicate.Binop (_, Predicate.Plus, Predicate.Var q)) when (Path.same p q)-> true
					| _ -> false
				) inds inds'
			) pairs in
			if (List.length pairs > 0) then 
				(assert (List.length pairs = 1);
				let (pexpr',_,_) = List.hd pairs in
				(res @ [(pexpr, pexpr')]))
			else res
		with _ -> res)
	) [] cons_arrs
	
let ex_id = ref 0
	
(** Generate unique existential variable *)	
let fresh_ex () = 
	(incr ex_id; ("ET" ^ string_of_int (!ex_id)))

let print_pattern pattern = match pattern.pat_desc with
	| Tpat_var id -> Ident.name id
	| _ -> "dummypat"

let get_pattern pattern = match pattern.pat_desc with
	| Tpat_var id -> Path.Pident id
	| _ -> assert false

(** Fixme. Duplicated code *)
let expression_to_pexpr e =
  match e.exp_desc with
    | Texp_constant (Const_int n) -> Predicate.PInt n
    | Texp_ident (id, _) -> Predicate.Var id
    | _ -> Predicate.Var (Path.mk_ident "dummy")

(** Find the boolean predicate for a boolean expression *)
let expression_to_pred se_env e = 
	let eframe = se_env.frames e in
	match eframe with
		| Fconstr (_, _, _, (subs, Qconst quals), _) -> 
			let ps = Common.map_partial (fun (_,_,qual) -> match qual with
				| Predicate.Iff (_, p) -> Some p
				| _ -> None) quals
			in Predicate.apply_substs subs (Predicate.big_and ps)
		| _ -> (fprintf err_formatter
						"@[Warning: Internal expression to pred fails. Please report%a.@]@.@."
						Frame.pprint eframe;
						assert false)

let transel_recflag recflag = match recflag with
	| Recursive -> true
	| _ -> false						
						
let rec retrieve_subs appframe = match appframe with
	| Fconstr (_, fs, cstrdesc, r, _) -> fst r
  | Ftuple (fs, r) -> fst r
  | Frecord (_, fs, r) -> fst r 
	| Farrow (_, _, f, _) -> retrieve_subs f 
	| Fvar _ -> []
	| _ -> (fprintf err_formatter "@[Warning: Dont know how to
		deal with an application %a@]@.@." Frame.pprint appframe;
		assert false)				
						
let rec get_funbody exp = match exp.exp_desc with
	| Texp_function ([(pat, e')], _) -> get_funbody e'
	| _ -> exp

let rec collect_fpath e1 = match e1.exp_desc with
	| Texp_apply (e1', exps) -> collect_fpath e1'
	| Texp_ident (id, _) -> id
	| _ -> 
		(fprintf err_formatter 
		"@[Warning: Dont know how to deal with non-simple lambda@]@.@.";
		assert false)


let retrieve_fun app se_env =
	let loop_retrieve fpath =
		if (Hashtbl.mem se_env.funbindings fpath) then 
			let (rec_flag, exp) = Hashtbl.find se_env.funbindings fpath in
			(*match exp.exp_desc with
				| Texp_apply _ -> (** recursively find the function body *)
					let fpath = collect_fpath exp in
					loop_retrieve fpath
				| Texp_ident (fpath, _) -> loop_retrieve fpath
				| _ -> (** function body found *)*)
			let _ = fprintf err_formatter "dealing with fpath %s@." (Path.name fpath) in
			let appframe = se_env.frames (app) in
			let subs = retrieve_subs appframe in
			let _ = fprintf err_formatter "dealing fr %a@." Frame.pprint appframe in
			let _ = List.iter (fun sub -> 
				fprintf err_formatter "The substitution of it: %a@," Frame.pprint_sub sub) subs in
			(** Partial application is considered as higher order function *)	
			match appframe with
				| Farrow (Some _,_,_,_) -> (** partial app*) (fpath, subs, None, None)
				| _ -> (** Full app *) (fpath, subs, Some (rec_flag, exp), None)
		else if (List.exists (fun p -> Path.same p fpath) se_env.builtin_funs) then
			let appframe = se_env.frames (app) in
			let subs = retrieve_subs appframe in
			let _ = fprintf err_formatter "dealing with fpath %s at loc %a@." 
							(Path.name fpath) (Location.print) app.exp_loc in
			let _ = fprintf err_formatter "dealing fr %a" Frame.pprint appframe in
			let _ = List.iter (fun sub -> 
				fprintf err_formatter "The substitution of it: %a@." Frame.pprint_sub sub) subs in	
			match appframe with
				| Fconstr (_, _, _, (subs, Qconst qs), _) -> (** Built-in function *)
					let funname = Path.name fpath in
					if (String.compare "Array.length" funname = 0) then
						let preds = Common.map_partial (fun ((_,_,p) as q) -> (match p with
							| Predicate.Atom (_,Predicate.Eq,_) -> Some (Qualifier.apply qual_test_expr q)
							| _ -> None)
							) qs in
						(fpath, subs, None, Some (Predicate.big_and preds))
					else if (String.compare "Array.set" funname = 0) then
						let args = List.map (fun sub -> Predicate.Var (fst sub)) subs in
						(fpath, subs, None, Some 
							(Predicate.Atom (List.nth args 2, Predicate.Eq, 
							Predicate.FunApp ("UF", [List.nth args 0; List.nth args 1]))))
					else 
						let preds = List.map (fun q ->
							Qualifier.apply qual_test_expr q
							) qs in
						(fpath, subs, None, Some (Predicate.big_and preds))
				| Fvar _ -> 
					let funname = Path.name fpath in
					if (String.compare "Array.get" funname = 0) then 
						let args = List.map (fun sub -> Predicate.Var (fst sub)) subs in
						(fpath, subs, None, Some 
							(Predicate.Atom (qual_test_expr, Predicate.Eq, 
							Predicate.FunApp ("UF", [List.nth args 0; List.nth args 1]))))
					else (fpath, [], None, Some (Predicate.True))
				| _ -> 
					let funname = Path.name fpath in
					if (String.compare "Array.get" funname = 0) then 
						let args = List.map (fun sub -> Predicate.Var (fst sub)) subs in
						(fpath, subs, None, Some 
							(Predicate.Atom (qual_test_expr, Predicate.Eq, 
							Predicate.FunApp ("UF", [List.nth args 0; List.nth args 1]))))
					else if (String.compare "Array.set" funname = 0) then
						let args = List.map (fun sub -> Predicate.Var (fst sub)) subs in
						(fpath, subs, None, Some 
							(Predicate.Atom (List.nth args 2, Predicate.Eq, 
							Predicate.FunApp ("UF", [List.nth args 0; List.nth args 1]))))
					else (** Insert other built-in function application encodings *)
					(fprintf err_formatter
					"@[Cannot deal with a function application of %s with frame %a in symbolic and backward execution@]@.@."
					funname Frame.pprint appframe; flush stderr;
					assert false)
		else (** Higher order function calls *)		
			(fpath, [], None, None) in 		
	let fpath = collect_fpath app in
	loop_retrieve fpath	

let rec delete_redundant_UF es = 
	(*begin:delete redundant UFs*)
	match es with
		| (Predicate.FunApp ("UF", es')) :: es -> 
			let es = delete_redundant_UF es in es'@es
		| _ -> es (*end*)

(*let rootmet = ref false 	*)

let simply_and (p1, p2) = match (p1, p2) with
	| (Predicate.True, _) -> p2
	| (_, Predicate.True) -> p1
	| _ -> Predicate.And (p1, p2)

(*If a function is a measure => do not instrument it*)
let is_measure se_env funname = 
	(String.compare funname "List.length" = 0) ||
	(Hashtbl.fold (fun _ ms res -> 
		if (res) then res
		else
			List.exists (fun (m, _) -> String.compare funname (Path.name m) = 0) ms
	) se_env.measures false)

let return = Predicate.Atom (Predicate.Var (Frame.returnpath), Predicate.Eq, qual_test_expr)

(* If rflag is set backwalker shoud not go into function application*)		
let rec symb_exe (rflag, rpath) se_env e (effect, pred, preturn) = (*match pred with
	| Predicate.Not (Predicate.True) when rflag -> (effect, pred, preturn)
	| _ -> *)
	(let _ = fprintf err_formatter "---Obtain precondition---%a with effect-----%a@." 
					Predicate.pprint pred Predicate.pprint effect in
	let desc_ty = (e.exp_desc, repr e.exp_type) in
	match desc_ty with (** with its type as repr e.exp_type *)
		| (Texp_apply _, {desc = t}) -> symb_exe_application (rflag, rpath) se_env t e (effect, pred, preturn)
		| (Texp_let (recflag, bindings, body_exp), t) -> symb_exe_let (rflag, rpath) se_env recflag bindings body_exp (effect, pred, preturn)
		 
	  | (Texp_ifthenelse (e1, e2, Some e3), _) -> symb_exe_if (rflag, rpath) se_env e1 e2 e3 (effect, pred, preturn)
	  | (Texp_match (e, pexps, partial), _) -> symb_exe_match (rflag, rpath) se_env e pexps (effect, pred, preturn)
	  | (Texp_sequence (e1, e2), _) -> symb_exe_sequence (rflag, rpath) se_env e1 e2 (effect, pred, preturn)
	  
	  | (Texp_construct (cstrdesc, args), {desc = Tconstr(p, _, _)}) -> 
			let _ = fprintf err_formatter "constructor at location %a with path %s@." 
							(Location.print) e.exp_loc (Path.name p) in
			symb_exe_construct se_env cstrdesc args p (effect, pred, preturn)
	  | (Texp_record (labeled_exprs, None), {desc = (Tconstr _)}) -> symb_exe_record labeled_exprs (effect, pred, preturn)
	  | (Texp_field (expr, label_desc), _) -> symb_exe_field expr label_desc (effect, pred, preturn)
		| (Texp_constant const, {desc = Tconstr(path, [], _)}) -> symb_exe_constant const (effect, pred, preturn)
		| (Texp_array es, _) -> symb_exe_array es (effect, pred, preturn)
		| (Texp_tuple es, _) -> symb_exe_tuple es (effect, pred, preturn)
		| (Texp_ident (id, _), {desc = Tconstr (p, [], _)} ) -> 
			(Predicate.subst (Predicate.Var id) qual_test_var effect, 
			 Predicate.subst (Predicate.Var id) qual_test_var pred,
			 Predicate.subst (Predicate.Var id) qual_test_var preturn)
	  | (Texp_ident (id, _), _) ->
			let effect = Predicate.subst (Predicate.Var id) qual_test_var effect in 
			let pred = Predicate.subst (Predicate.Var id) qual_test_var pred in
			let preturn = Predicate.subst (Predicate.Var id) qual_test_var preturn in
			(effect, de_order (rflag, rpath) se_env pred, preturn)
		| (Texp_function ([(pat, e')], _), t) -> (effect, pred, preturn)
		| (Texp_assertfalse, _) -> (effect, (*Predicate.Or (pred, Predicate.True)*)Predicate.True, preturn)
	  | (Texp_assert e, _) -> symb_exe_assert se_env e (effect, pred, preturn)
	  | (_, t) ->
	    (fprintf err_formatter "@[Warning: Don't know how to symbolically and backwardly execute expression,
	    structure:@ %a@ location:@ %a@]@.@." Printtyp.raw_type_expr t Location.print e.exp_loc; flush stderr;
	    assert false))

and symb_exe_application (rflag, rpath) se_env ety e (effect, pred, preturn) = 
	match e.exp_desc with
		| Texp_apply (_, exps) -> 
			let (fpath, subs, bodyexp, postpred) = retrieve_fun e se_env in 
			let exps = List.map (fun exp -> match exp with
				| (Some e2, _) -> e2
				| _ -> assert false) exps in
			let (effect, pred, preturn) = exe_fun (rflag, rpath) se_env fpath subs exps bodyexp postpred (effect, pred, preturn)	in
			(* preturn tries to be local and simple *)
			(effect, pred, preturn)
			(*match pred with
				| Predicate.Not (Predicate.True) -> 
					(*if (!rootmet) then (effect, pred) (* This is to say that function with false postcondition is not visited *)
					else 
						(rootmet := true; 
						exe_fun se_env fpath subs exps bodyexp postpred (effect, pred)) (* except the main function *)*)
					exe_fun se_env fpath subs exps bodyexp postpred (effect, pred)	
				| _ -> 
					exe_fun se_env fpath subs exps bodyexp postpred (effect, pred)*)
		| _ -> assert false

and check_complete fpath pred = 
	let flag = ref false in
	(ignore (Predicate.map_expr (fun expr -> match expr with
		| Predicate.FunApp (fn, exps) when String.compare fn "UF" = 0 -> 
			let path = Predicate.exp_var (List.hd exps) in
			if (Path.same path fpath) then ((flag := true); expr)
			else expr
		| _ -> expr 
	) pred); !flag)
		
and exe_fun (rflag, rpath) se_env fpath subs exps bodyexp postpred (effect, pred, preturn) = 
	let _ = fprintf err_formatter "Entering function %s with pred %a , effect %a and return%a@." 
					(Path.name fpath) Predicate.pprint pred Predicate.pprint effect Predicate.pprint preturn in
	(** If this is the first function that is ever met, record it as our root *)
	let _ = if (String.compare (!main_function) "" = 0) 
					then (main_function := Path.name fpath) in
	match (fpath, subs, bodyexp, postpred) with
		| (fpath, subs, None, None) -> (** Higher order function *)
			(** Encoding higher order function as uninterpreted *)
			(** Important: Measure function needs to be encoded differently  *)
			let _ = fprintf err_formatter "Higher order function encoding@." in
			let fun_encoding = 
				if (String.compare "List.length" (Path.name fpath) = 0) (* measure function *) then
					Predicate.FunApp ("List.length", List.map expression_to_pexpr exps)
				else if (is_measure se_env (Path.name fpath)) then
					Predicate.FunApp (Path.name fpath, List.map expression_to_pexpr exps)
				else (* ordinary higher order function *)
					Predicate.FunApp ("UF", (Predicate.Var fpath) :: List.map expression_to_pexpr exps) in
			(** Need to simplify the pred due to UF subsititution *)
			let pred = Predicate.subst fun_encoding qual_test_var pred in
			let preturn = Predicate.subst fun_encoding qual_test_var preturn in
			let _ = fprintf err_formatter "substituting the encoding@." in
			let pred = Predicate.map_expr (fun pexpr -> match pexpr with
				| Predicate.FunApp (fn, es) -> 
					if (String.compare fn "UF" = 0) then
						match es with
							| (Predicate.FunApp ("UF", es')) :: es -> 
								Predicate.FunApp ("UF", es'@es)
							| _ -> pexpr
					else pexpr
				| e -> e 
				) pred in
			(effect, de_order (rflag, rpath) se_env pred, preturn)
		| (fpath, subs, None, Some postpred) -> (** Builtin function *)
			let postpred = Predicate.apply_substs subs postpred in 
			(** Update pred based on what is provided by postpred *)
			(match postpred with (** matching for simplying pred *)
				| Predicate.Iff (tagf, postpred) -> 
						(effect, Predicate.map_pred (fun pred -> match pred with
							| (Predicate.Atom (tagf', Predicate.Eq, Predicate.PInt 1)) when tagf' = tagf ->
								postpred
							| (Predicate.Atom (tagf', Predicate.Eq, Predicate.PInt 0)) when tagf' = tagf ->
								Predicate.Not postpred
							| _ -> pred
							) pred, Predicate.map_pred (fun pred -> match pred with
							| (Predicate.Atom (tagf', Predicate.Eq, Predicate.PInt 1)) when tagf' = tagf ->
								postpred
							| (Predicate.Atom (tagf', Predicate.Eq, Predicate.PInt 0)) when tagf' = tagf ->
								Predicate.Not postpred
							| _ -> pred
							)preturn)
				| Predicate.Atom (Predicate.Var v, Predicate.Eq, result) when v = qual_test_var -> 
					(* Can deal with +,-,..., Array.get, Array.length *)
					(Predicate.subst result qual_test_var effect, Predicate.subst result qual_test_var pred,
					Predicate.subst result qual_test_var preturn)
				| Predicate.And (Predicate.Atom (Predicate.Var v, Predicate.Eq, result), _) ->
					(* Can only deal with / *)
					if (String.compare (Path.name fpath) "Pervasives./" = 0) then
						(Predicate.subst result qual_test_var effect, Predicate.subst result qual_test_var pred,
						Predicate.subst result qual_test_var preturn)
					else assert false
				| Predicate.Atom (_, Predicate.Eq, result) -> 
					(* Can deal with Array.set and Array.make *)
					if (String.compare (Path.name fpath) "Array.set" = 0) then
						(simply_and (effect, postpred), pred, preturn)
					else if (String.compare (Path.name fpath) "Array.make" = 0) then
						let temp_expr = Predicate.Var (Path.mk_ident (fresh_ex ())) in
						(Predicate.subst temp_expr qual_test_var effect, 
						Predicate.subst temp_expr qual_test_var (Predicate.And (postpred, pred)),
						Predicate.subst temp_expr qual_test_var preturn)
					else if (String.compare (Path.name fpath) "Pervasives.@" = 0) then
						(*List.length (x @ y) ==> List.length x + List.length y*)
						(*List.hd (x @ y) ==> List.hd x; List.tl (x@y) ==>List.tl y*)
						(effect, Predicate.map_expr (fun expr -> match expr with
							| Predicate.FunApp ("List.length", [e]) when e = qual_test_expr -> result
							(*| expr when expr = qual_test_expr -> assert false*)
							| _ -> (*Fixme*) expr
						) pred, Predicate.map_expr (fun expr -> match expr with
							| Predicate.FunApp ("List.length", [e]) when e = qual_test_expr -> result
							| _ -> (*Fixme*) expr
						) preturn)
					else (*effect, Predicate.And (postpred, pred);*) assert false
				| _ ->
					let pred = Predicate.And (pred, postpred) in
					let temp_expr = Predicate.Var (Path.mk_ident (fresh_ex ())) in
					(effect, Predicate.subst temp_expr qual_test_var pred, preturn))
		| (fpath, subs, Some (recflag, bodyexp), None) -> (** User-defined function *)
			(** If the function tends out to be a measure function, just do an encoding *)
			if (is_measure se_env (Path.name fpath)) then
				let encoding = Predicate.FunApp (Path.name fpath, List.map expression_to_pexpr exps) in
				let pred = Predicate.subst encoding qual_test_var pred in
				let preturn = Predicate.subst encoding qual_test_var preturn in
				let effect = Predicate.subst encoding qual_test_var effect in
				(effect, pred, preturn)	
			(** If the function is only partially used (parameter values are guarded), guard partial_used*)
			else let _ = if (not !(se_env.partial_used)) then match pred with
				| Predicate.Or (Predicate.And (p, _), 
					Predicate.And (Predicate.Not q, Predicate.Not Predicate.True)) when p = q ->
					let _ = Format.fprintf Format.std_formatter "%a@." Predicate.pprint pred in
					if not rflag then (se_env.partial_used := true) 
				| pred -> () in
			(** Do the reverse substitution bu only for user defined full function *)
			let _ = Format.fprintf Format.std_formatter "For function %s@." (Path.name fpath) in
			let reverse_subs = Common.map_partial (fun (path, pexpr) -> 
				let _ = Format.fprintf Format.std_formatter "The sub counter is %d@," 1 in
				match pexpr with
				| Predicate.Var path' -> Some (path', Predicate.Var path)
				| Predicate.PInt _ -> None
				| _ -> (** Fixme? This holds because normalization is set on *) 
					(*
					Printf.fprintf stdout "Ill parameter even nomalized";
					Predicate.pprint_pexpr Format.std_formatter pexpr;
					assert false*) None
				) subs in		
			let pred = Predicate.apply_substs reverse_subs pred in
			let returnpred = Predicate.subst (Predicate.Var ((*Path.mk_ident "r"*)Frame.returnpath)) qual_test_var pred in
			let pred = 
				if (recflag) then (** A previous incomplete version is commented downwards *)
					(*if (not (Hashtbl.mem se_env.badbindings fpath) || (* We are not revisiting it *)not (Path.same fpath rpath)) then 
						if (rflag && (* we will revist it *)Path.same fpath rpath) then (* Deal with recursive procedure unrolling *)*)
					if (not rflag) then 
						let _ = Format.fprintf Format.std_formatter "reach A@." in
						if (List.exists (fun p' -> Path.same p' fpath) (List.tl rpath)) then Predicate.Not Predicate.True
						else if (Path.same fpath (List.hd rpath)) then
							let _ = Format.fprintf Format.std_formatter "reach B@." in
							let _ = Hashtbl.replace se_env.badbindings fpath {pre=(Predicate.Not Predicate.True); post=Predicate.True} in
							(* pred is highly likely to refer to a input parameter; so subst input pred in pred and subst back *)
							let subs' = List.map (fun (p, _) -> 
								let s = (Path.Pident (Ident.create_with_stamp ((Path.name p)^"'") (Path.stamp p))) in
								((p, Predicate.Var s), (s, Predicate.Var p))) subs in
							let (subs'', subs''') = List.split subs' in
							let pred = Predicate.apply_substs subs'' pred in
							let (_, recpred, _) = symb_exe (true, rpath) se_env bodyexp (Predicate.True, pred, Predicate.True) in
							(* 1. Add the inner loop badcondition *)
							let _ = Hashtbl.replace se_env.badbindings fpath {
								pre=relax_list_len(Predicate.apply_substs subs''' recpred); 
								post=relax_list_len(Predicate.apply_substs subs''' (Predicate.And (negate_precondition recpred, returnpred)))} in
							(* As mentioned above, don't forget to subst back *)
							Predicate.apply_substs (subs@subs''') recpred 
						else (* Give an underapproximative condition to recursive procedure *)
							let _ = Format.fprintf Format.std_formatter "reacher C@." in
							let (m_effect, recpred, preturn) = symb_exe (false, fpath::rpath) se_env bodyexp (Predicate.True, pred, return) in
							let recpred = relax_list_len recpred in
							let returnpred = relax_list_len returnpred in
							(* 2. We have two class of badcondition: one is from the inner loop and the other is this outer loop *)
							let _ = 
								if (Hashtbl.mem se_env.badbindings fpath) then
									let record = try Hashtbl.find se_env.badbindings fpath with _ -> assert false in
									Hashtbl.replace se_env.badbindings fpath { 
										pre = (*Predicate.Or (recpred, record.pre)*)recpred;
										post = match returnpred with
											| Predicate.Not Predicate.True -> record.post
											| _ -> Predicate.And (negate_precondition recpred, returnpred)
											(*Predicate.Or (Predicate.And (Predicate.Not recpred, returnpred), record.post)*)
										}
								else Hashtbl.replace se_env.badbindings fpath {pre=recpred; post=Predicate.And (negate_precondition recpred, returnpred)} in
							(*let _ = Hashtbl.replace se_env.badbindings fpath {pre=recpred; post=Predicate.And (Predicate.Not recpred, returnpred)} in*)
							let _ = Hashtbl.replace se_env.effectbindings fpath m_effect in
							let _ = Hashtbl.replace se_env.returnbindings fpath preturn in 
							Predicate.apply_substs subs recpred
					else (* Reuse what is recoreded *)
						let _ = Format.fprintf Format.std_formatter "reacher D@." in
						if (Hashtbl.mem se_env.badbindings fpath) then
							let pred = (Hashtbl.find se_env.badbindings fpath).pre in
							Predicate.apply_substs subs pred
						else Predicate.Not Predicate.True
					(*if (not (Hashtbl.mem se_env.badbindings fpath)) then
						(** do the backward symbolic execution *)
						let _ = Hashtbl.replace se_env.badbindings fpath {pre=(Predicate.Not Predicate.True); post=Predicate.True} in
						let (_, recpred, _) = symb_exe true se_env bodyexp (Predicate.True, pred, Predicate.True) in
						let _ = Hashtbl.replace se_env.badbindings fpath {pre=recpred; post=Predicate.True} (*(Predicate.And (recpred, returnpred))*) in
						(** And do it again *)
						let (m_effect, recpred, preturn) = symb_exe false se_env bodyexp (Predicate.True, pred, return) in
						let _ = Hashtbl.replace se_env.badbindings fpath {pre=recpred; post=Predicate.And (Predicate.Not recpred, returnpred)} in
						let _ = Hashtbl.replace se_env.effectbindings fpath m_effect in
						let _ = Hashtbl.replace se_env.returnbindings fpath preturn in 
						Predicate.apply_substs subs recpred
					else	
						(** just reuse previous bad constraint *)
						let pred = (Hashtbl.find se_env.badbindings fpath).pre in
						Predicate.apply_substs subs pred*)
				else (* Give an RELATIVELY-complete condition to non-recursive procedure *)
					let (m_effect, pred, preturn) = symb_exe (rflag, rpath) se_env bodyexp (Predicate.True, pred, return) in
					let pred = relax_list_len pred in
					let returnpred = relax_list_len returnpred in
					(* We allow context sensitivity for non-recursive procedure only*)
					(* If rflag is set, then the newly inferred condition replaces and discards previous conditions *)
					let _ = 
						if (rflag) then (* Comment this if-condtion will roll back to original implementation *)
							(Hashtbl.replace se_env.badbindings fpath {pre=pred; post=Predicate.And (Predicate.Not pred, returnpred)};
							Hashtbl.replace se_env.effectbindings fpath m_effect;
							Hashtbl.replace se_env.returnbindings fpath preturn)
						(* If there is UF fpath ... in previous record ... *)
						(*else if (check_complete fpath record.pre) then (* Multiple execution for a single function *)
							(Hashtbl.replace se_env.badbindings fpath {pre=pred; post=Predicate.And (Predicate.Not pred, returnpred)};
							Hashtbl.replace se_env.effectbindings fpath m_effect;
							Hashtbl.replace se_env.returnbindings fpath preturn)*)
						else if (Hashtbl.mem se_env.badbindings fpath) then
							let record = Hashtbl.find se_env.badbindings fpath in
							(Hashtbl.replace se_env.badbindings fpath { 
								pre = Predicate.Or (pred, record.pre);
								post = Predicate.Or (Predicate.And (Predicate.Not pred, returnpred), record.post)
								};(*effectbindings and rturnbindings should be there already*))
						else
							(Hashtbl.replace se_env.badbindings fpath {pre=pred; post=Predicate.And (Predicate.Not pred, returnpred)};
							Hashtbl.replace se_env.effectbindings fpath m_effect;
							Hashtbl.replace se_env.returnbindings fpath preturn) in
					Predicate.apply_substs subs pred in
			(** After the substitution, uninterpreted function may be known *)
			(effect, de_order (rflag, rpath) se_env pred, Predicate.True)
		| _ -> (fprintf err_formatter "@[Warning: Internal error. Please report.@]@.@."; assert false)				


(** For each higher order encoding in pred which has been known do the execution  *)
and de_order (rflag, rpath) se_env pred = 
	let _ = fprintf err_formatter "trying de_ording for predicate %a@." 
						Predicate.pprint pred in
	let de_order_entity = ref [] in
	let pred = Predicate.map_expr_from_top (fun pexpr -> match pexpr with
		| Predicate.FunApp (fn, es) -> 
			if (String.compare "UF" fn = 0) then 
				(*begin:delete redundant UFs*)
				let es = delete_redundant_UF es in (*end*)
				let funpath = List.hd es in
				match funpath with
					| Predicate.Var funpath -> 
						let _ = fprintf err_formatter "trying de_ording for fun %s@." (Path.name funpath) in
						if (Hashtbl.mem se_env.funbindings funpath) then
							if (!de_order_entity = []) then (de_order_entity := es; qual_test_expr)
							else if (es = !de_order_entity) then(*A same application appears*) qual_test_expr
							(** Cannot deal this application in this iteration but it will be handled later *)
							else pexpr
						else pexpr
					| Predicate.FunApp (fn, _) when (String.compare fn "List.hd" = 0) -> 
						(* delay the processing until it becames known. Fixme for support me! *) pexpr
					| _ -> (fprintf err_formatter "Cannot understand %a@." Predicate.pprint_pexpr funpath; 
						assert false)
			else pexpr	
		| pexpr -> pexpr
		) pred in 
	match (!de_order_entity) with
		| [] -> let _ = fprintf err_formatter "no need de_ording@." in pred
		| (Predicate.Var funpath) :: funargs -> (* all the function application of funpath shoud be processed *)
			let _ = fprintf err_formatter "need de_ording@." in
			let funfr = Hashtbl.find se_env.funframebindings funpath in
			let rec extract_app_info funfr args subs = 	
				match (funfr, args) with
						| (Frame.Farrow (Some l, f, f',_), e :: es) ->
							let sub = Pattern.bind_pexpr l e in
							extract_app_info f' es (subs@sub)
						| (Frame.Farrow (None, _, _, _), []) -> subs
						| (Frame.Farrow _, []) -> assert false	
						| (_, _::_) -> assert false
						| _ -> subs in
			let subs = extract_app_info funfr funargs [] in
			let bodyexp = Hashtbl.find se_env.funbindings funpath in
			let (_, pred, _) = 
				exe_fun (rflag, rpath) se_env funpath subs [] (Some bodyexp) None 
				(Predicate.True, pred, Predicate.True) in
			de_order (rflag, rpath) se_env pred
		| _ -> assert false

(* The generated condition may need to be relaxed with semantic for list.length ... *)
(* Not beautiful but ... E.g. List.length (List.tl xs) = List.length (xs) - 1 *)	
and relax_list_len pred =
	let rec loop expr n = match expr with
		| Predicate.FunApp (fn, args) when (String.compare fn "List.tl" = 0) -> loop (List.hd args) (n+1)
		| expr -> (n, expr) in	
	Predicate.map_pred_from_bottom (fun pred -> 
		let store = Hashtbl.create 3 in
		let pred = Predicate.map_expr (fun expr -> match expr with
			| Predicate.FunApp (fn, args) when (String.compare fn "List.length" = 0) ->  
				let arg = List.hd args in
				let (n, xs) = loop arg 0 in
				let _ = Hashtbl.replace store ((n, xs)) () in
				if (n > 0) then (
					Predicate.Binop (Predicate.FunApp (fn, [xs]), Predicate.Minus, Predicate.PInt n))
				else expr
			| expr -> expr
		) pred in
		(*let conditions = Hashtbl.fold (fun (n, xs) _ res -> 
			res @ [(Predicate.Atom (Predicate.FunApp ("List.length", [xs]), Predicate.Ge, Predicate.PInt n))]
		) store [] in 
		Predicate.big_and (pred::conditions)*)pred
	) pred
																					
and symb_exe_binding (rflag, rpath) se_env (effect, pred, preturn) (pat, e) = 
	let _ = fprintf err_formatter "symb_pat = %s@." (print_pattern pat) in
	let subs = Pattern.bind_pexpr pat.pat_desc qual_test_expr in 
	let _ = fprintf err_formatter "reach here@." in
	(* subs : (Path.t * Predicate.pexpr) list*)	
	let vars = (Predicate.vars pred) @ (Predicate.vars effect) in 
	if (List.exists (fun (path, _) -> 
		List.exists (fun var -> Path.same var path) vars
		) subs || !Clflags.gen_inv) then
		let _ = fprintf err_formatter "entering the bining@." in
		let effect = Predicate.apply_substs subs effect in
		let pred = Predicate.apply_substs subs pred in
		let preturn = Predicate.apply_substs subs preturn in
		symb_exe (rflag, rpath) se_env e (effect, pred, preturn)
	else 
		(* consider side effect *)
		match e.exp_desc with
			| Texp_apply _ -> 
				(try let appframe = se_env.frames e in
				let m_effect = Frame.eff appframe in
				if (List.exists (fun (path, _) -> 
					List.exists (fun var -> Path.same var path) vars
					) m_effect) then
					let _ = fprintf err_formatter "entering the bining@." in
					symb_exe (rflag, rpath) se_env e (effect, pred, preturn)
				else
					(*Fix me? Anyway enforce entering this binding if side effect found *)
					let _ = fprintf err_formatter "entering the bining@." in
					symb_exe (rflag, rpath) se_env e (effect, pred, preturn)
					(*let _ = fprintf err_formatter "not entering the binding@." in pred*)
				with Not_found -> assert false)
			| _ -> let _ = fprintf err_formatter "not entering the binding@." in (effect, pred, preturn)

and symb_exe_bindings (rflag, rpath) se_env recflag bindings (effect, pred, preturn) = 
	match recflag with
  | Default | Nonrecursive -> List.fold_left (symb_exe_binding (rflag, rpath) se_env) (effect, pred, preturn) bindings
  | Recursive -> (effect, pred, preturn)

and symb_exe_let (rflag, rpath) se_env recflag bindings body_exp (effect, pred, preturn) = 
	let _ = print_string "in symb_let\n" in
	let (effect, pred, preturn) = symb_exe (rflag, rpath) se_env body_exp (effect, pred, preturn) in 
	symb_exe_bindings (rflag, rpath) se_env recflag bindings (effect, pred, preturn)

and symb_exe_if (rflag, rpath) se_env e1 e2 e3 (effect, pred, preturn) = 
	let cond_pred = expression_to_pred se_env e1 in
	let _ = Format.fprintf Format.std_formatter "If-Predicate ----> %a@." Predicate.pprint cond_pred in
	let (effect2, pred2, preturn2) = symb_exe (rflag, rpath) se_env e2 (effect, pred, preturn) in
	let (effect3, pred3, preturn3) = symb_exe (rflag, rpath) se_env e3 (effect, pred, preturn) in
	(Predicate.Or (Predicate.And (cond_pred, effect2), Predicate.And (Predicate.Not cond_pred, effect3)),
	Predicate.Or (Predicate.And (cond_pred, pred2), Predicate.And (Predicate.Not cond_pred, pred3)),
	Predicate.Or (preturn2, preturn3))

and symb_exe_case (rflag, rpath) se_env matche (effect, pred, preturn) (pat, e) = 
	let case_encoding = match pat.pat_desc with
		| Tpat_construct (constructor_desc, patterns) -> (
			match constructor_desc.cstr_res.desc with 
				| Tconstr(p, args, _) when Path.same p Predef.path_list -> (* We support list *) 			
					List.flatten (Misc.mapi (fun pat i -> match pat.pat_desc with (* Fixme. This code is not general *)
						| Tpat_var id -> (* Upon SSA, constructor argument should be a var *) 
							let _ = Format.fprintf Format.std_formatter "My dealing with %s@." (Ident.name id) in
							if (i = 0) then [(Path.Pident id, Predicate.FunApp ("List.hd", [matche]))]
							else if (i = 1) then [(Path.Pident id, Predicate.FunApp ("List.tl", [matche]))]
							else assert false
						| Tpat_construct (_, patterns) ->
								Misc.mapi (fun pat i -> match pat.pat_desc with
									| Tpat_var id ->
										if (i = 0) then (Path.Pident id, Predicate.FunApp ("List.hd", [Predicate.FunApp ("List.tl", [matche])]))
										else if (i = 1) then (Path.Pident id, Predicate.FunApp ("List.tl", [Predicate.FunApp ("List.tl", [matche])]))
										else assert false
									| _ -> assert false) patterns
						| _ -> assert false) patterns)
				| Tconstr(p, _, _) when (Hashtbl.mem se_env.measures p) -> 
					(*** added for datatype ---> ***)
					(*Format.fprintf Format.std_formatter "User-defined data structure %s@." (Path.name p); 
					assert (Hashtbl.mem se_env.measures p);
					raise Datatype*) ( [])
				| _ -> assert false)
		| pdesc -> Pattern.bind_pexpr pat.pat_desc matche in

	(* Support a simle sort: List.length *)
	let listsort = match pat.pat_desc with
		| Tpat_construct (constructor_desc, patterns) -> (
			match constructor_desc.cstr_res.desc with
				| Tconstr(p, args, _) when Path.same p Predef.path_list ->
					if (List.length patterns = 0) then 
						[Predicate.Atom (Predicate.FunApp ("List.length", [matche]), Predicate.Eq, Predicate.PInt 0)]
					else if (List.length patterns = 2) then 
						let tl = List.nth patterns 1 in
						match tl.pat_desc with
							| Tpat_var _ -> [Predicate.Atom (Predicate.FunApp ("List.length", [matche]), Predicate.Gt, Predicate.PInt 0)] 
							| Tpat_construct (_, patterns) -> 
								if (List.length patterns = 0) then [Predicate.Atom (Predicate.FunApp ("List.length", [matche]), Predicate.Eq, Predicate.PInt 1)] 
								else if (List.length patterns >= 2) then
								[Predicate.Atom (Predicate.FunApp ("List.length", [matche]), 
								Predicate.Gt, Predicate.PInt 1)] 
								else assert false
							| _ -> assert false
					else assert false 
				(*** added for datatype ---> ***)
				| Tconstr(path, args, _) when (Hashtbl.mem se_env.measures path) -> 
					let cstrname = constructor_desc.cstr_name in
					let args = List.map (fun pattern -> match pattern.pat_desc with
						| Tpat_var id -> Predicate.Var (Path.Pident id) | _ -> assert false
						) patterns in
					if (Hashtbl.mem se_env.measure_defs (path, cstrname)) then		
						let measures = Hashtbl.find se_env.measure_defs (path, cstrname) in
						List.fold_left (fun pred (measure, cstrargs, cstrdef) -> 
							let substs = List.map2 (fun cstrarg arg -> (cstrarg, arg)) cstrargs args in
							let substs = (Frame.returnpath, Predicate.FunApp (measure, [matche]))::substs in
							let cstrdef = Predicate.apply_substs substs cstrdef in
							pred@[cstrdef]		
						) [] measures		
					else []			
				| tpat -> [] )
		| pdes -> [] in
	let (effect, pred, preturn) = symb_exe (rflag, rpath) se_env e (effect, pred, preturn) in
	let effect = Predicate.apply_substs case_encoding effect in
	let pred = Predicate.apply_substs case_encoding pred in 
	let preturn = Predicate.apply_substs case_encoding preturn in
	let _ = Format.fprintf Format.std_formatter "case pred = %a@." Predicate.pprint (Predicate.big_and (pred::listsort)) in
	(effect, Predicate.big_and (pred::listsort), Predicate.big_and (preturn::listsort))	
			
and symb_exe_match (rflag, rpath) se_env e pexps (effect, pred, preturn) = 	
	let cases_encoding = List.map (symb_exe_case (rflag, rpath) se_env (expression_to_pexpr e) (effect, pred, preturn)) pexps in
	let (effects, preds, preturns) = Misc.split3 cases_encoding in
	(Predicate.big_or effects, Predicate.big_or preds, Predicate.big_or preturns)			
				
and symb_exe_sequence (rflag, rpath) se_env e1 e2 (effect, pred, preturn) = 
	let (effect, pred, preturn) = symb_exe (rflag, rpath) se_env e2 (effect, pred, preturn) in 
	symb_exe (rflag, rpath) se_env e1 (effect, pred, preturn) 

and symb_exe_construct se_env cstrdesc args path (effect, pred, preturn) = 
	(*(fprintf err_formatter "@[Warning: Dont support constructor in learning module@]@.";
	assert false) *)
	if (Path.same path Predef.path_unit) then
		(Predicate.subst (Predicate.Var path) qual_test_var effect,
		Predicate.subst (Predicate.Var path) qual_test_var pred,
		Predicate.subst (Predicate.Var path) qual_test_var preturn)
	else if (Path.same path Predef.path_list) then	
		if (List.length args = 0) then 
			(* Drop every single predicate that is around "List.hd" and "List.tl" *)
			(* However, List.length [] --> 0 *)
			let preds = Predicate.split pred in
			let preds = List.filter (fun pred -> 
				let fs = Predicate.get_all_funs pred in
				List.for_all (fun f -> match f with
					| Predicate.FunApp (fn, args) when 
						(String.compare fn "List.hd" = 0 || String.compare fn "List.tl" = 0) && (List.hd args = qual_test_expr) -> false
					| f -> true) fs) preds in
			let preds = List.map (fun pred -> Predicate.map_expr (fun expr -> match expr with
				| Predicate.FunApp (fn, args) when (String.compare fn "List.length" = 0 && (List.hd args = qual_test_expr)) -> Predicate.PInt 0
				| expr -> expr) pred) preds in
			if (List.length preds = 0) then (effect, Predicate.Not Predicate.True, preturn)
			else (effect, Predicate.big_and preds, preturn)
		else
		(* Basic strategy: List.hd Kappa --> List.hd args; List.tl Kappa --> List.snd args; List.length Kappa --> List.length (List.snd args) + 1 *)
		let args = List.map (expression_to_pexpr) args in
		let _ = List.iter (fun arg -> Format.fprintf Format.std_formatter "constructor arg = %a@." Predicate.pprint_pexpr arg) args in
		let _ = assert (List.length args = 2) in
		(Predicate.map_expr (fun expr -> match expr with
			| Predicate.FunApp ("List.hd", fargs) when (List.hd fargs = qual_test_expr) -> List.hd args
			| Predicate.FunApp ("List.tl", fargs) when (List.hd fargs = qual_test_expr)-> List.nth args 1
			| Predicate.FunApp ("List.length", fargs) when (List.hd fargs = qual_test_expr) -> 
				Predicate.Binop (Predicate.FunApp ("List.length", [List.nth args 1]), Predicate.Plus, Predicate.PInt 1)
			| expr -> expr
		) effect,
		Predicate.map_expr (fun expr -> match expr with
			| Predicate.FunApp ("List.hd", fargs) when (List.hd fargs = qual_test_expr) -> List.hd args
			| Predicate.FunApp ("List.tl", fargs) when (List.hd fargs = qual_test_expr) -> List.nth args 1
			| Predicate.FunApp ("List.length", fargs) when (List.hd fargs = qual_test_expr) -> 
				Predicate.Binop (Predicate.FunApp ("List.length", [List.nth args 1]), Predicate.Plus, Predicate.PInt 1)
			| expr -> expr
		) pred,
		Predicate.map_expr (fun expr -> match expr with
			| Predicate.FunApp ("List.hd", fargs) when (List.hd fargs = qual_test_expr) -> List.hd args
			| Predicate.FunApp ("List.tl", fargs) when (List.hd fargs = qual_test_expr)-> List.nth args 1
			| Predicate.FunApp ("List.length", fargs) when (List.hd fargs = qual_test_expr) -> 
				Predicate.Binop (Predicate.FunApp ("List.length", [List.nth args 1]), Predicate.Plus, Predicate.PInt 1)
			| expr -> expr
		) preturn)
	else (*(effect, pred, preturn) Fixme. The support to user-defined data structure is limited *)
		(*** added for datatype ---> ***)
		if (Hashtbl.mem se_env.measures path) then (* User defined data type *)
			let cstrname = cstrdesc.cstr_name in
			let args = List.map (expression_to_pexpr) args in
			if (Hashtbl.mem se_env.measure_defs (path, cstrname)) then
				let measures = Hashtbl.find se_env.measure_defs (path, cstrname) in
				(effect, List.fold_left (fun pred (measure, cstrargs, cstrdef) ->
					let substs = List.map2 (fun cstrarg arg -> (cstrarg, arg)) cstrargs args in
					let cstrdef = Predicate.apply_substs substs cstrdef in
					(* [\eplision <e> / m v] *)
					match cstrdef with
						| (Predicate.Atom (Predicate.Var v, Predicate.Eq, cstrdef)) when (Path.same v Frame.returnpath) ->
							Predicate.map_expr (fun expr -> match expr with
								| Predicate.FunApp (fn, fargs) when (String.compare measure fn = 0 && List.hd fargs = qual_test_expr) -> cstrdef
								| expr -> expr
								) pred
						| (Predicate.Or (Predicate.And (p1, (Predicate.Atom (Predicate.Var v1, Predicate.Eq, cstrdef1))), 
														 Predicate.And (p2, (Predicate.Atom (Predicate.Var v2, Predicate.Eq, cstrdef2))))) 
							when (Path.same v1 Frame.returnpath && Path.same v2 Frame.returnpath) ->
							let flag = ref false in
							let q1 = Predicate.map_expr (fun expr -> match expr with
								| Predicate.FunApp (fn, fargs) when (String.compare measure fn = 0 && List.hd fargs = qual_test_expr) -> (flag := true; cstrdef1)
								| expr -> expr
							) pred in
							let q2 = Predicate.map_expr (fun expr -> match expr with
								| Predicate.FunApp (fn, fargs) when (String.compare measure fn = 0 && List.hd fargs = qual_test_expr) -> (flag := true; cstrdef2)
								| expr -> expr
							) pred in
							if (!flag) then Predicate.Or (Predicate.And (p1, q1), Predicate.And (p2, q2)) else pred
						| def -> assert false
				) pred measures, preturn)
			else (effect, pred, preturn)
		else assert false
		(*Format.fprintf Format.std_formatter "User-defined data structure %s@." (Path.name path); 
					assert (Hashtbl.mem se_env.measures path);
					raise Datatype*)

and symb_exe_record labeled_exprs (effect, pred, preturn) = 
	let record_encoding = 
		List.map (fun (label, expr) -> 
			(Predicate.Field (label.lbl_name, qual_test_expr), expression_to_pexpr expr)
			(*Predicate.Atom (expression_to_pexpr expr, Predicate.Eq, 
				Predicate.Field (label.lbl_name, qual_test_var))*)
			) labeled_exprs in
	(Predicate.map_expr (fun expr -> 
		(try snd (List.find (fun (expr', _) -> (expr = expr')) record_encoding)
		with _ -> expr)
	) effect,		
	Predicate.map_expr (fun expr -> 
		(try snd (List.find (fun (expr', _) -> (expr = expr')) record_encoding)
		with _ -> expr)
	) pred,
	Predicate.map_expr (fun expr ->
		(try snd (List.find (fun (expr', _) -> (expr = expr')) record_encoding)
		with _ -> expr)	
	) preturn)		
			
and symb_exe_field expr label_desc (effect, pred, preturn) = 
	let field_name = label_desc.lbl_name in
	(Predicate.subst (Predicate.Field (field_name, expression_to_pexpr expr)) qual_test_var effect,
	Predicate.subst (Predicate.Field (field_name, expression_to_pexpr expr)) qual_test_var pred,
	Predicate.subst (Predicate.Field (field_name, expression_to_pexpr expr)) qual_test_var preturn)

and symb_exe_constant const (effect, pred, preturn) =
	match const with
		| Const_int n -> 
			(Predicate.subst (Predicate.PInt n) qual_test_var effect, 
			Predicate.subst (Predicate.PInt n) qual_test_var pred,
			Predicate.subst (Predicate.PInt n) qual_test_var preturn)
  	| _ -> (effect, pred, preturn)

and symb_exe_array es (effect, pred, preturn) = 
	(fprintf err_formatter "@[Warning: Dont support array construction in learning module@]@.";
	assert false)

and symb_exe_tuple es (effect, pred, preturn) = 
	let tuple_encoding = 
		Misc.mapi (fun e i -> (Predicate.Proj (i, qual_test_expr), expression_to_pexpr e)
			(*Predicate.Atom (expression_to_pexpr e, Predicate.Eq, 
				Predicate.Proj (i, temp_expr))*)) es in
	(Predicate.map_expr (fun expr -> 
		(try snd (List.find (fun (expr', _) -> (expr = expr')) tuple_encoding)
		with _ -> expr)
	) effect,		
	Predicate.map_expr (fun expr -> 
		(try snd (List.find (fun (expr', _) -> (expr = expr')) tuple_encoding)
		with _ -> expr)
	) pred,
	Predicate.map_expr (fun expr -> 
		(try snd (List.find (fun (expr', _) -> (expr = expr')) tuple_encoding)
		with _ -> expr)
	) preturn)
	
and symb_exe_assert se_env e (effect, pred, preturn) = 
	let _ = print_string "in symb_assert\n" in
	(effect, Predicate.Or (pred, Predicate.Not (expression_to_pred se_env e)), 
		Predicate.And (expression_to_pred se_env e, preturn))
		
let dummypath = Path.mk_ident ""		
let symbexe_match se_env e = match e.exp_desc with
	| Texp_match (e, pexps, partial) -> 
		List.map (fun (pat, e) -> 
			let (name, args) = match pat.pat_desc with
				| Tpat_construct (constructor_desc, patterns) ->
					(constructor_desc.cstr_name, List.map (fun pattern -> 
						match pattern.pat_desc with Tpat_var id -> Path.Pident id | _ -> assert false
					) patterns)
				| _ -> assert false in
			let (_,pre,preturn) = 
				(*let pred = Predicate.Atom (Backwalker.qual_test_expr, Predicate.Eq, Predicate.PInt 0) in*)
				symb_exe (false, [dummypath]) se_env e ((Predicate.True), (*pred*)return, return) in
			(name, args, (*preturn*)pre)
		) pexps
	| _ -> assert false				
		
let symbexe_measure se_env env =
	let measures = se_env.measures in
	Hashtbl.iter (fun typath ms -> List.iter (fun (m, _) -> 
		let _ = Format.fprintf Format.std_formatter "working for measure %s@." (Path.name m) in
		let (_, body) = Hashtbl.find se_env.funbindings m in
		let body = get_funbody body in
		let measure_defs = symbexe_match se_env body in
		List.iter (fun measure_def ->
			match measure_def with (name, args, preturn) ->
				(Format.fprintf Format.std_formatter "constructor name=%s@." name;
				List.iter (fun arg -> Format.fprintf Format.std_formatter "arg = %s " (Path.name arg)) args;
				Format.fprintf Format.std_formatter "body = %a@." Predicate.pprint preturn;
				if (Hashtbl.mem se_env.measure_defs (typath, name)) then
					Hashtbl.replace se_env.measure_defs (typath, name) 
						((Path.name m, args, preturn)::(Hashtbl.find se_env.measure_defs (typath, name)))
				else Hashtbl.replace se_env.measure_defs (typath, name) [(Path.name m, args, preturn)]) 
		) measure_defs
	) ms) measures		
	

(* We assume all computationa are enclosed into a main function *)
let symb_exe_structure se_env str =
	let dummypath = [Path.mk_ident ""] in
	let evalpath = Path.mk_ident "" in
	(** only find bindings *)
	let items = List.fold_left (fun items it -> match it with
		| (Tstr_value (recflag, bindings)) -> 
			(match (snd ((List.hd bindings))).exp_desc with
				| Texp_function ([(pat, e')], _) ->
					(true, get_pattern (fst (List.hd bindings)), (get_funbody (snd ((List.hd bindings)))))::items
				| _ -> (false, get_pattern (fst (List.hd bindings)), (get_funbody (snd ((List.hd bindings)))))::items
			)
		| (Tstr_eval e) -> (false, evalpath, e) :: items
		| _ -> items
		) [] str in
	(*let _ = List.iter (fun (flag, pattern, _) -> 
		Format.fprintf Format.std_formatter "Funtion pattern = %s@." (Path.name pattern)
	) items in*)
	let rec loop items = 	
		let items = (** check if any function is still not visited, then go for it *)
			List.filter (fun (flag, pattern, e) -> 
				flag && not (Hashtbl.mem se_env.badbindings pattern) && not (Path.same pattern evalpath) 
			) items in
		if (List.length items > 0) then
			let (_, fpath, e) = List.hd items in
			let oldpath = !curr_function_path in
			let _ = curr_function_path := fpath in
			let (effect, pred, return) = symb_exe (false, dummypath) se_env e ((Predicate.True), (Predicate.Not Predicate.True), (Predicate.True)) in
			let _ = curr_function_path := oldpath in
			((Hashtbl.replace se_env.badbindings fpath {pre=pred; post=Predicate.And (Predicate.Not pred, (Predicate.Not Predicate.True))};
			Hashtbl.replace se_env.effectbindings fpath effect;
			Hashtbl.replace se_env.returnbindings fpath return); 		
			loop (List.tl items))
		else [] in
	if (List.length items > 0) then
		(** deal with the test driver *)
		let (_, pattern, e) = List.hd items in
		let _ = symb_exe (false, dummypath) se_env e ((Predicate.True), (Predicate.Not Predicate.True), (Predicate.True)) in
		let items = List.tl items in
		(** deal with the other unvisited functions *)
		ignore (loop items)
	else assert false		

(* Return indicates if new tests are derivable *)	
let drive_new_test env se_env preinvs str = 
	if (Hashtbl.length preinvs > 0) then
		let _ = itercall := true in
		let _ = Hashtbl.iter (fun a b -> Hashtbl.replace prefails a b) preinvs in
		let _ = symb_exe_structure se_env str in
		let _ = itercall := false in
		let _ = Hashtbl.clear prefails in
		let _ = Hashtbl.clear conditionals in
		(* Find the invariant for the main function *)
		let fcost = Hashtbl.find (se_env.badbindings) !main_function_path in
		let _ = assert (String.compare (Path.name !main_function_path) "main" = 0) in
		(* Ask the solver to provide a new test for main *)
		let solution = TheoremProver.model fcost.pre 1 in
		if (solution = []) then (false, "")
		else
			let solution = List.hd solution in
			let funframe = Hashtbl.find (se_env.funframebindings) !main_function_path in
			let allbindings = Frame.get_fun_bindings env funframe in
			try 
				let line = List.fold_left (fun res (p, fr) -> 
					if (Path.same p Frame.returnpath) then res
					else res ^ " " ^ (Pervasives.string_of_int (Hashtbl.find solution p))	
				) "" allbindings 
				in (true, line)
			with _ -> (Format.fprintf Format.std_formatter "Main function inputs are ill-typed@."; assert false)
	else (false, "")
	
(* Analyze the program text to find constants that atomic predicates should use *)	
let gen_atomics () = 
	let result = Common.remove_duplicates (Hashtbl.fold (fun _ conditionals res -> (* Find a relation with constants *)
		List.fold_left (fun res conditional -> 
			(*let _ = Format.fprintf Format.std_formatter "see conditional %a@." Predicate.pprint conditional in*)
			let newcons = ref [] in
			let _ = Predicate.map_pred (fun pred -> match pred with
				| Predicate.Atom (_, Predicate.Eq, Predicate.PInt 0)
				| Predicate.Atom (Predicate.PInt 0, Predicate.Eq, _)
				| Predicate.Atom (_, Predicate.Ge, Predicate.PInt 0) 
				| Predicate.Atom (Predicate.PInt 0, Predicate.Le, _) -> 
					(newcons := (!newcons) @ [(Predicate.Ge, 0)]; pred)
				| Predicate.Atom (_, Predicate.Gt, Predicate.PInt 0) 
				| Predicate.Atom (Predicate.PInt 0, Predicate.Lt, _) -> 
					(newcons := (!newcons) @ [(Predicate.Le, 0)]; pred)
				| Predicate.Atom (_, Predicate.Le, Predicate.PInt 0) 
				| Predicate.Atom (Predicate.PInt 0, Predicate.Ge, _) -> 
					(newcons := (!newcons) @ [(Predicate.Le, 0)]; pred)
				| Predicate.Atom (_, Predicate.Lt, Predicate.PInt 0) 
				| Predicate.Atom (Predicate.PInt 0, Predicate.Gt, _)->
					(newcons := (!newcons) @ [(Predicate.Ge, 0)]; pred)
				| _ -> pred
			) conditional	in
			res @ (!newcons)
		) res conditionals
	) conditionals []) in
	result
	
(** Return specific integers that might interest invariant generator *)
let get_constants fpath = 
	(*let _ = Hashtbl.iter (fun path conds -> 
		Format.fprintf Format.std_formatter "function path = %s@." (Path.name path);
		List.iter (fun cond -> Format.fprintf Format.std_formatter "cond = %a@." Predicate.pprint cond) conds;
		Format.fprintf Format.std_formatter "completes@."
		) conditionals in*)
	if (Hashtbl.mem conditionals fpath) then
		let conditions = Hashtbl.find conditionals fpath in
		let constants = List.fold_left (fun res condition -> 
			res @ (Predicate.ints condition)) [] conditions in
		let constants = Common.remove_duplicates (0::constants) in
		(*let _ = Format.fprintf Format.std_formatter "constants in fun: %s@." (Path.name fpath) in
		let _ = List.iter (fun c -> Format.fprintf Format.std_formatter "%d " c) constants in
		let _ = Format.fprintf Format.std_formatter "@." in*)
		constants
	else []