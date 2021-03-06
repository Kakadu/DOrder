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

(* $Id: path.mli 5640 2003-07-01 13:05:43Z xleroy $ *)

(* Access paths *)

type t =
    Pident of Ident.t
  | Pdot of t * string * int
  | Papply of t * t

val mk_ident: string -> t
val unique_name: t -> string
val ident_name: t -> string option
val ident_name_crash: t -> string

val same: t -> t -> bool
val isfree: Ident.t -> t -> bool
val binding_time: t -> int

val nopos: int

val name: t -> string
val head: t -> Ident.t

(* This is a very dangerous extension for the internal use of Asolve only. *)
(*  He Zhu committed this code (use before careful consideration please) *)
val stamp: t -> int
