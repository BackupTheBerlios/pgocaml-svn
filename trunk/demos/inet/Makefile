PKG = unix,pgocaml

all: inet

inet: inet.cmo
	ocamlfind ocamlc -package $(PKG) -linkpkg -o $@ $<

inet.cmo: inet.ml
	ocamlfind ocamlc -package $(PKG),pgocaml.syntax -syntax camlp4o -c $<

iface: inet.ml
	ocamlfind ocamlc -package $(PKG),pgocaml.syntax -syntax camlp4o -i $<

clean:
	rm *.cm[io]

