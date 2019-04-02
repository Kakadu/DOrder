#!/usr/bin/env bash 
set +x
rm *.cmi
make
ln -s /home/kakadu/.opam/3.12.1/lib/ocaml/bigarray.cmi
ln -s /home/kakadu/.opam/3.12.1/lib/ocaml/array.cmi
ln -s /home/kakadu/.opam/3.12.1/lib/ocaml/pervasives.cmi 
