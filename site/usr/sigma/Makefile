all:
	$(CC) -o sigma sigma.c

clean:
	rm sigma

install: all
	mkdir -p /usr/local/bin
	install -m0755 sigma /usr/local/bin/

uninstall:
	rm /usr/local/bin/sigma
