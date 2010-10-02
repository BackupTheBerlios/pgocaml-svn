PKG = unix,pgocaml

all: arrays

arrays: arrays.cmo
	ocamlfind ocamlc -package $(PKG) -linkpkg -o $@ $<

arrays.cmo: arrays.ml
	ocamlfind ocamlc -package $(PKG),pgocaml.syntax -syntax camlp4o -c $<

iface: arrays.ml
	ocamlfind ocamlc -package $(PKG),pgocaml.syntax -syntax camlp4o -i $<

clean:
	rm *.cm[io]

