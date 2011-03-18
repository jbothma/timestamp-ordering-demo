.SUFFIXES: .erl .beam

.erl.beam:
	erlc -W $<

MODS = client parser window server

all: compile

compile: ${MODS:%=%.beam}

clean:
	rm -rf *.beam erl_crash.dump