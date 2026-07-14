all: liboracle.so libclient.so liboracle-bak.so libclient-bak.so
clean:
	rm -f *.o *.so

CC=gcc -g -Wall

liboracle.so: liboracle.o
	$(CC) -Wl,--version-script,liboracle.map -Wl,-soname,liboracle.so -shared -o $@ $^

libclient.so: liboracle.so client.c
	$(CC) -Wl,-rpath='$$ORIGIN',-z,origin -Wl,-soname,libclient.so -shared $^ -L. -loracle -o $@

%-bak.so: %.so
	cp $< $@

.PHONY: all clean
