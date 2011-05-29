PKG = unix,extlib,pcre,calendar,csv,pgocaml

all: test

test: test.cmo
	ocamlfind ocamlc -package $(PKG) -linkpkg -o $@ $<

test.cmo: test.ml
	ocamlfind ocamlc -package $(PKG),pgocaml.syntax -syntax camlp4o -c $<

iface: test.ml
	ocamlfind ocamlc -package $(PKG),pgocaml.syntax -syntax camlp4o -i $<

clean:
	rm -f test.cm[io] test
