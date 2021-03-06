(***********************************************************************)
(*                                                                     *)
(*                           Objective Caml                            *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id: clflags.ml 9464 2009-12-09 09:17:12Z weis $ *)

(* Command-line parameters *)

let objfiles = ref ([] : string list)   (* .cmo and .cma files *)
and ccobjs = ref ([] : string list)     (* .o, .a, .so and -cclib -lxxx *)
and dllibs = ref ([] : string list)     (* .so and -dllib -lxxx *)

let compile_only = ref false            (* -c *)
and output_name = ref (None : string option) (* -o *)
and include_dirs = ref ([] : string list)(* -I *)
and no_std_include = ref false          (* -nostdlib *)
and print_types = ref false             (* -i *)
and make_archive = ref false            (* -a *)
and debug = ref false                   (* -g *)
and fast = ref false                    (* -unsafe *)
and link_everything = ref false         (* -linkall *)
and custom_runtime = ref false          (* -custom *)
and output_c_object = ref false         (* -output-obj *)
and ccopts = ref ([] : string list)     (* -ccopt *)
and classic = ref false                 (* -nolabels *)
and nopervasives = ref false            (* -nopervasives *)
and preprocessor = ref(None : string option) (* -pp *)
let annotations = ref false             (* -annot *)
and use_threads = ref false             (* -thread *)
and use_vmthreads = ref false           (* -vmthread *)
and noassert = ref false                (* -noassert *)
and verbose = ref false                 (* -verbose *)
and noprompt = ref false                (* -noprompt *)
and init_file = ref (None : string option)   (* -init *)
and use_prims = ref ""                  (* -use-prims ... *)
and use_runtime = ref ""                (* -use-runtime ... *)
and principal = ref false               (* -principal *)
and recursive_types = ref false         (* -rectypes *)
and strict_sequence = ref false         (* -strict-sequence *)
and applicative_functors = ref true     (* -no-app-funct *)
and make_runtime = ref false            (* -make_runtime *)
and gprofile = ref false                (* -p *)
and c_compiler = ref (None: string option) (* -cc *)
and no_auto_link = ref false            (* -noautolink *)
and dllpaths = ref ([] : string list)   (* -dllpath *)
and make_package = ref false            (* -pack *)
and for_package = ref (None: string option) (* -for-pack *)
let dump_parsetree = ref false          (* -dparsetree *)
and dump_rawlambda = ref false          (* -drawlambda *)
and dump_lambda = ref false             (* -dlambda *)
and dump_instr = ref false              (* -dinstr *)


and dump_constraints = ref false        (* -dconstr *)
and dump_qexprs = ref false             (* -dqexprs *)
and dump_qualifs = ref false            (* -dqualifs *)
and dump_queries = ref false            (* -dqueries *)
and dump_frames = ref false             (* -dframes *)
and log_queries = ref false             (* -lqueries *)
and check_queries = ref false            (* -cqueries *)
and brief_quals = ref false              (* -bquals *)
and no_simple = ref false               (* -no-simple *)
and verify_simple = ref false           (* -verify-simple *)
and less_qualifs = ref false            (* -lqualifs *)
and no_anormal = ref false            (* -anormal *)
and use_list = ref false                (* -wlist *)
and kill_simplify = ref false           (* -ksimpl *)
and always_use_backup_prover = ref false (* -defprover *)
and use_qprover = ref false             (* -qprover *)
and qpdump = ref false                  (* -qpdump *)
and cache_queries = ref false           (* -cqueries *)
and psimple = ref true                  (* -psimple *)
and no_simple_subs = ref false          (* -no-simple-subs *)
and builtins_file = ref None              (* -use_builtins *)
and simpguard = ref true                (* simplify guard *)
and no_effect = ref true                (* side effect *)
and gen_inv = ref false                 (* generate invariant *)
and preservation = ref false            (* generate array preservation invariant *)

let keep_asm_file = ref false           (* -S *)
let optimize_for_speed = ref true       (* -compact *)

and dump_cmm = ref false                (* -dcmm *)
let dump_selection = ref false          (* -dsel *)
let dump_live = ref false               (* -dlive *)
let dump_spill = ref false              (* -dspill *)
let dump_split = ref false              (* -dsplit *)
let dump_scheduling = ref false         (* -dscheduling *)
let dump_interf = ref false             (* -dinterf *)
let dump_prefer = ref false             (* -dprefer *)
let dump_regalloc = ref false           (* -dalloc *)
let dump_reload = ref false             (* -dreload *)
let dump_scheduling = ref false         (* -dscheduling *)
let dump_linear = ref false             (* -dlinear *)
let keep_startup_file = ref false       (* -dstartup *)
let dump_combine = ref false            (* -dcombine *)

let native_code = ref false             (* set to true under ocamlopt *)
let inline_threshold = ref 10

let dont_write_files = ref false        (* set to true under ocamldoc *)

let std_include_flag prefix =
  if !no_std_include then ""
  else (prefix ^ (Filename.quote Config.standard_library))
;;

let std_include_dir () =
  if !no_std_include then [] else [Config.standard_library]
;;

let shared = ref false (* -shared *)
let dlcode = ref true (* not -nodynlink *)

let hoflag = ref false
let no_hoflag = ref false
let reachability = ref false
let dump_specs = ref false